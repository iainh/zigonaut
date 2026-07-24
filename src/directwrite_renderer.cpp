#include "directwrite_renderer.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <d2d1.h>
#include <dwrite.h>
#include <map>
#include <new>
#include <string>
#include <vector>

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

struct RowCell {
    std::u16string text;
    uint32_t column;
    uint32_t foreground;
    uint32_t background;
    bool bold;
    bool italic;
    ZigonautCellOccupancy occupancy;
};

struct RowSegment {
    std::u16string text;
    std::vector<uint32_t> start_columns;
    std::vector<uint32_t> end_columns;
    uint32_t foreground = 0;
    bool bold = false;
    bool italic = false;
};

D2D1_COLOR_F color(uint32_t value) {
    return D2D1::ColorF(
        static_cast<float>(value & 0xff) / 255.0f,
        static_cast<float>((value >> 8) & 0xff) / 255.0f,
        static_cast<float>((value >> 16) & 0xff) / 255.0f,
        1.0f);
}

} // namespace

class GridTextRenderer;

struct ZigonautTextEngine {
    IDWriteFactory* factory = nullptr;
    IDWriteFontCollection* fonts = nullptr;
    IDWriteFontFace* normal_face = nullptr;
    IDWriteTextFormat* formats[4] = {};
    ID2D1Factory* d2d_factory = nullptr;
    ID2D1HwndRenderTarget* target = nullptr;
    ID2D1SolidColorBrush* brush = nullptr;
    std::map<LayoutKey, IDWriteTextLayout*> layouts;
    std::vector<RowCell> row_cells;
    std::wstring family;
    HWND hwnd = nullptr;
    uint32_t font_size = 18;
    uint32_t dpi = 96;
    ZigonautCellMetrics metrics = {9, 18, 14};
    float row_origin_x = 0.0f;
    float row_top = 0.0f;
    float row_cell_width = 0.0f;
    float row_cell_height = 0.0f;
    bool row_active = false;

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
        bool italic,
        ZigonautCellOccupancy occupancy) {
        if (target == nullptr || brush == nullptr) return E_UNEXPECTED;
        const auto rect = D2D1::RectF(left, top, left + width, top + height);
        brush->SetColor(color(background));
        target->FillRectangle(rect, brush);
        if (row_active) {
            std::u16string cell_text;
            if (text_length != 0) {
                cell_text.assign(
                    reinterpret_cast<const char16_t*>(text),
                    reinterpret_cast<const char16_t*>(text) + text_length);
            }
            row_cells.push_back({
                std::move(cell_text),
                static_cast<uint32_t>(std::lround((left - row_origin_x) / row_cell_width)),
                foreground,
                background,
                bold,
                italic,
                occupancy,
            });
            return S_OK;
        }
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

    void beginRow(
        float origin_x,
        float top,
        float cell_width,
        float cell_height) {
        row_cells.clear();
        row_origin_x = origin_x;
        row_top = top;
        row_cell_width = cell_width;
        row_cell_height = cell_height;
        row_active = true;
    }

    void endRow();

    HRESULT drawSegment(const RowSegment& segment);
};

class GridTextRenderer final : public IDWriteTextRenderer {
public:
    GridTextRenderer(ZigonautTextEngine* engine, const RowSegment& segment)
        : engine_(engine), segment_(segment) {}

    IFACEMETHOD(QueryInterface)(REFIID iid, void** object) override {
        if (object == nullptr) return E_POINTER;
        *object = nullptr;
        if (iid == __uuidof(IUnknown) ||
            iid == __uuidof(IDWritePixelSnapping) ||
            iid == __uuidof(IDWriteTextRenderer)) {
            *object = static_cast<IDWriteTextRenderer*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    IFACEMETHOD_(ULONG, AddRef)() override {
        return ++references_;
    }

    IFACEMETHOD_(ULONG, Release)() override {
        const ULONG remaining = --references_;
        if (remaining == 0) delete this;
        return remaining;
    }

    IFACEMETHOD(IsPixelSnappingDisabled)(
        void*,
        BOOL* disabled) override {
        if (disabled == nullptr) return E_POINTER;
        *disabled = FALSE;
        return S_OK;
    }

    IFACEMETHOD(GetCurrentTransform)(
        void*,
        DWRITE_MATRIX* transform) override {
        if (transform == nullptr) return E_POINTER;
        *transform = {1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f};
        return S_OK;
    }

    IFACEMETHOD(GetPixelsPerDip)(void*, FLOAT* value) override {
        if (value == nullptr) return E_POINTER;
        *value = 1.0f;
        return S_OK;
    }

    IFACEMETHOD(DrawGlyphRun)(
        void*,
        FLOAT,
        FLOAT,
        DWRITE_MEASURING_MODE measuring_mode,
        const DWRITE_GLYPH_RUN* glyph_run,
        const DWRITE_GLYPH_RUN_DESCRIPTION* description,
        IUnknown*) override {
        if (glyph_run == nullptr || engine_->target == nullptr || engine_->brush == nullptr) {
            return E_INVALIDARG;
        }

        std::vector<FLOAT> advances(
            glyph_run->glyphAdvances,
            glyph_run->glyphAdvances + glyph_run->glyphCount);
        float origin_x = engine_->row_origin_x;

        if (description != nullptr && description->clusterMap != nullptr &&
            description->stringLength > 0) {
            struct ClusterSpan {
                uint32_t start_column = UINT32_MAX;
                uint32_t end_column = 0;
                uint32_t first_text_index = UINT32_MAX;
                uint32_t text_end = 0;
            };
            std::map<UINT16, ClusterSpan> spans;
            uint32_t run_start_column = UINT32_MAX;
            uint32_t run_end_column = 0;
            for (UINT32 index = 0; index < description->stringLength; ++index) {
                const uint32_t text_index = description->textPosition + index;
                if (text_index >= segment_.start_columns.size()) break;
                auto& span = spans[description->clusterMap[index]];
                span.start_column = std::min(
                    span.start_column,
                    segment_.start_columns[text_index]);
                span.end_column = std::max(
                    span.end_column,
                    segment_.end_columns[text_index]);
                span.first_text_index = std::min(span.first_text_index, text_index);
                span.text_end = std::max(span.text_end, text_index + 1);
                run_start_column = std::min(run_start_column, span.start_column);
                run_end_column = std::max(run_end_column, span.end_column);
            }

            std::vector<UINT16> glyph_starts;
            glyph_starts.reserve(spans.size());
            for (const auto& entry : spans) {
                if (entry.first < glyph_run->glyphCount) glyph_starts.push_back(entry.first);
            }
            std::sort(glyph_starts.begin(), glyph_starts.end());
            glyph_starts.erase(
                std::unique(glyph_starts.begin(), glyph_starts.end()),
                glyph_starts.end());
            for (size_t index = 0; index < glyph_starts.size(); ++index) {
                const UINT32 glyph_start = glyph_starts[index];
                const UINT32 glyph_end = index + 1 < glyph_starts.size()
                    ? glyph_starts[index + 1]
                    : glyph_run->glyphCount;
                if (glyph_start >= glyph_end) continue;
                const auto found = spans.find(static_cast<UINT16>(glyph_start));
                if (found == spans.end()) continue;
                float natural = 0.0f;
                for (UINT32 glyph = glyph_start; glyph < glyph_end; ++glyph) {
                    natural += advances[glyph];
                }
                const uint32_t cluster_left = segment_.start_columns[
                    found->second.first_text_index];
                const uint32_t cluster_right =
                    found->second.text_end < segment_.start_columns.size()
                    ? segment_.start_columns[found->second.text_end]
                    : segment_.end_columns[found->second.text_end - 1];
                const float expected = static_cast<float>(
                    cluster_right - cluster_left) * engine_->row_cell_width;
                advances[glyph_end - 1] += expected - natural;
            }

            if (run_start_column != UINT32_MAX) {
                origin_x += static_cast<float>(
                    glyph_run->bidiLevel % 2 == 0
                        ? run_start_column
                        : run_end_column) * engine_->row_cell_width;
            }
        }

        DWRITE_GLYPH_RUN adjusted = *glyph_run;
        adjusted.glyphAdvances = advances.data();
        engine_->brush->SetColor(color(segment_.foreground));
        engine_->target->DrawGlyphRun(
            D2D1::Point2F(
                origin_x,
                engine_->row_top + static_cast<float>(engine_->metrics.baseline)),
            &adjusted,
            engine_->brush,
            measuring_mode);
        return S_OK;
    }

    IFACEMETHOD(DrawUnderline)(
        void*, FLOAT, FLOAT, const DWRITE_UNDERLINE*, IUnknown*) override {
        return S_OK;
    }

    IFACEMETHOD(DrawStrikethrough)(
        void*, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH*, IUnknown*) override {
        return S_OK;
    }

    IFACEMETHOD(DrawInlineObject)(
        void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL, BOOL, IUnknown*) override {
        return E_NOTIMPL;
    }

private:
    std::atomic<ULONG> references_{1};
    ZigonautTextEngine* engine_;
    const RowSegment& segment_;
};

HRESULT ZigonautTextEngine::drawSegment(const RowSegment& segment) {
    if (segment.text.empty()) return S_OK;
    uint32_t start_column = UINT32_MAX;
    uint32_t end_column = 0;
    for (size_t index = 0; index < segment.start_columns.size(); ++index) {
        start_column = std::min(start_column, segment.start_columns[index]);
        end_column = std::max(end_column, segment.end_columns[index]);
    }
    if (start_column == UINT32_MAX || end_column <= start_column) return S_OK;

    IDWriteTextLayout* layout = nullptr;
    const size_t format_index = (segment.bold ? 1u : 0u) |
        (segment.italic ? 2u : 0u);
    HRESULT hr = factory->CreateTextLayout(
        reinterpret_cast<const wchar_t*>(segment.text.data()),
        static_cast<UINT32>(segment.text.size()),
        formats[format_index],
        static_cast<float>(end_column - start_column) * row_cell_width,
        row_cell_height,
        &layout);
    if (FAILED(hr)) return hr;

    auto* renderer = new (std::nothrow) GridTextRenderer(this, segment);
    if (renderer == nullptr) {
        release(layout);
        return E_OUTOFMEMORY;
    }
    hr = layout->Draw(nullptr, renderer, 0.0f, 0.0f);
    renderer->Release();
    release(layout);
    return hr;
}

void ZigonautTextEngine::endRow() {
    if (!row_active) return;
    row_active = false;

    RowSegment segment;
    bool has_segment = false;
    const auto flush = [&]() {
        if (has_segment) drawSegment(segment);
        segment = RowSegment{};
        has_segment = false;
    };

    for (const auto& cell : row_cells) {
        if (cell.occupancy == ZIGONAUT_CELL_WIDE_TAIL) continue;
        if (has_segment &&
            (segment.foreground != cell.foreground ||
             segment.bold != cell.bold ||
             segment.italic != cell.italic)) {
            flush();
        }
        if (!has_segment) {
            segment.foreground = cell.foreground;
            segment.bold = cell.bold;
            segment.italic = cell.italic;
            has_segment = true;
        }

        const uint32_t span = cell.occupancy == ZIGONAUT_CELL_WIDE ? 2u : 1u;
        if (cell.text.empty() || cell.occupancy == ZIGONAUT_CELL_WRAP_SPACER) {
            segment.text.push_back(u' ');
            segment.start_columns.push_back(cell.column);
            segment.end_columns.push_back(cell.column + span);
        } else {
            segment.text.append(cell.text);
            for (size_t index = 0; index < cell.text.size(); ++index) {
                segment.start_columns.push_back(cell.column);
                segment.end_columns.push_back(cell.column + span);
            }
        }
    }
    flush();
    row_cells.clear();
}

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

extern "C" void zigonaut_text_engine_begin_row(
    ZigonautTextEngine* engine,
    uint32_t,
    float origin_x,
    float top,
    float cell_width,
    float cell_height) {
    if (engine == nullptr || cell_width <= 0.0f || cell_height <= 0.0f) return;
    engine->beginRow(origin_x, top, cell_width, cell_height);
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
    BOOL italic,
    ZigonautCellOccupancy occupancy) {
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
        italic != FALSE,
        occupancy);
}

extern "C" void zigonaut_text_engine_end_row(ZigonautTextEngine* engine) {
    if (engine != nullptr) engine->endRow();
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
