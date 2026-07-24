#include "pch.h"
#include "App.xaml.h"
#include "bridge.h"
#include <MddBootstrap.h>
#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Content.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.UI.h>
#include <winrt/base.h>
#include <Microsoft.UI.Dispatching.Interop.h>
#include <winrt/Microsoft.UI.Interop.h>
#include <algorithm>
#include <array>
#include <string_view>

using namespace winrt;
using namespace Microsoft::UI;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Hosting;

namespace {
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

FrameworkElement findDescendant(DependencyObject const& root, wchar_t const* name) {
    auto const count = Microsoft::UI::Xaml::Media::VisualTreeHelper::GetChildrenCount(root);
    for (int32_t index = 0; index < count; ++index) {
        auto const child = Microsoft::UI::Xaml::Media::VisualTreeHelper::GetChild(root, index);
        if (auto const element = child.try_as<FrameworkElement>(); element && element.Name() == name) {
            return element;
        }
        if (auto const found = findDescendant(child, name)) return found;
    }
    return nullptr;
}

struct Bridge {
    // All XAML objects and event revocation must stay on this creating STA thread.
    DWORD thread_id = GetCurrentThreadId();
    zigonaut_chrome_command callback{};
    void* context{};
    Microsoft::UI::Dispatching::DispatcherQueueController dispatcher{nullptr};
    Application application{nullptr};
    HWND parent{};
    Microsoft::UI::Windowing::AppWindow app_window{nullptr};
    Microsoft::UI::Windowing::AppWindowTitleBar title_bar{nullptr};
    DesktopWindowXamlSource source{nullptr};
    Microsoft::UI::Xaml::Media::MicaBackdrop backdrop{nullptr};
    Grid root{nullptr};
    TabView tabs{nullptr};
    Button menu_button{nullptr};
    MenuFlyout app_menu{nullptr};
    MenuFlyoutItem open_settings_item{nullptr};
    MenuFlyoutItem reload_settings_item{nullptr};
    MenuFlyoutItem quit_item{nullptr};
    MenuFlyout new_tab_menu{nullptr};
    MenuFlyoutItem powershell_item{nullptr};
    MenuFlyoutItem wsl_item{nullptr};
    TabView::AddTabButtonClick_revoker add_tab_revoker{};
    TabView::SelectionChanged_revoker selection_revoker{};
    TabView::TabCloseRequested_revoker close_tab_revoker{};
    MenuFlyoutItem::Click_revoker open_settings_revoker{};
    MenuFlyoutItem::Click_revoker reload_settings_revoker{};
    MenuFlyoutItem::Click_revoker quit_revoker{};
    MenuFlyoutItem::Click_revoker powershell_revoker{};
    MenuFlyoutItem::Click_revoker wsl_revoker{};
    bool handlers_detached = false;
    bool updating = false;
    bool closed = false;
    bool custom_title_bar = false;

    Bridge(HWND parent, zigonaut_chrome_command cb, void* ctx,
           Microsoft::UI::Dispatching::DispatcherQueueController const& controller,
           Application const& app)
        : callback(cb), context(ctx), dispatcher(controller), application(app) {
        this->parent = parent;
        source = DesktopWindowXamlSource{};
        source.Initialize(Microsoft::UI::GetWindowIdFromWindow(parent));
        root = Grid{};
        tabs = TabView{};

        tabs.IsAddTabButtonVisible(true);
        tabs.VerticalAlignment(VerticalAlignment::Bottom);
        tabs.TabWidthMode(TabViewWidthMode::SizeToContent);
        tabs.CloseButtonOverlayMode(TabViewCloseButtonOverlayMode::Auto);
        add_tab_revoker = tabs.AddTabButtonClick(auto_revoke, [this](auto&&, auto&&) { showNewTabMenu(); });
        selection_revoker = tabs.SelectionChanged(auto_revoke, [this](auto&&, auto&&) {
            if (!updating && tabs.SelectedIndex() >= 0) {
                notify(ZIGONAUT_CHROME_SELECT, static_cast<uint32_t>(tabs.SelectedIndex()));
            }
        });
        close_tab_revoker = tabs.TabCloseRequested(auto_revoke, [this](TabView const& sender, TabViewTabCloseRequestedEventArgs const& args) {
            uint32_t index = 0;
            if (sender.TabItems().IndexOf(args.Item(), index)) notify(ZIGONAUT_CHROME_CLOSE, index);
        });

        menu_button = Button{};
        menu_button.Width(40);
        menu_button.Height(40);
        menu_button.HorizontalAlignment(HorizontalAlignment::Left);
        menu_button.VerticalAlignment(VerticalAlignment::Bottom);
        menu_button.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        menu_button.BorderThickness(Thickness{});
        menu_button.CornerRadius(CornerRadius{});
        auto const menu_icon = FontIcon{};
        menu_icon.Glyph(L"\xE700");
        menu_button.Content(menu_icon);

        app_menu = MenuFlyout{};
        app_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        open_settings_item = MenuFlyoutItem{};
        open_settings_item.Text(L"Open Settings");
        open_settings_revoker = open_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_OPEN_SETTINGS, 0); });
        reload_settings_item = MenuFlyoutItem{};
        reload_settings_item.Text(L"Reload Settings");
        reload_settings_revoker = reload_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_RELOAD_SETTINGS, 0); });
        quit_item = MenuFlyoutItem{};
        quit_item.Text(L"Quit");
        quit_revoker = quit_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_QUIT, 0); });
        app_menu.Items().Append(open_settings_item);
        app_menu.Items().Append(reload_settings_item);
        app_menu.Items().Append(quit_item);
        menu_button.Flyout(app_menu);

        new_tab_menu = MenuFlyout{};
        new_tab_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        powershell_item = MenuFlyoutItem{};
        powershell_item.Text(L"PowerShell");
        powershell_revoker = powershell_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_NEW_POWERSHELL, 0); });
        wsl_item = MenuFlyoutItem{};
        wsl_item.Text(L"WSL");
        wsl_revoker = wsl_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_NEW_WSL, 0); });
        new_tab_menu.Items().Append(powershell_item);
        new_tab_menu.Items().Append(wsl_item);

        root.Children().Append(tabs);
        root.Children().Append(menu_button);
        source.Content(root);
        backdrop = Microsoft::UI::Xaml::Media::MicaBackdrop{};
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::BaseAlt);
        source.SystemBackdrop(backdrop);
        enableTitleBar();
    }

    void enableTitleBar() {
        menu_button.Margin(Thickness{8, 0, 0, 0});
        tabs.Margin(Thickness{56, 0, 8, 0});
        if (!Microsoft::UI::Windowing::AppWindowTitleBar::IsCustomizationSupported()) return;
        try {
            app_window = Microsoft::UI::Windowing::AppWindow::GetFromWindowId(Microsoft::UI::GetWindowIdFromWindow(parent));
            title_bar = app_window.TitleBar();
            title_bar.ExtendsContentIntoTitleBar(true);
            custom_title_bar = true;
            title_bar.PreferredHeightOption(Microsoft::UI::Windowing::TitleBarHeightOption::Tall);
            auto const transparent = box_value(Windows::UI::Color{0, 0, 0, 0})
                .as<Windows::Foundation::IReference<Windows::UI::Color>>();
            title_bar.ButtonBackgroundColor(transparent);
            title_bar.ButtonInactiveBackgroundColor(transparent);
            updateTitleBarLayout();
        } catch (...) {
            reportCurrentException(L"enable custom title bar");
            HRESULT result = S_OK;
            if (!restoreTitleBar(result)) return;
            app_window = nullptr;
            title_bar = nullptr;
        }
    }

    bool restoreTitleBar(HRESULT& result) noexcept {
        if (!custom_title_bar) return true;
        if (IsWindow(parent)) {
            if (!cleanup(L"restore system title bar", [&] { title_bar.ResetToDefault(); }, result)) return false;
        }
        custom_title_bar = false;
        title_bar = nullptr;
        app_window = nullptr;
        return true;
    }

    void updateTitleBarLayout() {
        if (!custom_title_bar) return;
        RECT client{};
        if (IsIconic(parent) || !GetClientRect(parent, &client) || client.right <= 0 || client.bottom <= 0) return;
        auto const dpi = GetDpiForWindow(parent);
        auto const left_inset = title_bar.LeftInset();
        auto const right_inset = title_bar.RightInset();
        auto const client_width = static_cast<int32_t>(client.right);
        auto const client_height = static_cast<int32_t>(client.bottom);
        auto const drag_height = std::min(title_bar.Height(), client_height);
        auto const drag_right = std::max(0, client_width - std::max(right_inset, 0));
        auto const to_dips = [dpi](int32_t pixels) { return static_cast<double>(pixels) * 96.0 / dpi; };
        menu_button.Margin(Thickness{to_dips(left_inset) + 8, 0, 0, 0});
        tabs.Margin(Thickness{to_dips(left_inset) + 56, 0, to_dips(right_inset) + 8, 0});
        std::array<Windows::Graphics::RectInt32, 1> drag_areas{};
        uint32_t drag_area_count = 0;
        double occupied_width = tabs.Margin().Left;
        bool items_measured = true;
        for (auto const& value : tabs.TabItems()) {
            auto const width = value.as<TabViewItem>().ActualWidth();
            if (width <= 0) items_measured = false;
            occupied_width += width;
        }
        if (items_measured) {
            constexpr double add_button_width = 48;
            auto const drag_start = static_cast<int32_t>((occupied_width + add_button_width) * dpi / 96.0 + 0.5);
            if (drag_right > drag_start && drag_height > 0) {
                drag_areas[drag_area_count] = {drag_start, 0, drag_right - drag_start, drag_height};
                ++drag_area_count;
            }
        }
        title_bar.SetDragRectangles({drag_areas.data(), drag_area_count});
    }

    void move(int32_t x, int32_t y, int32_t width, int32_t height) {
        if (IsIconic(parent)) return;
        source.SiteBridge().MoveAndResize({x, y, width > 0 ? width : 1, height > 0 ? height : 1});
        updateTitleBarLayout();
    }

    void notify(zigonaut_chrome_command_id command, uint32_t argument) const {
        if (!closed && callback) callback(context, static_cast<uint32_t>(command), argument);
    }

    void update(char const* const* titles, uint32_t const* title_lengths, uint32_t count, int32_t active) {
        updating = true;
        struct ResetUpdating {
            bool& value;
            ~ResetUpdating() { value = false; }
        } reset{updating};
        auto items = tabs.TabItems();
        while (items.Size() > count) items.RemoveAtEnd();
        for (uint32_t i = 0; i < count; ++i) {
            TabViewItem item = i < items.Size() ? items.GetAt(i).as<TabViewItem>() : TabViewItem{};
            item.Header(box_value(to_hstring(std::string_view{titles[i], title_lengths[i]})));
            item.MinHeight(40);
            item.IsClosable(true);
            if (i == items.Size()) items.Append(item);
        }
        tabs.SelectedIndex(active >= 0 && active < static_cast<int32_t>(count) ? active : -1);
        tabs.UpdateLayout();
        updateTitleBarLayout();
    }

    void showNewTabMenu() {
        auto const add_button = findDescendant(tabs, L"AddButton");
        new_tab_menu.ShowAt(add_button ? add_button : tabs);
    }

    HRESULT close() noexcept {
        if (closed) return S_OK;
        callback = nullptr;
        context = nullptr;

        HRESULT result = S_OK;
        if (new_tab_menu) cleanup(L"hide new-tab menu", [&] { new_tab_menu.Hide(); }, result);
        if (app_menu) cleanup(L"hide application menu", [&] { app_menu.Hide(); }, result);
        powershell_revoker.revoke();
        wsl_revoker.revoke();
        open_settings_revoker.revoke();
        reload_settings_revoker.revoke();
        quit_revoker.revoke();
        add_tab_revoker.revoke();
        selection_revoker.revoke();
        close_tab_revoker.revoke();
        handlers_detached = true;
        if (!restoreTitleBar(result)) return result;
        closed = true;
        cleanup(L"clear new-tab menu", [&] { if (new_tab_menu) new_tab_menu.Items().Clear(); }, result);
        powershell_item = nullptr;
        wsl_item = nullptr;
        new_tab_menu = nullptr;
        cleanup(L"detach application menu", [&] { menu_button.Flyout(nullptr); }, result);
        cleanup(L"clear application menu", [&] { app_menu.Items().Clear(); }, result);
        open_settings_item = nullptr;
        reload_settings_item = nullptr;
        quit_item = nullptr;
        app_menu = nullptr;
        cleanup(L"clear tabs", [&] { tabs.TabItems().Clear(); }, result);
        cleanup(L"detach XAML content", [&] { source.Content(nullptr); }, result);
        cleanup(L"clear root content", [&] { root.Children().Clear(); }, result);
        menu_button = nullptr;
        tabs = nullptr;
        root = nullptr;
        cleanup(L"clear system backdrop", [&] { source.SystemBackdrop(nullptr); }, result);
        backdrop = nullptr;
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

extern "C" HRESULT __cdecl zigonaut_chrome_update(void* value, const char* const* titles, const uint32_t* title_lengths, uint32_t count, int32_t active) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (count && (!titles || !title_lengths)) return E_INVALIDARG;
    try { bridge->update(titles, title_lengths, count, active); return S_OK; } catch (...) { return reportCurrentException(L"update"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_move(void* value, int32_t x, int32_t y, int32_t width, int32_t height) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->move(x, y, width, height); return S_OK; } catch (...) { return reportCurrentException(L"move"); }
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
    if (!bridge->handlers_detached || bridge->custom_title_bar) return FAILED(result) ? result : E_FAIL;
    delete bridge;
    try { dispatcher.ShutdownQueue(); } catch (...) { reportCurrentException(L"ShutdownQueue"); }
    dispatcher = nullptr;
    MddBootstrapShutdown();
    uninit_apartment();
    return S_OK;
}
