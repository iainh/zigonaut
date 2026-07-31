#include "pch.h"
#include "TerminalControl.h"
#include "TerminalAutomationPeer.h"
#include "bridge.h"

using namespace winrt;
using namespace winrt::Microsoft::UI::Xaml::Automation::Peers;

namespace winrt::ZigonautWinUIBridge::implementation
{
    AutomationPeer TerminalControl::OnCreateAutomationPeer()
    {
        return make<TerminalAutomationPeer>(*this);
    }

    TerminalAutomationPeer::TerminalAutomationPeer(ZigonautWinUIBridge::TerminalControl const& owner)
        : TerminalAutomationPeer_base<TerminalAutomationPeer>(owner)
    {
    }

    hstring TerminalAutomationPeer::Query(uint32_t kind)
    {
        auto const owner = Owner().try_as<ZigonautWinUIBridge::TerminalControl>();
        if (!owner) return {};
        auto const hwnd = get_self<TerminalControl>(owner)->Window();
        if (!IsWindow(hwnd)) return {};
        zigonaut_accessibility_query query{sizeof(query), kind};
        if (SendMessageW(hwnd, ZIGONAUT_WM_ACCESSIBILITY_QUERY, 0, reinterpret_cast<LPARAM>(&query)) != 1 || !query.required)
            return {};
        std::wstring value(query.required, L'\0');
        query.output = reinterpret_cast<uint16_t*>(value.data());
        query.capacity = query.required;
        query.required = 0;
        if (SendMessageW(hwnd, ZIGONAUT_WM_ACCESSIBILITY_QUERY, 0, reinterpret_cast<LPARAM>(&query)) != 1 ||
            query.required > query.capacity) return {};
        value.resize(query.required);
        return hstring(value);
    }

    hstring TerminalAutomationPeer::GetClassNameCore() { return L"ZigonautTerminalPane"; }
    AutomationControlType TerminalAutomationPeer::GetAutomationControlTypeCore() { return AutomationControlType::Document; }
    hstring TerminalAutomationPeer::GetNameCore() { return Query(ZIGONAUT_ACCESSIBLE_NAME); }
    Windows::Foundation::IInspectable TerminalAutomationPeer::GetPatternCore(PatternInterface const& pattern)
    {
        if (pattern == PatternInterface::Value) return *this;
        return TerminalAutomationPeer_base<TerminalAutomationPeer>::GetPatternCore(pattern);
    }
    hstring TerminalAutomationPeer::Value() { return Query(ZIGONAUT_ACCESSIBLE_VALUE); }
    void TerminalAutomationPeer::SetValue(hstring const&) { throw hresult_not_implemented(); }
}
