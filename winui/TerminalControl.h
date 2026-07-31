#pragma once

#include "TerminalControl.g.h"

namespace winrt::ZigonautWinUIBridge::implementation
{
    struct TerminalControl : TerminalControlT<TerminalControl>
    {
        TerminalControl() = default;
        HWND Window() const noexcept { return window_; }
        void Window(HWND value) noexcept { window_ = value; }
        bool IsTerminal() const noexcept { return true; }
        Microsoft::UI::Xaml::Automation::Peers::AutomationPeer OnCreateAutomationPeer();

    private:
        HWND window_{};
    };

}

namespace winrt::ZigonautWinUIBridge::factory_implementation
{
    struct TerminalControl : TerminalControlT<TerminalControl, implementation::TerminalControl> {};
}
