#include "directwrite_renderer.h"

#include <algorithm>
#include <cmath>
#include <dwrite.h>
#include <new>

namespace {

template <typename T>
void release(T*& value) {
    if (value != nullptr) {
        value->Release();
        value = nullptr;
    }
}

constexpr wchar_t fallback_family[] = L"Consolas";

} // namespace

struct ZigonautTextEngine {
    IDWriteFactory* factory = nullptr;
    IDWriteFontCollection* fonts = nullptr;
    IDWriteFontFace* normal_face = nullptr;
    IDWriteTextFormat* formats[4] = {};
    uint32_t font_size = 18;
    uint32_t dpi = 96;
    ZigonautCellMetrics metrics = {9, 18, 14};

    ~ZigonautTextEngine() {
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
        const float em_size = static_cast<float>(font_size);
        for (size_t index = 0; index < 4; ++index) {
            hr = factory->CreateTextFormat(
                family,
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

        updateMetrics();
        return S_OK;
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
    engine->updateMetrics();
    return S_OK;
}

extern "C" ZigonautCellMetrics zigonaut_text_engine_get_cell_metrics(
    const ZigonautTextEngine* engine) {
    if (engine == nullptr) return {9, 18, 14};
    return engine->metrics;
}
