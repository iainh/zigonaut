#include "pch.h"
#include "App.xaml.h"
#include "bridge.h"
#include "TerminalControl.h"
#include "settings_dialog.h"
#include "tsf.h"
#include <MddBootstrap.h>
#include <WindowsAppSDK-VersionInfo.h>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Composition.SystemBackdrops.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/base.h>
#include <microsoft.ui.xaml.media.dxinterop.h>
#include <winrt/Microsoft.UI.Interop.h>
#include <winrt/Microsoft.Windows.AppNotifications.h>
#include <winrt/Microsoft.Windows.AppNotifications.Builder.h>
#include <shobjidl.h>
#include <algorithm>
#include <chrono>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <functional>
#include <limits>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
#include <unordered_map>
#include <unordered_set>

using namespace winrt;
using namespace winrt::Microsoft::UI;
using namespace winrt::Microsoft::UI::Xaml;
using namespace winrt::Microsoft::UI::Xaml::Controls;
using namespace winrt::Microsoft::Windows::AppNotifications;
using namespace winrt::Microsoft::Windows::AppNotifications::Builder;

namespace {
namespace Microsoft = winrt::Microsoft;

struct NotificationActivationState {
    std::atomic_bool active{true};
    zigonaut_chrome_command callback{};
    void* context{};
    Microsoft::UI::Dispatching::DispatcherQueue queue{nullptr};
    hstring nonce;
};

struct Bridge;

struct LayoutDispatchState {
    std::atomic_bool active{true};
    Bridge* bridge{};
};

HRESULT reportFailure(wchar_t const* operation, HRESULT result) noexcept {
    wchar_t message[160]{};
    swprintf_s(message, L"Zigonaut WinUI: %s failed with HRESULT 0x%08X\n", operation, static_cast<unsigned>(result));
    OutputDebugStringW(message);
    fwprintf(stderr, L"%ls", message);
    return result;
}

HRESULT reportCurrentException(wchar_t const* operation) noexcept {
    try {
        throw;
    } catch (hresult_error const& error) {
        fwprintf(stderr, L"Zigonaut WinUI: %ls\n", error.message().c_str());
        return reportFailure(operation, error.code());
    } catch (std::exception const& error) {
        fprintf(stderr, "Zigonaut WinUI: %s\n", error.what());
        return reportFailure(operation, E_FAIL);
    } catch (...) {
        return reportFailure(operation, E_FAIL);
    }
}

bool validString(char const* value, uint32_t length) noexcept {
    return length <= static_cast<uint32_t>(std::numeric_limits<int32_t>::max()) &&
        (value || !length);
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
    // All WinUI objects and event revocation stay on the Application::Start STA.
    DWORD thread_id = GetCurrentThreadId();
    zigonaut_chrome_command callback{};
    zigonaut_pane_event_callback pane_callback{};
    void* context{};
    Application application{nullptr};
    Window window{nullptr};
    HWND parent{};
    struct Attachment { HWND window{}; com_ptr<IDXGISwapChain> swap_chain; uint32_t cell_width{}, cell_height{}, minimum_width{}, minimum_height{}; };
    std::unordered_map<uint64_t, Attachment> attachments;
    uint64_t active_pane{};
    struct PaneHost {
        uint64_t pane_id{}; HWND window{}; com_ptr<IDXGISwapChain> swap_chain;
        uint32_t cell_width{}, cell_height{}, minimum_width{}, minimum_height{};
        Border frame{nullptr}; Grid grid{nullptr}; SwapChainPanel panel{nullptr}; ZigonautWinUIBridge::TerminalControl input{nullptr}; Border focus_indicator{nullptr};
        Microsoft::UI::Xaml::Controls::Primitives::ScrollBar scrollbar{nullptr};
        Microsoft::UI::Dispatching::DispatcherQueueTimer timer{nullptr};
        RECT bounds{-1,-1,-1,-1}; std::wstring translated_characters;
        TsfService::Provider tsf_provider{};
        bool tsf_focused{}, updating_scrollbar{}, pointer_over_scrollbar{}, initialized{}; uint32_t total{}, page{}, position{};
        UIElement::KeyDown_revoker key_down{}; UIElement::KeyUp_revoker key_up{}; UIElement::CharacterReceived_revoker character{};
        UIElement::GotFocus_revoker focus{}; UIElement::LostFocus_revoker blur{};
        UIElement::PointerPressed_revoker pressed{}; UIElement::PointerReleased_revoker released{}; UIElement::PointerMoved_revoker moved{};
        UIElement::PointerWheelChanged_revoker wheel{}; UIElement::PointerExited_revoker exited{};
        UIElement::PointerCanceled_revoker canceled{}; UIElement::PointerCaptureLost_revoker capture_lost{};
        Microsoft::UI::Xaml::Controls::Primitives::ScrollBar::Scroll_revoker scroll{};
        UIElement::PointerEntered_revoker scrollbar_entered{}; UIElement::PointerExited_revoker scrollbar_exited{};
        UIElement::PointerWheelChanged_revoker scrollbar_wheel{};
        Microsoft::UI::Dispatching::DispatcherQueueTimer::Tick_revoker tick{};
    };
    struct SplitHost {
        uint64_t id{}; uint32_t axis{}; uint16_t committed{}; Grid grid{nullptr};
        uint32_t cell_width{}, cell_height{};
        double minimum_width{}, minimum_height{}, minimum_first{}, minimum_second{};
        RowDefinition row_a{nullptr}, row_b{nullptr}; ColumnDefinition column_a{nullptr}, column_b{nullptr};
        Border divider{nullptr};
        Microsoft::UI::Xaml::Controls::Primitives::Thumb thumb{nullptr};
        Microsoft::UI::Input::InputCursor cursor{nullptr};
        FrameworkElement::Loaded_revoker loaded{};
        Microsoft::UI::Xaml::Controls::Primitives::Thumb::DragStarted_revoker started{};
        Microsoft::UI::Xaml::Controls::Primitives::Thumb::DragDelta_revoker delta{};
        Microsoft::UI::Xaml::Controls::Primitives::Thumb::DragCompleted_revoker completed{};
        UIElement::KeyDown_revoker key_down{};
        UIElement::GotFocus_revoker focus{}; UIElement::LostFocus_revoker blur{};
        UIElement::PointerEntered_revoker entered{}; UIElement::PointerExited_revoker exited{};
        double drag_origin{}, drag_change{}; bool dragging{};
    };
    std::unordered_map<uint64_t, std::unique_ptr<PaneHost>> pane_hosts;
    winrt::com_ptr<TsfService> tsf;
    std::unordered_map<uint64_t, std::unique_ptr<SplitHost>> split_hosts;
    Microsoft::UI::Windowing::AppWindow app_window{nullptr};
    Microsoft::UI::Windowing::AppWindowTitleBar title_bar{nullptr};
    Microsoft::UI::Xaml::Media::MicaBackdrop backdrop{nullptr};
    Grid root{nullptr};
    Grid app_title_bar{nullptr};
    Grid content_root{nullptr};
    Border find_border{nullptr};
    TextBox find_box{nullptr};
    TextBlock find_status{nullptr};
    Button find_previous{nullptr};
    Button find_next{nullptr};
    Button find_close{nullptr};
    uint64_t find_pane{};
    bool updating_find = false;
    TabView tabs{nullptr};
    StackPanel new_tab_controls{nullptr};
    SplitButton new_tab_button{nullptr};
    Button menu_button{nullptr};
    Border bottom_border{nullptr};
    MenuFlyout app_menu{nullptr};
    MenuFlyoutItem new_tab_item{nullptr};
    MenuFlyoutItem new_window_item{nullptr};
    MenuFlyoutSubItem view_item{nullptr};
    MenuFlyoutItem increase_font_size_item{nullptr};
    MenuFlyoutItem decrease_font_size_item{nullptr};
    MenuFlyoutItem reset_font_size_item{nullptr};
    MenuFlyoutItem open_settings_item{nullptr};
    MenuFlyoutItem about_item{nullptr};
    MenuFlyoutItem quit_item{nullptr};
    ContentDialog about_dialog{nullptr};
    Windows::Foundation::IAsyncOperation<ContentDialogResult> about_operation{nullptr};
    std::shared_ptr<ZigonautSettings::Dialog> settings_dialog;
    MenuFlyout new_tab_menu{nullptr};
    std::vector<MenuFlyoutItem> profile_items;
    std::vector<MenuFlyoutItem::Click_revoker> profile_revokers;
    std::vector<MenuFlyoutItem::Click_revoker> app_command_revokers;
    std::vector<Microsoft::UI::Xaml::Input::KeyboardAccelerator> accelerators;
    std::vector<Microsoft::UI::Xaml::Input::KeyboardAccelerator::Invoked_revoker> accelerator_revokers;
    Window::Closed_revoker window_closed_revoker{};
    Window::Activated_revoker window_activated_revoker{};
    XamlRoot::Changed_revoker xaml_root_changed_revoker{};
    FrameworkElement::LayoutUpdated_revoker layout_revoker{};
    FrameworkElement::Loaded_revoker terminal_loaded_revoker{};
    SplitButton::Click_revoker new_tab_revoker{};
    TabView::SelectionChanged_revoker selection_revoker{};
    TabView::TabCloseRequested_revoker close_tab_revoker{};
    MenuFlyoutItem::Click_revoker new_tab_item_revoker{};
    MenuFlyoutItem::Click_revoker new_window_revoker{};
    MenuFlyoutItem::Click_revoker increase_font_size_revoker{};
    MenuFlyoutItem::Click_revoker decrease_font_size_revoker{};
    MenuFlyoutItem::Click_revoker reset_font_size_revoker{};
    MenuFlyoutItem::Click_revoker open_settings_revoker{};
    MenuFlyoutItem::Click_revoker about_revoker{};
    MenuFlyoutItem::Click_revoker quit_revoker{};
    TextBox::TextChanged_revoker find_text_changed_revoker{};
    UIElement::KeyDown_revoker find_key_down_revoker{};
    Button::Click_revoker find_previous_revoker{};
    Button::Click_revoker find_next_revoker{};
    Button::Click_revoker find_close_revoker{};
    ContentDialog::Closed_revoker about_closed_revoker{};
    bool handlers_detached = false;
    bool updating = false;
    bool appearance_initialized = false;
    bool layout_pending = false;
    uint32_t backdrop_kind = ZIGONAUT_BACKDROP_MICA;
    bool high_contrast = false;
    bool dark_theme = false;
    bool show_tab_colors = false;
    double rasterization_scale = 1;
    bool initial_size_applied = false;
    bool closed = false;
    com_ptr<ITaskbarList3> taskbar;
    bool taskbar_state_initialized = false;
    uint32_t taskbar_state = ZIGONAUT_TASKBAR_PROGRESS_NONE;
    uint32_t taskbar_value = 0;
    AppNotificationManager notification_manager{nullptr};
    AppNotificationManager::NotificationInvoked_revoker notification_revoker{};
    bool notifications_registered = false;
    std::shared_ptr<NotificationActivationState> notification_activation;
    std::shared_ptr<LayoutDispatchState> layout_dispatch = std::make_shared<LayoutDispatchState>();
    hstring app_version;
    hstring git_hash;

    Bridge(zigonaut_chrome_command cb, zigonaut_pane_event_callback pcb, void* ctx, Application const& app,
           std::string_view version, std::string_view hash)
        : callback(cb), pane_callback(pcb), context(ctx), application(app),
          app_version(to_hstring(version)), git_hash(to_hstring(hash)) {
        layout_dispatch->bridge = this;
        window = Window{};
        window.Title(L"Zigonaut");
        check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&parent));
        app_window = window.AppWindow();
        title_bar = app_window.TitleBar();

        GUID nonce{};
        check_hresult(CoCreateGuid(&nonce));
        wchar_t nonce_text[40]{};
        if (!StringFromGUID2(nonce, nonce_text, static_cast<int>(std::size(nonce_text)))) throw hresult_error(E_FAIL);
        notification_activation = std::make_shared<NotificationActivationState>();
        notification_activation->callback = callback;
        notification_activation->context = context;
        notification_activation->queue = Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread();
        notification_activation->nonce = nonce_text;

        root = Grid{};
        root.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        auto title_row = RowDefinition{};
        title_row.Height(GridLength{1, GridUnitType::Auto});
        root.RowDefinitions().Append(title_row);
        auto content_row = RowDefinition{};
        content_row.Height(GridLength{1, GridUnitType::Star});
        root.RowDefinitions().Append(content_row);

        app_title_bar = Grid{};
        app_title_bar.Height(48);
        Grid::SetRow(app_title_bar, 0);
        content_root = Grid{};
        Grid::SetRow(content_root, 1);

        find_border = Border{};
        find_border.HorizontalAlignment(HorizontalAlignment::Right);
        find_border.VerticalAlignment(VerticalAlignment::Top);
        find_border.Margin(Thickness{0});
        find_border.Padding(Thickness{8});
        // This is an edge-attached command surface, not a floating card. Fluent
        // leaves corners square where a surface meets the window edge and uses
        // the large radius only on the exposed corner.
        find_border.CornerRadius(CornerRadius{0, 0, 0, 8});
        find_border.Background(application.Resources().Lookup(box_value(L"CardBackgroundFillColorDefaultBrush"))
            .as<Microsoft::UI::Xaml::Media::Brush>());
        find_border.BorderBrush(application.Resources().Lookup(box_value(L"CardStrokeColorDefaultBrush"))
            .as<Microsoft::UI::Xaml::Media::Brush>());
        find_border.BorderThickness(Thickness{1, 0, 0, 1});
        find_border.BackgroundSizing(BackgroundSizing::InnerBorderEdge);
        find_border.Visibility(Visibility::Collapsed);
        Canvas::SetZIndex(find_border, 100);

        auto find_layout = Grid{};
        find_layout.ColumnSpacing(8);
        auto find_text_column = ColumnDefinition{};
        find_text_column.Width(GridLength{240, GridUnitType::Pixel});
        find_layout.ColumnDefinitions().Append(find_text_column);
        auto find_status_column = ColumnDefinition{};
        find_status_column.Width(GridLength{1, GridUnitType::Auto});
        find_layout.ColumnDefinitions().Append(find_status_column);
        for (auto index = 0; index < 3; ++index) {
            auto column = ColumnDefinition{};
            column.Width(GridLength{1, GridUnitType::Auto});
            find_layout.ColumnDefinitions().Append(column);
        }

        find_box = TextBox{};
        find_box.PlaceholderText(L"Find in terminal");
        find_box.MinWidth(200);
        find_box.VerticalAlignment(VerticalAlignment::Center);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(find_box, L"Find in terminal");
        Grid::SetColumn(find_box, 0);
        find_layout.Children().Append(find_box);

        find_status = TextBlock{};
        find_status.Text(L"0 matches");
        find_status.MinWidth(72);
        find_status.VerticalAlignment(VerticalAlignment::Center);
        find_status.TextAlignment(TextAlignment::Center);
        Grid::SetColumn(find_status, 1);
        find_layout.Children().Append(find_status);

        auto make_find_button = [this, find_layout](wchar_t const* glyph, wchar_t const* name, int column) {
            auto button = Button{};
            button.Style(application.Resources().Lookup(box_value(L"ZigonautTitleBarButtonStyle")).as<Style>());
            auto icon = FontIcon{};
            icon.Glyph(glyph);
            icon.FontSize(12);
            button.Content(icon);
            Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(button, name);
            ToolTipService::SetToolTip(button, box_value(name));
            Grid::SetColumn(button, column);
            find_layout.Children().Append(button);
            return button;
        };
        find_previous = make_find_button(L"\xE70E", L"Previous match (Shift+Enter)", 2);
        find_next = make_find_button(L"\xE70D", L"Next match (Enter)", 3);
        find_close = make_find_button(L"\xE711", L"Close find (Esc)", 4);
        find_previous.IsEnabled(false);
        find_next.IsEnabled(false);
        find_border.Child(find_layout);

        find_text_changed_revoker = find_box.TextChanged(auto_revoke, [this](auto&&, auto&&) {
            if (updating_find || !find_pane) return;
            auto const text = find_box.Text();
            imeEvent(ZIGONAUT_PANE_EVENT_FIND_QUERY, find_pane, std::wstring_view{text.c_str(), text.size()});
        });
        find_key_down_revoker = find_box.KeyDown(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
            auto const control = GetKeyState(VK_CONTROL) < 0;
            if (args.Key() == Windows::System::VirtualKey::Escape ||
                (control && args.Key() == Windows::System::VirtualKey::G)) {
                closeFind(true);
                args.Handled(true);
            } else if (control && args.Key() == Windows::System::VirtualKey::U) {
                find_box.Text(L"");
                args.Handled(true);
            } else if (args.Key() == Windows::System::VirtualKey::Enter ||
                       (control && (args.Key() == Windows::System::VirtualKey::N ||
                                    args.Key() == Windows::System::VirtualKey::P))) {
                auto const previous = args.Key() == Windows::System::VirtualKey::P ||
                    (args.Key() == Windows::System::VirtualKey::Enter && GetKeyState(VK_SHIFT) < 0);
                paneEvent(previous ? ZIGONAUT_PANE_EVENT_FIND_PREVIOUS : ZIGONAUT_PANE_EVENT_FIND_NEXT, find_pane, 0);
                args.Handled(true);
            }
        });
        find_previous_revoker = find_previous.Click(auto_revoke, [this](auto&&, auto&&) {
            paneEvent(ZIGONAUT_PANE_EVENT_FIND_PREVIOUS, find_pane, 0);
            find_box.Focus(FocusState::Programmatic);
        });
        find_next_revoker = find_next.Click(auto_revoke, [this](auto&&, auto&&) {
            paneEvent(ZIGONAUT_PANE_EVENT_FIND_NEXT, find_pane, 0);
            find_box.Focus(FocusState::Programmatic);
        });
        find_close_revoker = find_close.Click(auto_revoke, [this](auto&&, auto&&) { closeFind(true); });

        tabs = TabView{};

        auto const resources = application.Resources();

        tabs.IsAddTabButtonVisible(false);
        tabs.VerticalAlignment(VerticalAlignment::Bottom);
        tabs.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        tabs.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        tabs.TabWidthMode(TabViewWidthMode::Equal);
        tabs.CloseButtonOverlayMode(TabViewCloseButtonOverlayMode::Auto);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(tabs, L"Terminal tabs");
        new_tab_controls = StackPanel{};
        new_tab_controls.Orientation(Orientation::Horizontal);
        new_tab_controls.VerticalAlignment(VerticalAlignment::Center);
        new_tab_menu = MenuFlyout{};
        new_tab_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        new_tab_button = SplitButton{};
        new_tab_button.Margin(Thickness{0, 0, 4, 0});
        new_tab_button.VerticalAlignment(VerticalAlignment::Center);
        auto const new_tab_icon = FontIcon{};
        new_tab_icon.Glyph(L"\xE710");
        new_tab_icon.FontSize(16);
        new_tab_button.Content(new_tab_icon);
        new_tab_button.Flyout(new_tab_menu);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(new_tab_button, L"New tab");
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(new_tab_button, L"Open the default profile, or choose another profile");
        ToolTipService::SetToolTip(new_tab_button, box_value(L"New tab (Ctrl+Shift+T)"));
        new_tab_revoker = new_tab_button.Click(auto_revoke, [this](auto&&, auto&&) {
            notify(ZIGONAUT_CHROME_NEW_DEFAULT, 0);
            focusTerminal();
        });
        new_tab_controls.Children().Append(new_tab_button);
        tabs.TabStripFooter(new_tab_controls);
        selection_revoker = tabs.SelectionChanged(auto_revoke, [this](auto&&, auto&&) {
            if (!updating && tabs.SelectedIndex() >= 0) {
                notify(ZIGONAUT_CHROME_SELECT, static_cast<uint32_t>(tabs.SelectedIndex()));
                focusTerminal();
            }
        });
        close_tab_revoker = tabs.TabCloseRequested(auto_revoke, [this](TabView const& sender, TabViewTabCloseRequestedEventArgs const& args) {
            uint32_t index = 0;
            if (sender.TabItems().IndexOf(args.Item(), index)) {
                notify(ZIGONAUT_CHROME_CLOSE, index);
                focusTerminal();
            }
        });

        menu_button = Button{};
        menu_button.Style(resources.Lookup(box_value(L"ZigonautTitleBarButtonStyle")).as<Style>());
        menu_button.HorizontalAlignment(HorizontalAlignment::Left);
        menu_button.VerticalAlignment(VerticalAlignment::Bottom);
        menu_button.VerticalContentAlignment(VerticalAlignment::Center);
        menu_button.Margin(Thickness{4, 0, 0, 8});
        auto const menu_icon = FontIcon{};
        menu_icon.Glyph(L"\xE700");
        menu_icon.FontSize(16);
        menu_button.Content(menu_icon);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(menu_button, L"Application menu");
        ToolTipService::SetToolTip(menu_button, box_value(L"Application menu"));

        bottom_border = Border{};
        bottom_border.Style(resources.Lookup(box_value(L"ZigonautTitleBarDividerStyle")).as<Style>());
        Grid::SetRow(bottom_border, 0);

        app_menu = MenuFlyout{};
        app_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        new_tab_item = MenuFlyoutItem{};
        new_tab_item.Text(L"New tab");
        new_tab_item.AccessKey(L"T");
        new_tab_item.KeyboardAcceleratorTextOverride(L"Ctrl+Shift+T");
        new_tab_item_revoker = new_tab_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_NEW_DEFAULT, 0); });
        new_window_item = MenuFlyoutItem{};
        new_window_item.Text(L"New window");
        new_window_item.AccessKey(L"N");
        new_window_item.KeyboardAcceleratorTextOverride(L"Ctrl+Shift+N");
        new_window_revoker = new_window_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_NEW_WINDOW, 0); });
        auto pane_item = MenuFlyoutSubItem{};
        pane_item.Text(L"Terminal");
        auto add_pane_command = [this, pane_item](std::wstring_view text, std::wstring_view shortcut, zigonaut_chrome_command_id command) {
            auto item = MenuFlyoutItem{};
            item.Text(text);
            item.KeyboardAcceleratorTextOverride(shortcut);
            app_command_revokers.emplace_back(item.Click(auto_revoke, [this, command](auto&&, auto&&) {
                notify(command, 0);
                focusTerminal();
            }));
            pane_item.Items().Append(item);
        };
        add_pane_command(L"Find", L"Ctrl+Shift+F", ZIGONAUT_CHROME_FIND);
        pane_item.Items().Append(MenuFlyoutSeparator{});
        add_pane_command(L"Split right", L"Ctrl+Shift+O", ZIGONAUT_CHROME_SPLIT_RIGHT);
        add_pane_command(L"Split down", L"Ctrl+Shift+E", ZIGONAUT_CHROME_SPLIT_DOWN);
        add_pane_command(L"Close pane", L"Ctrl+Shift+W", ZIGONAUT_CHROME_CLOSE_PANE);
        auto focus_item = MenuFlyoutSubItem{};
        focus_item.Text(L"Focus pane");
        auto add_focus_command = [this, focus_item](std::wstring_view text, std::wstring_view shortcut, zigonaut_chrome_command_id command) {
            auto item = MenuFlyoutItem{};
            item.Text(text);
            item.KeyboardAcceleratorTextOverride(shortcut);
            app_command_revokers.emplace_back(item.Click(auto_revoke, [this, command](auto&&, auto&&) {
                notify(command, 0);
                focusTerminal();
            }));
            focus_item.Items().Append(item);
        };
        add_focus_command(L"Left", L"Ctrl+Alt+Left", ZIGONAUT_CHROME_FOCUS_LEFT);
        add_focus_command(L"Right", L"Ctrl+Alt+Right", ZIGONAUT_CHROME_FOCUS_RIGHT);
        add_focus_command(L"Up", L"Ctrl+Alt+Up", ZIGONAUT_CHROME_FOCUS_UP);
        add_focus_command(L"Down", L"Ctrl+Alt+Down", ZIGONAUT_CHROME_FOCUS_DOWN);
        pane_item.Items().Append(focus_item);
        view_item = MenuFlyoutSubItem{};
        view_item.Text(L"View");
        view_item.AccessKey(L"V");
        increase_font_size_item = MenuFlyoutItem{};
        increase_font_size_item.Text(L"Increase font size");
        increase_font_size_item.AccessKey(L"I");
        increase_font_size_item.KeyboardAcceleratorTextOverride(L"Ctrl++");
        increase_font_size_revoker = increase_font_size_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_ZOOM_IN, 0); });
        decrease_font_size_item = MenuFlyoutItem{};
        decrease_font_size_item.Text(L"Decrease font size");
        decrease_font_size_item.AccessKey(L"D");
        decrease_font_size_item.KeyboardAcceleratorTextOverride(L"Ctrl+-");
        decrease_font_size_revoker = decrease_font_size_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_ZOOM_OUT, 0); });
        reset_font_size_item = MenuFlyoutItem{};
        reset_font_size_item.Text(L"Reset font size");
        reset_font_size_item.AccessKey(L"R");
        reset_font_size_item.KeyboardAcceleratorTextOverride(L"Ctrl+0");
        reset_font_size_revoker = reset_font_size_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_ZOOM_RESET, 0); });
        view_item.Items().Append(increase_font_size_item);
        view_item.Items().Append(decrease_font_size_item);
        view_item.Items().Append(reset_font_size_item);
        open_settings_item = MenuFlyoutItem{};
        open_settings_item.Text(L"Settings");
        open_settings_item.AccessKey(L"S");
        open_settings_revoker = open_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_OPEN_SETTINGS, 0); });
        about_item = MenuFlyoutItem{};
        about_item.Text(L"About Zigonaut");
        about_item.AccessKey(L"A");
        about_revoker = about_item.Click(auto_revoke, [this](auto&&, auto&&) { showAboutDialog(); });
        quit_item = MenuFlyoutItem{};
        quit_item.Text(L"Exit");
        quit_item.AccessKey(L"X");
        quit_revoker = quit_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_QUIT, 0); });
        app_menu.Items().Append(new_tab_item);
        app_menu.Items().Append(new_window_item);
        app_menu.Items().Append(MenuFlyoutSeparator{});
        app_menu.Items().Append(pane_item);
        app_menu.Items().Append(view_item);
        app_menu.Items().Append(MenuFlyoutSeparator{});
        app_menu.Items().Append(open_settings_item);
        app_menu.Items().Append(MenuFlyoutSeparator{});
        app_menu.Items().Append(about_item);
        app_menu.Items().Append(quit_item);
        menu_button.Flyout(app_menu);

        tabs.HorizontalAlignment(HorizontalAlignment::Left);
        tabs.Margin(Thickness{40, 0, 0, 0});
        app_title_bar.Children().Append(tabs);
        app_title_bar.Children().Append(menu_button);
        root.Children().Append(content_root);
        root.Children().Append(app_title_bar);
        root.Children().Append(bottom_border);
        window.Content(root);
        window.ExtendsContentIntoTitleBar(true);
        window.SetTitleBar(app_title_bar);
        title_bar.PreferredHeightOption(Microsoft::UI::Windowing::TitleBarHeightOption::Tall);
        backdrop = Microsoft::UI::Xaml::Media::MicaBackdrop{};
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::Base);
        window.SystemBackdrop(backdrop);
        enableTitleBar();
        layout_revoker = root.LayoutUpdated(auto_revoke, [this](auto&&, auto&&) {
            scheduleLayoutTerminal();
            updateTitleBarLayout();
        });
        window_closed_revoker = window.Closed(auto_revoke, [this](auto&&, auto&&) {
            notify(ZIGONAUT_CHROME_SHUTDOWN, 0);
            close();
        });
        window_activated_revoker = window.Activated(auto_revoke, [this](auto&&, WindowActivatedEventArgs const& args) {
            auto const active = pane_hosts.find(active_pane);
            if (active == pane_hosts.end()) return;
            if (args.WindowActivationState() == WindowActivationState::Deactivated) {
                SendMessageW(active->second->window, WM_KILLFOCUS, 0, 0);
            } else if (active->second->input.FocusState() != FocusState::Unfocused) {
                SendMessageW(active->second->window, WM_SETFOCUS, 0, 0);
            }
        });
        addAccelerator(Windows::System::VirtualKey::T, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_NEW_DEFAULT);
        addAccelerator(Windows::System::VirtualKey::N, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_NEW_WINDOW);
        addAccelerator(Windows::System::VirtualKey::F, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_FIND);
        addAccelerator(Windows::System::VirtualKey::W, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_CLOSE_PANE);
        addAccelerator(Windows::System::VirtualKey::O, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_SPLIT_RIGHT);
        addAccelerator(Windows::System::VirtualKey::E, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_SPLIT_DOWN);
        addAccelerator(Windows::System::VirtualKey::Left, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Menu, ZIGONAUT_CHROME_FOCUS_LEFT);
        addAccelerator(Windows::System::VirtualKey::Right, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Menu, ZIGONAUT_CHROME_FOCUS_RIGHT);
        addAccelerator(Windows::System::VirtualKey::Up, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Menu, ZIGONAUT_CHROME_FOCUS_UP);
        addAccelerator(Windows::System::VirtualKey::Down, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Menu, ZIGONAUT_CHROME_FOCUS_DOWN);
        addAccelerator(Windows::System::VirtualKey::Tab, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_SELECT_NEXT);
        addAccelerator(Windows::System::VirtualKey::Tab, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_SELECT_PREVIOUS);
        addAccelerator(Windows::System::VirtualKey::Number0, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_RESET);
        addAccelerator(Windows::System::VirtualKey::NumberPad0, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_RESET);
        addAccelerator(Windows::System::VirtualKey::Add, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_IN);
        addAccelerator(Windows::System::VirtualKey::Subtract, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_OUT);
        addAccelerator(static_cast<Windows::System::VirtualKey>(VK_OEM_PLUS), Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_IN);
        addAccelerator(static_cast<Windows::System::VirtualKey>(VK_OEM_MINUS), Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_OUT);
        // Initialize last so constructor failure cannot leave TSF's advised
        // sink references holding a partially constructed Bridge alive.
        tsf.attach(new TsfService{});
        if (FAILED(tsf->Initialize())) tsf = nullptr;
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
        try {
            auto const transparent = box_value(Windows::UI::Color{0, 0, 0, 0})
                .as<Windows::Foundation::IReference<Windows::UI::Color>>();
            title_bar.ButtonBackgroundColor(transparent);
            title_bar.ButtonInactiveBackgroundColor(transparent);
            updateTitleBarLayout();
        } catch (...) {
            reportCurrentException(L"enable custom title bar");
        }
    }

    void addAccelerator(Windows::System::VirtualKey key, Windows::System::VirtualKeyModifiers modifiers,
                        zigonaut_chrome_command_id command) {
        auto accelerator = Microsoft::UI::Xaml::Input::KeyboardAccelerator{};
        accelerator.Key(key);
        accelerator.Modifiers(modifiers);
        accelerator_revokers.emplace_back(accelerator.Invoked(auto_revoke, [this, command](auto&&, Microsoft::UI::Xaml::Input::KeyboardAcceleratorInvokedEventArgs const& args) {
            auto const active = pane_hosts.find(active_pane);
            if (active != pane_hosts.end() && active->second->input.FocusState() != FocusState::Unfocused) return;
            auto argument = uint32_t{};
            if (command == ZIGONAUT_CHROME_CLOSE && tabs.SelectedIndex() >= 0) {
                argument = static_cast<uint32_t>(tabs.SelectedIndex());
            }
            notify(command, argument);
            args.Handled(true);
        }));
        root.KeyboardAccelerators().Append(accelerator);
        accelerators.emplace_back(std::move(accelerator));
    }

    void attachPane(uint64_t id, HWND child, void* value, uint32_t cell_width, uint32_t cell_height, uint32_t minimum_width, uint32_t minimum_height, uint32_t initial_width, uint32_t initial_height) {
        if (!id || !child || GetParent(child) != parent || !value || !cell_width || !cell_height || !minimum_width || !minimum_height || !initial_width || !initial_height) throw hresult_invalid_argument();
        Attachment attachment{child, {}, cell_width, cell_height, minimum_width, minimum_height};
        static_cast<IDXGISwapChain*>(value)->QueryInterface(IID_PPV_ARGS(attachment.swap_chain.put()));
        if (!attachment.swap_chain) throw hresult_invalid_argument();
        attachments.insert_or_assign(id, std::move(attachment));
        if (!initial_size_applied) {
            initial_size_applied = true;
            RECT window_bounds{}, client_bounds{};
            if (GetWindowRect(parent, &window_bounds) && GetClientRect(parent, &client_bounds)) {
                auto const dpi = GetDpiForWindow(parent);
                auto const title_height = MulDiv(48, dpi ? dpi : 96, 96);
                auto const frame_width = (window_bounds.right - window_bounds.left) - client_bounds.right;
                auto const frame_height = (window_bounds.bottom - window_bounds.top) - client_bounds.bottom;
                app_window.Resize({
                    static_cast<int32_t>(initial_width) + frame_width,
                    static_cast<int32_t>(initial_height) + title_height + frame_height,
                });
            }
        }
    }

    void detachPane(uint64_t id) {
        if (!id) throw hresult_invalid_argument();
        if (pane_hosts.count(id)) {
            for (auto& [_, host] : pane_hosts) {
                if (tsf) tsf->Unfocus(&host->tsf_provider);
                if (host->timer) host->timer.Stop();
                check_hresult(host->panel.as<ISwapChainPanelNative>()->SetSwapChain(nullptr));
            }
            content_root.Children().Clear();
            pane_hosts.clear();
            split_hosts.clear();
            active_pane = 0;
        }
        attachments.erase(id);
    }

    void focusPane(uint64_t id) {
        auto it = pane_hosts.find(id); if (it == pane_hosts.end()) throw hresult_invalid_argument();
        if (find_pane && find_pane != id) closeFind(true);
        setFocusedPane(id);
        if (find_pane == id && find_border.Visibility() == Visibility::Visible) {
            find_box.Focus(FocusState::Programmatic);
        } else {
            it->second->input.Focus(FocusState::Programmatic);
        }
    }

    void paneEvent(uint32_t kind, uint64_t id, uint32_t value) {
        if (!closed && pane_callback) { zigonaut_pane_event e{}; e.size=sizeof(e); e.kind=kind; e.target_id=id; e.value=value; pane_callback(context, &e); }
    }
    void imeEvent(uint32_t kind, uint64_t id, std::wstring_view text = {}, uint32_t start = 0, uint32_t length = 0) {
        if (!closed && pane_callback) { zigonaut_pane_event e{}; e.size=sizeof(e); e.kind=kind; e.target_id=id; e.text=reinterpret_cast<uint16_t const*>(text.data()); e.text_length=static_cast<uint32_t>(text.size()); e.selection_start=start; e.selection_length=length; pane_callback(context, &e); }
    }
    void setFocusedPane(uint64_t id) {
        if (active_pane == id) return;
        if (find_pane && find_pane != id) closeFind(true);
        active_pane = id;
        updatePaneFocusIndicators();
        paneEvent(ZIGONAUT_PANE_EVENT_FOCUS, id, 0);
    }

    void updatePaneFocusIndicators() {
        auto const show = pane_hosts.size() > 1;
        auto const accent = application.Resources().Lookup(box_value(L"AccentFillColorDefaultBrush"))
            .as<Microsoft::UI::Xaml::Media::Brush>();
        for (auto& [id, pane] : pane_hosts) {
            pane->focus_indicator.Background(show && id == active_pane ? accent : nullptr);
        }
    }

    std::unique_ptr<PaneHost> makePane(uint64_t id, Attachment const& attachment) {
        auto owned = std::make_unique<PaneHost>(); auto* p = owned.get(); p->pane_id=id; p->window=attachment.window; p->swap_chain=attachment.swap_chain; p->cell_width=attachment.cell_width; p->cell_height=attachment.cell_height; p->minimum_width=attachment.minimum_width; p->minimum_height=attachment.minimum_height;
        p->frame=Border{}; p->frame.Style(application.Resources().Lookup(box_value(L"ZigonautTerminalFrameStyle")).as<Style>()); p->grid=Grid{};
        p->panel=SwapChainPanel{}; p->input=make<ZigonautWinUIBridge::implementation::TerminalControl>();
        get_self<ZigonautWinUIBridge::implementation::TerminalControl>(p->input)->Window(p->window);
        p->input.Opacity(0); p->input.IsTabStop(true); p->input.IsHitTestVisible(false);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetAccessibilityView(
            p->input, Microsoft::UI::Xaml::Automation::Peers::AccessibilityView::Control);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(p->input, L"ZigonautTerminalPane");
        p->focus_indicator=Border{}; p->focus_indicator.Height(2); p->focus_indicator.VerticalAlignment(VerticalAlignment::Top); p->focus_indicator.IsHitTestVisible(false);
        p->scrollbar=Microsoft::UI::Xaml::Controls::Primitives::ScrollBar{}; p->scrollbar.Orientation(Orientation::Vertical); p->scrollbar.HorizontalAlignment(HorizontalAlignment::Right); p->scrollbar.Width(12); p->scrollbar.Opacity(0); p->scrollbar.Visibility(Visibility::Collapsed);
        p->grid.Children().Append(p->panel); p->grid.Children().Append(p->input); p->grid.Children().Append(p->scrollbar); p->grid.Children().Append(p->focus_indicator); p->frame.Child(p->grid);
        check_hresult(p->panel.as<ISwapChainPanelNative>()->SetSwapChain(p->swap_chain.get()));
        p->tsf_provider.hwnd = p->window;
        p->tsf_provider.commit = [this, id](std::wstring_view value) { imeEvent(ZIGONAUT_PANE_EVENT_IME_COMMIT, id, value); };
        p->tsf_provider.preedit = [this, id](std::wstring_view value, uint32_t start, uint32_t length) { imeEvent(ZIGONAUT_PANE_EVENT_IME_PREEDIT, id, value, start, length); };
        p->tsf_provider.clear = [this, id] { imeEvent(ZIGONAUT_PANE_EVENT_IME_CLEAR, id); };
        p->focus = p->input.GotFocus(auto_revoke, [this, p](auto&&, auto&&) {
            setFocusedPane(p->pane_id);
            p->tsf_provider.focus_hwnd = GetFocus();
            p->tsf_focused = tsf && tsf->Focus(&p->tsf_provider);
            SendMessageW(p->window, WM_SETFOCUS, 0, 0);
        });
        p->blur = p->input.LostFocus(auto_revoke, [this, p](auto&&, auto&&) {
            if (tsf) tsf->Unfocus(&p->tsf_provider);
            p->tsf_focused = false;
            SendMessageW(p->window, WM_KILLFOCUS, 0, 0);
        });
        p->key_down = p->input.KeyDown(auto_revoke, [this, p](auto&&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
            auto const status = args.KeyStatus();
            if (status.IsMenuKeyDown && (args.Key() == Windows::System::VirtualKey::F4 ||
                                         args.Key() == Windows::System::VirtualKey::Space)) return;
            if (tsf && tsf->Active()) { args.Handled(true); return; }
            SendMessageW(p->window, status.IsMenuKeyDown ? WM_SYSKEYDOWN : WM_KEYDOWN,
                         static_cast<WPARAM>(args.Key()), keyLparam(status));
            forwardTranslatedCharacters(*p, args.Key(), status);
            args.Handled(true);
        });
        p->key_up = p->input.KeyUp(auto_revoke, [this, p](auto&&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
            auto const status = args.KeyStatus();
            if (tsf && tsf->Active()) { args.Handled(true); return; }
            SendMessageW(p->window, status.IsMenuKeyDown ? WM_SYSKEYUP : WM_KEYUP,
                         static_cast<WPARAM>(args.Key()), keyLparam(status));
            args.Handled(true);
        });
        p->character = p->input.CharacterReceived(auto_revoke, [this, p](auto&&, Microsoft::UI::Xaml::Input::CharacterReceivedRoutedEventArgs const& args) {
            auto const status = args.KeyStatus();
            if (tsf && tsf->Active()) { args.Handled(true); return; }
            if (!p->translated_characters.empty() &&
                static_cast<uint32_t>(p->translated_characters.front()) == args.Character()) {
                p->translated_characters.erase(p->translated_characters.begin());
                args.Handled(true);
                return;
            }
            p->translated_characters.clear();
            SendMessageW(p->window, status.IsMenuKeyDown ? WM_SYSCHAR : WM_CHAR,
                         static_cast<WPARAM>(args.Character()), keyLparam(status));
            args.Handled(true);
        });
        p->pressed=p->panel.PointerPressed(auto_revoke,[this,p](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& a){
            auto q=a.GetCurrentPoint(p->panel); UINT message{};
            switch(q.Properties().PointerUpdateKind()) {
            case Microsoft::UI::Input::PointerUpdateKind::LeftButtonPressed: message=WM_LBUTTONDOWN; break;
            case Microsoft::UI::Input::PointerUpdateKind::RightButtonPressed: message=WM_RBUTTONDOWN; break;
            case Microsoft::UI::Input::PointerUpdateKind::MiddleButtonPressed: message=WM_MBUTTONDOWN; break;
            default: return;
            }
            p->input.Focus(FocusState::Pointer); SendMessageW(p->window,message,pointerWparam(q.Properties()),pointerLparam(q)); p->panel.CapturePointer(a.Pointer()); a.Handled(true);
        });
        p->released=p->panel.PointerReleased(auto_revoke,[this,p](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& a){
            auto q=a.GetCurrentPoint(p->panel); UINT message{};
            switch(q.Properties().PointerUpdateKind()) {
            case Microsoft::UI::Input::PointerUpdateKind::LeftButtonReleased: message=WM_LBUTTONUP; break;
            case Microsoft::UI::Input::PointerUpdateKind::RightButtonReleased: message=WM_RBUTTONUP; break;
            case Microsoft::UI::Input::PointerUpdateKind::MiddleButtonReleased: message=WM_MBUTTONUP; break;
            default: return;
            }
            SendMessageW(p->window,message,pointerWparam(q.Properties()),pointerLparam(q)); p->panel.ReleasePointerCapture(a.Pointer()); a.Handled(true);
        });
        p->moved=p->panel.PointerMoved(auto_revoke,[this,p](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& a){auto q=a.GetCurrentPoint(p->panel); SendMessageW(p->window,WM_MOUSEMOVE,pointerWparam(q.Properties()),pointerLparam(q)); a.Handled(true);});
        p->wheel=p->panel.PointerWheelChanged(auto_revoke,[this,p](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& a){auto q=a.GetCurrentPoint(p->panel); auto local=pointerLparam(q); POINT screen{(short)LOWORD(local),(short)HIWORD(local)}; ClientToScreen(p->window,&screen); auto properties=q.Properties(); SendMessageW(p->window,properties.IsHorizontalMouseWheel()?WM_MOUSEHWHEEL:WM_MOUSEWHEEL,MAKEWPARAM(pointerWparam(properties),(short)properties.MouseWheelDelta()),MAKELPARAM((short)screen.x,(short)screen.y)); a.Handled(true);});
        p->exited=p->panel.PointerExited(auto_revoke,[p](auto&&, auto const& a){SendMessageW(p->window,WM_MOUSELEAVE,0,0);a.Handled(true);});
        p->canceled=p->panel.PointerCanceled(auto_revoke,[p](auto&&, auto const& a){SendMessageW(p->window,WM_CANCELMODE,0,0);a.Handled(true);});
        p->capture_lost=p->panel.PointerCaptureLost(auto_revoke,[p](auto&&, auto&&){SendMessageW(p->window,WM_CAPTURECHANGED,0,0);});
        p->scroll = p->scrollbar.Scroll(auto_revoke, [this, p](auto&&, Microsoft::UI::Xaml::Controls::Primitives::ScrollEventArgs const& args) {
            if (p->updating_scrollbar) return;
            showPaneScrollbar(*p);
            paneEvent(ZIGONAUT_PANE_EVENT_SCROLL, p->pane_id,
                      static_cast<uint32_t>(std::clamp(args.NewValue(), 0.0, static_cast<double>(UINT32_MAX))));
        });
        p->scrollbar_entered = p->scrollbar.PointerEntered(auto_revoke, [this, p](auto&&, auto&&) {
            p->pointer_over_scrollbar = true;
            showPaneScrollbar(*p);
        });
        p->scrollbar_exited = p->scrollbar.PointerExited(auto_revoke, [this, p](auto&&, auto&&) {
            p->pointer_over_scrollbar = false;
            schedulePaneScrollbarHide(*p);
        });
        p->scrollbar_wheel = p->scrollbar.PointerWheelChanged(auto_revoke, [this, p](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            showPaneScrollbar(*p);
            auto const delta = args.GetCurrentPoint(p->scrollbar).Properties().MouseWheelDelta();
            paneEvent(ZIGONAUT_PANE_EVENT_SCROLL_WHEEL, p->pane_id, static_cast<uint32_t>(delta));
            args.Handled(true);
        });
        p->timer=notification_activation->queue.CreateTimer(); p->timer.Interval(std::chrono::seconds(2)); p->timer.IsRepeating(false); p->tick=p->timer.Tick(auto_revoke,[p](auto&&,auto&&){if(!p->pointer_over_scrollbar)p->scrollbar.Opacity(0);});
        return owned;
    }

    void updateLayout(zigonaut_layout_node const* nodes, uint32_t count, uint64_t focused) {
        if (!nodes || !count || !focused) throw hresult_invalid_argument();
        if (auto const xaml_root = content_root.XamlRoot()) rasterization_scale = xaml_root.RasterizationScale();
        std::unordered_set<uint64_t> ids;
        for (uint32_t i = 0; i < count; ++i) {
            auto const& n = nodes[i];
            if (n.size != sizeof(n) || n.reserved || !n.id || !ids.insert(n.id).second ||
                !n.subtree_size || n.subtree_size > count - i) throw hresult_invalid_argument();
            if (n.kind == ZIGONAUT_LAYOUT_LEAF) {
                if (n.axis || n.ratio || n.subtree_size != 1) throw hresult_invalid_argument();
            } else if (n.kind == ZIGONAUT_LAYOUT_SPLIT) {
                if ((n.axis != ZIGONAUT_AXIS_LEFT_RIGHT && n.axis != ZIGONAUT_AXIS_TOP_BOTTOM) ||
                    !n.ratio || n.ratio >= 65535 || n.subtree_size < 3) throw hresult_invalid_argument();
                auto const left = i + 1;
                auto const right = left + nodes[left].subtree_size;
                if (right >= i + n.subtree_size || right + nodes[right].subtree_size != i + n.subtree_size)
                    throw hresult_invalid_argument();
            } else throw hresult_invalid_argument();
        }
        if (nodes[0].subtree_size != count) throw hresult_invalid_argument();
        auto found = false;
        for (uint32_t i = 0; i < count; ++i) if (nodes[i].kind == ZIGONAUT_LAYOUT_LEAF && nodes[i].id == focused) found = true;
        if (!found) throw hresult_invalid_argument();
        for(uint32_t i=0;i<count;++i) if(nodes[i].kind==ZIGONAUT_LAYOUT_LEAF && !attachments.count(nodes[i].id)) throw hresult_invalid_argument();
        if (find_pane && !ids.count(find_pane)) closeFind(true);
        if (active_pane != focused) {
            auto const previous = pane_hosts.find(active_pane);
            if (previous != pane_hosts.end() &&
                previous->second->input.FocusState() != FocusState::Unfocused) {
                SendMessageW(previous->second->window, WM_KILLFOCUS, 0, 0);
            }
        }
        content_root.Children().Clear();
        for (auto& [_, host] : split_hosts) host->grid.Children().Clear();
        for (auto it = pane_hosts.begin(); it != pane_hosts.end();) {
            if (ids.count(it->first)) {
                ++it;
            } else {
                if (tsf) tsf->Unfocus(&it->second->tsf_provider);
                if (it->second->timer) it->second->timer.Stop();
                check_hresult(it->second->panel.as<ISwapChainPanelNative>()->SetSwapChain(nullptr));
                it = pane_hosts.erase(it);
            }
        }
        for (auto it = split_hosts.begin(); it != split_hosts.end();) {
            auto const node = std::find_if(nodes, nodes + count, [id = it->first](auto const& value) {
                return value.kind == ZIGONAUT_LAYOUT_SPLIT && value.id == id;
            });
            if (node == nodes + count || node->axis != it->second->axis) {
                it = split_hosts.erase(it);
            } else {
                ++it;
            }
        }
        std::function<FrameworkElement(uint32_t)> build = [&](uint32_t i)->FrameworkElement {
            auto const& n=nodes[i];
            if(n.kind==ZIGONAUT_LAYOUT_LEAF){
                auto existing = pane_hosts.find(n.id);
                if (existing != pane_hosts.end()) return existing->second->frame;
                auto p=makePane(n.id,attachments.at(n.id)); auto visual=p->frame; pane_hosts.emplace(n.id,std::move(p)); return visual;
            }
            auto existing = split_hosts.find(n.id);
            SplitHost* h{};
            if (existing != split_hosts.end()) {
                h = existing->second.get();
            } else {
                auto s = std::make_unique<SplitHost>();
                h = s.get();
                h->id = n.id;
                h->axis = n.axis;
                h->grid = Grid{};
                h->thumb = Microsoft::UI::Xaml::Controls::Primitives::Thumb{};
                h->cursor = Microsoft::UI::Input::InputSystemCursor::Create(
                    n.axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? Microsoft::UI::Input::InputSystemCursorShape::SizeWestEast
                        : Microsoft::UI::Input::InputSystemCursorShape::SizeNorthSouth);
                h->thumb.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
                h->thumb.IsTabStop(true);
                h->thumb.UseSystemFocusVisuals(true);
                Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(h->thumb,
                    n.axis == ZIGONAUT_AXIS_LEFT_RIGHT ? L"Resize panes horizontally" : L"Resize panes vertically");
                Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(h->thumb,
                    n.axis == ZIGONAUT_AXIS_LEFT_RIGHT ? L"Use Left and Right arrow keys to resize panes" : L"Use Up and Down arrow keys to resize panes");
                h->loaded = h->thumb.Loaded(auto_revoke, [h](auto&&, auto&&) {
                    h->thumb.as<IUIElementProtected>().ProtectedCursor(h->cursor);
                    h->loaded.revoke();
                });
                h->divider = Border{};
                h->divider.Background(application.Resources()
                    .Lookup(box_value(L"DividerStrokeColorDefaultBrush"))
                    .as<Microsoft::UI::Xaml::Media::Brush>());
                if(n.axis==ZIGONAUT_AXIS_LEFT_RIGHT){h->column_a=ColumnDefinition{};auto gap=ColumnDefinition{};gap.Width({5,GridUnitType::Pixel});h->column_b=ColumnDefinition{};h->grid.ColumnDefinitions().Append(h->column_a);h->grid.ColumnDefinitions().Append(gap);h->grid.ColumnDefinitions().Append(h->column_b);h->thumb.Width(16);h->thumb.HorizontalAlignment(HorizontalAlignment::Center);}else{h->row_a=RowDefinition{};auto gap=RowDefinition{};gap.Height({5,GridUnitType::Pixel});h->row_b=RowDefinition{};h->grid.RowDefinitions().Append(h->row_a);h->grid.RowDefinitions().Append(gap);h->grid.RowDefinitions().Append(h->row_b);h->thumb.Height(16);h->thumb.VerticalAlignment(VerticalAlignment::Center);}
                auto set_divider_active = [this, h](bool active) {
                    h->divider.Background(application.Resources().Lookup(box_value(
                        active ? L"AccentFillColorDefaultBrush" : L"DividerStrokeColorDefaultBrush"))
                        .as<Microsoft::UI::Xaml::Media::Brush>());
                };
                h->entered = h->thumb.PointerEntered(auto_revoke, [set_divider_active](auto&&, auto&&) { set_divider_active(true); });
                h->exited = h->thumb.PointerExited(auto_revoke, [h, set_divider_active](auto&&, auto&&) {
                    if (!h->dragging && h->thumb.FocusState() == FocusState::Unfocused) set_divider_active(false);
                });
                h->focus = h->thumb.GotFocus(auto_revoke, [set_divider_active](auto&&, auto&&) { set_divider_active(true); });
                h->blur = h->thumb.LostFocus(auto_revoke, [h, set_divider_active](auto&&, auto&&) {
                    if (!h->dragging) set_divider_active(false);
                });
                h->key_down = h->thumb.KeyDown(auto_revoke, [this, h](auto&&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
                    auto const key = args.Key();
                    auto direction = 0;
                    if (h->axis == ZIGONAUT_AXIS_LEFT_RIGHT) {
                        if (key == Windows::System::VirtualKey::Left) direction = -1;
                        if (key == Windows::System::VirtualKey::Right) direction = 1;
                    } else {
                        if (key == Windows::System::VirtualKey::Up) direction = -1;
                        if (key == Windows::System::VirtualKey::Down) direction = 1;
                    }
                    if (!direction) return;
                    args.Handled(true);
                    auto const total = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->grid.ActualWidth() - 5
                        : h->grid.ActualHeight() - 5;
                    auto const physical_increment = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT ? h->cell_width : h->cell_height;
                    auto const increment = physical_increment / rasterization_scale;
                    if (!std::isfinite(total) || total <= 0 || !std::isfinite(increment) || increment <= 0) return;
                    auto minimum_first = h->minimum_first;
                    auto minimum_second = h->minimum_second;
                    auto const required = minimum_first + minimum_second;
                    if (required > total) {
                        auto const scale = total / required;
                        minimum_first *= scale;
                        minimum_second *= scale;
                    }
                    auto const current = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->column_a.ActualWidth()
                        : h->row_a.ActualHeight();
                    auto const next = std::clamp(current + direction * increment, minimum_first, total - minimum_second);
                    if (!std::isfinite(current) || std::abs(next - current) < 0.5) return;
                    h->committed = static_cast<uint16_t>(std::clamp(
                        std::lround(next / total * 65535), 1l, 65534l));
                    if (h->axis == ZIGONAUT_AXIS_LEFT_RIGHT) {
                        h->column_a.Width({next, GridUnitType::Star});
                        h->column_b.Width({total - next, GridUnitType::Star});
                    } else {
                        h->row_a.Height({next, GridUnitType::Star});
                        h->row_b.Height({total - next, GridUnitType::Star});
                    }
                    paneEvent(ZIGONAUT_PANE_EVENT_COMMITTED_RATIO, h->id, h->committed);
                });
                h->started = h->thumb.DragStarted(auto_revoke, [h, set_divider_active](auto&&, auto&&) {
                    h->dragging = true;
                    set_divider_active(true);
                    h->drag_origin = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->column_a.ActualWidth()
                        : h->row_a.ActualHeight();
                    h->drag_change = 0;
                });
                h->delta = h->thumb.DragDelta(auto_revoke, [this, h](auto&&, Microsoft::UI::Xaml::Controls::Primitives::DragDeltaEventArgs const& args) {
                    auto const total = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->grid.ActualWidth() - 5
                        : h->grid.ActualHeight() - 5;
                    if (!std::isfinite(total) || total <= 0) return;
                    auto const current = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->column_a.ActualWidth()
                        : h->row_a.ActualHeight();
                    auto const change = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? args.HorizontalChange()
                        : args.VerticalChange();
                    if (!std::isfinite(current) || !std::isfinite(change)) return;
                    h->drag_change += change;
                    auto const physical_increment = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT ? h->cell_width : h->cell_height;
                    auto const increment = physical_increment / rasterization_scale;
                    if (!std::isfinite(increment) || increment <= 0) return;
                    auto minimum_first = h->minimum_first;
                    auto minimum_second = h->minimum_second;
                    auto const required = minimum_first + minimum_second;
                    if (required > total) {
                        auto const scale = total / required;
                        minimum_first *= scale;
                        minimum_second *= scale;
                    }
                    auto lower = minimum_first;
                    auto upper = total - minimum_second;
                    if (lower > upper) lower = upper = std::clamp(lower, 0.0, total);
                    auto const next = std::clamp(
                        std::round((h->drag_origin + h->drag_change) / increment) * increment,
                        lower,
                        upper);
                    if (std::abs(next - current) < 0.5) return;
                    if (h->axis == ZIGONAUT_AXIS_LEFT_RIGHT) {
                        h->column_a.Width({next, GridUnitType::Star});
                        h->column_b.Width({total - next, GridUnitType::Star});
                    } else {
                        h->row_a.Height({next, GridUnitType::Star});
                        h->row_b.Height({total - next, GridUnitType::Star});
                    }
                });
                h->completed = h->thumb.DragCompleted(auto_revoke, [this, h, set_divider_active](auto&&, Microsoft::UI::Xaml::Controls::Primitives::DragCompletedEventArgs const& args) {
                    h->dragging = false;
                    if (h->thumb.FocusState() == FocusState::Unfocused) set_divider_active(false);
                    h->drag_change = 0;
                    auto const total = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->grid.ActualWidth() - 5
                        : h->grid.ActualHeight() - 5;
                    if (!std::isfinite(total) || total <= 0) return;
                    if (args.Canceled()) {
                        auto const first = total * h->committed / 65535.0;
                        if (h->axis == ZIGONAUT_AXIS_LEFT_RIGHT) {
                            h->column_a.Width({first, GridUnitType::Star});
                            h->column_b.Width({total - first, GridUnitType::Star});
                        } else {
                            h->row_a.Height({first, GridUnitType::Star});
                            h->row_b.Height({total - first, GridUnitType::Star});
                        }
                        return;
                    }
                    auto const first = h->axis == ZIGONAUT_AXIS_LEFT_RIGHT
                        ? h->column_a.ActualWidth()
                        : h->row_a.ActualHeight();
                    if (!std::isfinite(first)) return;
                    auto const proposed = static_cast<uint16_t>(std::clamp(
                        std::lround(first / total * 65535), 1l, 65534l));
                    auto const rounding_tolerance = static_cast<uint16_t>(std::min(
                        std::ceil(0.5 / total * 65535), 65535.0));
                    auto const difference = proposed > h->committed
                        ? proposed - h->committed
                        : h->committed - proposed;
                    if (difference <= rounding_tolerance) {
                        auto const committed = total * h->committed / 65535.0;
                        if (h->axis == ZIGONAUT_AXIS_LEFT_RIGHT) {
                            h->column_a.Width({committed, GridUnitType::Star});
                            h->column_b.Width({total - committed, GridUnitType::Star});
                        } else {
                            h->row_a.Height({committed, GridUnitType::Star});
                            h->row_b.Height({total - committed, GridUnitType::Star});
                        }
                        return;
                    }
                    h->committed = proposed;
                    paneEvent(ZIGONAUT_PANE_EVENT_COMMITTED_RATIO, h->id, h->committed);
                });
                split_hosts.emplace(n.id, std::move(s));
            }
            h->committed = static_cast<uint16_t>(n.ratio);
            auto first=build(i+1); auto right=i+1+nodes[i+1].subtree_size; auto second=build(right); double a=n.ratio, b=65535-n.ratio;
            auto subtree_cell_size = [&](uint32_t start, bool width) {
                auto const end = start + nodes[start].subtree_size;
                for (auto index = start; index < end; ++index) if (nodes[index].kind == ZIGONAUT_LAYOUT_LEAF) {
                    auto const pane = pane_hosts.find(nodes[index].id);
                    if (pane != pane_hosts.end()) return width ? pane->second->cell_width : pane->second->cell_height;
                }
                return uint32_t{};
            };
            h->cell_width = std::min(subtree_cell_size(i + 1, true), subtree_cell_size(right, true));
            h->cell_height = std::min(subtree_cell_size(i + 1, false), subtree_cell_size(right, false));
            auto subtree_minimum = [&](uint32_t index, bool width) {
                if (nodes[index].kind == ZIGONAUT_LAYOUT_LEAF) {
                    auto const pane = pane_hosts.find(nodes[index].id);
                    if (pane == pane_hosts.end()) return 0.0;
                    return (width ? pane->second->minimum_width : pane->second->minimum_height) / rasterization_scale;
                }
                auto const split = split_hosts.find(nodes[index].id);
                if (split == split_hosts.end()) return 0.0;
                return width ? split->second->minimum_width : split->second->minimum_height;
            };
            auto const first_minimum_width = subtree_minimum(i + 1, true);
            auto const first_minimum_height = subtree_minimum(i + 1, false);
            auto const second_minimum_width = subtree_minimum(right, true);
            auto const second_minimum_height = subtree_minimum(right, false);
            if (n.axis == ZIGONAUT_AXIS_LEFT_RIGHT) {
                h->minimum_first = first_minimum_width;
                h->minimum_second = second_minimum_width;
                h->minimum_width = first_minimum_width + 5 + second_minimum_width;
                h->minimum_height = std::max(first_minimum_height, second_minimum_height);
            } else {
                h->minimum_first = first_minimum_height;
                h->minimum_second = second_minimum_height;
                h->minimum_width = std::max(first_minimum_width, second_minimum_width);
                h->minimum_height = first_minimum_height + 5 + second_minimum_height;
            }
            if(n.axis==ZIGONAUT_AXIS_LEFT_RIGHT){h->column_a.Width({a,GridUnitType::Star});h->column_b.Width({b,GridUnitType::Star});Grid::SetColumn(first,0);Grid::SetColumn(h->divider,1);Grid::SetColumn(h->thumb,1);Grid::SetColumn(second,2);}else{h->row_a.Height({a,GridUnitType::Star});h->row_b.Height({b,GridUnitType::Star});Grid::SetRow(first,0);Grid::SetRow(h->divider,1);Grid::SetRow(h->thumb,1);Grid::SetRow(second,2);}
            h->grid.Children().Append(first);h->grid.Children().Append(second);h->grid.Children().Append(h->divider);h->grid.Children().Append(h->thumb);
            return h->grid;
        };
        content_root.Children().Append(build(0)); content_root.Children().Append(find_border); active_pane=focused; updatePaneFocusIndicators(); root.UpdateLayout(); layoutTerminal();
        if (find_pane == focused && find_border.Visibility() == Visibility::Visible) {
            find_box.Focus(FocusState::Programmatic);
        } else if (auto requested=pane_hosts.find(focused); requested!=pane_hosts.end()) {
            requested->second->input.Focus(FocusState::Programmatic);
        }
    }

    static LPARAM keyLparam(Windows::UI::Core::CorePhysicalKeyStatus const& status) {
        return static_cast<LPARAM>(status.RepeatCount) |
            (static_cast<LPARAM>(status.ScanCode) << 16) |
            (static_cast<LPARAM>(status.IsExtendedKey) << 24) |
            (static_cast<LPARAM>(status.WasKeyDown) << 30) |
            (static_cast<LPARAM>(status.IsKeyReleased) << 31);
    }

    static void forwardTranslatedCharacters(PaneHost& pane, Windows::System::VirtualKey key,
                                            Windows::UI::Core::CorePhysicalKeyStatus const& status) {
        pane.translated_characters.clear();
        BYTE keyboard_state[256]{};
        if (!GetKeyboardState(keyboard_state)) return;
        auto const virtual_key = static_cast<UINT>(key);
        if (virtual_key < std::size(keyboard_state)) keyboard_state[virtual_key] |= 0x80;
        wchar_t characters[8]{};
        auto const count = ToUnicodeEx(
            virtual_key,
            status.ScanCode,
            keyboard_state,
            characters,
            static_cast<int>(std::size(characters)),
            0,
            GetKeyboardLayout(0));
        if (count <= 0) return;
        auto const message = status.IsMenuKeyDown ? WM_SYSCHAR : WM_CHAR;
        pane.translated_characters.assign(characters, characters + count);
        for (int index = 0; index < count; ++index) {
            SendMessageW(pane.window, message, static_cast<WPARAM>(characters[index]), keyLparam(status));
        }
    }

    WPARAM pointerWparam(Microsoft::UI::Input::PointerPointProperties const& properties) const {
        WPARAM value = 0;
        if (properties.IsLeftButtonPressed()) value |= MK_LBUTTON;
        if (properties.IsRightButtonPressed()) value |= MK_RBUTTON;
        if (properties.IsMiddleButtonPressed()) value |= MK_MBUTTON;
        if (GetKeyState(VK_SHIFT) < 0) value |= MK_SHIFT;
        if (GetKeyState(VK_CONTROL) < 0) value |= MK_CONTROL;
        return value;
    }

    LPARAM pointerLparam(Microsoft::UI::Input::PointerPoint const& point) const {
        auto const position = point.Position();
        auto const x = static_cast<short>(std::lround(position.X * rasterization_scale));
        auto const y = static_cast<short>(std::lround(position.Y * rasterization_scale));
        return MAKELPARAM(x, y);
    }

    void activate() {
        window.Activate();
        layoutTerminal();
        focusTerminal();
    }

    void focusTerminal() {
        auto const active = pane_hosts.find(active_pane);
        if (active != pane_hosts.end()) active->second->input.Focus(FocusState::Programmatic);
    }

    void showFind(uint64_t pane_id) {
        if (!pane_id || !pane_hosts.count(pane_id)) throw hresult_invalid_argument();
        if (find_pane == pane_id && find_border.Visibility() == Visibility::Visible) {
            find_box.Focus(FocusState::Programmatic);
            find_box.SelectAll();
            return;
        }
        if (find_pane) closeFind(true);
        find_pane = pane_id;
        updating_find = true;
        find_box.Text(L"");
        updating_find = false;
        find_status.Text(L"0 matches");
        find_previous.IsEnabled(false);
        find_next.IsEnabled(false);
        find_border.Visibility(Visibility::Visible);
        uint32_t index{};
        if (!content_root.Children().IndexOf(find_border, index)) content_root.Children().Append(find_border);
        find_box.Focus(FocusState::Programmatic);
    }

    void closeFind(bool notify_cancel) {
        if (!find_pane) return;
        auto const pane_id = find_pane;
        find_pane = 0;
        find_border.Visibility(Visibility::Collapsed);
        if (notify_cancel) paneEvent(ZIGONAUT_PANE_EVENT_FIND_CLOSE, pane_id, 0);
        focusTerminal();
    }

    void updateFind(uint64_t pane_id, uint32_t match_count, int32_t active_match, bool scanning) {
        if (!pane_id || pane_id != find_pane) return;
        std::wstring status;
        if (active_match >= 0 && static_cast<uint32_t>(active_match) < match_count) {
            status = std::to_wstring(static_cast<uint32_t>(active_match) + 1) + L" / " + std::to_wstring(match_count);
        } else {
            status = std::to_wstring(match_count) + (match_count == 1 ? L" match" : L" matches");
        }
        if (scanning) status += L"…";
        find_status.Text(status);
        find_previous.IsEnabled(match_count != 0);
        find_next.IsEnabled(match_count != 0);
    }

    void scheduleLayoutTerminal() {
        if (closed || layout_pending) return;
        layout_pending = true;
        auto const state = layout_dispatch;
        if (!notification_activation->queue.TryEnqueue(Microsoft::UI::Dispatching::DispatcherQueuePriority::Normal, [state] {
                if (!state->active.load(std::memory_order_acquire)) return;
                auto* bridge = state->bridge;
                if (!bridge->layout_pending) return;
                bridge->layout_pending = false;
                bridge->layoutTerminal();
            })) {
            layout_pending = false;
        }
    }

    void layoutTerminal() {
        layout_pending = false;
        for (auto& [_, owned] : pane_hosts) {
            auto& p=*owned; if(!p.window || !IsWindow(p.window) || !p.panel.XamlRoot()) continue;
            auto o=p.panel.TransformToVisual(root).TransformPoint({0,0}); RECT n{(LONG)std::lround(o.X*rasterization_scale),(LONG)std::lround(o.Y*rasterization_scale),(LONG)std::lround((o.X+p.panel.ActualWidth())*rasterization_scale),(LONG)std::lround((o.Y+p.panel.ActualHeight())*rasterization_scale)};
            if(n.right>n.left&&n.bottom>n.top&&!EqualRect(&n,&p.bounds)){p.bounds=n;SetWindowPos(p.window,nullptr,n.left,n.top,n.right-n.left,n.bottom-n.top,SWP_NOACTIVATE|SWP_NOOWNERZORDER|SWP_NOZORDER);}
        }
    }

    bool runBenchmarkIfRequested() {
        wchar_t scenario[32]{};
        auto const length = GetEnvironmentVariableW(
            L"ZIGONAUT_WINUI_BENCHMARK", scenario, static_cast<DWORD>(std::size(scenario)));
        if (!length || length >= std::size(scenario)) return false;

        uint32_t iterations{};
        auto operation = std::wstring_view{scenario, length};
        auto const started = std::chrono::steady_clock::now();
        if (operation == L"layout") {
            iterations = 100000;
            for (uint32_t index = 0; index < iterations; ++index) layoutTerminal();
        } else if (operation == L"tabs") {
            iterations = 1000;
            constexpr uint32_t tab_count = 50;
            std::vector<std::string> storage(tab_count, "terminal");
            std::vector<char const*> titles(tab_count);
            std::vector<uint32_t> lengths(tab_count);
            std::vector<uint32_t> colors(tab_count, 0x202020);
            for (uint32_t index = 0; index < tab_count; ++index) {
                storage[index] += std::to_string(index);
                titles[index] = storage[index].data();
                lengths[index] = static_cast<uint32_t>(storage[index].size());
            }
            for (uint32_t index = 0; index < iterations; ++index) {
                storage[0].back() = index % 2 ? 'A' : 'B';
                update(titles.data(), lengths.data(), colors.data(), tab_count, 0, true);
            }
        } else if (operation == L"scrollbar") {
            iterations = 100000;
            for (uint32_t index = 0; index < iterations; ++index) {
                auto const active = pane_hosts.find(active_pane);
                if (active != pane_hosts.end()) updatePaneScrollbar(active_pane, 100000, 40, 50000, false);
            }
        } else if (operation == L"appearance") {
            iterations = 1000;
            for (uint32_t index = 0; index < iterations; ++index) {
                updateAppearance(ZIGONAUT_BACKDROP_MICA, false, true);
            }
        } else if (operation == L"taskbar") {
            iterations = 10000;
            for (uint32_t index = 0; index < iterations; ++index) {
                check_hresult(updateTaskbarProgress(ZIGONAUT_TASKBAR_PROGRESS_NORMAL, 50));
            }
        } else {
            fwprintf(stderr, L"unknown WinUI benchmark: %.*ls\n", static_cast<int>(length), scenario);
            return true;
        }
        auto const elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        fwprintf(stderr, L"WINUI_BENCHMARK %.*ls %u %.6f ms %.3f ns/op\n",
                 static_cast<int>(length), scenario, iterations, elapsed,
                 elapsed * 1000000.0 / iterations);
        return true;
    }

    void showAboutDialog() {
        if (about_dialog) return;

        auto content = StackPanel{};
        content.MaxWidth(320);
        content.Spacing(10);
        content.Padding(Thickness{0, 8, 0, 0});
        content.HorizontalAlignment(HorizontalAlignment::Stretch);

        std::wstring module_path(32768, L'\0');
        auto const module_path_length = GetModuleFileNameW(nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
        if (module_path_length && module_path_length < module_path.size()) {
            module_path.resize(module_path_length);
            std::wstring path(module_path);
            auto const separator = path.find_last_of(L"\\/");
            path.resize(separator == std::wstring::npos ? 0 : separator + 1);
            path += L"zigonaut-about-1024.png";
            std::replace(path.begin(), path.end(), L'\\', L'/');

            auto bitmap = Microsoft::UI::Xaml::Media::Imaging::BitmapImage{};
            bitmap.UriSource(Windows::Foundation::Uri{hstring{L"file:///" + path}});
            auto image = Image{};
            image.Source(bitmap);
            image.Width(96);
            image.Height(96);
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
        version.Style(application.Resources().Lookup(box_value(L"BodyTextBlockStyle")).as<Style>());
        version.HorizontalAlignment(HorizontalAlignment::Stretch);
        version.TextAlignment(TextAlignment::Center);
        content.Children().Append(version);

        auto hash = TextBlock{};
        hash.Style(application.Resources().Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
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
            for (auto& [_, pane] : pane_hosts) pane->bounds = {-1, -1, -1, -1};
            layoutTerminal();
            focusTerminal();
        });
        try {
            about_operation = about_dialog.ShowAsync();
        } catch (...) {
            reportCurrentException(L"show About dialog");
            about_closed_revoker.revoke();
            about_operation = nullptr;
            about_dialog = nullptr;
            for (auto& [_, pane] : pane_hosts) pane->bounds = {-1, -1, -1, -1};
            layoutTerminal();
        }
    }

    void showPaneScrollbar(PaneHost& pane) {
        if (pane.scrollbar.Visibility() != Visibility::Visible) return;
        pane.scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::MouseIndicator);
        pane.scrollbar.Opacity(1);
        schedulePaneScrollbarHide(pane);
    }

    void updateTitleBarLayout() {
        auto const dpi = GetDpiForWindow(parent);
        if (!dpi) return;
        auto const to_dips = [dpi](int32_t pixels) { return static_cast<double>(pixels) * 96.0 / dpi; };
        auto const padding = Thickness{
            to_dips(std::max(title_bar.LeftInset(), 0)),
            0,
            to_dips(std::max(title_bar.RightInset(), 0)),
            0,
        };
        if (app_title_bar.Padding() != padding) app_title_bar.Padding(padding);
    }

    void updateTabColorVisibility() {
        auto const visibility = show_tab_colors && !high_contrast ? Visibility::Visible : Visibility::Collapsed;
        for (auto const& value : tabs.TabItems()) {
            auto const item = value.try_as<TabViewItem>();
            if (!item) continue;
            auto const header = item.Header().try_as<StackPanel>();
            if (!header || header.Children().Size() < 1) continue;
            auto const marker = header.Children().GetAt(0).try_as<Border>();
            if (!marker) continue;
            marker.Visibility(visibility);
            header.Spacing(visibility == Visibility::Visible ? 6 : 0);
        }
    }

    void updateAppearance(uint32_t kind, bool high_contrast, bool dark_theme) {
        if (appearance_initialized && kind == backdrop_kind &&
            high_contrast == this->high_contrast && dark_theme == this->dark_theme) return;
        appearance_initialized = true;
        backdrop_kind = kind;
        this->high_contrast = high_contrast;
        this->dark_theme = dark_theme;
        updateTabColorVisibility();
        auto const requested_theme = high_contrast ? ElementTheme::Default : dark_theme ? ElementTheme::Dark : ElementTheme::Light;
        root.RequestedTheme(requested_theme);
        ZigonautSettings::setTheme(settings_dialog, high_contrast, dark_theme);
        title_bar.PreferredTheme(high_contrast
            ? Microsoft::UI::Windowing::TitleBarTheme::UseDefaultAppMode
            : dark_theme ? Microsoft::UI::Windowing::TitleBarTheme::Dark
                         : Microsoft::UI::Windowing::TitleBarTheme::Light);
        if (high_contrast || kind == ZIGONAUT_BACKDROP_NONE) {
            auto const theme_key = high_contrast ? L"HighContrast" : dark_theme ? L"Dark" : L"Default";
            auto const theme_resources = application.Resources().ThemeDictionaries()
                .Lookup(box_value(theme_key)).as<ResourceDictionary>();
            root.Background(theme_resources.Lookup(box_value(L"ZigonautWindowBackgroundBrush"))
                .as<Microsoft::UI::Xaml::Media::Brush>());
        } else {
            root.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        }

        window.SystemBackdrop(nullptr);
        backdrop = nullptr;
        if (high_contrast || kind == ZIGONAUT_BACKDROP_NONE) return;
        if (kind == ZIGONAUT_BACKDROP_ACRYLIC) {
            window.SystemBackdrop(Microsoft::UI::Xaml::Media::DesktopAcrylicBackdrop{});
            return;
        }
        backdrop = Microsoft::UI::Xaml::Media::MicaBackdrop{};
        backdrop.Kind(backdrop_kind == ZIGONAUT_BACKDROP_MICA_ALT
            ? Microsoft::UI::Composition::SystemBackdrops::MicaKind::BaseAlt
            : Microsoft::UI::Composition::SystemBackdrops::MicaKind::Base);
        window.SystemBackdrop(backdrop);
    }

    static void schedulePaneScrollbarHide(PaneHost& pane) {
        if (!pane.timer) return;
        pane.timer.Stop();
        if (!pane.pointer_over_scrollbar) pane.timer.Start();
    }

    void updatePaneScrollbar(uint64_t id, uint32_t total, uint32_t page, uint32_t position, bool show) {
        auto const found = pane_hosts.find(id);
        if (found == pane_hosts.end()) throw hresult_invalid_argument();
        auto& pane = *found->second;
        if (pane.initialized && total == pane.total && page == pane.page && position == pane.position) {
            if (show) showPaneScrollbar(pane);
            return;
        }
        pane.initialized = true;
        pane.total = total;
        pane.page = page;
        pane.position = position;
        pane.updating_scrollbar = true;
        struct ResetUpdating {
            bool& value;
            ~ResetUpdating() { value = false; }
        } reset{pane.updating_scrollbar};
        auto const maximum = total > page ? total - page : 0;
        pane.scrollbar.Minimum(0);
        pane.scrollbar.Maximum(maximum);
        pane.scrollbar.LargeChange(std::max(page, 1u));
        pane.scrollbar.ViewportSize(page);
        pane.scrollbar.Value(std::min(position, maximum));
        pane.scrollbar.IsEnabled(maximum > 0);
        pane.scrollbar.Visibility(maximum > 0 ? Visibility::Visible : Visibility::Collapsed);
        if (maximum == 0) {
            pane.timer.Stop();
            pane.scrollbar.Opacity(0);
        } else if (show) {
            showPaneScrollbar(pane);
        }
    }

    HRESULT updateTaskbarProgress(uint32_t state, uint32_t value) noexcept {
        value = std::min(value, 100u);
        if (taskbar_state_initialized && state == taskbar_state && value == taskbar_value) return S_OK;
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
        if (FAILED(result)) return result;
        if (flag != TBPF_NOPROGRESS && flag != TBPF_INDETERMINATE) {
            result = taskbar->SetProgressValue(parent, value, 100);
            if (FAILED(result)) return result;
        }
        taskbar_state_initialized = true;
        taskbar_state = state;
        taskbar_value = value;
        return S_OK;
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

    void update(char const* const* titles, uint32_t const* title_lengths, uint32_t const* colors, uint32_t count, int32_t active, bool show_colors) {
        updating = true;
        struct ResetUpdating {
            bool& value;
            ~ResetUpdating() { value = false; }
        } reset{updating};
        auto items = tabs.TabItems();
        auto changed = false;
        show_tab_colors = show_colors;
        auto const marker_visibility = show_colors && !high_contrast ? Visibility::Visible : Visibility::Collapsed;
        while (items.Size() > count) {
            items.RemoveAtEnd();
            changed = true;
        }
        for (uint32_t i = 0; i < count; ++i) {
            auto const title = to_hstring(std::string_view{titles[i] ? titles[i] : "", title_lengths[i]});
            auto const color = Windows::UI::Color{
                0xff,
                static_cast<uint8_t>(colors[i] >> 16),
                static_cast<uint8_t>(colors[i] >> 8),
                static_cast<uint8_t>(colors[i]),
            };
            if (i == items.Size()) {
                auto item = TabViewItem{};
                auto header = StackPanel{};
                header.Orientation(Orientation::Horizontal);
                header.Spacing(marker_visibility == Visibility::Visible ? 6 : 0);
                auto marker = Border{};
                marker.Width(9);
                marker.Height(9);
                marker.CornerRadius(CornerRadius{4.5});
                marker.VerticalAlignment(VerticalAlignment::Center);
                marker.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{color});
                marker.Visibility(marker_visibility);
                auto text = TextBlock{};
                text.Text(title);
                text.VerticalAlignment(VerticalAlignment::Center);
                header.Children().Append(marker);
                header.Children().Append(text);
                item.Header(header);
                item.Height(40);
                item.IsClosable(true);
                Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(item, title);
                ToolTipService::SetToolTip(item, box_value(title));
                items.Append(item);
                changed = true;
            } else {
                auto item = items.GetAt(i).as<TabViewItem>();
                auto header = item.Header().as<StackPanel>();
                auto marker = header.Children().GetAt(0).as<Border>();
                auto text = header.Children().GetAt(1).as<TextBlock>();
                auto brush = marker.Background().as<Microsoft::UI::Xaml::Media::SolidColorBrush>();
                auto const previous_color = brush.Color();
                if (text.Text() != title) {
                    text.Text(title);
                    Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(item, title);
                    ToolTipService::SetToolTip(item, box_value(title));
                    changed = true;
                }
                if (previous_color.A != color.A || previous_color.R != color.R || previous_color.G != color.G || previous_color.B != color.B) {
                    brush.Color(color);
                    changed = true;
                }
                if (marker.Visibility() != marker_visibility) {
                    marker.Visibility(marker_visibility);
                    header.Spacing(marker_visibility == Visibility::Visible ? 6 : 0);
                    changed = true;
                }
            }
        }
        auto const selected = active >= 0 && active < static_cast<int32_t>(count) ? active : -1;
        if (tabs.SelectedIndex() != selected) {
            tabs.SelectedIndex(selected);
            changed = true;
        }
        if (changed) {
            tabs.UpdateLayout();
        }
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
            item.Text(to_hstring(std::string_view{names[index] ? names[index] : "", name_lengths[index]}));
            profile_revokers.emplace_back(item.Click(auto_revoke, [this, index](auto&&, auto&&) {
                notify(ZIGONAUT_CHROME_NEW_PROFILE, index);
                focusTerminal();
            }));
            new_tab_menu.Items().Append(item);
            profile_items.emplace_back(std::move(item));
        }
    }

    void showSettings(std::string_view path, std::string_view contents) {
        if (ZigonautSettings::isOpen(settings_dialog)) {
            ZigonautSettings::activate(settings_dialog);
            return;
        }
        settings_dialog = ZigonautSettings::show(path, contents, high_contrast, dark_theme, [this] {
            notify(ZIGONAUT_CHROME_RELOAD_SETTINGS, 0);
        });
    }

    HRESULT close() noexcept {
        if (closed) return S_OK;
        closed = true;
        layout_dispatch->active.store(false, std::memory_order_release);
        notification_activation->active.store(false, std::memory_order_release);
        callback = nullptr;
        pane_callback = nullptr;
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
        if (ZigonautSettings::isOpen(settings_dialog)) cleanup(L"close settings window", [&] { ZigonautSettings::close(settings_dialog); }, result);
        settings_dialog.reset();
        about_closed_revoker.revoke();
        if (about_dialog) cleanup(L"hide About dialog", [&] { about_dialog.Hide(); }, result);
        for (auto& revoker : profile_revokers) revoker.revoke();
        profile_revokers.clear();
        for (auto& revoker : app_command_revokers) revoker.revoke();
        app_command_revokers.clear();
        new_tab_item_revoker.revoke();
        new_window_revoker.revoke();
        increase_font_size_revoker.revoke();
        decrease_font_size_revoker.revoke();
        reset_font_size_revoker.revoke();
        open_settings_revoker.revoke();
        about_revoker.revoke();
        quit_revoker.revoke();
        find_text_changed_revoker.revoke();
        find_key_down_revoker.revoke();
        find_previous_revoker.revoke();
        find_next_revoker.revoke();
        find_close_revoker.revoke();
        new_tab_revoker.revoke();
        selection_revoker.revoke();
        close_tab_revoker.revoke();
        layout_revoker.revoke();
        terminal_loaded_revoker.revoke();
        xaml_root_changed_revoker.revoke();
        for (auto& revoker : accelerator_revokers) revoker.revoke();
        accelerator_revokers.clear();
        window_closed_revoker.revoke();
        window_activated_revoker.revoke();
        handlers_detached = true;
        cleanup(L"detach new-tab menu", [&] { new_tab_button.Flyout(nullptr); }, result);
        cleanup(L"clear new-tab menu", [&] { if (new_tab_menu) new_tab_menu.Items().Clear(); }, result);
        profile_items.clear();
        new_tab_menu = nullptr;
        cleanup(L"detach application menu", [&] { menu_button.Flyout(nullptr); }, result);
        cleanup(L"clear application menu", [&] { app_menu.Items().Clear(); }, result);
        new_tab_item = nullptr;
        new_window_item = nullptr;
        view_item = nullptr;
        increase_font_size_item = nullptr;
        decrease_font_size_item = nullptr;
        reset_font_size_item = nullptr;
        open_settings_item = nullptr;
        about_item = nullptr;
        quit_item = nullptr;
        app_menu = nullptr;
        cleanup(L"detach new-tab controls", [&] { tabs.TabStripFooter(nullptr); }, result);
        cleanup(L"clear new-tab controls", [&] { new_tab_controls.Children().Clear(); }, result);
        new_tab_button = nullptr;
        new_tab_controls = nullptr;
        cleanup(L"clear tabs", [&] { tabs.TabItems().Clear(); }, result);
        cleanup(L"clear title bar content", [&] { app_title_bar.Children().Clear(); }, result);
        cleanup(L"clear keyboard accelerators", [&] { root.KeyboardAccelerators().Clear(); }, result);
        accelerators.clear();
        cleanup(L"stop TSF", [&] { if (tsf) { auto service=std::move(tsf); service->Shutdown(); service=nullptr; } }, result);
        cleanup(L"detach pane swap chains", [&] { for(auto& [_,p]:pane_hosts){if(p->timer)p->timer.Stop();p->panel.as<ISwapChainPanelNative>()->SetSwapChain(nullptr);} }, result);
        cleanup(L"clear content root", [&] { content_root.Children().Clear(); }, result);
        pane_hosts.clear(); split_hosts.clear(); attachments.clear();
        cleanup(L"clear root content", [&] { root.Children().Clear(); }, result);
        cleanup(L"detach custom title bar", [&] { window.SetTitleBar(nullptr); }, result);
        cleanup(L"clear system backdrop", [&] { window.SystemBackdrop(nullptr); }, result);
        cleanup(L"detach window content", [&] { window.Content(nullptr); }, result);
        content_root = nullptr;
        find_border = nullptr;
        find_box = nullptr;
        find_status = nullptr;
        find_previous = nullptr;
        find_next = nullptr;
        find_close = nullptr;
        app_title_bar = nullptr;
        bottom_border = nullptr;
        menu_button = nullptr;
        tabs = nullptr;
        root = nullptr;
        backdrop = nullptr;
        title_bar = nullptr;
        app_window = nullptr;
        window = nullptr;
        about_operation = nullptr;
        about_dialog = nullptr;
        application = nullptr;
        return result;
    }
};

HRESULT validate(Bridge* bridge) {
    if (!bridge) return E_POINTER;
    if (bridge->thread_id != GetCurrentThreadId()) return RPC_E_WRONG_THREAD;
    return bridge->closed ? RO_E_CLOSED : S_OK;
}
}

extern "C" HRESULT __cdecl zigonaut_window_run(zigonaut_window_started started, zigonaut_chrome_command callback, zigonaut_pane_event_callback pane_callback, void* context, const char* version, uint32_t version_length, const char* git_hash, uint32_t git_hash_length) noexcept {
    if (!started || !callback || !pane_callback || !context ||
        !validString(version, version_length) || !validString(git_hash, git_hash_length)) return E_INVALIDARG;
    try {
        init_apartment(apartment_type::single_threaded);
    } catch (...) {
        return reportCurrentException(L"init_apartment");
    }
    auto result = S_OK;
    auto bootstrapped = false;
    Bridge* bridge{};
    try {
        auto const bootstrap_result = MddBootstrapInitialize2(
            ::Microsoft::WindowsAppSDK::Release::MajorMinor,
            ::Microsoft::WindowsAppSDK::Release::VersionTag,
            {::Microsoft::WindowsAppSDK::Runtime::Version::UInt64},
            MddBootstrapInitializeOptions_OnNoMatch_ShowUI);
        if (FAILED(bootstrap_result)) {
            reportFailure(L"MddBootstrapInitialize2", bootstrap_result);
            uninit_apartment();
            return bootstrap_result;
        }
        bootstrapped = true;
        try {
            Application::Start([&](auto&&) {
                make<ZigonautWinUIBridge::implementation::App>([&] {
                    try {
                        bridge = new Bridge(
                            callback,
                            pane_callback,
                            context,
                            Application::Current(),
                            std::string_view{version ? version : "", version_length},
                            std::string_view{git_hash ? git_hash : "", git_hash_length});
                        bridge->terminal_loaded_revoker = bridge->content_root.Loaded(auto_revoke, [&, started, context](auto&&, auto&&) {
                            bridge->terminal_loaded_revoker.revoke();
                            try {
                                bridge->root.UpdateLayout();
                                auto const xaml_root = bridge->content_root.XamlRoot();
                                bridge->rasterization_scale = xaml_root.RasterizationScale();
                                bridge->xaml_root_changed_revoker = xaml_root.Changed(auto_revoke, [bridge](XamlRoot const& sender, auto&&) {
                                    bridge->rasterization_scale = sender.RasterizationScale();
                                    for(auto& [_,p]:bridge->pane_hosts) p->bounds={-1,-1,-1,-1};
                                    bridge->layoutTerminal();
                                });
                                if (!started(context, bridge, bridge->parent)) {
                                    result = E_ABORT;
                                    bridge->window.Close();
                                    return;
                                }
                                if (bridge->runBenchmarkIfRequested()) {
                                    bridge->window.Close();
                                    return;
                                }
                                bridge->activate();
                            } catch (...) {
                                result = reportCurrentException(L"initialize WinUI window");
                                if (bridge && bridge->window) {
                                    try { bridge->window.Close(); } catch (...) { reportCurrentException(L"close failed window"); }
                                }
                            }
                        });
                        bridge->window.Activate();
                    } catch (...) {
                        result = reportCurrentException(L"create WinUI window");
                        if (bridge && bridge->window) {
                            try { bridge->window.Close(); } catch (...) { reportCurrentException(L"close failed window"); }
                        }
                    }
                });
            });
        } catch (...) {
            result = reportCurrentException(L"WinUI application");
        }
    } catch (...) {
        result = reportCurrentException(L"Windows App SDK initialization");
    }
    if (bridge) {
        auto const close_result = bridge->close();
        if (SUCCEEDED(result) && FAILED(close_result)) result = close_result;
        delete bridge;
    }
    if (bootstrapped) MddBootstrapShutdown();
    uninit_apartment();
    return result;
}

extern "C" HRESULT __cdecl zigonaut_chrome_attach_pane(void* value, uint64_t pane_id, HWND terminal, void* swap_chain, uint32_t cell_width, uint32_t cell_height, uint32_t minimum_width, uint32_t minimum_height, uint32_t initial_width, uint32_t initial_height) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->attachPane(pane_id, terminal, swap_chain, cell_width, cell_height, minimum_width, minimum_height, initial_width, initial_height); return S_OK; } catch (...) { return reportCurrentException(L"attach pane"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_detach_pane(void* value, uint64_t pane_id) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->detachPane(pane_id); return S_OK; } catch (...) { return reportCurrentException(L"detach pane"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_focus_pane(void* value, uint64_t pane_id) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->focusPane(pane_id); return S_OK; } catch (...) { return reportCurrentException(L"focus pane"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_layout(void* value, const zigonaut_layout_node* nodes, uint32_t count, uint64_t focused_pane) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->updateLayout(nodes, count, focused_pane); return S_OK; } catch (...) { return reportCurrentException(L"update layout"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update(void* value, const char* const* titles, const uint32_t* title_lengths, const uint32_t* colors, uint32_t count, int32_t active, BOOL show_colors) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (count && (!titles || !title_lengths || !colors)) return E_INVALIDARG;
    for (uint32_t index = 0; index < count; ++index) {
        if (!validString(titles[index], title_lengths[index])) return E_INVALIDARG;
    }
    try { bridge->update(titles, title_lengths, colors, count, active, show_colors != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_profiles(void* value, const char* const* names, const uint32_t* name_lengths, uint32_t count) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!count || !names || !name_lengths) return E_INVALIDARG;
    for (uint32_t index = 0; index < count; ++index) {
        if (!validString(names[index], name_lengths[index])) return E_INVALIDARG;
    }
    try { bridge->updateProfiles(names, name_lengths, count); return S_OK; } catch (...) { return reportCurrentException(L"update profiles"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_pane_scrollbar(void* value, uint64_t pane_id, uint32_t total, uint32_t page, uint32_t position, BOOL show) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!pane_id) return E_INVALIDARG;
    try { bridge->updatePaneScrollbar(pane_id, total, page, position, show != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update scrollbar"); }
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
    if (!validString(title, title_length) || !validString(body, body_length)) return E_INVALIDARG;
    return bridge->showNotification(session_id, std::string_view(title ? title : "", title_length), std::string_view(body ? body : "", body_length));
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_appearance(void* value, uint32_t backdrop, BOOL high_contrast, BOOL dark_theme) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (backdrop > ZIGONAUT_BACKDROP_MICA_ALT) return E_INVALIDARG;
    try { bridge->updateAppearance(backdrop, high_contrast != FALSE, dark_theme != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update appearance"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_show_settings(void* value, const char* path, uint32_t path_length, const char* contents, uint32_t contents_length) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!validString(path, path_length) || !path_length || !validString(contents, contents_length)) return E_INVALIDARG;
    try {
        bridge->showSettings(std::string_view{path, path_length}, std::string_view{contents ? contents : "", contents_length});
        return S_OK;
    } catch (...) { return reportCurrentException(L"show settings"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_show_find(void* value, uint64_t pane_id) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!pane_id) return E_INVALIDARG;
    try { bridge->showFind(pane_id); return S_OK; } catch (...) { return reportCurrentException(L"show find"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_find(void* value, uint64_t pane_id, uint32_t match_count, int32_t active_match, BOOL scanning) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!pane_id || active_match < -1) return E_INVALIDARG;
    try { bridge->updateFind(pane_id, match_count, active_match, scanning != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update find"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_update_ime_bounds(void* value, uint64_t pane_id, const zigonaut_ime_bounds* bounds) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (!bounds || bounds->size < sizeof(*bounds) || !pane_id || bounds->right <= bounds->left || bounds->bottom <= bounds->top ||
        bounds->pane_right <= bounds->pane_left || bounds->pane_bottom <= bounds->pane_top) return E_INVALIDARG;
    // The TSF context owner consumes this rectangle. Retain physical screen
    // coordinates on the pane so GetTextExt can return them without crossing ABI ownership.
    auto pane = bridge->pane_hosts.find(pane_id);
    if (pane == bridge->pane_hosts.end()) return E_INVALIDARG;
    pane->second->tsf_provider.caret = { bounds->left, bounds->top, bounds->right, bounds->bottom };
    pane->second->tsf_provider.viewport = { bounds->pane_left, bounds->pane_top, bounds->pane_right, bounds->pane_bottom };
    return S_OK;
}
