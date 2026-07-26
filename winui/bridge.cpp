#include "pch.h"
#include "App.xaml.h"
#include "bridge.h"
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
#include <memory>
#include <string>
#include <string_view>
#include <vector>

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
    void* context{};
    Application application{nullptr};
    Window window{nullptr};
    HWND parent{};
    HWND terminal{};
    Microsoft::UI::Windowing::AppWindow app_window{nullptr};
    Microsoft::UI::Windowing::AppWindowTitleBar title_bar{nullptr};
    Microsoft::UI::Xaml::Media::MicaBackdrop backdrop{nullptr};
    Grid root{nullptr};
    TitleBar app_title_bar{nullptr};
    Grid content_root{nullptr};
    Grid terminal_presenter{nullptr};
    SwapChainPanel terminal_surface{nullptr};
    ContentControl terminal_input{nullptr};
    Border terminal_frame{nullptr};
    TabView tabs{nullptr};
    Button new_tab_button{nullptr};
    Grid title_bar_drag_region{nullptr};
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
    std::vector<Microsoft::UI::Xaml::Input::KeyboardAccelerator> accelerators;
    std::vector<Microsoft::UI::Xaml::Input::KeyboardAccelerator::Invoked_revoker> accelerator_revokers;
    Microsoft::UI::Dispatching::DispatcherQueueTimer scrollbar_timer{nullptr};
    Window::Closed_revoker window_closed_revoker{};
    Window::Activated_revoker window_activated_revoker{};
    FrameworkElement::LayoutUpdated_revoker layout_revoker{};
    FrameworkElement::Loaded_revoker terminal_loaded_revoker{};
    UIElement::KeyDown_revoker terminal_key_down_revoker{};
    UIElement::KeyUp_revoker terminal_key_up_revoker{};
    UIElement::CharacterReceived_revoker terminal_character_revoker{};
    UIElement::GotFocus_revoker terminal_focus_revoker{};
    UIElement::LostFocus_revoker terminal_blur_revoker{};
    UIElement::PointerPressed_revoker terminal_pressed_revoker{};
    UIElement::PointerReleased_revoker terminal_released_revoker{};
    UIElement::PointerMoved_revoker terminal_moved_revoker{};
    UIElement::PointerWheelChanged_revoker terminal_wheel_revoker{};
    UIElement::PointerExited_revoker terminal_exited_revoker{};
    UIElement::PointerCanceled_revoker terminal_canceled_revoker{};
    UIElement::PointerCaptureLost_revoker terminal_capture_lost_revoker{};
    Button::Click_revoker new_tab_revoker{};
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
    bool scrollbar_state_initialized = false;
    uint32_t scrollbar_total = 0;
    uint32_t scrollbar_page = 0;
    uint32_t scrollbar_position = 0;
    bool closed = false;
    RECT terminal_bounds{ -1, -1, -1, -1 };
    com_ptr<ITaskbarList3> taskbar;
    AppNotificationManager notification_manager{nullptr};
    AppNotificationManager::NotificationInvoked_revoker notification_revoker{};
    bool notifications_registered = false;
    std::shared_ptr<NotificationActivationState> notification_activation;
    hstring app_version;
    hstring git_hash;
    std::wstring translated_characters;

    Bridge(zigonaut_chrome_command cb, void* ctx, Application const& app,
           std::string_view version, std::string_view hash)
        : callback(cb), context(ctx), application(app),
          app_version(to_hstring(version)), git_hash(to_hstring(hash)) {
        window = Window{};
        window.Title(L"Zigonaut");
        check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&parent));
        app_window = window.AppWindow();
        title_bar = app_window.TitleBar();
        app_window.Resize({1100, 700});

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

        app_title_bar = TitleBar{};
        Grid::SetRow(app_title_bar, 0);
        content_root = Grid{};
        Grid::SetRow(content_root, 1);

        terminal_frame = Border{};
        terminal_frame.Style(application.Resources().Lookup(box_value(L"ZigonautTerminalFrameStyle")).as<Style>());
        terminal_presenter = Grid{};
        terminal_surface = SwapChainPanel{};
        terminal_input = ContentControl{};
        terminal_input.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        terminal_input.Opacity(0);
        terminal_input.IsHitTestVisible(false);
        terminal_input.IsTabStop(true);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(terminal_input, L"Terminal input surface");
        terminal_presenter.Children().Append(terminal_surface);
        terminal_presenter.Children().Append(terminal_input);
        tabs = TabView{};

        scrollbar = Microsoft::UI::Xaml::Controls::Primitives::ScrollBar{};
        scrollbar.Orientation(Orientation::Vertical);
        scrollbar.HorizontalAlignment(HorizontalAlignment::Right);
        scrollbar.VerticalAlignment(VerticalAlignment::Stretch);
        scrollbar.Margin(Thickness{0, 4, 2, 4});
        scrollbar.Width(12);
        scrollbar.SmallChange(1);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(scrollbar, L"Terminal scrollback");
        scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::MouseIndicator);
        scrollbar.Opacity(0);
        scrollbar.Visibility(Visibility::Collapsed);
        scrollbar_scroll_revoker = scrollbar.Scroll(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Controls::Primitives::ScrollEventArgs const& args) {
            if (updating_scrollbar) return;
            showScrollbar();
            notify(ZIGONAUT_CHROME_SCROLL, static_cast<uint32_t>(std::clamp(args.NewValue(), 0.0, static_cast<double>(UINT32_MAX))));
        });
        scrollbar_entered_revoker = scrollbar.PointerEntered(auto_revoke, [this](auto&&, auto&&) {
            pointer_over_scrollbar = true;
            showScrollbar();
        });
        scrollbar_exited_revoker = scrollbar.PointerExited(auto_revoke, [this](auto&&, auto&&) {
            pointer_over_scrollbar = false;
            scheduleScrollbarHide();
        });
        scrollbar_wheel_revoker = scrollbar.PointerWheelChanged(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            auto const delta = args.GetCurrentPoint(scrollbar).Properties().MouseWheelDelta();
            showScrollbar();
            notify(ZIGONAUT_CHROME_SCROLL_WHEEL, static_cast<uint32_t>(delta));
            args.Handled(true);
        });
        terminal_presenter.Children().Append(scrollbar);
        terminal_frame.Child(terminal_presenter);

        scrollbar_timer = notification_activation->queue.CreateTimer();
        scrollbar_timer.IsRepeating(false);
        scrollbar_timer.Interval(std::chrono::seconds(2));
        scrollbar_tick_revoker = scrollbar_timer.Tick(auto_revoke, [this](auto&&, auto&&) {
            if (!pointer_over_scrollbar && scrollbar) {
                scrollbar.Opacity(0);
            }
        });

        auto const resources = application.Resources();

        tabs.IsAddTabButtonVisible(false);
        tabs.VerticalAlignment(VerticalAlignment::Bottom);
        tabs.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        tabs.TabWidthMode(TabViewWidthMode::SizeToContent);
        tabs.CloseButtonOverlayMode(TabViewCloseButtonOverlayMode::Auto);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(tabs, L"Terminal tabs");
        new_tab_button = Button{};
        new_tab_button.Style(resources.Lookup(box_value(L"ZigonautTitleBarButtonStyle")).as<Style>());
        new_tab_button.VerticalAlignment(VerticalAlignment::Center);
        auto const new_tab_icon = SymbolIcon{Symbol::Add};
        new_tab_button.Content(new_tab_icon);
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(new_tab_button, L"New tab");
        ToolTipService::SetToolTip(new_tab_button, box_value(L"New tab (Ctrl+Shift+T); right-click for profiles"));
        new_tab_revoker = new_tab_button.Click(auto_revoke, [this](auto&&, auto&&) {
            notify(ZIGONAUT_CHROME_NEW_DEFAULT, 0);
            focusTerminal();
        });
        tabs.TabStripFooter(new_tab_button);
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
        menu_button.VerticalAlignment(VerticalAlignment::Center);
        menu_button.Content(SymbolIcon{Symbol::GlobalNavigationButton});
        Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(menu_button, L"Application menu");
        ToolTipService::SetToolTip(menu_button, box_value(L"Application menu"));

        bottom_border = Border{};
        bottom_border.Style(resources.Lookup(box_value(L"ZigonautTitleBarDividerStyle")).as<Style>());
        Grid::SetRow(bottom_border, 0);

        app_menu = MenuFlyout{};
        app_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        open_settings_item = MenuFlyoutItem{};
        open_settings_item.Text(L"Open Settings");
        open_settings_item.AccessKey(L"S");
        open_settings_revoker = open_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_OPEN_SETTINGS, 0); });
        reload_settings_item = MenuFlyoutItem{};
        reload_settings_item.Text(L"Reload Settings");
        reload_settings_item.AccessKey(L"R");
        reload_settings_revoker = reload_settings_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_RELOAD_SETTINGS, 0); });
        about_item = MenuFlyoutItem{};
        about_item.Text(L"About Zigonaut");
        about_item.AccessKey(L"A");
        about_revoker = about_item.Click(auto_revoke, [this](auto&&, auto&&) { showAboutDialog(); });
        quit_item = MenuFlyoutItem{};
        quit_item.Text(L"Quit");
        quit_item.AccessKey(L"Q");
        quit_revoker = quit_item.Click(auto_revoke, [this](auto&&, auto&&) { notify(ZIGONAUT_CHROME_QUIT, 0); });
        app_menu.Items().Append(open_settings_item);
        app_menu.Items().Append(reload_settings_item);
        app_menu.Items().Append(MenuFlyoutSeparator{});
        app_menu.Items().Append(about_item);
        app_menu.Items().Append(quit_item);
        menu_button.Flyout(app_menu);

        new_tab_menu = MenuFlyout{};
        new_tab_menu.Placement(Microsoft::UI::Xaml::Controls::Primitives::FlyoutPlacementMode::BottomEdgeAlignedLeft);
        new_tab_button.ContextFlyout(new_tab_menu);

        auto title_bar_content = Grid{};
        auto tabs_column = ColumnDefinition{};
        tabs_column.Width(GridLength{1, GridUnitType::Auto});
        title_bar_content.ColumnDefinitions().Append(tabs_column);
        auto drag_column = ColumnDefinition{};
        drag_column.Width(GridLength{1, GridUnitType::Star});
        title_bar_content.ColumnDefinitions().Append(drag_column);
        tabs.HorizontalAlignment(HorizontalAlignment::Left);
        Grid::SetColumn(tabs, 0);
        title_bar_content.Children().Append(tabs);
        title_bar_drag_region = Grid{};
        title_bar_drag_region.Background(Microsoft::UI::Xaml::Media::SolidColorBrush{Windows::UI::Colors::Transparent()});
        Grid::SetColumn(title_bar_drag_region, 1);
        TitleBar::SetIsDragRegion(
            title_bar_drag_region,
            box_value(true).as<Windows::Foundation::IReference<bool>>());
        title_bar_content.Children().Append(title_bar_drag_region);

        app_title_bar.LeftHeader(menu_button);
        app_title_bar.Content(title_bar_content);
        content_root.Children().Append(terminal_frame);
        root.Children().Append(content_root);
        root.Children().Append(app_title_bar);
        root.Children().Append(bottom_border);
        window.Content(root);
        window.ExtendsContentIntoTitleBar(true);
        window.SetTitleBar(app_title_bar);
        title_bar.PreferredHeightOption(Microsoft::UI::Windowing::TitleBarHeightOption::Tall);
        backdrop = Microsoft::UI::Xaml::Media::MicaBackdrop{};
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::BaseAlt);
        window.SystemBackdrop(backdrop);
        enableTitleBar();
        layout_revoker = root.LayoutUpdated(auto_revoke, [this](auto&&, auto&&) {
            layoutTerminal();
        });
        window_closed_revoker = window.Closed(auto_revoke, [this](auto&&, auto&&) {
            notify(ZIGONAUT_CHROME_SHUTDOWN, 0);
            close();
        });
        window_activated_revoker = window.Activated(auto_revoke, [this](auto&&, WindowActivatedEventArgs const& args) {
            if (!terminal) return;
            if (args.WindowActivationState() == WindowActivationState::Deactivated) {
                SendMessageW(terminal, WM_KILLFOCUS, 0, 0);
            } else if (terminal_input && terminal_input.FocusState() != FocusState::Unfocused) {
                SendMessageW(terminal, WM_SETFOCUS, 0, 0);
            }
        });
        addAccelerator(Windows::System::VirtualKey::T, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_NEW_DEFAULT);
        addAccelerator(Windows::System::VirtualKey::W, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_CLOSE);
        addAccelerator(Windows::System::VirtualKey::Tab, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_SELECT_NEXT);
        addAccelerator(Windows::System::VirtualKey::Tab, Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, ZIGONAUT_CHROME_SELECT_PREVIOUS);
        addAccelerator(Windows::System::VirtualKey::Number0, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_RESET);
        addAccelerator(Windows::System::VirtualKey::NumberPad0, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_RESET);
        addAccelerator(Windows::System::VirtualKey::Add, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_IN);
        addAccelerator(Windows::System::VirtualKey::Subtract, Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_OUT);
        addAccelerator(static_cast<Windows::System::VirtualKey>(VK_OEM_PLUS), Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_IN);
        addAccelerator(static_cast<Windows::System::VirtualKey>(VK_OEM_MINUS), Windows::System::VirtualKeyModifiers::Control, ZIGONAUT_CHROME_ZOOM_OUT);
        attachTerminalInput();
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
            if (terminal_input && terminal_input.FocusState() != FocusState::Unfocused) return;
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

    void attachTerminal(HWND child, void* swap_chain) {
        if (!child || GetParent(child) != parent || !swap_chain) throw hresult_invalid_argument();
        check_hresult(terminal_surface.as<ISwapChainPanelNative>()->SetSwapChain(
            static_cast<IDXGISwapChain*>(swap_chain)));
        terminal = child;
        layoutTerminal();
    }

    static LPARAM keyLparam(Windows::UI::Core::CorePhysicalKeyStatus const& status) {
        return static_cast<LPARAM>(status.RepeatCount) |
            (static_cast<LPARAM>(status.ScanCode) << 16) |
            (static_cast<LPARAM>(status.IsExtendedKey) << 24) |
            (static_cast<LPARAM>(status.WasKeyDown) << 30) |
            (static_cast<LPARAM>(status.IsKeyReleased) << 31);
    }

    void forwardTranslatedCharacters(Windows::System::VirtualKey key,
                                     Windows::UI::Core::CorePhysicalKeyStatus const& status) {
        translated_characters.clear();
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
        translated_characters.assign(characters, characters + count);
        for (int index = 0; index < count; ++index) {
            SendMessageW(terminal, message, static_cast<WPARAM>(characters[index]), keyLparam(status));
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
        auto const scale = terminal_surface.XamlRoot().RasterizationScale();
        auto const position = point.Position();
        auto const x = static_cast<short>(std::lround(position.X * scale));
        auto const y = static_cast<short>(std::lround(position.Y * scale));
        return MAKELPARAM(x, y);
    }

    void attachTerminalInput() {
        terminal_key_down_revoker = terminal_input.KeyDown(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
            if (!terminal) return;
            auto const status = args.KeyStatus();
            if (status.IsMenuKeyDown && (args.Key() == Windows::System::VirtualKey::F4 ||
                                         args.Key() == Windows::System::VirtualKey::Space)) return;
            SendMessageW(terminal, status.IsMenuKeyDown ? WM_SYSKEYDOWN : WM_KEYDOWN,
                         static_cast<WPARAM>(args.Key()), keyLparam(status));
            forwardTranslatedCharacters(args.Key(), status);
            args.Handled(true);
        });
        terminal_key_up_revoker = terminal_input.KeyUp(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
            if (!terminal) return;
            auto const status = args.KeyStatus();
            SendMessageW(terminal, status.IsMenuKeyDown ? WM_SYSKEYUP : WM_KEYUP,
                         static_cast<WPARAM>(args.Key()), keyLparam(status));
            args.Handled(true);
        });
        terminal_character_revoker = terminal_input.CharacterReceived(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::CharacterReceivedRoutedEventArgs const& args) {
            if (!terminal) return;
            auto const status = args.KeyStatus();
            if (!translated_characters.empty() &&
                static_cast<uint32_t>(translated_characters.front()) == args.Character()) {
                translated_characters.erase(translated_characters.begin());
                args.Handled(true);
                return;
            }
            translated_characters.clear();
            SendMessageW(terminal, status.IsMenuKeyDown ? WM_SYSCHAR : WM_CHAR,
                         static_cast<WPARAM>(args.Character()), keyLparam(status));
            args.Handled(true);
        });
        terminal_focus_revoker = terminal_input.GotFocus(auto_revoke, [this](auto&&, auto&&) {
            if (terminal) SendMessageW(terminal, WM_SETFOCUS, 0, 0);
        });
        terminal_blur_revoker = terminal_input.LostFocus(auto_revoke, [this](auto&&, auto&&) {
            if (terminal) SendMessageW(terminal, WM_KILLFOCUS, 0, 0);
        });
        terminal_pressed_revoker = terminal_surface.PointerPressed(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            if (!terminal) return;
            terminal_input.Focus(FocusState::Pointer);
            auto const point = args.GetCurrentPoint(terminal_surface);
            auto const kind = point.Properties().PointerUpdateKind();
            UINT message{};
            switch (kind) {
            case Microsoft::UI::Input::PointerUpdateKind::LeftButtonPressed: message = WM_LBUTTONDOWN; break;
            case Microsoft::UI::Input::PointerUpdateKind::RightButtonPressed: message = WM_RBUTTONDOWN; break;
            case Microsoft::UI::Input::PointerUpdateKind::MiddleButtonPressed: message = WM_MBUTTONDOWN; break;
            default: return;
            }
            SendMessageW(terminal, message, pointerWparam(point.Properties()), pointerLparam(point));
            terminal_surface.CapturePointer(args.Pointer());
            args.Handled(true);
        });
        terminal_released_revoker = terminal_surface.PointerReleased(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            if (!terminal) return;
            auto const point = args.GetCurrentPoint(terminal_surface);
            auto const kind = point.Properties().PointerUpdateKind();
            UINT message{};
            switch (kind) {
            case Microsoft::UI::Input::PointerUpdateKind::LeftButtonReleased: message = WM_LBUTTONUP; break;
            case Microsoft::UI::Input::PointerUpdateKind::RightButtonReleased: message = WM_RBUTTONUP; break;
            case Microsoft::UI::Input::PointerUpdateKind::MiddleButtonReleased: message = WM_MBUTTONUP; break;
            default: return;
            }
            SendMessageW(terminal, message, pointerWparam(point.Properties()), pointerLparam(point));
            terminal_surface.ReleasePointerCapture(args.Pointer());
            args.Handled(true);
        });
        terminal_moved_revoker = terminal_surface.PointerMoved(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            if (!terminal) return;
            auto const point = args.GetCurrentPoint(terminal_surface);
            SendMessageW(terminal, WM_MOUSEMOVE, pointerWparam(point.Properties()), pointerLparam(point));
            args.Handled(true);
        });
        terminal_wheel_revoker = terminal_surface.PointerWheelChanged(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            if (!terminal) return;
            auto const point = args.GetCurrentPoint(terminal_surface);
            auto const local = pointerLparam(point);
            POINT screen_point{
                static_cast<short>(LOWORD(local)),
                static_cast<short>(HIWORD(local)),
            };
            ClientToScreen(terminal, &screen_point);
            auto const properties = point.Properties();
            auto const wheel = static_cast<short>(properties.MouseWheelDelta());
            auto const message = properties.IsHorizontalMouseWheel() ? WM_MOUSEHWHEEL : WM_MOUSEWHEEL;
            SendMessageW(terminal, message, MAKEWPARAM(pointerWparam(properties), wheel),
                         MAKELPARAM(static_cast<short>(screen_point.x), static_cast<short>(screen_point.y)));
            args.Handled(true);
        });
        terminal_exited_revoker = terminal_surface.PointerExited(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            if (terminal) SendMessageW(terminal, WM_MOUSELEAVE, 0, 0);
            args.Handled(true);
        });
        terminal_canceled_revoker = terminal_surface.PointerCanceled(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args) {
            if (terminal) SendMessageW(terminal, WM_CANCELMODE, 0, 0);
            args.Handled(true);
        });
        terminal_capture_lost_revoker = terminal_surface.PointerCaptureLost(auto_revoke, [this](auto&&, Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const&) {
            if (terminal) SendMessageW(terminal, WM_CAPTURECHANGED, 0, 0);
        });
    }

    void activate() {
        window.Activate();
        layoutTerminal();
        focusTerminal();
    }

    void focusTerminal() {
        if (terminal_input) terminal_input.Focus(FocusState::Programmatic);
    }

    void layoutTerminal() {
        if (!terminal || !IsWindow(terminal) || !terminal_surface || !terminal_surface.XamlRoot()) return;
        auto const origin = terminal_surface.TransformToVisual(root).TransformPoint({0, 0});
        auto const scale = terminal_surface.XamlRoot().RasterizationScale();
        RECT next{
            static_cast<LONG>(std::lround(origin.X * scale)),
            static_cast<LONG>(std::lround(origin.Y * scale)),
            static_cast<LONG>(std::lround((origin.X + terminal_surface.ActualWidth()) * scale)),
            static_cast<LONG>(std::lround((origin.Y + terminal_surface.ActualHeight()) * scale)),
        };
        if (next.right <= next.left || next.bottom <= next.top || EqualRect(&next, &terminal_bounds)) return;
        terminal_bounds = next;
        SetWindowPos(terminal, nullptr, next.left, next.top, next.right - next.left, next.bottom - next.top,
                     SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER);
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
            for (uint32_t index = 0; index < tab_count; ++index) {
                storage[index] += std::to_string(index);
                titles[index] = storage[index].data();
                lengths[index] = static_cast<uint32_t>(storage[index].size());
            }
            for (uint32_t index = 0; index < iterations; ++index) {
                storage[0].back() = index % 2 ? 'A' : 'B';
                update(titles.data(), lengths.data(), tab_count, 0);
            }
        } else if (operation == L"scrollbar") {
            iterations = 100000;
            for (uint32_t index = 0; index < iterations; ++index) {
                updateScrollbar(100000, 40, 50000, false);
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
            terminal_bounds = {-1, -1, -1, -1};
            layoutTerminal();
            if (terminal_input) terminal_input.Focus(FocusState::Programmatic);
        });
        try {
            about_operation = about_dialog.ShowAsync();
        } catch (...) {
            reportCurrentException(L"show About dialog");
            about_closed_revoker.revoke();
            about_operation = nullptr;
            about_dialog = nullptr;
            terminal_bounds = {-1, -1, -1, -1};
            layoutTerminal();
        }
    }

    void showScrollbar() {
        if (!scrollbar || scrollbar.Visibility() != Visibility::Visible) return;
        scrollbar.IndicatorMode(Microsoft::UI::Xaml::Controls::Primitives::ScrollingIndicatorMode::MouseIndicator);
        scrollbar.Opacity(1);
        scheduleScrollbarHide();
    }

    void updateAppearance(uint32_t kind, bool high_contrast, bool dark_theme) {
        auto const requested_theme = high_contrast ? ElementTheme::Default : dark_theme ? ElementTheme::Dark : ElementTheme::Light;
        root.RequestedTheme(requested_theme);
        if (high_contrast || kind == ZIGONAUT_BACKDROP_NONE) {
            root.Background(application.Resources().Lookup(box_value(L"TabViewBackground")).as<Microsoft::UI::Xaml::Media::Brush>());
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
        backdrop.Kind(Microsoft::UI::Composition::SystemBackdrops::MicaKind::BaseAlt);
        window.SystemBackdrop(backdrop);
    }

    void scheduleScrollbarHide() {
        if (!scrollbar_timer) return;
        scrollbar_timer.Stop();
        if (!pointer_over_scrollbar) scrollbar_timer.Start();
    }

    void updateScrollbar(uint32_t total, uint32_t page, uint32_t position, bool show) {
        if (scrollbar_state_initialized && total == scrollbar_total &&
            page == scrollbar_page && position == scrollbar_position) {
            if (show) showScrollbar();
            return;
        }
        scrollbar_state_initialized = true;
        scrollbar_total = total;
        scrollbar_page = page;
        scrollbar_position = position;
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
            scrollbar.Opacity(0);
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
        auto changed = false;
        while (items.Size() > count) {
            items.RemoveAtEnd();
            changed = true;
        }
        for (uint32_t i = 0; i < count; ++i) {
            auto const title = to_hstring(std::string_view{titles[i], title_lengths[i]});
            if (i == items.Size()) {
                auto item = TabViewItem{};
                item.Header(box_value(title));
                item.MaxWidth(240);
                item.IsClosable(true);
                ToolTipService::SetToolTip(item, item.Header());
                items.Append(item);
                changed = true;
            } else {
                auto item = items.GetAt(i).as<TabViewItem>();
                if (unbox_value<hstring>(item.Header()) != title) {
                    item.Header(box_value(title));
                    ToolTipService::SetToolTip(item, item.Header());
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
            app_title_bar.RecomputeDragRegions();
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
            item.Text(to_hstring(std::string_view{names[index], name_lengths[index]}));
            profile_revokers.emplace_back(item.Click(auto_revoke, [this, index](auto&&, auto&&) {
                notify(ZIGONAUT_CHROME_NEW_PROFILE, index);
                focusTerminal();
            }));
            new_tab_menu.Items().Append(item);
            profile_items.emplace_back(std::move(item));
        }
    }

    HRESULT close() noexcept {
        if (closed) return S_OK;
        closed = true;
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
        layout_revoker.revoke();
        terminal_loaded_revoker.revoke();
        terminal_key_down_revoker.revoke();
        terminal_key_up_revoker.revoke();
        terminal_character_revoker.revoke();
        terminal_focus_revoker.revoke();
        terminal_blur_revoker.revoke();
        terminal_pressed_revoker.revoke();
        terminal_released_revoker.revoke();
        terminal_moved_revoker.revoke();
        terminal_wheel_revoker.revoke();
        terminal_exited_revoker.revoke();
        terminal_canceled_revoker.revoke();
        terminal_capture_lost_revoker.revoke();
        for (auto& revoker : accelerator_revokers) revoker.revoke();
        accelerator_revokers.clear();
        window_closed_revoker.revoke();
        window_activated_revoker.revoke();
        handlers_detached = true;
        cleanup(L"detach new-tab menu", [&] { new_tab_button.ContextFlyout(nullptr); }, result);
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
        title_bar_drag_region = nullptr;
        cleanup(L"clear tabs", [&] { tabs.TabItems().Clear(); }, result);
        cleanup(L"detach title bar content", [&] {
            app_title_bar.LeftHeader(nullptr);
            app_title_bar.Content(nullptr);
        }, result);
        cleanup(L"clear keyboard accelerators", [&] { root.KeyboardAccelerators().Clear(); }, result);
        accelerators.clear();
        scrollbar = nullptr;
        scrollbar_timer = nullptr;
        cleanup(L"clear content root", [&] { content_root.Children().Clear(); }, result);
        cleanup(L"clear root content", [&] { root.Children().Clear(); }, result);
        cleanup(L"detach terminal swap chain", [&] {
            if (terminal_surface) terminal_surface.as<ISwapChainPanelNative>()->SetSwapChain(nullptr);
        }, result);
        cleanup(L"detach custom title bar", [&] { window.SetTitleBar(nullptr); }, result);
        cleanup(L"clear system backdrop", [&] { window.SystemBackdrop(nullptr); }, result);
        cleanup(L"detach window content", [&] { window.Content(nullptr); }, result);
        terminal = nullptr;
        terminal_input = nullptr;
        terminal_surface = nullptr;
        terminal_presenter = nullptr;
        terminal_frame = nullptr;
        content_root = nullptr;
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

extern "C" HRESULT __cdecl zigonaut_window_run(zigonaut_window_started started, zigonaut_chrome_command callback, void* context, const char* version, uint32_t version_length, const char* git_hash, uint32_t git_hash_length) noexcept {
    if (!started || !callback || !context || (version_length && !version) || (git_hash_length && !git_hash)) return E_INVALIDARG;
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
                            context,
                            Application::Current(),
                            std::string_view{version ? version : "", version_length},
                            std::string_view{git_hash ? git_hash : "", git_hash_length});
                        bridge->terminal_loaded_revoker = bridge->terminal_surface.Loaded(auto_revoke, [&, started, context](auto&&, auto&&) {
                            bridge->terminal_loaded_revoker.revoke();
                            try {
                                bridge->root.UpdateLayout();
                                bridge->app_title_bar.RecomputeDragRegions();
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

extern "C" HRESULT __cdecl zigonaut_chrome_attach_terminal(void* value, HWND terminal, void* swap_chain) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->attachTerminal(terminal, swap_chain); return S_OK; } catch (...) { return reportCurrentException(L"attach terminal"); }
}

extern "C" HRESULT __cdecl zigonaut_chrome_focus_terminal(void* value) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    try { bridge->focusTerminal(); return S_OK; } catch (...) { return reportCurrentException(L"focus terminal"); }
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

extern "C" HRESULT __cdecl zigonaut_chrome_update_appearance(void* value, uint32_t backdrop, BOOL high_contrast, BOOL dark_theme) noexcept {
    auto bridge = static_cast<Bridge*>(value);
    auto const validation = validate(bridge); if (FAILED(validation)) return validation;
    if (backdrop > ZIGONAUT_BACKDROP_ACRYLIC) return E_INVALIDARG;
    try { bridge->updateAppearance(backdrop, high_contrast != FALSE, dark_theme != FALSE); return S_OK; } catch (...) { return reportCurrentException(L"update appearance"); }
}
