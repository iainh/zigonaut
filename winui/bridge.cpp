#include "pch.h"
#include "App.xaml.h"
#include "bridge.h"
#include <MddBootstrap.h>
#include <WindowsAppSDK-VersionInfo.h>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Content.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Hosting.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.UI.h>
#include <winrt/base.h>
#include <Microsoft.UI.Dispatching.Interop.h>
#include <winrt/Microsoft.UI.Interop.h>
#include <winrt/Microsoft.Windows.AppNotifications.h>
#include <winrt/Microsoft.Windows.AppNotifications.Builder.h>
#include <shobjidl.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <atomic>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

using namespace winrt;
using namespace Microsoft::UI;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Hosting;
using namespace Microsoft::Windows::AppNotifications;
using namespace Microsoft::Windows::AppNotifications::Builder;

namespace {
struct NotificationActivationState {
    std::atomic_bool active{true};
    zigonaut_chrome_command callback{};
    void* context{};
    Microsoft::UI::Dispatching::DispatcherQueue queue{nullptr};
    hstring nonce;
};

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
    DesktopWindowXamlSource scrollbar_source{nullptr};
    Microsoft::UI::Xaml::Media::MicaBackdrop backdrop{nullptr};
    Grid root{nullptr};
    Grid scrollbar_root{nullptr};
    TabView tabs{nullptr};
    SplitButton new_tab_button{nullptr};
    Microsoft::UI::Xaml::Controls::Primitives::ScrollBar scrollbar{nullptr};
    Button menu_button{nullptr};
    Border bottom_border{nullptr};
    MenuFlyout app_menu{nullptr};
    MenuFlyoutItem open_settings_item{nullptr};
    MenuFlyoutItem reload_settings_item{nullptr};
    MenuFlyoutItem about_item{nullptr};
    MenuFlyoutItem quit_item{nullptr};
    ContentDialog about_dialog{nullptr};
    Windows::Foundation::IAsyncOperation<ContentDialogResult> about_operation{nullptr};
    MenuFlyout new_tab_menu{nullptr};
    std::vector<MenuFlyoutItem> profile_items;
    std::vector<MenuFlyoutItem::Click_revoker> profile_revokers;
    Microsoft::UI::Dispatching::DispatcherQueueTimer scrollbar_timer{nullptr};
    SplitButton::Click_revoker new_tab_revoker{};
    TabView::SelectionChanged_revoker selection_revoker{};
    TabView::TabCloseRequested_revoker close_tab_revoker{};
    MenuFlyoutItem::Click_revoker open_settings_revoker{};
    MenuFlyoutItem::Click_revoker reload_settings_revoker{};
    MenuFlyoutItem::Click_revoker about_revoker{};
    MenuFlyoutItem::Click_revoker quit_revoker{};
    ContentDialog::Closed_revoker about_closed_revoker{};
    Microsoft::UI::Xaml::Controls::Primitives::ScrollBar::Scroll_revoker scrollbar_scroll_revoker{};
    UIElement::PointerEntered_revoker scrollbar_entered_revoker{};
    UIElement::PointerExited_revoker scrollbar_exited_revoker{};
    UIElement::PointerWheelChanged_revoker scrollbar_wheel_revoker{};
    Microsoft::UI::Dispatching::DispatcherQueueTimer::Tick_revoker scrollbar_tick_revoker{};
    bool handlers_detached = false;
    bool updating = false;
    bool updating_scrollbar = false;
    bool pointer_over_scrollbar = false;
    bool closed = false;
    bool custom_title_bar = false;
    com_ptr<ITaskbarList3> taskbar;
    AppNotificationManager notification_manager{nullptr};
    AppNotificationManager::NotificationInvoked_revoker notification_revoker{};
    bool notifications_registered = false;
    std::shared_ptr<NotificationActivationState> notification_activation;
    hstring app_version;
    hstring git_hash;

    Bridge(HWND parent, zigonaut_chrome_command cb, void* ctx,
           Microsoft::UI::Dispatching::DispatcherQueueController const& controller,
           Application const& app, std::string_view version, std::string_view hash)
        : callback(cb), context(ctx), dispatcher(controller), application(app),
          app_version(to_hstring(version)), git_hash(to_hstring(hash)) {
        this->parent = parent;
        GUID nonce{};
        check_hresult(CoCreateGuid(&nonce));
        wchar_t nonce_text[40]{};
        if (!StringFromGUID2(nonce, nonce_text, static_cast<int>(std::size(nonce_text)))) throw hresult_error(E_FAIL);
        notification_activation = std::make_shared<NotificationActivationState>();
        notification_activation->callback = callback;
        notification_activation->context = context;
        notification_activation->queue = dispatcher.DispatcherQueue();
        notification_activation->nonce = nonce_text;
        source = DesktopWindowXamlSource{};
        source.Initialize(Microsoft::UI::GetWindowIdFromWindow(parent));
        root = Grid{};
        tabs = TabView{};

        scrollbar_source = DesktopWindowXamlSource{};
        scrollbar_source.Initialize(Microsoft::UI::GetWindowIdFromWindow(parent));
        scrollbar_root = Grid{};
        scrollbar_root.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        scrollbar = Microsoft::UI::Xaml::Controls::Primitives::ScrollBar{};
        scrollbar.Orientation(Orientation::Vertical);
        scrollbar.HorizontalAlignment(HorizontalAlignment::Right);
        scrollbar.Width(12);
        scrollbar.SmallChange(1);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(scrollbar, L"Terminal scrollback");
        scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::None);
        scrollbar.Visibility(Visibility::Collapsed);
        scrollbar_scroll_revoker = scrollbar.Scroll(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Controls::Primitives::ScrollEventArgs const& args) {
            if (updating_scrollbar) return;
            showScrollbar();
            notify(ZIGONAUT_CHROME_SCROLL, static_cast<uint32_t>(std::clamp(args.NewValue(), 0.0, static_cast<double>(UINT32_MAX))));
        });
        scrollbar_entered_revoker = scrollbar_root.PointerEntered(auto_revoke, [this](auto&&, auto&&) {
            pointer_over_scrollbar = true;
            showScrollbar();
        });
        scrollbar_exited_revoker = scrollbar_root.PointerExited(auto_revoke, [this](auto&&, auto&&) {
            pointer_over_scrollbar = false;
            scheduleScrollbarHide();
        });
        scrollbar_wheel_revoker = scrollbar_root.PointerWheelChanged(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            auto const delta = args.GetCurrentPoint(scrollbar_root).Properties().MouseWheelDelta();
            showScrollbar();
            notify(ZIGONAUT_CHROME_SCROLL_WHEEL, static_cast<uint32_t>(delta));
            args.Handled(true);
        });
        scrollbar_root.Children().Append(scrollbar);
        scrollbar_source.Content(scrollbar_root);

        scrollbar_timer = dispatcher.DispatcherQueue().CreateTimer();
        scrollbar_timer.IsRepeating(false);
        scrollbar_timer.Interval(std::chrono::seconds(2));
        scrollbar_tick_revoker = scrollbar_timer.Tick(auto_revoke, [this](auto&&, auto&&) {
            if (!pointer_over_scrollbar && scrollbar) {
                scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::None);
            }
        });

        auto const resources = application.Resources();
        root.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});

        tabs.IsAddTabButtonVisible(false);
        tabs.VerticalAlignment(VerticalAlignment::Bottom);
        tabs.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        tabs.TabWidthMode(TabViewWidthMode::SizeToContent);
        tabs.CloseButtonOverlayMode(TabViewCloseButtonOverlayMode::Auto);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(tabs, L"Terminal tabs");
        new_tab_button = SplitButton{};
        new_tab_button.Height(40);
        auto const new_tab_icon = SymbolIcon{Symbol::Add};
        new_tab_button.Content(new_tab_icon);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(new_tab_button, L"New tab");
        ToolTipService::SetToolTip(new_tab_button, box_value(L"New tab (Ctrl+Shift+T)"));
        new_tab_revoker = new_tab_button.Click(auto_revoke, [this](auto&&, auto&&) {
            notify(ZIGONAUT_CHROME_NEW_DEFAULT, 0);
        });
        tabs.TabStripFooter(new_tab_button);
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
        auto const menu_icon = SymbolIcon{Symbol::GlobalNavigationButton};
        menu_button.Content(menu_icon);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(menu_button, L"Application menu");
        ToolTipService::SetToolTip(menu_button, box_value(L"Application menu"));

        bottom_border = Border{};
        bottom_border.Height(1);
        bottom_border.VerticalAlignment(VerticalAlignment::Bottom);
        bottom_border.IsHitTestVisible(false);
        bottom_border.Background(resources.Lookup(box_value(L"CardStrokeColorDefaultBrush")).as<Microsoft::UI::Xaml::Media::Brush>());

        app_menu = MenuFlyout{};
        app_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        open_settings_item = MenuFlyoutItem{};
        open_settings_item.Text(L"Open Settings");
        open_settings_revoker = open_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_OPEN_SETTINGS, 0); });
        reload_settings_item = MenuFlyoutItem{};
        reload_settings_item.Text(L"Reload Settings");
        reload_settings_revoker = reload_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_RELOAD_SETTINGS, 0); });
        about_item = MenuFlyoutItem{};
        about_item.Text(L"About Zigonaut");
        about_revoker = about_item.Click(auto_revoke, [this](auto&&, auto&&) { showAboutDialog(); });
        quit_item = MenuFlyoutItem{};
        quit_item.Text(L"Quit");
        quit_revoker = quit_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_QUIT, 0); });
        app_menu.Items().Append(open_settings_item);
        app_menu.Items().Append(reload_settings_item);
        app_menu.Items().Append(MenuFlyoutSeparator{});
        app_menu.Items().Append(about_item);
        app_menu.Items().Append(quit_item);
        menu_button.Flyout(app_menu);

        new_tab_menu = MenuFlyout{};
        new_tab_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        new_tab_button.Flyout(new_tab_menu);

        root.Children().Append(tabs);
        root.Children().Append(menu_button);
        root.Children().Append(bottom_border);
        source.Content(root);
        backdrop = Microsoft::UI::Xaml::Media::MicaBackdrop{};
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::BaseAlt);
        source.SystemBackdrop(backdrop);
        enableTitleBar();
    }

    bool ensureNotificationsRegistered() noexcept {
        if (notifications_registered) return true;
        try {
            notification_manager = AppNotificationManager::Default();
            auto const activation = notification_activation;
            notification_revoker = notification_manager.NotificationInvoked(auto_revoke, [activation](auto const&, AppNotificationActivatedEventArgs const& args) {
                auto const values = args.Arguments();
                if (!values.HasKey(L"session") || !values.HasKey(L"process") || !values.HasKey(L"nonce")) return;
                wchar_t* process_end{};
                auto const process = wcstoul(values.Lookup(L"process").c_str(), &process_end, 10);
                if (!process_end || *process_end != L'\0' || process != GetCurrentProcessId()) return;
                if (values.Lookup(L"nonce") != activation->nonce) return;
                auto const text = values.Lookup(L"session");
                wchar_t* end{};
                auto const id = wcstoul(text.c_str(), &end, 10);
                if (!end || *end != L'\0' || id > UINT32_MAX) return;
                activation->queue.TryEnqueue([activation, id] {
                    if (!activation->active.load(std::memory_order_acquire) || !activation->callback) return;
                    activation->callback(activation->context, ZIGONAUT_CHROME_NOTIFICATION_ACTIVATE, static_cast<uint32_t>(id));
                });
            });
            notification_manager.Register();
            notifications_registered = true;
            return true;
        } catch (...) {
            reportCurrentException(L"register app notifications");
            notification_revoker.revoke();
            notification_manager = nullptr;
            return false;
        }
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

    void showAboutDialog() {
        if (about_dialog) return;

        auto content = StackPanel{};
        content.MaxWidth(320);
        content.Spacing(10);
        content.Padding(Thickness{0, 8, 0, 0});
        content.HorizontalAlignment(HorizontalAlignment::Stretch);

        wchar_t module_path[MAX_PATH]{};
        auto const module_path_length = GetModuleFileNameW(nullptr, module_path, static_cast<DWORD>(std::size(module_path)));
        if (module_path_length && module_path_length < std::size(module_path)) {
            std::wstring path(module_path, module_path_length);
            auto const separator = path.find_last_of(L"\\/");
            path.resize(separator == std::wstring::npos ? 0 : separator + 1);
            path += L"zigonaut-about-1024.png";
            std::replace(path.begin(), path.end(), L'\\', L'/');

            auto bitmap = Microsoft::UI::Xaml::Media::Imaging::BitmapImage{};
            bitmap.UriSource(Windows::Foundation::Uri{hstring{L"file:///" + path}});
            auto image = Image{};
            image.Source(bitmap);
            image.Width(192);
            image.Height(192);
            image.Stretch(Microsoft::UI::Xaml::Media::Stretch::Uniform);
            image.HorizontalAlignment(HorizontalAlignment::Center);
            content.Children().Append(image);
        }

        auto name = TextBlock{};
        name.Text(L"Zigonaut");
        name.Style(application.Resources().Lookup(box_value(L"TitleTextBlockStyle")).as<Style>());
        name.HorizontalAlignment(HorizontalAlignment::Stretch);
        name.TextAlignment(TextAlignment::Center);
        content.Children().Append(name);

        auto version = TextBlock{};
        version.Text(hstring{L"Version " + std::wstring{app_version}});
        version.HorizontalAlignment(HorizontalAlignment::Stretch);
        version.TextAlignment(TextAlignment::Center);
        content.Children().Append(version);

        auto hash = TextBlock{};
        hash.HorizontalAlignment(HorizontalAlignment::Stretch);
        hash.TextAlignment(TextAlignment::Center);
        auto hash_label = Microsoft::UI::Xaml::Documents::Run{};
        hash_label.Text(L"Git commit ");
        hash.Inlines().Append(hash_label);
        auto hash_link = Microsoft::UI::Xaml::Documents::Hyperlink{};
        auto hash_text = Microsoft::UI::Xaml::Documents::Run{};
        auto const abbreviated_hash = std::wstring_view{git_hash}.substr(0, std::min<size_t>(12, git_hash.size()));
        hash_text.Text(hstring{abbreviated_hash});
        hash_link.Inlines().Append(hash_text);
        hash_link.NavigateUri(Windows::Foundation::Uri{
            hstring{L"https://github.com/iainh/zigonaut/commit/" + std::wstring{git_hash}},
        });
        hash.Inlines().Append(hash_link);
        content.Children().Append(hash);

        about_dialog = ContentDialog{};
        about_dialog.XamlRoot(root.XamlRoot());
        about_dialog.Title(box_value(L"About Zigonaut"));
        about_dialog.Content(content);
        about_dialog.CloseButtonText(L"Close");
        about_dialog.DefaultButton(ContentDialogButton::Close);
        about_closed_revoker = about_dialog.Closed(auto_revoke, [this](auto&&, auto&&) {
            about_operation = nullptr;
            about_dialog = nullptr;
        });
        try {
            about_operation = about_dialog.ShowAsync();
        } catch (...) {
            reportCurrentException(L"show About dialog");
            about_closed_revoker.revoke();
            about_operation = nullptr;
            about_dialog = nullptr;
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
            auto const new_tab_width = new_tab_button.ActualWidth();
            if (new_tab_width <= 0) items_measured = false;
            occupied_width += new_tab_width;
        }
        if (items_measured) {
            auto const drag_start = static_cast<int32_t>(occupied_width * dpi / 96.0 + 0.5);
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
        RECT client{};
        if (GetClientRect(parent, &client)) {
            auto const dpi = GetDpiForWindow(parent);
            auto const overlay_width = std::max(1, MulDiv(16, dpi, 96));
            auto const terminal_top = y + height;
            scrollbar_source.SiteBridge().MoveAndResize({
                std::max(x, x + width - overlay_width),
                terminal_top,
                std::min(std::max(width, 1), overlay_width),
                std::max(static_cast<int32_t>(client.bottom) - terminal_top, 1),
            });
        }
        updateTitleBarLayout();
    }

    void showScrollbar() {
        if (!scrollbar || scrollbar.Visibility() != Visibility::Visible) return;
        scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::MouseIndicator);
        scheduleScrollbarHide();
    }

    void updateAppearance(uint32_t kind, bool high_contrast, bool dark_theme) {
        auto const requested_theme = high_contrast ? ElementTheme::Default : dark_theme ? ElementTheme::Dark : ElementTheme::Light;
        root.RequestedTheme(requested_theme);
        scrollbar_root.RequestedTheme(requested_theme);
        if (high_contrast) {
            root.Background(application.Resources().Lookup(box_value(L"TabViewBackground")).as<Microsoft::UI::Xaml::Media::Brush>());
            bottom_border.Background(application.Resources().Lookup(box_value(L"CardStrokeColorDefaultBrush")).as<Microsoft::UI::Xaml::Media::Brush>());
        } else {
            auto const color = dark_theme
                ? Windows::UI::Color{255, 0x2e, 0x2e, 0x2e}
                : Windows::UI::Color{255, 0xe8, 0xe8, 0xe8};
            root.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{color});
            auto const border_color = dark_theme
                ? Windows::UI::Color{0x26, 0xff, 0xff, 0xff}
                : Windows::UI::Color{0x0f, 0x00, 0x00, 0x00};
            bottom_border.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{border_color});
        }
        source.SystemBackdrop(nullptr);
        backdrop = nullptr;
        if (high_contrast || kind == ZIGONAUT_BACKDROP_NONE) return;
        if (kind == ZIGONAUT_BACKDROP_ACRYLIC) {
            source.SystemBackdrop(Microsoft::UI::Xaml::Media::DesktopAcrylicBackdrop{});
            return;
        }
        backdrop = Microsoft::UI::Xaml::Media::MicaBackdrop{};
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::BaseAlt);
        source.SystemBackdrop(backdrop);
    }

    void scheduleScrollbarHide() {
        if (!scrollbar_timer) return;
        scrollbar_timer.Stop();
        if (!pointer_over_scrollbar) scrollbar_timer.Start();
    }

    void updateScrollbar(uint32_t total, uint32_t page, uint32_t position, bool show) {
        updating_scrollbar = true;
        struct ResetUpdating {
            bool& value;
            ~ResetUpdating() { value = false; }
        } reset{updating_scrollbar};
        auto const maximum = total > page ? total - page : 0;
        scrollbar.Minimum(0);
        scrollbar.Maximum(maximum);
        scrollbar.LargeChange(std::max(page, 1u));
        scrollbar.ViewportSize(page);
        scrollbar.Value(std::min(position, maximum));
        scrollbar.IsEnabled(maximum > 0);
        scrollbar.Visibility(maximum > 0 ? Visibility::Visible : Visibility::Collapsed);
        if (maximum == 0) {
            scrollbar_timer.Stop();
            scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::None);
        } else if (show) {
            showScrollbar();
        }
    }

    HRESULT updateTaskbarProgress(uint32_t state, uint32_t value) noexcept {
        if (!taskbar) {
            auto const created = CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                                   IID_PPV_ARGS(taskbar.put()));
            if (FAILED(created)) return created;
            auto const initialized = taskbar->HrInit();
            if (FAILED(initialized)) {
                taskbar = nullptr;
                return initialized;
            }
        }
        auto const flag = static_cast<TBPFLAG>(state);
        auto result = taskbar->SetProgressState(parent, flag);
        if (FAILED(result) || flag == TBPF_NOPROGRESS || flag == TBPF_INDETERMINATE) return result;
        return taskbar->SetProgressValue(parent, std::min(value, 100u), 100);
    }

    HRESULT showNotification(uint32_t session_id, std::string_view title, std::string_view body) noexcept {
        if (!ensureNotificationsRegistered()) return E_NOTIMPL;
        try {
            auto builder = AppNotificationBuilder{}
                .AddArgument(L"session", to_hstring(session_id))
                .AddArgument(L"process", to_hstring(static_cast<uint32_t>(GetCurrentProcessId())))
                .AddArgument(L"nonce", notification_activation->nonce)
                .AddText(to_hstring(title))
                .AddText(to_hstring(body));
            notification_manager.Show(builder.BuildNotification());
            return S_OK;
        } catch (...) {
            return reportCurrentException(L"show app notification");
        }
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
            item.MaxWidth(240);
            item.IsClosable(true);
            ToolTipService::SetToolTip(item, item.Header());
            if (i == items.Size()) items.Append(item);
        }
        tabs.SelectedIndex(active >= 0 && active < static_cast<int32_t>(count) ? active : -1);
        tabs.UpdateLayout();
        updateTitleBarLayout();
    }

    void updateProfiles(char const* const* names, uint32_t const* name_lengths, uint32_t count) {
        for (auto& revoker : profile_revokers) revoker.revoke();
        profile_revokers.clear();
        profile_items.clear();
        new_tab_menu.Items().Clear();
        profile_items.reserve(count);
        profile_revokers.reserve(count);
        for (uint32_t index = 0; index < count; ++index) {
            auto item = MenuFlyoutItem{};
            item.Text(to_hstring(std::string_view{names[index], name_lengths[index]}));
            profile_revokers.emplace_back(item.Click(auto_revoke, [this, index](auto&&, auto&&) {
                notify(ZIGONAUT_CHROME_NEW_PROFILE, index);
            }));
            new_tab_menu.Items().Append(item);
            profile_items.emplace_back(std::move(item));
        }
    }

    HRESULT close() noexcept {
        if (closed) return S_OK;
        notification_activation->active.store(false, std::memory_order_release);
        callback = nullptr;
        context = nullptr;

        HRESULT result = S_OK;
        if (notifications_registered) {
            cleanup(L"unregister app notifications", [&] { notification_manager.Unregister(); }, result);
            notifications_registered = false;
        }
        notification_revoker.revoke();
        notification_manager = nullptr;
        if (new_tab_menu) cleanup(L"hide new-tab menu", [&] { new_tab_menu.Hide(); }, result);
        if (app_menu) cleanup(L"hide application menu", [&] { app_menu.Hide(); }, result);
        about_closed_revoker.revoke();
        if (about_dialog) cleanup(L"hide About dialog", [&] { about_dialog.Hide(); }, result);
        for (auto& revoker : profile_revokers) revoker.revoke();
        profile_revokers.clear();
        open_settings_revoker.revoke();
        reload_settings_revoker.revoke();
        about_revoker.revoke();
        quit_revoker.revoke();
        new_tab_revoker.revoke();
        selection_revoker.revoke();
        close_tab_revoker.revoke();
        scrollbar_scroll_revoker.revoke();
        scrollbar_entered_revoker.revoke();
        scrollbar_exited_revoker.revoke();
        scrollbar_wheel_revoker.revoke();
        scrollbar_tick_revoker.revoke();
        if (scrollbar_timer) scrollbar_timer.Stop();
        handlers_detached = true;
        if (!restoreTitleBar(result)) return result;
        closed = true;
        cleanup(L"detach new-tab menu", [&] { new_tab_button.Flyout(nullptr); }, result);
        cleanup(L"clear new-tab menu", [&] { if (new_tab_menu) new_tab_menu.Items().Clear(); }, result);
        profile_items.clear();
        new_tab_menu = nullptr;
        cleanup(L"detach application menu", [&] { menu_button.Flyout(nullptr); }, result);
        cleanup(L"clear application menu", [&] { app_menu.Items().Clear(); }, result);
        open_settings_item = nullptr;
        reload_settings_item = nullptr;
        about_item = nullptr;
        quit_item = nullptr;
        app_menu = nullptr;
        cleanup(L"detach new-tab button", [&] { tabs.TabStripFooter(nullptr); }, result);
        new_tab_button = nullptr;
        cleanup(L"clear tabs", [&] { tabs.TabItems().Clear(); }, result);
        cleanup(L"detach scrollbar content", [&] { scrollbar_source.Content(nullptr); }, result);
        cleanup(L"clear scrollbar content", [&] { scrollbar_root.Children().Clear(); }, result);
        scrollbar = nullptr;
        scrollbar_root = nullptr;
        cleanup(L"close scrollbar XAML source", [&] { scrollbar_source.Close(); }, result);
        scrollbar_source = nullptr;
        scrollbar_timer = nullptr;
        cleanup(L"detach XAML content", [&] { source.Content(nullptr); }, result);
        cleanup(L"clear root content", [&] { root.Children().Clear(); }, result);
        bottom_border = nullptr;
        menu_button = nullptr;
        tabs = nullptr;
        root = nullptr;
        cleanup(L"clear system backdrop", [&] { source.SystemBackdrop(nullptr); }, result);
        backdrop = nullptr;
        cleanup(L"close XAML source", [&] { source.Close(); }, result);
        source = nullptr;
        about_operation = nullptr;
        about_dialog = nullptr;
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

extern "C" void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context, const char* version, uint32_t version_length, const char* git_hash, uint32_t git_hash_length) noexcept {
    if (!parent || !callback || (version_length && !version) || (git_hash_length && !git_hash)) return nullptr;
    try {
        init_apartment(apartment_type::single_threaded);
    } catch (...) {
        reportCurrentException(L"init_apartment");
        return nullptr;
    }
    try {
        auto const bootstrap_result = MddBootstrapInitialize2(
            Microsoft::WindowsAppSDK::Release::MajorMinor,
            Microsoft::WindowsAppSDK::Release::VersionTag,
            {Microsoft::WindowsAppSDK::Runtime::Version::UInt64},
            MddBootstrapInitializeOptions_OnNoMatch_ShowUI);
        if (FAILED(bootstrap_result)) {
            reportFailure(L"MddBootstrapInitialize2", bootstrap_result);
            uninit_apartment();
            return nullptr;
        }
        try {
            auto dispatcher = Microsoft::UI::Dispatching::DispatcherQueueController::CreateOnCurrentThread();
            auto application = make<ZigonautWinUIBridge::implementation::App>();
            return new Bridge(
                parent,
                callback,
                context,
                dispatcher,
                application,
                std::string_view{version ? version : "", version_length},
                std::string_view{git_hash ? git_hash : "", git_hash_length});
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

extern "C" HRESULT __cdecl zigonaut_chrome_update_profiles(void* value, const char* const* names, const uint32_t* name_lengths, uint32_t count) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!count || !names || !name_lengths) return E_INVALIDARG;
    try { bridge->updateProfiles(names, name_lengths, count); return S_OK; } catch (...) { return reportCurrentException(L"update profiles"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_scrollbar(void* value, uint32_t total, uint32_t page, uint32_t position, BOOL show) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->updateScrollbar(total, page, position, show != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update scrollbar"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_taskbar_progress(void* value, uint32_t state, uint32_t progress) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (state != TBPF_NOPROGRESS && state != TBPF_INDETERMINATE && state != TBPF_NORMAL && state != TBPF_ERROR && state != TBPF_PAUSED) return E_INVALIDARG;
    return bridge->updateTaskbarProgress(state, progress);
}

extern "C" HRESULT __cdecl zigonaut_chrome_show_notification(void* value, uint32_t session_id, const char* title, uint32_t title_length, const char* body, uint32_t body_length) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if ((title_length && !title) || (body_length && !body)) return E_INVALIDARG;
    return bridge->showNotification(session_id, std::string_view(title ? title : "", title_length), std::string_view(body ? body : "", body_length));
}

extern "C" HRESULT __cdecl zigonaut_chrome_move(void* value, int32_t x, int32_t y, int32_t width, int32_t height) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->move(x, y, width, height); return S_OK; } catch (...) { return reportCurrentException(L"move"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_appearance(void* value, uint32_t backdrop, BOOL high_contrast, BOOL dark_theme) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (backdrop > ZIGONAUT_BACKDROP_ACRYLIC) return E_INVALIDARG;
    try { bridge->updateAppearance(backdrop, high_contrast != FALSE, dark_theme != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update appearance"); }
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
