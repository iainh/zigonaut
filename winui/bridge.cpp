#include "pch.h"
#include "App.xaml.h"
#include "bridge.h"
#include <MddBootstrap.h>
#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Content.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/base.h>
#include <Microsoft.UI.Dispatching.Interop.h>
#include <winrt/Microsoft.UI.Interop.h>

using namespace winrt;
using namespace Microsoft::UI;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Hosting;

namespace {
constexpr uint32_t command_new_powershell = 1;
constexpr uint32_t command_new_wsl = 2;
constexpr uint32_t command_close = 3;
constexpr uint32_t command_select = 4;

HRESULT reportFailure(wchar_t const* operation, HRESULT result) noexcept {
    wchar_t message[160]{};
    swprintf_s(message, L"Zigonaut WinUI: %s failed with HRESULT 0x%08X\n", operation, static_cast<unsigned>(result));
    OutputDebugStringW(message);
    return result;
}

HRESULT reportCurrentException(wchar_t const* operation) noexcept {
    try {
        throw;
    } catch (hresult_error const& error) {
        return reportFailure(operation, error.code());
    } catch (...) {
        return reportFailure(operation, E_FAIL);
    }
}

template <typename Action>
bool cleanup(wchar_t const* operation, Action&& action, HRESULT& result) noexcept {
    try {
        action();
        return true;
    } catch (...) {
        auto const failure = reportCurrentException(operation);
        if (SUCCEEDED(result)) result = failure;
        return false;
    }
}

struct Bridge {
    DWORD thread_id = GetCurrentThreadId();
    zigonaut_chrome_command callback{};
    void* context{};
    Microsoft::UI::Dispatching::DispatcherQueueController dispatcher{nullptr};
    Application application{nullptr};
    DesktopWindowXamlSource source{nullptr};
    TabView tabs{nullptr};
    MenuFlyout new_tab_menu{nullptr};
    MenuFlyoutItem powershell_item{nullptr};
    MenuFlyoutItem wsl_item{nullptr};
    event_token add_tab_token{};
    event_token selection_token{};
    event_token close_tab_token{};
    event_token powershell_token{};
    event_token wsl_token{};
    bool add_tab_handler_attached = true;
    bool selection_handler_attached = true;
    bool close_tab_handler_attached = true;
    bool powershell_handler_attached = false;
    bool wsl_handler_attached = false;
    bool handlers_detached = false;
    bool updating = false;
    bool closed = false;

    Bridge(HWND parent, zigonaut_chrome_command cb, void* ctx,
           Microsoft::UI::Dispatching::DispatcherQueueController const& controller,
           Application const& app)
        : callback(cb), context(ctx), dispatcher(controller), application(app) {
        source = DesktopWindowXamlSource{};
        source.Initialize(Microsoft::UI::GetWindowIdFromWindow(parent));
        tabs = TabView{};

        tabs.Margin(Thickness{8, 4, 8, 0});
        tabs.IsAddTabButtonVisible(true);
        tabs.TabWidthMode(TabViewWidthMode::SizeToContent);
        tabs.CloseButtonOverlayMode(TabViewCloseButtonOverlayMode::Auto);
        add_tab_token = tabs.AddTabButtonClick([this](auto&&, auto&&) { showNewTabMenu(); });
        selection_token = tabs.SelectionChanged([this](auto&&, auto&&) {
            if (!updating && tabs.SelectedIndex() >= 0) {
                notify(command_select, static_cast<uint32_t>(tabs.SelectedIndex()));
            }
        });
        close_tab_token = tabs.TabCloseRequested([this](TabView const& sender, TabViewTabCloseRequestedEventArgs const& args) {
            uint32_t index = 0;
            if (sender.TabItems().IndexOf(args.Item(), index)) notify(command_close, index);
        });
        source.Content(tabs);
    }

    void notify(uint32_t command, uint32_t argument) const {
        if (!closed && callback) callback(context, command, argument);
    }

    void update(uint8_t const* kinds, uint32_t count, int32_t active) {
        updating = true;
        struct ResetUpdating {
            bool& value;
            ~ResetUpdating() { value = false; }
        } reset{updating};
        auto items = tabs.TabItems();
        while (items.Size() > count) items.RemoveAtEnd();
        for (uint32_t i = 0; i < count; ++i) {
            TabViewItem item = i < items.Size() ? items.GetAt(i).as<TabViewItem>() : TabViewItem{};
            item.Header(box_value(kinds[i] == 0 ? L"PowerShell" : L"WSL"));
            item.IsClosable(true);
            if (i == items.Size()) items.Append(item);
        }
        tabs.SelectedIndex(active >= 0 && active < static_cast<int32_t>(count) ? active : -1);
    }

    void showNewTabMenu() {
        closeNewTabMenu();
        new_tab_menu = MenuFlyout{};
        powershell_item = MenuFlyoutItem{};
        powershell_item.Text(L"PowerShell");
        powershell_token = powershell_item.Click([this](auto&&, auto&&) { notify(command_new_powershell, 0); });
        powershell_handler_attached = true;
        wsl_item = MenuFlyoutItem{};
        wsl_item.Text(L"WSL");
        wsl_token = wsl_item.Click([this](auto&&, auto&&) { notify(command_new_wsl, 0); });
        wsl_handler_attached = true;
        new_tab_menu.Items().Append(powershell_item);
        new_tab_menu.Items().Append(wsl_item);
        new_tab_menu.ShowAt(tabs);
    }

    void closeNewTabMenu() {
        if (!new_tab_menu) return;
        new_tab_menu.Hide();
        if (powershell_handler_attached) {
            powershell_item.Click(powershell_token);
            powershell_handler_attached = false;
        }
        if (wsl_handler_attached) {
            wsl_item.Click(wsl_token);
            wsl_handler_attached = false;
        }
        new_tab_menu.Items().Clear();
        powershell_item = nullptr;
        wsl_item = nullptr;
        new_tab_menu = nullptr;
    }

    HRESULT close() noexcept {
        if (closed) return S_OK;
        callback = nullptr;
        context = nullptr;

        HRESULT result = S_OK;
        bool safe_to_release = true;
        if (new_tab_menu) cleanup(L"hide new-tab menu", [&] { new_tab_menu.Hide(); }, result);
        if (powershell_handler_attached) {
            if (cleanup(L"revoke PowerShell menu handler", [&] { powershell_item.Click(powershell_token); }, result)) {
                powershell_handler_attached = false;
            } else safe_to_release = false;
        }
        if (wsl_handler_attached) {
            if (cleanup(L"revoke WSL menu handler", [&] { wsl_item.Click(wsl_token); }, result)) {
                wsl_handler_attached = false;
            } else safe_to_release = false;
        }
        if (add_tab_handler_attached && cleanup(L"revoke add-tab handler", [&] { tabs.AddTabButtonClick(add_tab_token); }, result)) add_tab_handler_attached = false;
        if (selection_handler_attached && cleanup(L"revoke selection handler", [&] { tabs.SelectionChanged(selection_token); }, result)) selection_handler_attached = false;
        if (close_tab_handler_attached && cleanup(L"revoke close-tab handler", [&] { tabs.TabCloseRequested(close_tab_token); }, result)) close_tab_handler_attached = false;
        if (add_tab_handler_attached || selection_handler_attached || close_tab_handler_attached) safe_to_release = false;
        if (!safe_to_release) return result;

        handlers_detached = true;
        closed = true;
        cleanup(L"clear new-tab menu", [&] { if (new_tab_menu) new_tab_menu.Items().Clear(); }, result);
        powershell_item = nullptr;
        wsl_item = nullptr;
        new_tab_menu = nullptr;
        cleanup(L"clear tabs", [&] { tabs.TabItems().Clear(); }, result);
        cleanup(L"detach XAML content", [&] { source.Content(nullptr); }, result);
        tabs = nullptr;
        cleanup(L"close XAML source", [&] { source.Close(); }, result);
        source = nullptr;
        application = nullptr;
        return result;
    }
};

bool owner(Bridge* bridge) { return bridge && bridge->thread_id == GetCurrentThreadId(); }

HRESULT validate(Bridge* bridge) {
    if (!bridge) return E_POINTER;
    return bridge->thread_id == GetCurrentThreadId() ? S_OK : RPC_E_WRONG_THREAD;
}
}

extern "C" void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context) noexcept {
    if (!parent || !callback) return nullptr;
    try {
        init_apartment(apartment_type::single_threaded);
    } catch (...) {
        reportCurrentException(L"init_apartment");
        return nullptr;
    }
    try {
        PACKAGE_VERSION minimum{};
        minimum.Version = 0;
        auto const bootstrap_result = MddBootstrapInitialize(0x00010008, nullptr, minimum);
        if (FAILED(bootstrap_result)) {
            reportFailure(L"MddBootstrapInitialize", bootstrap_result);
            uninit_apartment();
            return nullptr;
        }
        try {
            auto dispatcher = Microsoft::UI::Dispatching::DispatcherQueueController::CreateOnCurrentThread();
            auto application = make<ZigonautWinUIBridge::implementation::App>();
            return new Bridge(parent, callback, context, dispatcher, application);
        }
        catch (...) {
            reportCurrentException(L"WinUI initialization");
            MddBootstrapShutdown();
            uninit_apartment();
            return nullptr;
        }
    } catch (...) {
        reportCurrentException(L"Windows App SDK initialization");
        uninit_apartment();
        return nullptr;
    }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update(void* value, const uint8_t* kinds, uint32_t count, int32_t active) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (count && !kinds) return E_INVALIDARG;
    try { bridge->update(kinds, count, active); return S_OK; } catch (...) { return reportCurrentException(L"update"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_move(void* value, int32_t x, int32_t y, int32_t width, int32_t height) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->source.SiteBridge().MoveAndResize({x, y, width > 0 ? width : 1, height > 0 ? height : 1}); return S_OK; } catch (...) { return reportCurrentException(L"move"); }
}

extern "C" BOOL __cdecl zigonaut_chrome_pretranslate(void* value, MSG* message) noexcept {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge) || !message) return FALSE;
    try { return ContentPreTranslateMessage(message) ? TRUE : FALSE; } catch (...) { reportCurrentException(L"pretranslate"); return FALSE; }
}

extern "C" HRESULT __cdecl zigonaut_chrome_close(void* value) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    return bridge->close();
}

extern "C" HRESULT __cdecl zigonaut_chrome_destroy(void* value) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    auto dispatcher = bridge->dispatcher;
    auto result = bridge->close();
    if (!bridge->handlers_detached) return result;
    delete bridge;
    try { dispatcher.ShutdownQueue(); } catch (...) { if (SUCCEEDED(result)) result = reportCurrentException(L"ShutdownQueue"); }
    dispatcher = nullptr;
    MddBootstrapShutdown();
    uninit_apartment();
    return result;
}
