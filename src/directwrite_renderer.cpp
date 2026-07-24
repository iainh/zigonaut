#include "directwrite_renderer.h"

#include <algorithm>
#include <cmath>
#include <d2d1.h>
#include <dwrite.h>
#include <map>
#include <new>
#include <string>

namespace {

template <typename T>
void release(T*& value) {
    if (value != nullptr) {
        value->Release();
        value = nullptr;
    }
}

constexpr wchar_t fallback_family[] = L"Consolas";
constexpr size_t max_layout_cache_entries = 2048;

struct LayoutKey {
    std::u16string text;
    uint32_t width;
    uint32_t height;
    uint8_t style;

    bool operator<(const LayoutKey& other) const {
        if (style != other.style) return style < other.style;
        if (width != other.width) return width < other.width;
        if (height != other.height) return height < other.height;
        return text < other.text;
    }
};

D2D1_COLOR_F color(uint32_t value) {
    return D2D1::ColorF(
        static_cast<float>(value & 0xff) / 255.0f,
        static_cast<float>((value >> 8) & 0xff) / 255.0f,
        static_cast<float>((value >> 16) & 0xff) / 255.0f,
        1.0f);
}

} // namespace

struct ZigonautTextEngine {
    IDWriteFactory* factory = nullptr;
    IDWriteFontCollection* fonts = nullptr;
    IDWriteFontFace* normal_face = nullptr;
    IDWriteTextFormat* formats[4] = {};
    ID2D1Factory* d2d_factory = nullptr;
    ID2D1HwndRenderTarget* target = nullptr;
    ID2D1SolidColorBrush* brush = nullptr;
    std::map<LayoutKey, IDWriteTextLayout*> layouts;
    std::wstring family;
    HWND hwnd = nullptr;
    uint32_t font_size = 18;
    uint32_t dpi = 96;
    ZigonautCellMetrics metrics = {9, 18, 14};

    ~ZigonautTextEngine() {
        discardTarget();
        release(d2d_factory);
        clearLayouts();
        for (auto*& format : formats) release(format);
        release(normal_face);
        release(fonts);
        release(factory);
    }

    HRESULT initialize(const wchar_t* requested_family) {
        HRESULT hr = DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED,
            __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(&factory));
        if (FAILED(hr)) return hr;

        hr = factory->GetSystemFontCollection(&fonts, FALSE);
        if (FAILED(hr)) return hr;

        const wchar_t* family = requested_family;
        UINT32 family_index = 0;
        BOOL exists = FALSE;
        hr = fonts->FindFamilyName(family, &family_index, &exists);
        if (FAILED(hr)) return hr;
        if (!exists) {
            family = fallback_family;
            hr = fonts->FindFamilyName(family, &family_index, &exists);
            if (FAILED(hr)) return hr;
            if (!exists) return DWRITE_E_NOFONT;
        }
        this->family = family;

        IDWriteFontFamily* font_family = nullptr;
        hr = fonts->GetFontFamily(family_index, &font_family);
        if (FAILED(hr)) return hr;

        IDWriteFont* normal_font = nullptr;
        hr = font_family->GetFirstMatchingFont(
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            &normal_font);
        release(font_family);
        if (FAILED(hr)) return hr;

        hr = normal_font->CreateFontFace(&normal_face);
        release(normal_font);
        if (FAILED(hr)) return hr;

        hr = D2D1CreateFactory(
            D2D1_FACTORY_TYPE_SINGLE_THREADED,
            __uuidof(ID2D1Factory),
            nullptr,
            reinterpret_cast<void**>(&d2d_factory));
        if (FAILED(hr)) return hr;

        hr = createFormats();
        if (FAILED(hr)) return hr;

        updateMetrics();
        return S_OK;
    }

    HRESULT createFormats() {
        clearLayouts();
        for (auto*& format : formats) release(format);
        constexpr DWRITE_FONT_WEIGHT weights[] = {
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_WEIGHT_BOLD,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_WEIGHT_BOLD,
        };
        constexpr DWRITE_FONT_STYLE styles[] = {
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STYLE_ITALIC,
            DWRITE_FONT_STYLE_ITALIC,
        };
        const float em_size = static_cast<float>(font_size) *
            static_cast<float>(dpi) / 96.0f;
        for (size_t index = 0; index < 4; ++index) {
            const HRESULT hr = factory->CreateTextFormat(
                family.c_str(),
                fonts,
                weights[index],
                styles[index],
                DWRITE_FONT_STRETCH_NORMAL,
                em_size,
                L"en-us",
                &formats[index]);
            if (FAILED(hr)) return hr;
            formats[index]->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        }
        return S_OK;
    }

    void discardTarget() {
        release(brush);
        release(target);
    }

    void clearLayouts() {
        for (auto& entry : layouts) release(entry.second);
        layouts.clear();
    }

    HRESULT ensureTarget(uint32_t width, uint32_t height) {
        if (hwnd == nullptr) return E_HANDLE;
        const D2D1_SIZE_U size = D2D1::SizeU(width, height);
        HRESULT hr = S_OK;
        if (target == nullptr) {
            hr = d2d_factory->CreateHwndRenderTarget(
                D2D1::RenderTargetProperties(),
                D2D1::HwndRenderTargetProperties(hwnd, size),
                &target);
            if (FAILED(hr)) return hr;
            target->SetDpi(96.0f, 96.0f);
            hr = target->CreateSolidColorBrush(D2D1::ColorF(1.0f, 1.0f, 1.0f), &brush);
            if (FAILED(hr)) {
                discardTarget();
                return hr;
            }
        } else if (target->GetPixelSize().width != width ||
                   target->GetPixelSize().height != height) {
            hr = target->Resize(size);
        }
        return hr;
    }

    void updateMetrics() {
        DWRITE_FONT_METRICS font_metrics{};
        normal_face->GetMetrics(&font_metrics);
        const float em_pixels = static_cast<float>(font_size) *
            static_cast<float>(dpi) / 96.0f;
        const float scale = em_pixels /
            static_cast<float>(font_metrics.designUnitsPerEm);

        UINT32 codepoint = L'M';
        UINT16 glyph = 0;
        DWRITE_GLYPH_METRICS glyph_metrics{};
        normal_face->GetGlyphIndices(&codepoint, 1, &glyph);
        if (SUCCEEDED(normal_face->GetDesignGlyphMetrics(
                &glyph, 1, &glyph_metrics, FALSE))) {
            metrics.width = std::max(
                1u,
                static_cast<uint32_t>(std::lround(
                    static_cast<float>(glyph_metrics.advanceWidth) * scale)));
        }

        const int32_t line_units = std::max<int32_t>(
            1,
            static_cast<int32_t>(font_metrics.ascent) +
                static_cast<int32_t>(font_metrics.descent) +
                static_cast<int32_t>(font_metrics.lineGap));
        metrics.height = std::max(
            1u,
            static_cast<uint32_t>(std::lround(
                static_cast<float>(line_units) * scale)));
        metrics.baseline = std::min(
            metrics.height,
            static_cast<uint32_t>(std::lround(
                static_cast<float>(font_metrics.ascent) * scale)));
    }


    HRESULT drawCell(
        const uint16_t* text,
        uint32_t text_length,
        float left,
        float top,
        float width,
        float height,
        uint32_t foreground,
        uint32_t background,
        bool bold,
        bool italic) {
        if (target == nullptr || brush == nullptr) return E_UNEXPECTED;
        const auto rect = D2D1::RectF(left, top, left + width, top + height);
        brush->SetColor(color(background));
        target->FillRectangle(rect, brush);
        if (text_length == 0) return S_OK;

        const size_t format_index = (bold ? 1u : 0u) | (italic ? 2u : 0u);
        LayoutKey key{
            std::u16string(
                reinterpret_cast<const char16_t*>(text),
                reinterpret_cast<const char16_t*>(text) + text_length),
            static_cast<uint32_t>(std::lround(width)),
            static_cast<uint32_t>(std::lround(height)),
            static_cast<uint8_t>(format_index),
        };
        auto existing = layouts.find(key);
        IDWriteTextLayout* layout = nullptr;
        if (existing != layouts.end()) {
            layout = existing->second;
        } else {
            if (layouts.size() >= max_layout_cache_entries) clearLayouts();
            HRESULT hr = factory->CreateTextLayout(
                reinterpret_cast<const wchar_t*>(text),
                text_length,
                formats[format_index],
                width,
                height,
                &layout);
            if (FAILED(hr)) return hr;
            layouts.emplace(std::move(key), layout);
        }
        brush->SetColor(color(foreground));
        target->PushAxisAlignedClip(rect, D2D1_ANTIALIAS_MODE_ALIASED);
        target->DrawTextLayout(
            D2D1::Point2F(left, top),
            layout,
            brush,
            D2D1_DRAW_TEXT_OPTIONS_CLIP);
        target->PopAxisAlignedClip();
        return S_OK;
    }
};

extern "C" HRESULT zigonaut_text_engine_create(
    const wchar_t* font_family,
    uint32_t font_size,
    uint32_t dpi,
    ZigonautTextEngine** result) {
    if (font_family == nullptr || result == nullptr || font_size == 0 || dpi == 0) {
        return E_INVALIDARG;
    }
    *result = nullptr;

    auto* engine = new (std::nothrow) ZigonautTextEngine();
    if (engine == nullptr) return E_OUTOFMEMORY;
    engine->font_size = font_size;
    engine->dpi = dpi;
    const HRESULT hr = engine->initialize(font_family);
    if (FAILED(hr)) {
        delete engine;
        return hr;
    }
    *result = engine;
    return S_OK;
}

extern "C" void zigonaut_text_engine_destroy(ZigonautTextEngine* engine) {
    delete engine;
}

extern "C" HRESULT zigonaut_text_engine_set_dpi(
    ZigonautTextEngine* engine,
    uint32_t dpi) {
    if (engine == nullptr || dpi == 0) return E_INVALIDARG;
    engine->dpi = dpi;
    const HRESULT hr = engine->createFormats();
    if (FAILED(hr)) return hr;
    engine->updateMetrics();
    return S_OK;
}

extern "C" ZigonautCellMetrics zigonaut_text_engine_get_cell_metrics(
    const ZigonautTextEngine* engine) {
    if (engine == nullptr) return {9, 18, 14};
    return engine->metrics;
}

extern "C" HRESULT zigonaut_text_engine_set_window(
    ZigonautTextEngine* engine,
    uintptr_t hwnd) {
    if (engine == nullptr || hwnd == 0) return E_INVALIDARG;
    engine->discardTarget();
    engine->hwnd = reinterpret_cast<HWND>(hwnd);
    return S_OK;
}

extern "C" HRESULT zigonaut_text_engine_begin_frame(
    ZigonautTextEngine* engine,
    uint32_t width,
    uint32_t height,
    uint32_t background) {
    if (engine == nullptr || width == 0 || height == 0) return E_INVALIDARG;
    const HRESULT hr = engine->ensureTarget(width, height);
    if (FAILED(hr)) return hr;
    engine->target->BeginDraw();
    engine->target->SetTransform(D2D1::Matrix3x2F::Identity());
    engine->target->Clear(color(background));
    return S_OK;
}

extern "C" HRESULT zigonaut_text_engine_draw_cell(
    ZigonautTextEngine* engine,
    const uint16_t* text,
    uint32_t text_length,
    float left,
    float top,
    float width,
    float height,
    uint32_t foreground,
    uint32_t background,
    BOOL bold,
    BOOL italic) {
    if (engine == nullptr || (text == nullptr && text_length != 0)) return E_INVALIDARG;
    return engine->drawCell(
        text,
        text_length,
        left,
        top,
        width,
        height,
        foreground,
        background,
        bold != FALSE,
        italic != FALSE);
}

extern "C" void zigonaut_text_engine_draw_cursor(
    ZigonautTextEngine* engine,
    float left,
    float top,
    float width,
    float height,
    uint32_t cursor_color) {
    if (engine == nullptr || engine->target == nullptr || engine->brush == nullptr) return;
    engine->brush->SetColor(color(cursor_color));
    engine->target->DrawRectangle(
        D2D1::RectF(left + 0.5f, top + 0.5f, left + width - 0.5f, top + height - 0.5f),
        engine->brush,
        1.0f);
}

extern "C" HRESULT zigonaut_text_engine_end_frame(ZigonautTextEngine* engine) {
    if (engine == nullptr || engine->target == nullptr) return E_INVALIDARG;
    const HRESULT hr = engine->target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) engine->discardTarget();
    return hr;
}
