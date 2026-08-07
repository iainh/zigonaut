#pragma once

#include "TerminalAutomationPeer.g.h"

namespace winrt::ZigonautWinUIBridge::implementation
{
    struct TerminalAutomationPeer : TerminalAutomationPeerT<TerminalAutomationPeer>
    {
        explicit TerminalAutomationPeer(ZigonautWinUIBridge::TerminalControl const& owner);
        ~TerminalAutomationPeer() noexcept;
        winrt::hstring ProviderClassName() { return L"ZigonautTerminalPane"; }
        winrt::hstring GetClassNameCore();
        Microsoft::UI::Xaml::Automation::Peers::AutomationControlType GetAutomationControlTypeCore();
        winrt::hstring GetNameCore();
        winrt::Windows::Foundation::IInspectable GetPatternCore(
            Microsoft::UI::Xaml::Automation::Peers::PatternInterface const& pattern);
        bool IsReadOnly() const noexcept { return true; }
        winrt::hstring Value();
        void SetValue(winrt::hstring const&);
        Microsoft::UI::Xaml::Automation::Provider::ITextRangeProvider DocumentRange();
        Microsoft::UI::Xaml::Automation::SupportedTextSelection SupportedTextSelection() const noexcept;
        winrt::com_array<Microsoft::UI::Xaml::Automation::Provider::ITextRangeProvider> GetSelection();
        winrt::com_array<Microsoft::UI::Xaml::Automation::Provider::ITextRangeProvider> GetVisibleRanges();
        Microsoft::UI::Xaml::Automation::Provider::ITextRangeProvider RangeFromChild(Microsoft::UI::Xaml::Automation::Provider::IRawElementProviderSimple const&);
        Microsoft::UI::Xaml::Automation::Provider::ITextRangeProvider RangeFromPoint(Windows::Foundation::Point const& point);
        void RaiseTextEvents(uint32_t changes);

    private:
        winrt::hstring Query(uint32_t kind);
        HWND m_registeredWindow{};
        uint64_t m_registrationToken{};
    };
}

namespace winrt::ZigonautWinUIBridge::factory_implementation
{
    struct TerminalAutomationPeer : TerminalAutomationPeerT<TerminalAutomationPeer, implementation::TerminalAutomationPeer> {};
}
