#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <oleauto.h>
#include <textstor.h>
#include <msctf.h>
#include <functional>
#include <string_view>

#ifndef TF_CLIENTID_NULL
#define TF_CLIENTID_NULL ((TfClientId)0)
#endif

// MinGW's TSF headers currently omit this Windows SDK interface. Keep the
// compatibility declaration ABI-identical to the SDK so the core can still be
// cross-compiled and checked outside Visual Studio.
#ifndef __ITfContextOwner_INTERFACE_DEFINED__
#define __ITfContextOwner_INTERFACE_DEFINED__
inline constexpr IID IID_ITfContextOwner = {
    0xaa80e80c, 0x2021, 0x11d2, {0x93, 0xe0, 0x00, 0x60, 0xb0, 0x67, 0xb8, 0x6e}
};
MIDL_INTERFACE("aa80e80c-2021-11d2-93e0-0060b067b86e")
ITfContextOwner : public IUnknown {
public:
    virtual HRESULT STDMETHODCALLTYPE GetACPFromPoint(const POINT*, DWORD, LONG*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetTextExt(LONG, LONG, RECT*, BOOL*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetScreenExt(RECT*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetStatus(TF_STATUS*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetWnd(HWND*) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetAttribute(REFGUID, VARIANT*) = 0;
};
#endif

// One of these lives on the WinUI STA. The provider is borrowed and is changed
// whenever a pane receives XAML keyboard focus.
class TsfService final : public ITfContextOwner,
                         public ITfContextOwnerCompositionSink,
                         public ITfTextEditSink {
public:
    struct Provider {
        HWND hwnd{};
        HWND focus_hwnd{};
        RECT viewport{};
        RECT caret{};
        std::function<void(std::wstring_view)> commit;
        std::function<void(std::wstring_view, uint32_t, uint32_t)> preedit;
        std::function<void()> clear;
    };

    HRESULT Initialize() noexcept;
    void Shutdown() noexcept;
    bool Focus(Provider* provider) noexcept;
    void Unfocus(Provider* provider) noexcept;
    bool Active() const noexcept { return compositions_ != 0; }

    STDMETHODIMP QueryInterface(REFIID, void**) noexcept override;
    ULONG STDMETHODCALLTYPE AddRef() noexcept override;
    ULONG STDMETHODCALLTYPE Release() noexcept override;
    STDMETHODIMP GetACPFromPoint(const POINT*, DWORD, LONG*) noexcept override;
    STDMETHODIMP GetTextExt(LONG, LONG, RECT*, BOOL*) noexcept override;
    STDMETHODIMP GetScreenExt(RECT*) noexcept override;
    STDMETHODIMP GetStatus(TF_STATUS*) noexcept override;
    STDMETHODIMP GetWnd(HWND*) noexcept override;
    STDMETHODIMP GetAttribute(REFGUID, VARIANT*) noexcept override;
    STDMETHODIMP OnStartComposition(ITfCompositionView*, BOOL*) noexcept override;
    STDMETHODIMP OnUpdateComposition(ITfCompositionView*, ITfRange*) noexcept override;
    STDMETHODIMP OnEndComposition(ITfCompositionView*) noexcept override;
    STDMETHODIMP OnEndEdit(ITfContext*, TfEditCookie, ITfEditRecord*) noexcept override;

private:
    struct EditSession final : ITfEditSession {
        TsfService* owner{};
        ULONG refs{};
        std::function<void(std::wstring_view)> commit;
        std::function<void(std::wstring_view, uint32_t, uint32_t)> preedit;
        std::function<void()> clear;
        explicit EditSession(TsfService* value) noexcept : owner(value) {}
        bool Capture(const Provider* provider) noexcept;
        void Clear() noexcept;
        STDMETHODIMP QueryInterface(REFIID, void**) noexcept override;
        ULONG STDMETHODCALLTYPE AddRef() noexcept override;
        ULONG STDMETHODCALLTYPE Release() noexcept override;
        STDMETHODIMP DoEditSession(TfEditCookie) noexcept override;
    } edit_{this};
    void RequestUpdate() noexcept;
    HRESULT Update(TfEditCookie) noexcept;

    volatile LONG refs_{1};
    bool shutting_down_{};
    ITfThreadMgrEx* manager_{};
    ITfDocumentMgr* document_{};
    ITfContext* context_{};
    ITfContextOwnerCompositionServices* composition_services_{};
    ITfSource* source_{};
    DWORD owner_cookie_{TF_INVALID_COOKIE};
    DWORD edit_cookie_{TF_INVALID_COOKIE};
    TfClientId client_{TF_CLIENTID_NULL};
    Provider* provider_{};
    HWND associated_{};
    unsigned compositions_{};
};
