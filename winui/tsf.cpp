#include "tsf.h"
#include <algorithm>
#include <climits>
#include <string>

#pragma comment(lib, "msctf.lib")

template<class T> static void release(T*& p) noexcept { if (p) { p->Release(); p = nullptr; } }

static HRESULT rangeLength(ITfRange* range, TfEditCookie ec, LONG* out) noexcept {
    if (!range || !out) return E_POINTER;
    *out = 0;
    ITfRange* copy{};
    auto hr = range->Clone(&copy);
    if (FAILED(hr)) return hr;
    wchar_t buffer[256];
    while (SUCCEEDED(hr)) {
        ULONG count{};
        hr = copy->GetText(ec, TF_TF_MOVESTART, buffer, 256, &count);
        if (FAILED(hr) || count == 0) break;
        if (*out > LONG_MAX - static_cast<LONG>(count)) { hr = E_FAIL; break; }
        *out += static_cast<LONG>(count);
    }
    release(copy);
    return hr;
}

HRESULT TsfService::Initialize() noexcept {
    shutting_down_ = false;
    HRESULT hr = CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&manager_));
    if (SUCCEEDED(hr)) hr = manager_->ActivateEx(&client_, TF_TMAE_NOACTIVATETIP | TF_TMAE_NOACTIVATEKEYBOARDLAYOUT);
    if (SUCCEEDED(hr)) hr = manager_->CreateDocumentMgr(&document_);
    TfEditCookie cookie{};
    if (SUCCEEDED(hr)) hr = document_->CreateContext(client_, 0, static_cast<ITfContextOwnerCompositionSink*>(this), &context_, &cookie);
    if (SUCCEEDED(hr)) context_->QueryInterface(IID_PPV_ARGS(&composition_services_)); // optional
    if (SUCCEEDED(hr)) hr = context_->QueryInterface(IID_PPV_ARGS(&source_));
    if (SUCCEEDED(hr)) hr = source_->AdviseSink(IID_ITfContextOwner, static_cast<ITfContextOwner*>(this), &owner_cookie_);
    if (SUCCEEDED(hr)) hr = source_->AdviseSink(IID_ITfTextEditSink, static_cast<ITfTextEditSink*>(this), &edit_cookie_);
    if (SUCCEEDED(hr)) hr = document_->Push(context_);
    if (FAILED(hr)) Shutdown();
    return hr;
}

void TsfService::Shutdown() noexcept {
    if (shutting_down_) return;
    shutting_down_ = true;
    Unfocus(provider_);
    if (manager_ && associated_) {
        ITfDocumentMgr* previous{};
        manager_->AssociateFocus(associated_, nullptr, &previous);
        release(previous);
        associated_ = nullptr;
    }
    if (source_ && edit_cookie_ != TF_INVALID_COOKIE) source_->UnadviseSink(edit_cookie_);
    if (source_ && owner_cookie_ != TF_INVALID_COOKIE) source_->UnadviseSink(owner_cookie_);
    edit_cookie_ = owner_cookie_ = TF_INVALID_COOKIE;
    if (document_) document_->Pop(TF_POPF_ALL);
    if (manager_ && client_ != TF_CLIENTID_NULL) manager_->Deactivate();
    release(source_); release(composition_services_); release(context_); release(document_); release(manager_);
    client_ = TF_CLIENTID_NULL;
}

bool TsfService::Focus(Provider* p) noexcept {
    if (!p || !manager_ || !document_ || edit_.refs) return false;
    GetWindowRect(p->hwnd, &p->viewport);
    if (p->caret.right <= p->caret.left || p->caret.bottom <= p->caret.top) {
        p->caret = p->viewport;
        p->caret.top = std::max(p->viewport.top, p->viewport.bottom - 1);
        p->caret.right = std::min(p->viewport.right, p->viewport.left + 1);
    }
    provider_ = p;
    auto const focus = p->focus_hwnd ? p->focus_hwnd : p->hwnd;
    if (associated_ != focus) {
        if (associated_) {
            ITfDocumentMgr* previous{};
            manager_->AssociateFocus(associated_, nullptr, &previous);
            release(previous);
        }
        ITfDocumentMgr* previous{};
        if (FAILED(manager_->AssociateFocus(focus, document_, &previous))) { provider_ = nullptr; associated_ = nullptr; return false; }
        release(previous); associated_ = focus;
    }
    if (FAILED(manager_->SetFocus(document_))) { provider_ = nullptr; return false; }
    return true;
}

void TsfService::Unfocus(Provider* p) noexcept {
    if (!p || provider_ != p) return;
    if (p->clear) p->clear();
    provider_ = nullptr;
    if (compositions_ && composition_services_) composition_services_->TerminateComposition(nullptr);
    compositions_ = 0;
    if (manager_) manager_->SetFocus(nullptr);
}

HRESULT TsfService::QueryInterface(REFIID id, void** out) noexcept {
    if (!out) return E_POINTER; *out = nullptr;
    if (id == IID_IUnknown || id == IID_ITfContextOwner) *out = static_cast<ITfContextOwner*>(this);
    else if (id == IID_ITfContextOwnerCompositionSink) *out = static_cast<ITfContextOwnerCompositionSink*>(this);
    else if (id == IID_ITfTextEditSink) *out = static_cast<ITfTextEditSink*>(this);
    else return E_NOINTERFACE;
    AddRef(); return S_OK;
}
ULONG TsfService::AddRef() noexcept { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
ULONG TsfService::Release() noexcept { auto n = InterlockedDecrement(&refs_); if (!n) delete this; return static_cast<ULONG>(n); }
HRESULT TsfService::GetACPFromPoint(const POINT*, DWORD, LONG*) noexcept { return E_NOTIMPL; }
HRESULT TsfService::GetTextExt(LONG, LONG, RECT* r, BOOL* clipped) noexcept { if (!r || !clipped) return E_POINTER; *r = provider_ ? provider_->caret : RECT{}; *clipped = FALSE; return S_OK; }
HRESULT TsfService::GetScreenExt(RECT* r) noexcept { if (!r) return E_POINTER; *r = provider_ ? provider_->viewport : RECT{}; return S_OK; }
HRESULT TsfService::GetStatus(TF_STATUS* s) noexcept { if (!s) return E_POINTER; s->dwDynamicFlags = 0; s->dwStaticFlags = TS_SS_TRANSITORY | TS_SS_NOHIDDENTEXT; return S_OK; }
HRESULT TsfService::GetWnd(HWND* h) noexcept { if (!h) return E_POINTER; *h = provider_ ? provider_->hwnd : nullptr; return S_OK; }
HRESULT TsfService::GetAttribute(REFGUID, VARIANT* v) noexcept { if (!v) return E_POINTER; VariantInit(v); return S_OK; }
HRESULT TsfService::OnStartComposition(ITfCompositionView*, BOOL* ok) noexcept {
    if (!ok) return E_POINTER;
    ++compositions_;
    *ok = TRUE;
    // Snapshot the destination before the first edit. Some TIPs commit without
    // ever publishing a non-empty preedit string.
    if (provider_ && provider_->preedit) provider_->preedit({}, 0, 0);
    return S_OK;
}
HRESULT TsfService::OnUpdateComposition(ITfCompositionView*, ITfRange*) noexcept { return S_OK; }
HRESULT TsfService::OnEndComposition(ITfCompositionView*) noexcept { if (compositions_) --compositions_; RequestUpdate(); return S_OK; }
HRESULT TsfService::OnEndEdit(ITfContext*, TfEditCookie, ITfEditRecord*) noexcept { RequestUpdate(); return S_OK; }

bool TsfService::EditSession::Capture(const Provider* provider) noexcept {
    try {
        commit = provider ? provider->commit : nullptr;
        preedit = provider ? provider->preedit : nullptr;
        clear = provider ? provider->clear : nullptr;
        return true;
    } catch (...) {
        Clear();
        return false;
    }
}
void TsfService::EditSession::Clear() noexcept { commit = nullptr; preedit = nullptr; clear = nullptr; }
HRESULT TsfService::EditSession::QueryInterface(REFIID id, void** out) noexcept { if (!out) return E_POINTER; if (id != IID_IUnknown && id != IID_ITfEditSession) { *out=nullptr; return E_NOINTERFACE; } *out=this; AddRef(); return S_OK; }
ULONG TsfService::EditSession::AddRef() noexcept { ++refs; return owner->AddRef(); }
ULONG TsfService::EditSession::Release() noexcept { if (--refs == 0) Clear(); return owner->Release(); }
HRESULT TsfService::EditSession::DoEditSession(TfEditCookie ec) noexcept { return owner->Update(ec); }
void TsfService::RequestUpdate() noexcept {
    if (shutting_down_ || !context_ || edit_.refs) return;
    if (!edit_.Capture(provider_)) return;
    HRESULT session{};
    const auto hr = context_->RequestEditSession(client_, &edit_, TF_ES_READWRITE | TF_ES_ASYNC, &session);
    if (FAILED(hr) || FAILED(session)) edit_.Clear();
}

HRESULT TsfService::Update(TfEditCookie ec) noexcept {
    if (shutting_down_ || !context_) return S_OK;
    ITfRange* all{};
    HRESULT hr = context_->GetStart(ec, &all); LONG length{};
    if (SUCCEEDED(hr)) hr = all->ShiftEnd(ec, LONG_MAX, &length, nullptr);
    std::wstring text;
    if (SUCCEEDED(hr) && length > 0) { text.resize(length); ULONG got{}; hr = all->GetText(ec, 0, text.data(), length, &got); text.resize(got); }
    ITfProperty* composing{};
    ITfReadOnlyProperty* tracked{};
    if (SUCCEEDED(hr)) hr = context_->GetProperty(GUID_PROP_COMPOSING, &composing);
    const GUID* properties[]{&GUID_PROP_COMPOSING, &GUID_PROP_ATTRIBUTE};
    if (SUCCEEDED(hr)) hr = context_->TrackProperties(properties, 2, nullptr, 0, &tracked);
    LONG finalized = 0;
    if (SUCCEEDED(hr) && !text.empty()) {
        IEnumTfRanges* ranges{}; hr = tracked->EnumRanges(ec, &ranges, all);
        bool sawComposition = false;
        while (SUCCEEDED(hr) && ranges) {
            ITfRange* range{};
            ULONG fetched{};
            const auto next = ranges->Next(1, &range, &fetched);
            if (next == S_FALSE) break;
            if (FAILED(next)) { hr = next; break; }
            VARIANT value{};
            VariantInit(&value);
            hr = composing->GetValue(ec, range, &value);
            if (FAILED(hr)) { VariantClear(&value); release(range); break; }
            bool active = value.vt == VT_I4 && value.lVal != 0;
            LONG range_length{};
            hr = rangeLength(range, ec, &range_length);
            if (FAILED(hr)) { VariantClear(&value); release(range); break; }
            // Tracked ranges cover the complete context in order. Only text
            // before the first active composition can be irrevocably emitted.
            if (active) sawComposition = true;
            else if (!sawComposition) finalized += std::max(range_length, 0L);
            VariantClear(&value); release(range);
        }
        release(ranges);
        if (!sawComposition) finalized = compositions_ ? 0 : length;
    }
    if (FAILED(hr)) { release(tracked); release(composing); release(all); return hr; }
    LONG caret = 0; TF_SELECTION selection{}; ULONG count{};
    if (SUCCEEDED(context_->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &selection, &count)) && count) {
        ITfRange* begin{};
        if (SUCCEEDED(context_->GetStart(ec, &begin)) && begin) {
            TF_HALTCOND halt{selection.range, selection.style.ase == TF_AE_START ? TF_ANCHOR_START : TF_ANCHOR_END};
            if (FAILED(begin->ShiftEnd(ec, LONG_MAX, &caret, &halt))) caret = 0;
        }
        release(begin);
        release(selection.range);
    }
    finalized = std::clamp(finalized, 0L, static_cast<LONG>(text.size()));
    auto active = std::wstring_view{text}.substr(finalized);
    auto removed = finalized == 0;
    if (finalized) {
        ITfRange* prefix{};
        LONG moved{};
        hr = context_->GetStart(ec, &prefix);
        if (SUCCEEDED(hr)) hr = prefix->ShiftEnd(ec, finalized, &moved, nullptr);
        if (SUCCEEDED(hr) && moved != finalized) hr = E_FAIL;
        if (SUCCEEDED(hr)) hr = prefix->SetText(ec, 0, nullptr, 0);
        release(prefix);
        removed = SUCCEEDED(hr);
    }
    if (edit_.preedit) edit_.preedit(active, std::clamp<LONG>(caret-finalized, 0, static_cast<LONG>(active.size())), 0);
    if (removed && finalized && edit_.commit) edit_.commit(std::wstring_view{text}.substr(0, finalized));
    if (compositions_ == 0 && active.empty() && edit_.clear) edit_.clear();
    release(tracked); release(composing); release(all); return hr;
}
