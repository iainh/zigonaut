#pragma once

#include "TerminalAutomationPeer.g.h"

namespace winrt::ZigonautWinUIBridge::implementation
{
    struct TerminalAutomationPeer : TerminalAutomationPeerT<TerminalAutomationPeer>
    {
        explicit TerminalAutomationPeer(ZigonautWinUIBridge::TerminalControl const& owner);
        winrt::hstring ProviderClassName() { return L"ZigonautTerminalPane"; }
        winrt::hstring GetClassNameCore();
        Microsoft::UI::Xaml::Automation::Peers::AutomationControlType GetAutomationControlTypeCore();
        winrt::hstring GetNameCore();
        winrt::Windows::Foundation::IInspectable GetPatternCore(
            Microsoft::UI::Xaml::Automation::Peers::PatternInterface const& pattern);
        bool IsReadOnly() const noexcept { return true; }
        winrt::hstring Value();
        void SetValue(winrt::hstring const&);

    private:
        winrt::hstring Query(uint32_t kind);
    };
}

namespace winrt::ZigonautWinUIBridge::factory_implementation
{
    struct TerminalAutomationPeer : TerminalAutomationPeerT<TerminalAutomationPeer, implementation::TerminalAutomationPeer> {};
}
