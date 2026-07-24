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

struct Bridge {
    DWORD thread_id = GetCurrentThreadId();
    zigonaut_chrome_command callback{};
    void* context{};
    Microsoft::UI::Dispatching::DispatcherQueueController dispatcher{nullptr};
    Application application{nullptr};
    DesktopWindowXamlSource source{nullptr};
    TabView tabs{nullptr};
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
        tabs.AddTabButtonClick([this](auto&&, auto&&) { showNewTabMenu(); });
        tabs.SelectionChanged([this](auto&&, auto&&) {
            if (!updating && tabs.SelectedIndex() >= 0) {
                callback(context, command_select, static_cast<uint32_t>(tabs.SelectedIndex()));
            }
        });
        tabs.TabCloseRequested([this](TabView const& sender, TabViewTabCloseRequestedEventArgs const& args) {
            uint32_t index = 0;
            if (sender.TabItems().IndexOf(args.Item(), index)) callback(context, command_close, index);
        });
        source.Content(tabs);
    }

    void update(uint8_t const* kinds, uint32_t count, int32_t active) {
        updating = true;
        auto items = tabs.TabItems();
        while (items.Size() > count) items.RemoveAtEnd();
        for (uint32_t i = 0; i < count; ++i) {
            TabViewItem item = i < items.Size() ? items.GetAt(i).as<TabViewItem>() : TabViewItem{};
            item.Header(box_value(kinds[i] == 0 ? L"PowerShell" : L"WSL"));
            item.IsClosable(true);
            if (i == items.Size()) items.Append(item);
        }
        tabs.SelectedIndex(active >= 0 && active < static_cast<int32_t>(count) ? active : -1);
        updating = false;
    }

    void showNewTabMenu() {
        MenuFlyout menu;
        MenuFlyoutItem powershell;
        powershell.Text(L"PowerShell");
        powershell.Click([this](auto&&, auto&&) { callback(context, command_new_powershell, 0); });
        MenuFlyoutItem wsl;
        wsl.Text(L"WSL");
        wsl.Click([this](auto&&, auto&&) { callback(context, command_new_wsl, 0); });
        menu.Items().Append(powershell);
        menu.Items().Append(wsl);
        menu.ShowAt(tabs);
    }

    void close() {
        if (closed) return;
        closed = true;
        tabs.TabItems().Clear();
        source.Content(nullptr);
        tabs = nullptr;
        source.Close();
        source = nullptr;
        application = nullptr;
    }
};

bool owner(Bridge* bridge) { return bridge && bridge->thread_id == GetCurrentThreadId(); }
}

extern "C" void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context) noexcept {
    if (!parent || !callback) return nullptr;
    try {
        init_apartment(apartment_type::single_threaded);
    } catch (...) {
        return nullptr;
    }
    try {
        PACKAGE_VERSION minimum{};
        minimum.Version = 0;
        if (FAILED(MddBootstrapInitialize(0x00010008, nullptr, minimum))) {
            uninit_apartment();
            return nullptr;
        }
        try {
            auto dispatcher = Microsoft::UI::Dispatching::DispatcherQueueController::CreateOnCurrentThread();
            auto application = make<ZigonautWinUIBridge::implementation::App>();
            return new Bridge(parent, callback, context, dispatcher, application);
        }
        catch (...) {
            MddBootstrapShutdown();
            uninit_apartment();
            return nullptr;
        }
    } catch (...) {
        uninit_apartment();
        return nullptr;
    }
}

extern "C" void __cdecl zigonaut_chrome_update(void* value, const uint8_t* kinds, uint32_t count, int32_t active) noexcept {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge) || (count && !kinds)) return;
    try { bridge->update(kinds, count, active); } catch (...) {}
}

extern "C" void __cdecl zigonaut_chrome_move(void* value, int32_t x, int32_t y, int32_t width, int32_t height) noexcept {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge)) return;
    try { bridge->source.SiteBridge().MoveAndResize({x, y, width > 0 ? width : 1, height > 0 ? height : 1}); } catch (...) {}
}

extern "C" BOOL __cdecl zigonaut_chrome_pretranslate(void* value, MSG* message) noexcept {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge) || !message) return FALSE;
    try { return ContentPreTranslateMessage(message) ? TRUE : FALSE; } catch (...) { return FALSE; }
}

extern "C" void __cdecl zigonaut_chrome_close(void* value) noexcept {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge)) return;
    try { bridge->close(); } catch (...) {}
}

extern "C" void __cdecl zigonaut_chrome_destroy(void* value) noexcept {
    auto bridge = static_cast<Bridge*>(value); if (!owner(bridge)) return;
    auto dispatcher = bridge->dispatcher;
    try { bridge->close(); } catch (...) {}
    delete bridge;
    try { dispatcher.ShutdownQueue(); } catch (...) {}
    dispatcher = nullptr;
    MddBootstrapShutdown();
    uninit_apartment();
}
