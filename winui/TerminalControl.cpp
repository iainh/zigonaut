#include "pch.h"
#include "TerminalControl.h"
#include "TerminalAutomationPeer.h"
#include "bridge.h"

#include <algorithm>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

extern "C" HRESULT WINAPI UiaGetReservedNotSupportedValue(IUnknown** value);
constexpr int32_t IsReadOnlyAttributeId = 40015;

using namespace winrt;
using namespace winrt::Microsoft::UI::Xaml::Automation;
using namespace winrt::Microsoft::UI::Xaml::Automation::Peers;
using namespace winrt::Microsoft::UI::Xaml::Automation::Provider;
using namespace winrt::Microsoft::UI::Xaml::Automation::Text;

namespace
{
    struct TextSnapshot
    {
        HWND window{};
        uint64_t owner{};
        uint64_t fingerprint{};
        std::wstring text;
        std::vector<zigonaut_accessibility_run> runs;
        uint32_t caret{};
        uint32_t selectionStart{};
        uint32_t selectionEnd{};
        bool caretValid{};
        bool selectionActive{};
        int32_t left{};
        int32_t top{};
        uint32_t cellWidth{};
        uint32_t cellHeight{};
        uint32_t rows{};
        uint32_t columns{};
        weak_ref<ZigonautWinUIBridge::TerminalAutomationPeer> peer;
    };

    std::shared_ptr<TextSnapshot> TakeSnapshot(
        HWND window,
        ZigonautWinUIBridge::TerminalAutomationPeer const& peer)
    {
        for (unsigned attempt = 0; attempt != 3; ++attempt)
        {
            zigonaut_accessibility_snapshot query{ sizeof(query), ZIGONAUT_ACCESSIBLE_TEXT_SNAPSHOT };
            if (SendMessageW(window, ZIGONAUT_WM_ACCESSIBILITY_QUERY, 0,
                    reinterpret_cast<LPARAM>(&query)) != 1)
            {
                return {};
            }

            auto snapshot = std::make_shared<TextSnapshot>();
            snapshot->text.resize(query.text_required);
            snapshot->runs.resize(query.run_required);
            auto const expectedOwner = query.owner;
            auto const expectedFingerprint = query.fingerprint;
            auto const expectedText = query.text_required;
            auto const expectedRuns = query.run_required;
            query.text = reinterpret_cast<uint16_t*>(snapshot->text.data());
            query.text_capacity = expectedText;
            query.runs = snapshot->runs.data();
            query.run_capacity = expectedRuns;
            if (SendMessageW(window, ZIGONAUT_WM_ACCESSIBILITY_QUERY, 0,
                    reinterpret_cast<LPARAM>(&query)) != 1)
            {
                return {};
            }
            if (query.owner != expectedOwner || query.fingerprint != expectedFingerprint ||
                query.text_required != expectedText || query.run_required != expectedRuns)
            {
                continue;
            }

            snapshot->window = window;
            snapshot->owner = query.owner;
            snapshot->fingerprint = query.fingerprint;
            snapshot->caret = query.caret;
            snapshot->caretValid = query.caret_valid != 0;
            snapshot->selectionStart = query.selection_start;
            snapshot->selectionEnd = query.selection_end;
            snapshot->selectionActive = query.selection_active != 0;
            snapshot->left = query.grid_left;
            snapshot->top = query.grid_top;
            snapshot->cellWidth = query.cell_width;
            snapshot->cellHeight = query.cell_height;
            snapshot->rows = query.rows;
            snapshot->columns = query.columns;
            snapshot->peer = peer;
            return snapshot;
        }
        return {};
    }

    bool IsHighSurrogate(wchar_t value) noexcept { return value >= 0xD800 && value <= 0xDBFF; }
    bool IsLowSurrogate(wchar_t value) noexcept { return value >= 0xDC00 && value <= 0xDFFF; }

    Windows::Foundation::IInspectable NotSupportedValue()
    {
        IUnknown* raw{};
        check_hresult(UiaGetReservedNotSupportedValue(&raw));
        com_ptr<IUnknown> value;
        value.attach(raw);
        return value.as<Windows::Foundation::IInspectable>();
    }

    struct TerminalTextRange : implements<TerminalTextRange, ITextRangeProvider>
    {
        std::shared_ptr<TextSnapshot> snapshot;
        uint32_t start{};
        uint32_t end{};

        TerminalTextRange(std::shared_ptr<TextSnapshot> value, uint32_t first, uint32_t last)
            : snapshot(std::move(value)), start(first), end(last)
        {
            start = std::min<uint32_t>(start, snapshot->text.size());
            end = std::min<uint32_t>(end, snapshot->text.size());
            if (start > end) std::swap(start, end);
        }

        bool Compatible(TerminalTextRange const& other) const noexcept
        {
            return snapshot->owner == other.snapshot->owner &&
                snapshot->fingerprint == other.snapshot->fingerprint;
        }

        std::vector<uint32_t> CharacterBoundaries() const
        {
            std::vector<uint32_t> result{ 0 };
            for (auto const& run : snapshot->runs)
            {
                if (result.back() != run.start) result.push_back(run.start);
                if (result.back() != run.end) result.push_back(run.end);
            }
            for (uint32_t i = 0; i < snapshot->text.size(); ++i)
            {
                if (snapshot->text[i] == L'\n') result.push_back(i + 1);
            }
            result.push_back(static_cast<uint32_t>(snapshot->text.size()));
            std::sort(result.begin(), result.end());
            result.erase(std::unique(result.begin(), result.end()), result.end());
            return result;
        }

        std::vector<uint32_t> Boundaries(TextUnit requested) const
        {
            auto unit = requested;
            if (unit == TextUnit::Format) unit = TextUnit::Word;
            if (unit == TextUnit::Paragraph || unit == TextUnit::Page) unit = TextUnit::Document;
            uint32_t const length = static_cast<uint32_t>(snapshot->text.size());
            if (unit == TextUnit::Document) return { 0, length };
            if (unit == TextUnit::Character) return CharacterBoundaries();

            std::vector<uint32_t> result{ 0 };
            if (unit == TextUnit::Line)
            {
                for (uint32_t i = 0; i < length; ++i)
                    if (snapshot->text[i] == L'\n') result.push_back(i + 1);
            }
            else
            {
                // Windows' ordinal case APIs and FindText use UTF-16; word grouping
                // deliberately remains stable and locale independent here. Walk
                // terminal grapheme boundaries so a word boundary can never split
                // a surrogate pair or a combining sequence within one cell.
                auto const characters = CharacterBoundaries();
                auto word = [this](uint32_t offset)
                {
                    auto const value = snapshot->text[offset];
                    return IsCharAlphaNumericW(value) || value == L'_';
                };
                for (size_t i = 1; i + 1 < characters.size(); ++i)
                    if (word(characters[i - 1]) != word(characters[i])) result.push_back(characters[i]);
            }
            result.push_back(length);
            result.erase(std::unique(result.begin(), result.end()), result.end());
            return result;
        }

        static uint32_t Previous(std::vector<uint32_t> const& boundaries, uint32_t position)
        {
            auto it = std::lower_bound(boundaries.begin(), boundaries.end(), position);
            return it == boundaries.begin() ? position : *std::prev(it);
        }

        static uint32_t Next(std::vector<uint32_t> const& boundaries, uint32_t position)
        {
            auto it = std::upper_bound(boundaries.begin(), boundaries.end(), position);
            return it == boundaries.end() ? position : *it;
        }

        std::pair<uint32_t, uint32_t> Enclosing(uint32_t position, TextUnit unit) const
        {
            auto boundaries = Boundaries(unit);
            if (boundaries.size() < 2) return { 0, 0 };
            if (position >= boundaries.back()) return { boundaries[boundaries.size() - 2], boundaries.back() };
            auto upper = std::upper_bound(boundaries.begin(), boundaries.end(), position);
            return { *std::prev(upper), *upper };
        }

        ITextRangeProvider Clone() { return make<TerminalTextRange>(snapshot, start, end); }

        bool Compare(ITextRangeProvider const& value)
        {
            auto other = value.try_as<TerminalTextRange>();
            return other && Compatible(*other) && start == other->start && end == other->end;
        }

        int32_t CompareEndpoints(TextPatternRangeEndpoint endpoint, ITextRangeProvider const& value,
            TextPatternRangeEndpoint otherEndpoint)
        {
            auto other = value.try_as<TerminalTextRange>();
            if (!other || !Compatible(*other)) throw hresult_invalid_argument();
            auto left = endpoint == TextPatternRangeEndpoint::Start ? start : end;
            auto right = otherEndpoint == TextPatternRangeEndpoint::Start ? other->start : other->end;
            return left < right ? -1 : left > right ? 1 : 0;
        }

        void ExpandToEnclosingUnit(TextUnit unit)
        {
            auto range = Enclosing(start, unit);
            start = range.first;
            end = range.second;
        }

        Windows::Foundation::IInspectable GetAttributeValue(int32_t attribute)
        {
            if (attribute == IsReadOnlyAttributeId) return box_value(true);
            return NotSupportedValue();
        }

        ITextRangeProvider FindAttribute(int32_t attribute,
            Windows::Foundation::IInspectable const& value, bool backward)
        {
            if (attribute != IsReadOnlyAttributeId) return nullptr;
            auto wanted = unbox_value_or<bool>(value, false);
            if (!wanted) return nullptr;
            return make<TerminalTextRange>(snapshot, start, end);
        }

        bool ValidBoundary(uint32_t offset) const
        {
            auto boundaries = CharacterBoundaries();
            return std::binary_search(boundaries.begin(), boundaries.end(), offset);
        }

        ITextRangeProvider FindText(hstring const& value, bool backward, bool ignoreCase)
        {
            if (value.empty()) return nullptr;
            auto const needle = std::wstring_view(value);
            uint32_t candidate = backward ? end : start;
            while (backward ? candidate >= start + needle.size() : candidate + needle.size() <= end)
            {
                uint32_t at = backward ? candidate - static_cast<uint32_t>(needle.size()) : candidate;
                bool equal = ignoreCase
                    ? CompareStringOrdinal(snapshot->text.data() + at, static_cast<int>(needle.size()),
                        needle.data(), static_cast<int>(needle.size()), TRUE) == CSTR_EQUAL
                    : std::wstring_view(snapshot->text).substr(at, needle.size()) == needle;
                if (equal && ValidBoundary(at) && ValidBoundary(at + static_cast<uint32_t>(needle.size())))
                    return make<TerminalTextRange>(snapshot, at, at + static_cast<uint32_t>(needle.size()));
                if (backward) --candidate; else ++candidate;
            }
            return nullptr;
        }

        void GetBoundingRectangles(com_array<double>& result)
        {
            std::vector<double> rectangles;
            bool active = false;
            uint16_t row = 0;
            uint32_t firstColumn = 0;
            uint32_t lastColumn = 0;
            auto flush = [&]
            {
                if (!active) return;
                rectangles.insert(rectangles.end(), {
                    double(snapshot->left + firstColumn * snapshot->cellWidth),
                    double(snapshot->top + row * snapshot->cellHeight),
                    double((lastColumn - firstColumn) * snapshot->cellWidth),
                    double(snapshot->cellHeight) });
                active = false;
            };
            if (start != end)
            {
                for (auto const& run : snapshot->runs)
                {
                    if (run.end <= start || run.start >= end) continue;
                    if (!active || run.row != row || run.column != lastColumn)
                    {
                        flush();
                        active = true;
                        row = run.row;
                        firstColumn = run.column;
                    }
                    lastColumn = run.column + run.columns;
                }
                flush();
            }
            result = com_array<double>(rectangles);
        }

        IRawElementProviderSimple GetEnclosingElement()
        {
            auto peer = snapshot->peer.get();
            if (!peer) return nullptr;
            auto protectedPeer = peer.as<IAutomationPeerProtected>();
            return protectedPeer.ProviderFromPeer(peer);
        }

        hstring GetText(int32_t maxLength)
        {
            if (maxLength < -1) throw hresult_invalid_argument();
            uint32_t first = start;
            uint32_t count = end - start;
            if (maxLength >= 0) count = std::min<uint32_t>(count, maxLength);
            if (count && IsHighSurrogate(snapshot->text[first + count - 1])) --count;
            if (count && IsLowSurrogate(snapshot->text[first])) { ++first; --count; }
            return hstring(snapshot->text.substr(first, count));
        }

        int32_t Move(TextUnit unit, int32_t count)
        {
            if (!count) return 0;
            auto boundaries = Boundaries(unit);
            if (boundaries.size() < 2) return 0;

            if (start == end)
            {
                auto current = std::lower_bound(boundaries.begin(), boundaries.end(), start);
                auto index = static_cast<int64_t>(std::distance(boundaries.begin(), current));
                auto target = std::clamp<int64_t>(index + count, 0, boundaries.size() - 1);
                start = end = boundaries[static_cast<size_t>(target)];
                return static_cast<int32_t>(target - index);
            }

            auto const currentRange = Enclosing(start, unit);
            auto current = std::lower_bound(boundaries.begin(), boundaries.end(), currentRange.first);
            auto index = static_cast<int64_t>(std::distance(boundaries.begin(), current));
            auto const lastUnit = static_cast<int64_t>(boundaries.size()) - 2;
            auto target = std::clamp<int64_t>(index + count, 0, lastUnit);
            start = boundaries[static_cast<size_t>(target)];
            end = boundaries[static_cast<size_t>(target + 1)];
            return static_cast<int32_t>(target - index);
        }

        int32_t MoveEndpointByUnit(TextPatternRangeEndpoint endpoint, TextUnit unit, int32_t count)
        {
            auto boundaries = Boundaries(unit);
            uint32_t& position = endpoint == TextPatternRangeEndpoint::Start ? start : end;
            int32_t moved = 0;
            while (moved != count)
            {
                auto next = count > 0 ? Next(boundaries, position) : Previous(boundaries, position);
                if (next == position) break;
                position = next;
                moved += count > 0 ? 1 : -1;
            }
            if (start > end)
            {
                if (endpoint == TextPatternRangeEndpoint::Start) end = start;
                else start = end;
            }
            return moved;
        }

        void MoveEndpointByRange(TextPatternRangeEndpoint endpoint, ITextRangeProvider const& value,
            TextPatternRangeEndpoint otherEndpoint)
        {
            auto other = value.try_as<TerminalTextRange>();
            if (!other || !Compatible(*other)) throw hresult_invalid_argument();
            auto position = otherEndpoint == TextPatternRangeEndpoint::Start ? other->start : other->end;
            if (endpoint == TextPatternRangeEndpoint::Start)
            {
                start = position;
                if (start > end) end = start;
            }
            else
            {
                end = position;
                if (end < start) start = end;
            }
        }

        void Select()
        {
            zigonaut_accessibility_action action{ sizeof(action), ZIGONAUT_ACCESSIBILITY_SELECT,
                snapshot->owner, snapshot->fingerprint, start, end };
            if (SendMessageW(snapshot->window, ZIGONAUT_WM_ACCESSIBILITY_ACTION, 0,
                    reinterpret_cast<LPARAM>(&action)) != 1)
                throw hresult_invalid_argument();
        }
        void AddToSelection() { throw hresult_not_implemented(); }
        void RemoveFromSelection() { throw hresult_not_implemented(); }
        void ScrollIntoView(bool) {}
        com_array<IRawElementProviderSimple> GetChildren() { return {}; }
    };

    struct Registration
    {
        weak_ref<ZigonautWinUIBridge::TerminalAutomationPeer> peer;
        uint64_t token{};
        uint64_t fingerprint{};
        uint32_t pending{};
        bool queued{};
    };
    std::mutex registryMutex;
    std::unordered_map<HWND, Registration> registry;
    uint64_t nextToken{};
}

namespace winrt::ZigonautWinUIBridge::implementation
{
    AutomationPeer TerminalControl::OnCreateAutomationPeer() { return make<TerminalAutomationPeer>(*this); }

    TerminalAutomationPeer::TerminalAutomationPeer(ZigonautWinUIBridge::TerminalControl const& owner)
        : TerminalAutomationPeer_base<TerminalAutomationPeer>(owner)
    {
        auto window = get_self<TerminalControl>(owner)->Window();
        std::scoped_lock lock(registryMutex);
        registry[window] = Registration{ *this, ++nextToken };
    }

    hstring TerminalAutomationPeer::Query(uint32_t kind)
    {
        auto owner = Owner().try_as<ZigonautWinUIBridge::TerminalControl>();
        if (!owner) return {};
        auto window = get_self<TerminalControl>(owner)->Window();
        if (!IsWindow(window)) return {};
        zigonaut_accessibility_query query{ sizeof(query), kind };
        if (SendMessageW(window, ZIGONAUT_WM_ACCESSIBILITY_QUERY, 0, reinterpret_cast<LPARAM>(&query)) != 1 || !query.required) return {};
        std::wstring value(query.required, L'\0');
        query.output = reinterpret_cast<uint16_t*>(value.data());
        query.capacity = query.required;
        if (SendMessageW(window, ZIGONAUT_WM_ACCESSIBILITY_QUERY, 0, reinterpret_cast<LPARAM>(&query)) != 1 || query.required > query.capacity) return {};
        value.resize(query.required);
        return hstring(value);
    }

    hstring TerminalAutomationPeer::GetClassNameCore() { return L"ZigonautTerminalPane"; }
    AutomationControlType TerminalAutomationPeer::GetAutomationControlTypeCore() { return AutomationControlType::Document; }
    hstring TerminalAutomationPeer::GetNameCore() { return Query(ZIGONAUT_ACCESSIBLE_NAME); }
    Windows::Foundation::IInspectable TerminalAutomationPeer::GetPatternCore(PatternInterface const& pattern)
    {
        if (pattern == PatternInterface::Value || pattern == PatternInterface::Text) return *this;
        return TerminalAutomationPeer_base<TerminalAutomationPeer>::GetPatternCore(pattern);
    }
    hstring TerminalAutomationPeer::Value() { return Query(ZIGONAUT_ACCESSIBLE_VALUE); }
    void TerminalAutomationPeer::SetValue(hstring const&) { throw hresult_not_implemented(); }

    ITextRangeProvider TerminalAutomationPeer::DocumentRange()
    {
        auto owner = Owner().try_as<ZigonautWinUIBridge::TerminalControl>();
        if (!owner) return nullptr;
        auto snapshot = TakeSnapshot(get_self<TerminalControl>(owner)->Window(), *this);
        return snapshot ? make<TerminalTextRange>(snapshot, 0, static_cast<uint32_t>(snapshot->text.size())) : nullptr;
    }
    SupportedTextSelection TerminalAutomationPeer::SupportedTextSelection() const noexcept { return SupportedTextSelection::Single; }
    com_array<ITextRangeProvider> TerminalAutomationPeer::GetSelection()
    {
        auto owner = Owner().try_as<ZigonautWinUIBridge::TerminalControl>();
        if (!owner) return {};
        auto snapshot = TakeSnapshot(get_self<TerminalControl>(owner)->Window(), *this);
        if (!snapshot) return {};
        if (snapshot->selectionActive) return { make<TerminalTextRange>(snapshot, snapshot->selectionStart, snapshot->selectionEnd) };
        if (snapshot->caretValid) return { make<TerminalTextRange>(snapshot, snapshot->caret, snapshot->caret) };
        return {};
    }
    com_array<ITextRangeProvider> TerminalAutomationPeer::GetVisibleRanges()
    {
        auto range = DocumentRange();
        return range ? com_array<ITextRangeProvider>{ range } : com_array<ITextRangeProvider>{};
    }
    ITextRangeProvider TerminalAutomationPeer::RangeFromChild(IRawElementProviderSimple const&) { throw hresult_invalid_argument(); }
    ITextRangeProvider TerminalAutomationPeer::RangeFromPoint(Windows::Foundation::Point const& point)
    {
        auto owner = Owner().try_as<ZigonautWinUIBridge::TerminalControl>();
        if (!owner) return nullptr;
        auto snapshot = TakeSnapshot(get_self<TerminalControl>(owner)->Window(), *this);
        if (!snapshot) return nullptr;
        auto row = std::clamp<int>(static_cast<int>((point.Y - snapshot->top) / std::max(1u, snapshot->cellHeight)), 0, std::max(0, static_cast<int>(snapshot->rows) - 1));
        auto column = std::clamp<int>(static_cast<int>((point.X - snapshot->left) / std::max(1u, snapshot->cellWidth)), 0, std::max(0, static_cast<int>(snapshot->columns) - 1));
        uint32_t offset = static_cast<uint32_t>(snapshot->text.size());
        for (auto const& run : snapshot->runs)
            if (run.row == row && column >= run.column && column < run.column + run.columns) { offset = run.start; break; }
        return make<TerminalTextRange>(snapshot, offset, offset);
    }
    void TerminalAutomationPeer::RaiseTextEvents(uint32_t changes)
    {
        if (changes & ZIGONAUT_AUTOMATION_TEXT_CHANGED) RaiseAutomationEvent(AutomationEvents::TextPatternOnTextChanged);
        if (changes & ZIGONAUT_AUTOMATION_SELECTION_CHANGED) RaiseAutomationEvent(AutomationEvents::TextPatternOnTextSelectionChanged);
    }
}

extern "C" __declspec(dllexport) void __cdecl zigonaut_terminal_automation_notify(HWND window, uint32_t changes) noexcept
{
    try
    {
        weak_ref<ZigonautWinUIBridge::TerminalAutomationPeer> weak;
        uint64_t token{};
        {
            std::scoped_lock lock(registryMutex);
            auto found = registry.find(window);
            if (found == registry.end()) return;
            auto peer = found->second.peer.get();
            if (!peer) { registry.erase(found); return; }
            auto snapshot = TakeSnapshot(window, peer);
            if (!snapshot || snapshot->fingerprint == found->second.fingerprint) return;
            found->second.fingerprint = snapshot->fingerprint;
            found->second.pending |= changes;
            if (found->second.queued) return;
            found->second.queued = true;
            weak = found->second.peer;
            token = found->second.token;
        }
        auto peer = weak.get();
        if (!peer) return;
        bool queued = peer.DispatcherQueue().TryEnqueue([window, token]
        {
            uint32_t pending{};
            weak_ref<ZigonautWinUIBridge::TerminalAutomationPeer> currentWeak;
            {
                std::scoped_lock lock(registryMutex);
                auto found = registry.find(window);
                if (found == registry.end() || found->second.token != token) return;
                pending = found->second.pending;
                found->second.pending = 0;
                found->second.queued = false;
                currentWeak = found->second.peer;
            }
            if (auto current = currentWeak.get())
                get_self<ZigonautWinUIBridge::implementation::TerminalAutomationPeer>(current)->RaiseTextEvents(pending);
        });
        if (!queued)
        {
            std::scoped_lock lock(registryMutex);
            auto found = registry.find(window);
            if (found != registry.end() && found->second.token == token) found->second.queued = false;
        }
    }
    catch (...) {}
}
