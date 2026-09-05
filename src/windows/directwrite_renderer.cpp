#include "directwrite_renderer.h"
#include "glyph_atlas_allocator.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <d2d1_3.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#if defined(ZIGONAUT_BENCHMARK_PRESENT)
#include <dcomp.h>
#endif
#include <dwrite.h>
#include <dwrite_2.h>
#include <dxgi1_3.h>
#include <objbase.h>
#include <wincodec.h>
#include <list>
#include <map>
#include <memory>
#include <new>
#include <string>
#include <string_view>
#include <tuple>
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

enum FrameCommandTag : uint32_t {
    frame_command_begin = 1,
    frame_command_clear = 2,
    frame_command_row = 3,
    frame_command_builtin = 4,
    frame_command_image = 5,
    frame_command_cursor = 6,
    frame_command_preedit = 7,
    frame_command_cell_decoration = 8,
    frame_command_row_clip = 9,
    frame_command_row_glyph = 10,
    frame_command_row_builtin = 11,
    frame_command_row_sprite = 12,
    frame_command_row_strikethrough = 13,
};

HRESULT classifyPresentResult(HRESULT result) {
    if (result == DXGI_ERROR_WAS_STILL_DRAWING) return S_FALSE;
    return FAILED(result) ? result : S_OK;
}

struct LayoutKey {
    std::u16string text;
    uint32_t width;
    uint32_t height;
    uint8_t style;
};

struct LayoutKeyView {
    std::u16string_view text;
    uint32_t width;
    uint32_t height;
    uint8_t style;
};

LayoutKeyView view(const LayoutKey& key) {
    return {key.text, key.width, key.height, key.style};
}

struct LayoutKeyLess {
    using is_transparent = void;

    bool operator()(const LayoutKey& left, const LayoutKey& right) const {
        return less(view(left), view(right));
    }

    bool operator()(const LayoutKey& left, LayoutKeyView right) const {
        return less(view(left), right);
    }

    bool operator()(LayoutKeyView left, const LayoutKey& right) const {
        return less(left, view(right));
    }

private:
    static bool less(LayoutKeyView left, LayoutKeyView right) {
        if (left.style != right.style) return left.style < right.style;
        if (left.width != right.width) return left.width < right.width;
        if (left.height != right.height) return left.height < right.height;
        return left.text < right.text;
    }
};

struct OwnedGlyphRun {
    struct Placement {
        uint64_t generation = 0;
        D2D1_RECT_U source{};
        int32_t left = 0, top = 0;
        uint32_t width = 0, height = 0;
        bool valid = false, empty = false;
    };
    IDWriteFontFace* font_face = nullptr;
    std::vector<UINT16> indices;
    std::vector<FLOAT> advances;
    std::vector<DWRITE_GLYPH_OFFSET> offsets;
    FLOAT em_size = 0.0f;
    BOOL sideways = FALSE;
    UINT32 bidi_level = 0;
    FLOAT origin_x = 0.0f;
    FLOAT origin_y = 0.0f;
    DWRITE_MEASURING_MODE measuring_mode = DWRITE_MEASURING_MODE_NATURAL;
    mutable Placement placement;

    OwnedGlyphRun() = default;
    OwnedGlyphRun(const OwnedGlyphRun&) = delete;
    OwnedGlyphRun& operator=(const OwnedGlyphRun&) = delete;
    OwnedGlyphRun(OwnedGlyphRun&& other) noexcept
        : font_face(other.font_face), indices(std::move(other.indices)),
          advances(std::move(other.advances)), offsets(std::move(other.offsets)),
          em_size(other.em_size), sideways(other.sideways), bidi_level(other.bidi_level),
          origin_x(other.origin_x), origin_y(other.origin_y), measuring_mode(other.measuring_mode),
          placement(other.placement) {
        other.font_face = nullptr;
    }
    ~OwnedGlyphRun() { release(font_face); }

    DWRITE_GLYPH_RUN glyphRun() const {
        return {font_face, em_size, static_cast<UINT32>(indices.size()), indices.data(),
            advances.empty() ? nullptr : advances.data(), offsets.empty() ? nullptr : offsets.data(),
            sideways, bidi_level};
    }
};

struct ResolvedDrawPlan {
    // Packed terminal spans, normalized to the segment's leftmost column.
    std::vector<uint32_t> columns;
    float cell_width = 0.0f;
    float cell_height = 0.0f;
    std::vector<OwnedGlyphRun> runs;
};

struct LayoutEntry {
    IDWriteTextLayout* layout;
    std::list<const LayoutKey*>::iterator recency;
    std::unique_ptr<ResolvedDrawPlan> plan;
};

struct RowCell {
    uint32_t text_offset;
    uint32_t text_length;
    uint32_t column;
    uint32_t foreground;
    uint32_t background;
    bool bold;
    bool italic;
    bool strikethrough;
    ZigonautCellOccupancy occupancy;
    uint32_t underline_color = 0;
    uint8_t underline = 0;
    bool overline = false;
    bool selection_background = false;
    bool search_background = false;
    enum class Kind : uint8_t { font, builtin } kind = Kind::font;
    uint32_t builtin_codepoint = 0;
    std::vector<uint8_t> builtin_mask;
    uint32_t builtin_width = 0, builtin_height = 0, builtin_stride = 0;
};

struct BuiltinKey {
    uint32_t codepoint, width, height, span;
    uint64_t generation;
    bool operator<(const BuiltinKey& other) const {
        return std::tie(codepoint,width,height,span,generation) <
            std::tie(other.codepoint,other.width,other.height,other.span,other.generation);
    }
};

struct BuiltinPlacement { D2D1_RECT_U source{}; };

struct OwnedColorLayer {
    IDWriteFontFace* font_face = nullptr;
    std::vector<UINT16> indices;
    std::vector<FLOAT> advances;
    std::vector<DWRITE_GLYPH_OFFSET> offsets;
    FLOAT em_size = 0.0f;
    BOOL sideways = FALSE;
    UINT32 bidi_level = 0;
    FLOAT origin_x = 0.0f;
    FLOAT origin_y = 0.0f;
    DWRITE_COLOR_F run_color{};
    UINT16 palette_index = 0xffff;

    ~OwnedColorLayer() {
        release(font_face);
    }

    void reset() {
        release(font_face);
        indices.clear();
        advances.clear();
        offsets.clear();
    }

    DWRITE_GLYPH_RUN glyphRun() const {
        return {
            font_face,
            em_size,
            static_cast<UINT32>(indices.size()),
            indices.data(),
            advances.empty() ? nullptr : advances.data(),
            offsets.empty() ? nullptr : offsets.data(),
            sideways,
            bidi_level,
        };
    }
};

struct RowSegment {
    std::u16string text;
    std::vector<uint32_t> columns;
    uint32_t foreground = 0;
    bool bold = false;
    bool italic = false;

    void clear() {
        text.clear();
        columns.clear();
    }
};

struct ImageCacheEntry {
    ID2D1Bitmap1* bitmap = nullptr;
    uint64_t generation = 0;
    uint64_t last_seen_frame = 0;
};

struct SceneDamage {
    bool full = false;
    std::vector<D3D11_BOX> boxes;

    void clear() {
        full = false;
        boxes.clear();
    }
};

uint32_t packedColumns(uint32_t start, uint32_t span) {
    return start | ((span - 1) << 16);
}

uint32_t startColumn(uint32_t packed) {
    return packed & 0xffff;
}

uint32_t endColumn(uint32_t packed) {
    return startColumn(packed) + 1 + ((packed >> 16) & 1);
}

bool matchesNormalizedColumns(const std::vector<uint32_t>& normalized,
    const std::vector<uint32_t>& columns, uint32_t origin) {
    if (normalized.size() != columns.size()) return false;
    for (size_t index = 0; index < columns.size(); ++index) {
        if (normalized[index] != packedColumns(
                startColumn(columns[index]) - origin,
                endColumn(columns[index]) - startColumn(columns[index]))) return false;
    }
    return true;
}

struct ClusterSpan {
    uint32_t start_column = UINT32_MAX;
    uint32_t end_column = 0;
    uint32_t first_text_index = UINT32_MAX;
    uint32_t text_end = 0;
    bool used = false;
};

D2D1_COLOR_F color(uint32_t value) {
    return D2D1::ColorF(
        static_cast<float>(value & 0xff) / 255.0f,
        static_cast<float>((value >> 8) & 0xff) / 255.0f,
        static_cast<float>((value >> 16) & 0xff) / 255.0f,
        1.0f);
}

uint32_t blend(uint32_t foreground, uint32_t background) {
    const uint32_t red = ((foreground & 0xff) + (background & 0xff)) / 2;
    const uint32_t green = (((foreground >> 8) & 0xff) +
                            ((background >> 8) & 0xff)) / 2;
    const uint32_t blue = (((foreground >> 16) & 0xff) +
                           ((background >> 16) & 0xff)) / 2;
    return red | (green << 8) | (blue << 16);
}

std::u16string numberedLayoutText(const char16_t* prefix, uint32_t value) {
    std::u16string result(prefix);
    const std::string digits = std::to_string(value);
    result.append(digits.begin(), digits.end());
    return result;
}

} // namespace

extern "C" HRESULT zigonaut_decode_png(const uint8_t* data, size_t length,
    ZigonautDecodedImage* result) {
    if (!data || !length || !result || length > UINT32_MAX) return E_INVALIDARG;
    *result = {};
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(com) && com != RPC_E_CHANGED_MODE) return com;
    const bool uninitialize = SUCCEEDED(com);
    IWICImagingFactory* factory = nullptr; IWICStream* stream = nullptr;
    IWICBitmapDecoder* decoder = nullptr; IWICBitmapFrameDecode* frame = nullptr;
    IWICFormatConverter* converter = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromMemory(
        const_cast<BYTE*>(data), static_cast<DWORD>(length));
    if (SUCCEEDED(hr)) hr = factory->CreateDecoderFromStream(stream, nullptr,
        WICDecodeMetadataCacheOnLoad, &decoder);
    GUID container_format{};
    if (SUCCEEDED(hr)) hr = decoder->GetContainerFormat(&container_format);
    if (SUCCEEDED(hr) && !IsEqualGUID(container_format, GUID_ContainerFormatPng)) hr = WINCODEC_ERR_BADIMAGE;
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr)) hr = factory->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) hr = converter->Initialize(frame, GUID_WICPixelFormat32bppRGBA,
        WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom);
    UINT width = 0, height = 0;
    if (SUCCEEDED(hr)) hr = converter->GetSize(&width, &height);
    size_t bytes = 0;
    if (!width || !height || width > SIZE_MAX / height ||
        static_cast<size_t>(width) * height > (32u * 1024u * 1024u) / 4u) hr = E_INVALIDARG;
    if (SUCCEEDED(hr)) bytes = static_cast<size_t>(width) * height * 4;
    uint8_t* pixels = SUCCEEDED(hr) ? new (std::nothrow) uint8_t[bytes] : nullptr;
    if (SUCCEEDED(hr) && !pixels) hr = E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) hr = converter->CopyPixels(nullptr, width * 4,
        static_cast<UINT>(bytes), pixels);
    if (FAILED(hr)) delete[] pixels; else *result = {width, height, pixels, bytes};
    release(converter); release(frame); release(decoder); release(stream); release(factory);
    if (uninitialize) CoUninitialize();
    return hr;
}

extern "C" void zigonaut_free_decoded_image(uint8_t* pixels) { delete[] pixels; }

extern "C" HRESULT zigonaut_test_glyph_atlas_allocator() {
    GlyphAtlasAllocator atlas(2048), repeat(2048);
    GlyphAtlasAllocator::Rect a{}, b{}, repeat_a{}, repeat_b{}, failed{7,7,7,7};
    if (!atlas.reserve(10, 20, a) || a.x != 1 || a.y != 1 ||
        !atlas.reserve(10, 20, b) || b.x != 13 || b.y != 1 ||
        !repeat.reserve(10, 20, repeat_a) || !repeat.reserve(10, 20, repeat_b) ||
        repeat_a.x != a.x || repeat_a.y != a.y || repeat_b.x != b.x || repeat_b.y != b.y ||
        a.x + a.width + 2 > b.x) return E_FAIL;
    const size_t nodes = atlas.nodeCount();
    if (atlas.reserve(0, 1, failed) || atlas.reserve(UINT32_MAX, 1, failed) ||
        atlas.reserve(2047, 1, failed) || atlas.nodeCount() != nodes || failed.x != 7 ||
        !atlas.reserve(1, 1, failed) || failed.x != 25 || failed.y != 1) return E_FAIL;
    GlyphAtlasAllocator full(2048);
    GlyphAtlasAllocator::Rect large{};
    if (!full.reserve(2046, 2046, large) || large.x != 1 || large.y != 1 ||
        full.reserve(1, 1, failed)) return E_FAIL;
    return S_OK;
}

extern "C" HRESULT zigonaut_test_present_status_classification() {
    if (classifyPresentResult(S_OK) != S_OK ||
        classifyPresentResult(DXGI_ERROR_WAS_STILL_DRAWING) != S_FALSE ||
        classifyPresentResult(DXGI_STATUS_OCCLUDED) != S_OK ||
        classifyPresentResult(E_FAIL) != E_FAIL) return E_FAIL;
    return S_OK;
}

class GridTextRenderer;

struct SelectionInterval {
    uint32_t start = 0;
    uint32_t end = 0;
    bool active = false;
};

bool intervalsOverlap(const SelectionInterval& left, const SelectionInterval& right) {
    return left.active && right.active &&
        std::max(left.start, right.start) < std::min(left.end, right.end);
}

HRESULT createSelectionGeometry(ID2D1Factory1* factory,
    SelectionInterval previous, SelectionInterval current, SelectionInterval next,
    float origin_x, float top, float cell_width, float cell_height,
    bool top_clipped, bool bottom_clipped, ID2D1PathGeometry** result) {
    if (result == nullptr) return E_POINTER;
    *result = nullptr;
    if (factory == nullptr || !current.active || cell_width <= 0.0f || cell_height <= 0.0f)
        return E_INVALIDARG;
    struct Line { float left, right, top; };
    Line lines[3]{};
    size_t count = 0;
    if (intervalsOverlap(previous, current)) lines[count++] = {
        origin_x + previous.start * cell_width,
        origin_x + previous.end * cell_width,
        top - cell_height,
    };
    lines[count++] = {
        origin_x + current.start * cell_width,
        origin_x + current.end * cell_width,
        top,
    };
    if (intervalsOverlap(current, next)) lines[count++] = {
        origin_x + next.start * cell_width,
        origin_x + next.end * cell_width,
        top + cell_height,
    };
    const bool clip_top = top_clipped && count != 0 && lines[0].top == top;
    const bool clip_bottom = bottom_clipped && count != 0 &&
        lines[count - 1].top == top;
    const float radius = std::min(0.15f * cell_height, 0.25f * cell_width);
    const float vertical_radius = std::min(radius, 0.5f * cell_height);

    ID2D1PathGeometry* geometry = nullptr;
    HRESULT hr = factory->CreatePathGeometry(&geometry);
    ID2D1GeometrySink* sink = nullptr;
    if (SUCCEEDED(hr)) hr = geometry->Open(&sink);
    if (FAILED(hr)) {
        release(sink);
        release(geometry);
        return hr;
    }
    const auto point = [](float x, float y) { return D2D1::Point2F(x, y); };
    const auto line_to = [&](float x, float y) { sink->AddLine(point(x, y)); };
    const auto curve_to = [&](float control_x, float control_y, float x, float y) {
        sink->AddQuadraticBezier(D2D1::QuadraticBezierSegment(
            point(control_x, control_y), point(x, y)));
    };

    const Line& first = lines[0];
    const float first_top = first.top;
    const float first_width_radius = std::min(radius, 0.5f * (first.right - first.left));
    if (clip_top) {
        sink->BeginFigure(point(first.right, first_top), D2D1_FIGURE_BEGIN_FILLED);
    } else {
        sink->BeginFigure(point(first.right - first_width_radius, first_top),
            D2D1_FIGURE_BEGIN_FILLED);
        curve_to(first.right, first_top, first.right, first_top + vertical_radius);
    }

    for (size_t index = 0; index + 1 < count; ++index) {
        const Line& upper = lines[index];
        const Line& lower = lines[index + 1];
        const float boundary = lower.top;
        if (upper.right == lower.right) {
            line_to(lower.right, boundary);
            continue;
        }
        const float direction = lower.right > upper.right ? 1.0f : -1.0f;
        const float width_radius = std::min(radius,
            0.5f * std::abs(lower.right - upper.right));
        line_to(upper.right, boundary - vertical_radius);
        curve_to(upper.right, boundary,
            upper.right + direction * width_radius, boundary);
        line_to(lower.right - direction * width_radius, boundary);
        curve_to(lower.right, boundary,
            lower.right, boundary + vertical_radius);
    }

    const Line& last = lines[count - 1];
    const float bottom = last.top + cell_height;
    const float last_width_radius = std::min(radius, 0.5f * (last.right - last.left));
    if (clip_bottom) {
        line_to(last.right, bottom);
        line_to(last.left, bottom);
    } else {
        line_to(last.right, bottom - vertical_radius);
        curve_to(last.right, bottom, last.right - last_width_radius, bottom);
        line_to(last.left + last_width_radius, bottom);
        curve_to(last.left, bottom, last.left, bottom - vertical_radius);
    }

    for (size_t index = count - 1; index > 0; --index) {
        const Line& lower = lines[index];
        const Line& upper = lines[index - 1];
        const float boundary = lower.top;
        if (lower.left == upper.left) {
            line_to(upper.left, boundary);
            continue;
        }
        const float direction = upper.left > lower.left ? 1.0f : -1.0f;
        const float width_radius = std::min(radius,
            0.5f * std::abs(upper.left - lower.left));
        line_to(lower.left, boundary + vertical_radius);
        curve_to(lower.left, boundary,
            lower.left + direction * width_radius, boundary);
        line_to(upper.left - direction * width_radius, boundary);
        curve_to(upper.left, boundary,
            upper.left, boundary - vertical_radius);
    }

    if (clip_top) {
        line_to(first.left, first_top);
    } else {
        line_to(first.left, first_top + vertical_radius);
        curve_to(first.left, first_top,
            first.left + first_width_radius, first_top);
    }
    sink->EndFigure(D2D1_FIGURE_END_CLOSED);
    hr = sink->Close();
    release(sink);
    if (FAILED(hr)) {
        release(geometry);
        return hr;
    }
    *result = geometry;
    return S_OK;
}

extern "C" HRESULT zigonaut_test_selection_geometry() {
    ID2D1Factory1* factory = nullptr;
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
        __uuidof(ID2D1Factory1), nullptr, reinterpret_cast<void**>(&factory));
    if (FAILED(hr)) return hr;
    ID2D1PathGeometry* geometry = nullptr;
    const auto contains = [&](float x, float y, bool expected) {
        BOOL value = FALSE;
        const HRESULT result = geometry->FillContainsPoint(
            D2D1::Point2F(x, y), nullptr, 0.01f, &value);
        return SUCCEEDED(result) && (value != FALSE) == expected;
    };

    hr = createSelectionGeometry(factory, {}, {1, 4, true}, {},
        0.0f, 0.0f, 10.0f, 20.0f, false, false, &geometry);
    if (SUCCEEDED(hr) && (!contains(20.0f, 10.0f, true) ||
            !contains(10.1f, 0.1f, false) || !contains(39.9f, 19.9f, false)))
        hr = E_FAIL;
    release(geometry);

    if (SUCCEEDED(hr)) hr = createSelectionGeometry(factory,
        {0, 4, true}, {2, 4, true}, {},
        0.0f, 20.0f, 10.0f, 20.0f, false, false, &geometry);
    bool found_concave_bleed = false;
    bool concave_bleed_covered = true;
    if (SUCCEEDED(hr)) {
        for (float y = 20.05f; y < 23.0f; y += 0.05f) {
            for (float x = 15.0f; x < 20.0f; x += 0.05f) {
                BOOL value = FALSE;
                if (SUCCEEDED(geometry->FillContainsPoint(
                        D2D1::Point2F(x, y), nullptr, 0.01f, &value)) && value != FALSE) {
                    // The concave curve enters the unselected notch, and the
                    // horizontal radius expansion must cover every such point.
                    found_concave_bleed = true;
                    concave_bleed_covered = concave_bleed_covered && x >= 20.0f - 2.5f;
                }
            }
        }
        if (!contains(10.0f, 10.0f, true) || !contains(30.0f, 30.0f, true) ||
                !found_concave_bleed || !concave_bleed_covered) hr = E_FAIL;
    }
    release(geometry);

    if (SUCCEEDED(hr)) hr = createSelectionGeometry(factory, {}, {0, 2, true}, {},
        0.0f, 0.0f, 10.0f, 20.0f, true, true, &geometry);
    if (SUCCEEDED(hr) && (!contains(0.1f, 0.1f, true) ||
            !contains(19.9f, 19.9f, true)))
        hr = E_FAIL;
    release(geometry);
    release(factory);
    return hr;
}

struct ZigonautTextEngine {
    enum class TestFault { none, atlas_resource, atlas_texture, rasterize, upload,
        instance_upload, instance_append };
    IDWriteFactory* factory = nullptr;
    IDWriteFactory2* factory2 = nullptr;
    IDWriteRenderingParams* rendering_params = nullptr;
    IDWriteFontCollection* fonts = nullptr;
    IDWriteFontFallback* symbol_fallback = nullptr;
    IDWriteFontFace* normal_face = nullptr;
    IDWriteTextFormat* formats[4] = {};
    ID2D1Factory1* d2d_factory = nullptr;
    ID3D11Device* d3d_device = nullptr;
    ID3D11DeviceContext* d3d_context = nullptr;
    ID2D1Device* d2d_device = nullptr;
    ID2D1DeviceContext* target = nullptr;
    ID2D1DeviceContext3* target3 = nullptr;
    ID2D1SpriteBatch* sprite_batch = nullptr;
    ID2D1Bitmap1* atlas_bitmap = nullptr;
    ID2D1DeviceContext* atlas_context = nullptr;
    ID2D1SolidColorBrush* atlas_brush = nullptr;
    ID3D11Texture2D* atlas_texture = nullptr;
    struct GlyphInstance { float destination[4], source[4], tint[4], clip[4], target[4]; };
    std::vector<GlyphInstance> glyph_instances;
    ID3D11VertexShader* glyph_vs = nullptr;
    ID3D11PixelShader* glyph_ps = nullptr;
    struct GlyphBufferSlot {
        ID3D11Buffer* buffer = nullptr;
        ID3D11ShaderResourceView* view = nullptr;
        UINT capacity = 0;
    } glyph_slots[3];
    uint32_t glyph_slot_next = 0;
    bool benchmark_immutable_instances = false;
    uint64_t glyph_slot_uses = 0;
    uint64_t glyph_slot_wraps = 0;
    uint64_t glyph_buffer_creations = 0;
    uint64_t glyph_capacity_growths = 0;
    ID3D11ShaderResourceView* atlas_view = nullptr;
    ID3D11RenderTargetView* scene_rtv = nullptr;
    ID3D11SamplerState* glyph_sampler = nullptr;
    ID3D11BlendState* glyph_blend = nullptr;
    bool glyph_pipeline_failed = false;
    HRESULT glyph_frame_failure = S_OK;
    ZigonautFrameFailure frame_failure{};
    bool frame_diagnostics = false;
    bool benchmark_legacy_sprite_batch = false;
    std::unique_ptr<GlyphAtlasAllocator> atlas_allocator;
    uint64_t atlas_generation = 1;
    uint32_t atlas_extent = 1024;
    uint64_t atlas_reserved_area = 0;
    uint64_t atlas_rejected_area = 0;
    uint64_t atlas_rejected_count = 0;
    uint64_t atlas_pressure_resets = 0;
    uint64_t atlas_resource_allocations = 0;
    ZigonautTextAntialiasing text_antialiasing = ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE;
    bool atlas_reset_pending = false;
    bool atlas_invalidation_pending = false;
    bool atlas_disabled_for_frame = false;
    TestFault test_fault = TestFault::none;
    bool atlas_draw_active = false;
    uint32_t sprite_count = 0;
    IDXGISwapChain1* swap_chain = nullptr;
    HANDLE frame_latency_waitable_object = nullptr;
    ID2D1Bitmap1* target_bitmap = nullptr;
    ID2D1Bitmap1* scene_bitmap = nullptr;
    ID3D11Texture2D* backbuffer_texture = nullptr;
    ID3D11Texture2D* scene_texture = nullptr;
    ID3D11Texture2D* scene_shift_scratch = nullptr;
    ID2D1SolidColorBrush* brush = nullptr;
    std::map<LayoutKey, LayoutEntry, LayoutKeyLess> layouts;
    std::list<const LayoutKey*> layout_recency;
    std::map<uint32_t, ImageCacheEntry> images;
    std::map<BuiltinKey, BuiltinPlacement> builtin_placements;
    std::map<BuiltinKey, ID2D1Bitmap*> builtin_bitmaps;
    uint64_t builtin_generation = 1;
    uint64_t builtin_bitmap_creations = 0;
    uint64_t layout_creation_count = 0;
    ZigonautDirectWriteBenchmark benchmark{};
    bool benchmark_active = false;
    bool benchmark_legacy_background_fills = false;
    bool benchmark_background_active = false;
    uint64_t background_fill_calls = 0;
    uint64_t image_frame = 0;
    std::vector<RowCell> row_cells;
    std::u16string row_text;
    RowSegment row_segment;
    std::vector<RowSegment> row_segments;
    std::vector<int64_t> row_order;
    std::vector<D2D1_RECT_F> glyph_destinations;
    std::vector<D2D1_RECT_U> glyph_sources;
    std::vector<D2D1_COLOR_F> glyph_colors;
    GridTextRenderer* grid_renderer = nullptr;
    std::wstring family;
    std::wstring locale;
    HWND hwnd = nullptr;
    uint32_t font_size = 18;
    DWRITE_FONT_WEIGHT font_weight = DWRITE_FONT_WEIGHT_NORMAL;
    DWRITE_FONT_WEIGHT intense_font_weight = DWRITE_FONT_WEIGHT_BOLD;
    uint16_t line_height_percent = 100;
    uint32_t dpi = 96;
    ZigonautCellMetrics metrics = {9, 18, 14, 1};
    float row_origin_x = 0.0f;
    float row_top = 0.0f;
    float row_cell_width = 0.0f;
    float row_cell_height = 0.0f;
    uint32_t frame_background = 0;
    D2D1_RECT_F pending_row_background{};
    uint32_t pending_row_background_color = 0;
    bool pending_row_background_active = false;
    bool pending_row_background_selection = false;
    ID2D1PathGeometry* selection_geometry = nullptr;
    float selection_radius = 0.0f;
    bool row_active = false;
    bool frame_active = false;
    bool present_pending = false;
    uint64_t d3d_scene_copy_count = 0;
    uint64_t d3d_scene_full_copy_count = 0;
    uint64_t d3d_scene_region_copy_count = 0;
    uint64_t d3d_scene_region_copy_bytes = 0;
    uint32_t scene_width = 0;
    uint32_t scene_height = 0;
    SceneDamage frame_damage;
    SceneDamage previous_present_damage;
    bool damage_history_valid = false;

    HRESULT initializeGlyphPipeline() {
        if (glyph_pipeline_failed) return E_FAIL;
        if (!atlas_texture) return E_FAIL;
        const bool static_complete = glyph_vs && glyph_ps && glyph_sampler && glyph_blend;
        if (!static_complete) {
            // A previous interrupted attempt is not a usable pipeline.
            release(glyph_blend); release(glyph_sampler); release(glyph_ps); release(glyph_vs);
        static const char shader[] = R"(
struct I { float4 d; float4 s; float4 c; float4 clip; float4 target; };
StructuredBuffer<I> instances : register(t1);
Texture2D atlas : register(t0); SamplerState samp : register(s0);
struct O { float4 p:SV_Position; float2 uv:TEXCOORD0; float4 c:COLOR0; float4 clip:TEXCOORD1; };
O vs(uint v:SV_VertexID,uint n:SV_InstanceID) { uint k=v==3?2:(v==4?1:(v==5?3:v));
 I i=instances[n]; float2 xy=float2((k&1)?i.d.z:i.d.x,(k&2)?i.d.w:i.d.y);
 O o; o.p=float4(xy.x/i.target.x*2-1,1-xy.y/i.target.y*2,0,1);
 o.uv=float2((k&1)?i.s.z:i.s.x,(k&2)?i.s.w:i.s.y); o.c=i.c; o.clip=i.clip; return o; }
float4 ps(O i):SV_Target { if(i.p.x<i.clip.x||i.p.y<i.clip.y||i.p.x>=i.clip.z||i.p.y>=i.clip.w) discard;
 float a=atlas.Sample(samp,i.uv).a*i.c.a; return float4(i.c.rgb*a,a); })";
        ID3DBlob *vs = nullptr, *ps = nullptr, *errors = nullptr;
        HRESULT hr = D3DCompile(shader, sizeof(shader)-1, "Zigonaut glyph instancing", nullptr,
            nullptr, "vs", "vs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &vs, &errors);
        release(errors);
        if (SUCCEEDED(hr)) hr = D3DCompile(shader, sizeof(shader)-1, "Zigonaut glyph instancing", nullptr,
            nullptr, "ps", "ps_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &ps, &errors);
        release(errors);
        if (SUCCEEDED(hr)) hr = d3d_device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &glyph_vs);
        if (SUCCEEDED(hr)) hr = d3d_device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &glyph_ps);
        release(vs); release(ps);
        D3D11_SAMPLER_DESC sd{}; sd.Filter=D3D11_FILTER_MIN_MAG_MIP_POINT;
        sd.AddressU=sd.AddressV=sd.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP; sd.MaxLOD=D3D11_FLOAT32_MAX;
        if (SUCCEEDED(hr)) hr=d3d_device->CreateSamplerState(&sd,&glyph_sampler);
        D3D11_BLEND_DESC bd{}; bd.RenderTarget[0].BlendEnable=TRUE; bd.RenderTarget[0].SrcBlend=D3D11_BLEND_ONE;
        bd.RenderTarget[0].DestBlend=D3D11_BLEND_INV_SRC_ALPHA; bd.RenderTarget[0].BlendOp=D3D11_BLEND_OP_ADD;
        bd.RenderTarget[0].SrcBlendAlpha=D3D11_BLEND_ONE; bd.RenderTarget[0].DestBlendAlpha=D3D11_BLEND_INV_SRC_ALPHA;
        bd.RenderTarget[0].BlendOpAlpha=D3D11_BLEND_OP_ADD; bd.RenderTarget[0].RenderTargetWriteMask=D3D11_COLOR_WRITE_ENABLE_ALL;
        if (SUCCEEDED(hr)) hr=d3d_device->CreateBlendState(&bd,&glyph_blend);
        if (FAILED(hr)) {
            release(glyph_blend); release(glyph_sampler); release(glyph_ps); release(glyph_vs);
            glyph_pipeline_failed=true; return hr; }
        }
        if (!atlas_view) {
            D3D11_SHADER_RESOURCE_VIEW_DESC av{}; av.Format=DXGI_FORMAT_B8G8R8A8_UNORM;
            av.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D; av.Texture2D.MipLevels=1;
            const HRESULT hr=d3d_device->CreateShaderResourceView(atlas_texture,&av,&atlas_view);
            if (FAILED(hr)) return hr; // Atlas generation failure is retryable.
        }
        return S_OK;
    }

    HRESULT flushGlyphInstances() {
        if (glyph_instances.empty()) return glyph_frame_failure;
        if (glyph_instances.size() > UINT_MAX / sizeof(GlyphInstance)) {
            glyph_instances.clear(); glyph_frame_failure = E_OUTOFMEMORY; return glyph_frame_failure;
        }
        const UINT submitted=static_cast<UINT>(glyph_instances.size());
        HRESULT hr=endAtlasDraw();
        if (FAILED(hr) || FAILED(initializeGlyphPipeline())) { glyph_instances.clear();
            hr=FAILED(hr)?hr:E_FAIL; if (SUCCEEDED(glyph_frame_failure)) glyph_frame_failure=hr; return hr; }
        hr=target->EndDraw();
        if (FAILED(hr)) { glyph_instances.clear(); if (SUCCEEDED(glyph_frame_failure)) glyph_frame_failure=hr; return hr; }
        target->SetTarget(nullptr);
        if (test_fault == TestFault::instance_upload) hr = E_FAIL;
        ID3D11Buffer* upload_buffer = nullptr;
        ID3D11ShaderResourceView* upload_view = nullptr;
        GlyphBufferSlot* slot = nullptr;
        if (SUCCEEDED(hr) && benchmark_immutable_instances) {
            D3D11_BUFFER_DESC b{}; b.ByteWidth=submitted*sizeof(GlyphInstance);
            b.Usage=D3D11_USAGE_IMMUTABLE; b.BindFlags=D3D11_BIND_SHADER_RESOURCE;
            b.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; b.StructureByteStride=sizeof(GlyphInstance);
            D3D11_SUBRESOURCE_DATA data{glyph_instances.data(),0,0};
            hr=d3d_device->CreateBuffer(&b,&data,&upload_buffer);
            if (SUCCEEDED(hr)) { D3D11_SHADER_RESOURCE_VIEW_DESC sv{}; sv.Format=DXGI_FORMAT_UNKNOWN;
                sv.ViewDimension=D3D11_SRV_DIMENSION_BUFFER; sv.Buffer.NumElements=submitted;
                hr=d3d_device->CreateShaderResourceView(upload_buffer,&sv,&upload_view); }
        } else if (SUCCEEDED(hr)) {
            const uint32_t index = glyph_slot_next;
            glyph_slot_next = (glyph_slot_next + 1) % 3;
            ++glyph_slot_uses; if (glyph_slot_next == 0) ++glyph_slot_wraps;
            slot = &glyph_slots[index];
            if (slot->capacity < submitted) {
                UINT capacity = slot->capacity ? slot->capacity : 256;
                while (capacity < submitted) {
                    if (capacity > UINT_MAX / 2) { capacity = submitted; break; }
                    capacity *= 2;
                }
                if (capacity < submitted || capacity > UINT_MAX / sizeof(GlyphInstance)) hr=E_OUTOFMEMORY;
                ID3D11Buffer* replacement = nullptr; ID3D11ShaderResourceView* replacement_view = nullptr;
                D3D11_BUFFER_DESC b{}; b.ByteWidth=capacity*sizeof(GlyphInstance); b.Usage=D3D11_USAGE_DYNAMIC;
                b.BindFlags=D3D11_BIND_SHADER_RESOURCE; b.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
                b.MiscFlags=D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; b.StructureByteStride=sizeof(GlyphInstance);
                if (SUCCEEDED(hr)) hr=d3d_device->CreateBuffer(&b,nullptr,&replacement);
                if (SUCCEEDED(hr)) { D3D11_SHADER_RESOURCE_VIEW_DESC sv{}; sv.Format=DXGI_FORMAT_UNKNOWN;
                    sv.ViewDimension=D3D11_SRV_DIMENSION_BUFFER; sv.Buffer.NumElements=capacity;
                    hr=d3d_device->CreateShaderResourceView(replacement,&sv,&replacement_view); }
                if (SUCCEEDED(hr)) { release(slot->view); release(slot->buffer); slot->buffer=replacement;
                    slot->view=replacement_view; slot->capacity=capacity; ++glyph_buffer_creations; ++glyph_capacity_growths;
                } else { release(replacement_view); release(replacement); }
            }
            if (SUCCEEDED(hr)) { D3D11_MAPPED_SUBRESOURCE mapped{};
                hr=d3d_context->Map(slot->buffer,0,D3D11_MAP_WRITE_DISCARD,0,&mapped);
                if (SUCCEEDED(hr)) { memcpy(mapped.pData,glyph_instances.data(),submitted*sizeof(GlyphInstance));
                    d3d_context->Unmap(slot->buffer,0); upload_view=slot->view; } }
        }
        if (SUCCEEDED(hr) && !scene_rtv) hr=d3d_device->CreateRenderTargetView(scene_texture,nullptr,&scene_rtv);
        if (SUCCEEDED(hr)) { ID3D11ShaderResourceView* views[2]={atlas_view,upload_view};
            d3d_context->OMSetRenderTargets(1,&scene_rtv,nullptr); float factor[4]={};
            D3D11_VIEWPORT viewport{0,0,static_cast<float>(scene_width),static_cast<float>(scene_height),0,1};
            d3d_context->RSSetViewports(1,&viewport);
            d3d_context->OMSetBlendState(glyph_blend,factor,0xffffffff); d3d_context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            d3d_context->VSSetShader(glyph_vs,nullptr,0); d3d_context->VSSetShaderResources(1,1,&views[1]);
            d3d_context->PSSetShader(glyph_ps,nullptr,0); d3d_context->PSSetShaderResources(0,1,&views[0]); d3d_context->PSSetSamplers(0,1,&glyph_sampler);
            d3d_context->DrawInstanced(6,submitted,0,0);
            if (benchmark_active) { ++benchmark.atlas_sprite_batches; benchmark.atlas_sprites += submitted; }
            ID3D11ShaderResourceView* nulls[2]={}; d3d_context->VSSetShaderResources(1,1,&nulls[0]); d3d_context->PSSetShaderResources(0,1,&nulls[0]);
            d3d_context->OMSetRenderTargets(0,nullptr,nullptr); d3d_context->ClearState(); }
        if (benchmark_immutable_instances) { release(upload_view); release(upload_buffer); }
        glyph_instances.clear(); target->SetTarget(scene_bitmap); target->BeginDraw();
        if (FAILED(hr)) { markFullDamage(frame_damage); if (SUCCEEDED(glyph_frame_failure)) glyph_frame_failure=hr; }
        return hr;
    }

    void resetDamageHistory() {
        frame_damage.clear();
        previous_present_damage.clear();
        damage_history_valid = false;
    }

    void markFullDamage(SceneDamage& damage) {
        damage.full = true;
        damage.boxes.clear();
    }

    void addDamage(SceneDamage& damage, uint32_t left, uint32_t top,
        uint32_t right, uint32_t bottom) {
        if (damage.full || scene_texture == nullptr) return;
        left = std::min(left, scene_width);
        top = std::min(top, scene_height);
        right = std::min(right, scene_width);
        bottom = std::min(bottom, scene_height);
        if (left >= right || top >= bottom) return;
        D3D11_BOX added{left, top, 0, right, bottom, 1};
        for (size_t index = 0; index < damage.boxes.size();) {
            const auto& existing = damage.boxes[index];
            const bool overlaps = added.left < existing.right &&
                added.right > existing.left && added.top < existing.bottom &&
                added.bottom > existing.top;
            const bool vertical_neighbor = added.left == existing.left &&
                added.right == existing.right &&
                (added.bottom == existing.top || added.top == existing.bottom);
            const bool horizontal_neighbor = added.top == existing.top &&
                added.bottom == existing.bottom &&
                (added.right == existing.left || added.left == existing.right);
            if (!overlaps && !vertical_neighbor && !horizontal_neighbor) {
                ++index;
                continue;
            }
            added.left = std::min(added.left, existing.left);
            added.top = std::min(added.top, existing.top);
            added.right = std::max(added.right, existing.right);
            added.bottom = std::max(added.bottom, existing.bottom);
            damage.boxes.erase(damage.boxes.begin() + index);
            index = 0;
        }
        try {
            damage.boxes.push_back(added);
            // Fragmented damage eventually costs more than one device-local copy.
            // Falling back to full damage also preserves correctness on allocation pressure.
            if (damage.boxes.size() > 64) markFullDamage(damage);
        } catch (...) {
            markFullDamage(damage);
        }
    }

    void addDamage(SceneDamage& damage, float left, float top,
        float right, float bottom) {
        if (!std::isfinite(left) || !std::isfinite(top) ||
                !std::isfinite(right) || !std::isfinite(bottom)) {
            markFullDamage(damage);
            return;
        }
        if (scene_texture == nullptr) return;
        left = std::clamp(left, 0.0f, static_cast<float>(scene_width));
        top = std::clamp(top, 0.0f, static_cast<float>(scene_height));
        right = std::clamp(right, 0.0f, static_cast<float>(scene_width));
        bottom = std::clamp(bottom, 0.0f, static_cast<float>(scene_height));
        addDamage(damage,
            static_cast<uint32_t>(std::floor(left)),
            static_cast<uint32_t>(std::floor(top)),
            static_cast<uint32_t>(std::ceil(right)),
            static_cast<uint32_t>(std::ceil(bottom)));
    }

    SceneDamage transferDamage() {
        SceneDamage result = frame_damage;
        if (!damage_history_valid) {
            markFullDamage(result);
            return result;
        }
        if (previous_present_damage.full) {
            markFullDamage(result);
            return result;
        }
        for (const auto& box : previous_present_damage.boxes)
            addDamage(result, box.left, box.top, box.right, box.bottom);
        return result;
    }

    bool shouldCopyFull(const SceneDamage& damage) const {
        if (damage.full || scene_texture == nullptr) return true;
        const uint64_t texture_area = static_cast<uint64_t>(scene_width) * scene_height;
        uint64_t damaged_area = 0;
        for (const auto& box : damage.boxes)
            damaged_area += static_cast<uint64_t>(box.right - box.left) *
                (box.bottom - box.top);
        return damage.boxes.size() > 16 || damaged_area * 2 > texture_area;
    }

    void commitPresentedDamage() {
        previous_present_damage = std::move(frame_damage);
        frame_damage.clear();
        damage_history_valid = true;
    }

    void invalidateAtlas() {
        if (atlas_draw_active) { atlas_context->EndDraw(); atlas_draw_active = false; }
        if (atlas_context) atlas_context->SetTarget(nullptr);
        release(atlas_brush); release(atlas_context); release(atlas_bitmap);
        release(atlas_view); release(atlas_texture); release(sprite_batch); release(target3);
        atlas_allocator.reset();
        atlas_reset_pending = false; atlas_invalidation_pending = false;
        atlas_reserved_area = 0; sprite_count = 0;
        builtin_placements.clear();
        if (++atlas_generation == 0) ++atlas_generation;
    }

    HRESULT beginAtlasDraw() {
        if (atlas_draw_active) return S_OK;
        if (!atlas_context) return E_HANDLE;
        atlas_context->BeginDraw();
        atlas_draw_active = true;
        return S_OK;
    }

    HRESULT endAtlasDraw() {
        if (!atlas_draw_active) return S_OK;
        const HRESULT hr = atlas_context->EndDraw();
        atlas_draw_active = false;
        if (FAILED(hr) || test_fault == TestFault::upload) {
            // Placements were stamped before submission. Keep this generation alive
            // for earlier scene commands, then invalidate it at the next frame boundary.
            atlas_invalidation_pending = true;
            return FAILED(hr)?hr:E_FAIL;
        }
        if (benchmark_active) ++benchmark.atlas_uploads;
        return S_OK;
    }

    void initializeAtlas() {
        if (text_antialiasing != ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE || target3 || !target) return;
        if (test_fault == TestFault::atlas_resource) return;
        if (FAILED(target->QueryInterface(IID_PPV_ARGS(&target3)))) return;
        if (FAILED(target3->CreateSpriteBatch(&sprite_batch))) { invalidateAtlas(); return; }
        if (test_fault == TestFault::atlas_texture) { invalidateAtlas(); return; }
        try {
            atlas_allocator = std::make_unique<GlyphAtlasAllocator>(atlas_extent);
        } catch (...) { invalidateAtlas(); return; }
        // Direct2D atlas population follows the approach used by Microsoft's
        // MIT-licensed Windows Terminal BackendD3D; see licenses/Microsoft-Terminal-LICENSE.txt.
        // D2D owns the staging/upload strategy for this shared render-target texture.
        D3D11_TEXTURE2D_DESC description{};
        description.Width = atlas_extent; description.Height = atlas_extent;
        description.MipLevels = 1; description.ArraySize = 1;
        description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        description.SampleDesc.Count = 1; description.Usage = D3D11_USAGE_DEFAULT;
        description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        if (FAILED(d3d_device->CreateTexture2D(&description, nullptr, &atlas_texture)) ||
            FAILED(d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &atlas_context))) {
            invalidateAtlas(); return;
        }
        IDXGISurface* surface = nullptr;
        HRESULT hr = atlas_texture->QueryInterface(IID_PPV_ARGS(&surface));
        const auto properties = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_NONE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
        const auto target_properties = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET,
            properties.pixelFormat, 96.0f, 96.0f);
        if (SUCCEEDED(hr)) hr = atlas_context->CreateBitmapFromDxgiSurface(surface, &target_properties, &atlas_bitmap);
        release(surface);
        if (SUCCEEDED(hr)) hr = atlas_context->CreateSolidColorBrush(D2D1::ColorF(1,1,1,1), &atlas_brush);
        if (FAILED(hr)) { invalidateAtlas(); return; }
        atlas_context->SetTarget(atlas_bitmap); atlas_context->SetUnitMode(D2D1_UNIT_MODE_PIXELS);
        atlas_context->SetDpi(96,96); atlas_context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        atlas_context->SetTextRenderingParams(rendering_params); atlas_context->SetTransform(D2D1::Matrix3x2F::Identity());
        atlas_context->BeginDraw(); atlas_context->Clear(D2D1::ColorF(0,0,0,0));
        if (FAILED(atlas_context->EndDraw())) { invalidateAtlas(); return; }
        ++atlas_resource_allocations;
    }

    void rejectAtlasReservation(uint32_t width, uint32_t height, bool exhausted) {
        if (exhausted || (atlas_extent < 2048 && width <= 2046 && height <= 2046))
            atlas_reset_pending = true;
        ++atlas_rejected_count;
        atlas_rejected_area += (static_cast<uint64_t>(width) + 2) *
            (static_cast<uint64_t>(height) + 2);
        if (benchmark_active) ++benchmark.atlas_full_misses;
    }

    bool rasterize(OwnedGlyphRun& owned) {
        if (owned.placement.valid && owned.placement.generation == atlas_generation) {
            if (benchmark_active) ++benchmark.atlas_placement_hits;
            return true;
        }
        if (benchmark_active) ++benchmark.atlas_placement_misses;
        if (test_fault == TestFault::rasterize) return false;
        if (!atlas_context || !atlas_allocator || owned.sideways || owned.indices.empty()) return false;
        DWRITE_GLYPH_RUN run = owned.glyphRun();
        D2D1_RECT_F world{};
        HRESULT hr = atlas_context->GetGlyphRunWorldBounds(D2D1::Point2F(0,0), &run, owned.measuring_mode, &world);
        if (FAILED(hr) || !std::isfinite(world.left) || !std::isfinite(world.top) ||
            !std::isfinite(world.right) || !std::isfinite(world.bottom)) return false;
        const double rounded_left = std::floor(static_cast<double>(world.left));
        const double rounded_top = std::floor(static_cast<double>(world.top));
        const double rounded_right = std::ceil(static_cast<double>(world.right));
        const double rounded_bottom = std::ceil(static_cast<double>(world.bottom));
        if (rounded_left < INT32_MIN || rounded_top < INT32_MIN ||
            rounded_right > INT32_MAX || rounded_bottom > INT32_MAX) return false;
        const int32_t left = static_cast<int32_t>(rounded_left), top = static_cast<int32_t>(rounded_top);
        const int32_t right = static_cast<int32_t>(rounded_right), bottom = static_cast<int32_t>(rounded_bottom);
        const int64_t width64 = static_cast<int64_t>(right) - left;
        const int64_t height64 = static_cast<int64_t>(bottom) - top;
        if (width64 < 0 || height64 < 0) return false;
        if (!width64 || !height64) {
            owned.placement = {atlas_generation, {}, left, top, 0, 0, true, true}; return true;
        }
        if (width64 > UINT32_MAX || height64 > UINT32_MAX) return false;
        const uint32_t width = static_cast<uint32_t>(width64), height = static_cast<uint32_t>(height64);
        if (width > atlas_extent - 2 || height > atlas_extent - 2) {
            rejectAtlasReservation(width, height, false);
            return false;
        }
        GlyphAtlasAllocator::Rect slot{};
        if (!atlas_allocator->reserve(width, height, slot)) {
            rejectAtlasReservation(width, height, true);
            return false;
        }
        atlas_reserved_area += (static_cast<uint64_t>(width) + 2) *
            (static_cast<uint64_t>(height) + 2);
        const D2D1_RECT_U dirty{slot.x, slot.y, slot.x + width, slot.y + height};
        if (FAILED(beginAtlasDraw())) return false;
        atlas_context->PushAxisAlignedClip(D2D1::RectF(static_cast<float>(dirty.left), static_cast<float>(dirty.top),
            static_cast<float>(dirty.right), static_cast<float>(dirty.bottom)), D2D1_ANTIALIAS_MODE_ALIASED);
        atlas_context->DrawGlyphRun(D2D1::Point2F(
            static_cast<float>(slot.x) - static_cast<float>(left),
            static_cast<float>(slot.y) - static_cast<float>(top)),
            &run, atlas_brush, owned.measuring_mode);
        atlas_context->PopAxisAlignedClip();
        owned.placement = {atlas_generation, dirty, left, top, width, height, true, false};
        if (benchmark_active) ++benchmark.atlas_rasterizations;
        return true;
    }

    ~ZigonautTextEngine();

    HRESULT initialize(const wchar_t* requested_family) {
        HRESULT hr = DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED,
            __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(&factory));
        if (FAILED(hr)) return hr;
        factory->QueryInterface(__uuidof(IDWriteFactory2),
            reinterpret_cast<void**>(&factory2));

        hr = refreshRenderingParams();
        if (FAILED(hr)) return hr;

        wchar_t locale_name[LOCALE_NAME_MAX_LENGTH] = {};
        if (GetUserDefaultLocaleName(locale_name, LOCALE_NAME_MAX_LENGTH) != 0) {
            locale = locale_name;
        }

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
            font_weight,
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
            __uuidof(ID2D1Factory1),
            nullptr,
            reinterpret_cast<void**>(&d2d_factory));
        if (FAILED(hr)) return hr;

        UINT device_flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#if defined(_DEBUG)
        device_flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
        constexpr D3D_FEATURE_LEVEL feature_levels[] = {
            D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1,
            D3D_FEATURE_LEVEL_10_0,
        };
        D3D_FEATURE_LEVEL feature_level{};
        hr = D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            device_flags,
            feature_levels,
            static_cast<UINT>(std::size(feature_levels)),
            D3D11_SDK_VERSION,
            &d3d_device,
            &feature_level,
            nullptr);
#if defined(_DEBUG)
        if (hr == DXGI_ERROR_SDK_COMPONENT_MISSING) {
            device_flags &= ~D3D11_CREATE_DEVICE_DEBUG;
            hr = D3D11CreateDevice(
                nullptr,
                D3D_DRIVER_TYPE_HARDWARE,
                nullptr,
                device_flags,
                feature_levels,
                static_cast<UINT>(std::size(feature_levels)),
                D3D11_SDK_VERSION,
                &d3d_device,
                &feature_level,
                nullptr);
        }
#endif
        if (FAILED(hr)) {
            hr = D3D11CreateDevice(
                nullptr,
                D3D_DRIVER_TYPE_WARP,
                nullptr,
                device_flags,
                feature_levels,
                static_cast<UINT>(std::size(feature_levels)),
                D3D11_SDK_VERSION,
                &d3d_device,
                &feature_level,
                nullptr);
        }
        if (FAILED(hr)) return hr;
        d3d_device->GetImmediateContext(&d3d_context);
        if (d3d_context == nullptr) return E_HANDLE;

        IDXGIDevice* dxgi_device = nullptr;
        hr = d3d_device->QueryInterface(IID_PPV_ARGS(&dxgi_device));
        if (FAILED(hr)) return hr;
        hr = d2d_factory->CreateDevice(dxgi_device, &d2d_device);
        if (SUCCEEDED(hr)) {
            hr = d2d_device->CreateDeviceContext(
                D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                &target);
        }
        if (SUCCEEDED(hr)) target->SetTextAntialiasMode(
            text_antialiasing == ZIGONAUT_TEXT_AA_NATIVE_CLEARTYPE
                ? D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE
                : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);

        IDXGIAdapter* adapter = nullptr;
        IDXGIFactory2* dxgi_factory = nullptr;
        if (SUCCEEDED(hr)) hr = dxgi_device->GetAdapter(&adapter);
        if (SUCCEEDED(hr)) hr = adapter->GetParent(IID_PPV_ARGS(&dxgi_factory));
        if (SUCCEEDED(hr)) {
            DXGI_SWAP_CHAIN_DESC1 description{};
            description.Width = 1;
            description.Height = 1;
            description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            description.Stereo = FALSE;
            description.SampleDesc.Count = 1;
            description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            description.BufferCount = 2;
            description.Scaling = DXGI_SCALING_STRETCH;
            description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
            description.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
            hr = dxgi_factory->CreateSwapChainForComposition(
                d3d_device,
                &description,
                nullptr,
                &swap_chain);
        }
        release(dxgi_factory);
        release(adapter);
        release(dxgi_device);
        if (FAILED(hr)) return hr;

        IDXGISwapChain2* swap_chain2 = nullptr;
        hr = swap_chain->QueryInterface(IID_PPV_ARGS(&swap_chain2));
        if (SUCCEEDED(hr)) hr = swap_chain2->SetMaximumFrameLatency(1);
        if (SUCCEEDED(hr)) {
            frame_latency_waitable_object = swap_chain2->GetFrameLatencyWaitableObject();
            if (frame_latency_waitable_object == nullptr) hr = E_HANDLE;
        }
        release(swap_chain2);
        if (FAILED(hr)) return hr;

        hr = updateSwapChainTransform();
        if (FAILED(hr)) return hr;

        target->SetUnitMode(D2D1_UNIT_MODE_PIXELS);
        target->SetDpi(96.0f, 96.0f);
        target->SetTextRenderingParams(rendering_params);
        hr = target->CreateSolidColorBrush(
            D2D1::ColorF(1.0f, 1.0f, 1.0f),
            &brush);
        if (FAILED(hr)) return hr;

        hr = createFormats();
        if (FAILED(hr)) return hr;

        updateMetrics();
        return S_OK;
    }

    HRESULT createFormats() {
        if (!frame_active) invalidateAtlas();
        clearLayouts();
        for (auto*& format : formats) release(format);
        const DWRITE_FONT_WEIGHT weights[] = {
            font_weight,
            intense_font_weight,
            font_weight,
            intense_font_weight,
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
                locale.c_str(),
                &formats[index]);
            if (FAILED(hr)) return hr;
            formats[index]->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
            if (symbol_fallback != nullptr) {
                IDWriteTextFormat1* format = nullptr;
                const HRESULT fallback_hr = formats[index]->QueryInterface(IID_PPV_ARGS(&format));
                if (FAILED(fallback_hr)) return fallback_hr;
                const HRESULT set_hr = format->SetFontFallback(symbol_fallback);
                release(format);
                if (FAILED(set_hr)) return set_hr;
            }
        }
        return S_OK;
    }

    HRESULT setSymbolFallback(const wchar_t* fallback) {
        if (factory2 == nullptr || fallback == nullptr || fallback[0] == L'\0') return E_INVALIDARG;
        IDWriteFontFallbackBuilder* builder = nullptr;
        IDWriteFontFallback* system_fallback = nullptr;
        IDWriteFontFallback* configured = nullptr;
        HRESULT hr = factory2->CreateFontFallbackBuilder(&builder);
        constexpr DWRITE_UNICODE_RANGE ranges[] = {
            {0xE000, 0xF8FF},
            {0xF0000, 0xFFFFD},
            {0x100000, 0x10FFFD},
        };
        const wchar_t* families[] = {fallback};
        if (SUCCEEDED(hr)) hr = builder->AddMapping(
            ranges, static_cast<UINT32>(std::size(ranges)),
            families, static_cast<UINT32>(std::size(families)),
            fonts, nullptr, family.c_str(), 1.0f);
        if (SUCCEEDED(hr)) hr = factory2->GetSystemFontFallback(&system_fallback);
        if (SUCCEEDED(hr)) hr = builder->AddMappings(system_fallback);
        if (SUCCEEDED(hr)) hr = builder->CreateFontFallback(&configured);
        release(system_fallback);
        release(builder);
        if (FAILED(hr)) {
            release(configured);
            return hr;
        }
        release(symbol_fallback);
        symbol_fallback = configured;
        return createFormats();
    }

    HRESULT updateSwapChainTransform() {
        if (swap_chain == nullptr || dpi == 0) return E_HANDLE;
        IDXGISwapChain2* swap_chain2 = nullptr;
        HRESULT hr = swap_chain->QueryInterface(IID_PPV_ARGS(&swap_chain2));
        if (FAILED(hr)) return hr;
        const float scale = 96.0f / static_cast<float>(dpi);
        DXGI_MATRIX_3X2_F transform{scale, 0.0f, 0.0f, scale, 0.0f, 0.0f};
        hr = swap_chain2->SetMatrixTransform(&transform);
        release(swap_chain2);
        return hr;
    }

    void discardTargetBitmap() {
        if (!frame_active) invalidateAtlas();
        if (target != nullptr) target->SetTarget(nullptr);
        release(target_bitmap);
        release(scene_bitmap);
        release(backbuffer_texture);
        release(scene_texture);
        release(scene_shift_scratch);
        release(scene_rtv);
        clearImages();
        scene_width = 0;
        scene_height = 0;
        resetDamageHistory();
    }

    void clearBuiltinBitmaps() {
        for (auto& entry : builtin_bitmaps) release(entry.second);
        builtin_bitmaps.clear();
    }

    HRESULT getBuiltinBitmap(uint32_t codepoint, uint32_t width, uint32_t height,
        uint32_t span, const uint8_t* mask, uint32_t stride, ID2D1Bitmap** result) {
        if (!result || !mask || !width || !height || stride < width) return E_INVALIDARG;
        const BuiltinKey key{codepoint, width, height, span, builtin_generation};
        const auto found = builtin_bitmaps.find(key);
        if (found != builtin_bitmaps.end()) {
            *result = found->second;
            return S_OK;
        }
        ID2D1Bitmap* bitmap = nullptr;
        const auto properties = D2D1::BitmapProperties(
            D2D1::PixelFormat(DXGI_FORMAT_A8_UNORM, D2D1_ALPHA_MODE_STRAIGHT), 96, 96);
        HRESULT hr = target->CreateBitmap(D2D1::SizeU(width, height), mask,
            stride, properties, &bitmap);
        if (FAILED(hr)) return hr;
        try {
            builtin_bitmaps.emplace(key, bitmap);
        } catch (...) {
            release(bitmap);
            return E_OUTOFMEMORY;
        }
        ++builtin_bitmap_creations;
        *result = bitmap;
        return S_OK;
    }

    HRESULT transferSceneTo(ID3D11Texture2D* destination, bool force_full = false) {
        if (target == nullptr || d3d_context == nullptr || scene_texture == nullptr ||
            destination == nullptr) return E_HANDLE;
        // EndDraw has submitted the D2D scene writes on this device. The following
        // immediate-context copy is ordered after them; this does not wait for GPU
        // completion. Drop D2D's retained target association before switching APIs.
        target->SetTarget(nullptr);
        SceneDamage damage;
        try {
            damage = transferDamage();
        } catch (...) {
            markFullDamage(damage);
        }
        if (force_full || shouldCopyFull(damage)) {
            d3d_context->CopyResource(destination, scene_texture);
            ++d3d_scene_full_copy_count;
            ++d3d_scene_copy_count;
        } else {
            for (const auto& box : damage.boxes) {
                d3d_context->CopySubresourceRegion(destination, 0,
                    box.left, box.top, 0, scene_texture, 0, &box);
                ++d3d_scene_region_copy_count;
                ++d3d_scene_copy_count;
                d3d_scene_region_copy_bytes +=
                    static_cast<uint64_t>(box.right - box.left) *
                    (box.bottom - box.top) * 4;
            }
        }
        const HRESULT removed = d3d_device->GetDeviceRemovedReason();
        return FAILED(removed) ? removed : S_OK;
    }

    HRESULT transferScene() {
        return transferSceneTo(backbuffer_texture);
    }

    void clearImages() {
        for (auto& entry : images) release(entry.second.bitmap);
        images.clear();
    }

    void evictUnusedImages() {
        for (auto iterator = images.begin(); iterator != images.end();) {
            if (iterator->second.last_seen_frame == image_frame) {
                ++iterator;
                continue;
            }
            release(iterator->second.bitmap);
            iterator = images.erase(iterator);
        }
    }

    void clearLayouts() {
        for (auto& entry : layouts) release(entry.second.layout);
        layouts.clear();
        layout_recency.clear();
    }

    HRESULT layoutFor(
        const char16_t* text,
        size_t text_length,
        uint32_t width,
        uint32_t height,
        size_t format_index,
        IDWriteTextLayout** result) {
        if (result == nullptr || text_length > UINT32_MAX || format_index >= std::size(formats)) {
            return E_INVALIDARG;
        }
        const LayoutKeyView key{
            std::u16string_view(text, text_length),
            width,
            height,
            static_cast<uint8_t>(format_index),
        };
        auto existing = layouts.find(key);
        if (existing != layouts.end()) {
            if (benchmark_active) ++benchmark.layout_hits;
            layout_recency.splice(layout_recency.end(), layout_recency,
                existing->second.recency);
            *result = existing->second.layout;
            return S_OK;
        }
        if (benchmark_active) ++benchmark.layout_misses;
        if (layouts.size() >= max_layout_cache_entries) {
            auto oldest = layouts.find(*layout_recency.front());
            release(oldest->second.layout);
            layout_recency.pop_front();
            layouts.erase(oldest);
        }
        IDWriteTextLayout* layout = nullptr;
        const HRESULT hr = factory->CreateTextLayout(
            reinterpret_cast<const wchar_t*>(text),
            static_cast<UINT32>(text_length),
            formats[format_index],
            static_cast<float>(width),
            static_cast<float>(height),
            &layout);
        if (FAILED(hr)) return hr;
        ++layout_creation_count;
        auto inserted = layouts.emplace(
            LayoutKey{
                std::u16string(text, text + text_length),
                width,
                height,
                static_cast<uint8_t>(format_index),
            },
            LayoutEntry{layout, {}, nullptr}).first;
        layout_recency.push_back(&inserted->first);
        auto recency = std::prev(layout_recency.end());
        inserted->second.recency = recency;
        *result = layout;
        return S_OK;
    }

    HRESULT refreshRenderingParams() {
        IDWriteRenderingParams* updated = nullptr;
        const HMONITOR monitor = hwnd == nullptr
            ? nullptr
            : MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        const HRESULT hr = monitor == nullptr
            ? factory->CreateRenderingParams(&updated)
            : factory->CreateMonitorRenderingParams(monitor, &updated);
        if (FAILED(hr)) return hr;
        release(rendering_params);
        rendering_params = updated;
        if (target != nullptr) target->SetTextRenderingParams(rendering_params);
        if (!frame_active) invalidateAtlas();
        return S_OK;
    }

    HRESULT ensureTarget(uint32_t width, uint32_t height) {
        if (target == nullptr || swap_chain == nullptr) return E_HANDLE;
        if (target_bitmap != nullptr && scene_bitmap != nullptr &&
            target_bitmap->GetPixelSize().width == width &&
            target_bitmap->GetPixelSize().height == height) return S_OK;

        discardTargetBitmap();
        HRESULT hr = swap_chain->ResizeBuffers(
            2,
            width,
            height,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        if (FAILED(hr)) return hr;

        hr = swap_chain->GetBuffer(0, IID_PPV_ARGS(&backbuffer_texture));
        IDXGISurface* surface = nullptr;
        if (SUCCEEDED(hr)) hr = backbuffer_texture->QueryInterface(IID_PPV_ARGS(&surface));
        if (SUCCEEDED(hr)) {
            auto const properties = D2D1::BitmapProperties1(
                D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                D2D1::PixelFormat(
                    DXGI_FORMAT_B8G8R8A8_UNORM,
                    D2D1_ALPHA_MODE_IGNORE),
                96.0f,
                96.0f);
            hr = target->CreateBitmapFromDxgiSurface(
                surface,
                &properties,
                &target_bitmap);
        }
        release(surface);
        if (SUCCEEDED(hr)) {
            D3D11_TEXTURE2D_DESC scene_description{};
            scene_description.Width = width;
            scene_description.Height = height;
            scene_description.MipLevels = 1;
            scene_description.ArraySize = 1;
            scene_description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            scene_description.SampleDesc.Count = 1;
            scene_description.Usage = D3D11_USAGE_DEFAULT;
            scene_description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
            hr = d3d_device->CreateTexture2D(&scene_description, nullptr, &scene_texture);
            if (SUCCEEDED(hr)) hr = d3d_device->CreateTexture2D(&scene_description, nullptr,
                &scene_shift_scratch);
        }
        IDXGISurface* scene_surface = nullptr;
        if (SUCCEEDED(hr)) hr = scene_texture->QueryInterface(IID_PPV_ARGS(&scene_surface));
        if (SUCCEEDED(hr)) {
            auto const scene_properties = D2D1::BitmapProperties1(
                D2D1_BITMAP_OPTIONS_TARGET,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE),
                96.0f, 96.0f);
            hr = target->CreateBitmapFromDxgiSurface(scene_surface,
                &scene_properties, &scene_bitmap);
        }
        release(scene_surface);
        if (FAILED(hr)) discardTargetBitmap();
        else {
            scene_width = width;
            scene_height = height;
        }
        return hr;
    }

    void updateMetrics() {
        clearBuiltinBitmaps();
        if (++builtin_generation == 0) ++builtin_generation;
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
        const uint32_t natural_height = std::max(
            1u,
            static_cast<uint32_t>(std::lround(
                static_cast<float>(line_units) * scale)));
        metrics.height = std::max(1u, static_cast<uint32_t>(std::lround(
            static_cast<float>(natural_height) * line_height_percent / 100.0f)));
        const int32_t natural_baseline = static_cast<int32_t>(std::lround(
            static_cast<float>(font_metrics.ascent) * scale));
        const int32_t centred_baseline = natural_baseline +
            static_cast<int32_t>(std::lround((static_cast<int32_t>(metrics.height) -
                static_cast<int32_t>(natural_height)) / 2.0f));
        metrics.baseline = static_cast<uint32_t>(std::clamp(
            centred_baseline, 0, static_cast<int32_t>(metrics.height)));
        const uint32_t underline_thickness = static_cast<uint32_t>(std::lround(
            static_cast<float>(font_metrics.underlineThickness) * scale));
        const uint32_t proportional_thickness = (metrics.height + 8) / 16;
        metrics.builtin_thickness = std::max(1u, std::min(std::min(metrics.width, metrics.height),
            std::max(underline_thickness, proportional_thickness)));
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
        uint32_t underline_color,
        bool bold,
        bool italic,
        bool faint,
        bool strikethrough,
        bool overline,
        uint8_t underline,
        ZigonautCellOccupancy occupancy,
        uint32_t ordinary_background = UINT32_MAX,
        bool selection_background = false,
        bool search_background = false) {
        if (target == nullptr || brush == nullptr) return E_UNEXPECTED;
        if (ordinary_background == UINT32_MAX) ordinary_background = background;
        setTag(frame_command_cell_decoration);
        const auto rect = D2D1::RectF(left, top, left + width, top + height);
        if (!row_active && frame_active) {
            addDamage(frame_damage, left - 1.0f, top - 1.0f,
                left + width + 1.0f, top + height + 1.0f);
        }
        if (row_active && !benchmark_legacy_background_fills) {
            if (selection_background) {
                if (ordinary_background != frame_background) {
                    brush->SetColor(color(ordinary_background));
                    target->FillRectangle(rect, brush);
                    if (benchmark_background_active) ++background_fill_calls;
                }
                if (pending_row_background_active && pending_row_background_selection &&
                        pending_row_background_color == background &&
                        pending_row_background.right == rect.left &&
                        pending_row_background.top == rect.top &&
                        pending_row_background.bottom == rect.bottom) {
                    pending_row_background.right = rect.right;
                } else {
                    flushRowBackground();
                    pending_row_background = rect;
                    pending_row_background_color = background;
                    pending_row_background_selection = true;
                    pending_row_background_active = true;
                }
            } else if (search_background) {
                if (ordinary_background != frame_background) {
                    brush->SetColor(color(ordinary_background));
                    target->FillRectangle(rect, brush);
                    if (benchmark_background_active) ++background_fill_calls;
                }
                flushRowBackground();
            } else if (background == frame_background && !search_background) {
                flushRowBackground();
            } else if (pending_row_background_active &&
                    !pending_row_background_selection &&
                    pending_row_background_color == background &&
                    pending_row_background.right == rect.left &&
                    pending_row_background.top == rect.top &&
                    pending_row_background.bottom == rect.bottom) {
                pending_row_background.right = rect.right;
            } else {
                flushRowBackground();
                pending_row_background = rect;
                pending_row_background_color = background;
                pending_row_background_selection = false;
                pending_row_background_active = true;
            }
        } else if ((search_background ? ordinary_background : background) != frame_background) {
            brush->SetColor(color(search_background ? ordinary_background : background));
            target->FillRectangle(rect, brush);
            if (benchmark_background_active) ++background_fill_calls;
        }
        if (faint) {
            foreground = blend(foreground, background);
            underline_color = blend(underline_color, background);
        }
        const bool defer_decorations = row_active;
        brush->SetColor(color(underline_color));
        const float underline_y = top + height - 1.5f;
        if (underline != 0 && !defer_decorations) {
            if (underline == 4) {
                for (float x = left + 1.0f; x < left + width; x += 3.0f) {
                    target->DrawLine(D2D1::Point2F(x, underline_y),
                        D2D1::Point2F(x + 0.5f, underline_y), brush, 1.0f);
                }
            } else if (underline == 5) {
                for (float x = left; x < left + width; x += 6.0f) {
                    target->DrawLine(D2D1::Point2F(x, underline_y),
                        D2D1::Point2F(std::min(x + 3.0f, left + width), underline_y),
                        brush, 1.0f);
                }
            } else if (underline == 3) {
                for (float x = left; x < left + width; x += 4.0f) {
                    target->DrawLine(D2D1::Point2F(x, underline_y - 1.0f),
                        D2D1::Point2F(std::min(x + 2.0f, left + width), underline_y),
                        brush, 1.0f);
                    target->DrawLine(D2D1::Point2F(std::min(x + 2.0f, left + width), underline_y),
                        D2D1::Point2F(std::min(x + 4.0f, left + width), underline_y - 1.0f),
                        brush, 1.0f);
                }
            } else {
                target->DrawLine(D2D1::Point2F(left, underline_y),
                    D2D1::Point2F(left + width, underline_y), brush, 1.0f);
                if (underline == 2) {
                    target->DrawLine(D2D1::Point2F(left, underline_y - 2.0f),
                        D2D1::Point2F(left + width, underline_y - 2.0f), brush, 1.0f);
                }
            }
        }
        brush->SetColor(color(foreground));
        if (strikethrough && !row_active) {
            const float y = top + height * 0.55f;
            target->DrawLine(D2D1::Point2F(left, y), D2D1::Point2F(left + width, y), brush, 1.0f);
        }
        if (overline && !defer_decorations) {
            target->DrawLine(D2D1::Point2F(left, top + 1.0f),
                D2D1::Point2F(left + width, top + 1.0f), brush, 1.0f);
        }
        if (row_active) {
            const uint32_t text_offset = static_cast<uint32_t>(row_text.size());
            if (text_length != 0) {
                row_text.append(
                    reinterpret_cast<const char16_t*>(text),
                    reinterpret_cast<const char16_t*>(text) + text_length);
            }
            row_cells.push_back({
                text_offset,
                text_length,
                static_cast<uint32_t>(std::lround((left - row_origin_x) / row_cell_width)),
                foreground,
                background,
                bold,
                italic,
                strikethrough,
                occupancy,
                underline_color,
                underline,
                overline,
                selection_background,
                search_background,
            });
            return S_OK;
        }
        if (text_length == 0) return S_OK;

        const size_t format_index = (bold ? 1u : 0u) | (italic ? 2u : 0u);
        IDWriteTextLayout* layout = nullptr;
        const HRESULT hr = layoutFor(
            reinterpret_cast<const char16_t*>(text),
            text_length,
            static_cast<uint32_t>(std::lround(width)),
            static_cast<uint32_t>(std::lround(height)),
            format_index,
            &layout);
        if (FAILED(hr)) return hr;
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
        float cell_height,
        SelectionInterval previous = {},
        SelectionInterval current = {},
        SelectionInterval next = {},
        bool top_clipped = false,
        bool bottom_clipped = false) {
        row_cells.clear();
        row_text.clear();
        row_origin_x = origin_x;
        row_top = top;
        row_cell_width = cell_width;
        row_cell_height = cell_height;
        pending_row_background_active = false;
        pending_row_background_selection = false;
        release(selection_geometry);
        selection_radius = std::min(0.15f * cell_height, 0.25f * cell_width);
        if (current.active) {
            (void)createSelectionGeometry(d2d_factory, previous, current, next,
                origin_x, top, cell_width, cell_height,
                top_clipped, bottom_clipped, &selection_geometry);
        }
        row_active = true;
        if (target != nullptr && scene_texture != nullptr && frame_active) {
            addDamage(frame_damage, 0.0f, top,
                static_cast<float>(scene_width), top + cell_height);
        }
    }

    HRESULT endRow();

    void flushRowBackground() {
        if (!pending_row_background_active) return;
        brush->SetColor(color(pending_row_background_color));
        if (pending_row_background_selection && selection_geometry != nullptr) {
            auto parameters = D2D1::LayerParameters1();
            parameters.geometricMask = selection_geometry;
            parameters.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
            target->PushLayer(parameters, nullptr);
            target->FillRectangle(pending_row_background, brush);
            target->PopLayer();
        } else {
            target->FillRectangle(pending_row_background, brush);
        }
        pending_row_background_active = false;
        pending_row_background_selection = false;
        if (benchmark_background_active) ++background_fill_calls;
    }

    HRESULT drawSegment(const RowSegment& segment);

    void setTag(uint32_t command, uint32_t subtype = 0) {
        if (frame_diagnostics && target != nullptr) target->SetTags(command, subtype);
    }
};

class GridTextRenderer final : public IDWriteTextRenderer {
public:
    explicit GridTextRenderer(ZigonautTextEngine* engine)
        : engine_(engine) {}

    void setSegment(const RowSegment* segment, uint32_t start_column,
        ResolvedDrawPlan* plan, bool* cacheable) {
        segment_ = segment;
        segment_start_column_ = start_column;
        plan_ = plan;
        cacheable_ = cacheable;
    }

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
        if (glyph_run == nullptr || segment_ == nullptr || engine_->target == nullptr || engine_->brush == nullptr) {
            return E_INVALIDARG;
        }
        if (engine_->benchmark_active) ++engine_->benchmark.glyph_callbacks;
        const auto& segment = *segment_;

        try {
            advances_.assign(
                glyph_run->glyphAdvances,
                glyph_run->glyphAdvances + glyph_run->glyphCount);
        } catch (...) {
            return E_OUTOFMEMORY;
        }
        float origin_x = engine_->row_origin_x;

        if (description != nullptr && description->clusterMap != nullptr &&
            description->stringLength > 0) {
            try {
                spans_.assign(glyph_run->glyphCount, ClusterSpan{});
                glyph_starts_.clear();
                glyph_starts_.reserve(std::min<UINT32>(
                    description->stringLength,
                    glyph_run->glyphCount));
            } catch (...) {
                return E_OUTOFMEMORY;
            }
            uint32_t run_start_column = UINT32_MAX;
            uint32_t run_end_column = 0;
            for (UINT32 index = 0; index < description->stringLength; ++index) {
                const uint32_t text_index = description->textPosition + index;
                if (text_index >= segment.columns.size()) break;
                const UINT16 glyph_start = description->clusterMap[index];
                if (glyph_start >= glyph_run->glyphCount) continue;
                auto& span = spans_[glyph_start];
                if (!span.used) {
                    span.used = true;
                    glyph_starts_.push_back(glyph_start);
                }
                span.start_column = std::min(
                    span.start_column,
                    startColumn(segment.columns[text_index]));
                span.end_column = std::max(
                    span.end_column,
                    endColumn(segment.columns[text_index]));
                span.first_text_index = std::min(span.first_text_index, text_index);
                span.text_end = std::max(span.text_end, text_index + 1);
                run_start_column = std::min(run_start_column, span.start_column);
                run_end_column = std::max(run_end_column, span.end_column);
            }

            std::sort(glyph_starts_.begin(), glyph_starts_.end());
            for (size_t index = 0; index < glyph_starts_.size(); ++index) {
                const UINT32 glyph_start = glyph_starts_[index];
                const UINT32 glyph_end = index + 1 < glyph_starts_.size()
                    ? glyph_starts_[index + 1]
                    : glyph_run->glyphCount;
                if (glyph_start >= glyph_end) continue;
                const auto& span = spans_[glyph_start];
                const uint32_t cluster_left = startColumn(
                    segment.columns[span.first_text_index]);
                const uint32_t cluster_right =
                    span.text_end < segment.columns.size()
                    ? startColumn(segment.columns[span.text_end])
                    : endColumn(segment.columns[span.text_end - 1]);
                const float expected = static_cast<float>(
                    cluster_right - cluster_left) * engine_->row_cell_width;
                zigonaut_fit_cluster_advances(
                    advances_.data() + glyph_start,
                    glyph_end - glyph_start,
                    expected);
            }

            if (run_start_column != UINT32_MAX) {
                origin_x += static_cast<float>(
                    glyph_run->bidiLevel % 2 == 0
                        ? run_start_column
                        : run_end_column) * engine_->row_cell_width;
            }
        }

        DWRITE_GLYPH_RUN adjusted = *glyph_run;
        adjusted.glyphAdvances = advances_.data();
        const float origin_y = engine_->row_top +
            static_cast<float>(engine_->metrics.baseline);
        bool rendered_color = false;
        if (engine_->factory2 != nullptr) {
            if (engine_->benchmark_active) ++engine_->benchmark.color_translate_attempts;
            const DWRITE_MATRIX transform = {1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f};
            IDWriteColorGlyphRunEnumerator* layers = nullptr;
            const HRESULT color_result = engine_->factory2->TranslateColorGlyphRun(
                origin_x,
                origin_y,
                &adjusted,
                description,
                measuring_mode,
                &transform,
                0,
                &layers);
            if (SUCCEEDED(color_result)) {
                if (engine_->benchmark_active) ++engine_->benchmark.color_translate_successes;
                for (auto& layer : color_layers_) layer->reset();
                size_t color_layer_count = 0;
                bool enumeration_complete = false;
                BOOL has_layer = FALSE;
                for (;;) {
                    const HRESULT next_result = layers->MoveNext(&has_layer);
                    if (FAILED(next_result)) break;
                    if (!has_layer) {
                        enumeration_complete = true;
                        break;
                    }
                    const DWRITE_COLOR_GLYPH_RUN* layer = nullptr;
                    if (FAILED(layers->GetCurrentRun(&layer)) || layer == nullptr) break;
                    try {
                        if (color_layer_count == color_layers_.size()) {
                            color_layers_.push_back(std::make_unique<OwnedColorLayer>());
                        }
                        auto& owned = color_layers_[color_layer_count++];
                        owned->font_face = layer->glyphRun.fontFace;
                        if (owned->font_face != nullptr) owned->font_face->AddRef();
                        owned->em_size = layer->glyphRun.fontEmSize;
                        owned->sideways = layer->glyphRun.isSideways;
                        owned->bidi_level = layer->glyphRun.bidiLevel;
                        owned->origin_x = layer->baselineOriginX;
                        owned->origin_y = layer->baselineOriginY;
                        owned->run_color = layer->runColor;
                        owned->palette_index = layer->paletteIndex;
                        owned->indices.assign(
                            layer->glyphRun.glyphIndices,
                            layer->glyphRun.glyphIndices + layer->glyphRun.glyphCount);
                        if (layer->glyphRun.glyphAdvances != nullptr) {
                            owned->advances.assign(
                                layer->glyphRun.glyphAdvances,
                                layer->glyphRun.glyphAdvances + layer->glyphRun.glyphCount);
                        }
                        if (layer->glyphRun.glyphOffsets != nullptr) {
                            owned->offsets.assign(
                                layer->glyphRun.glyphOffsets,
                                layer->glyphRun.glyphOffsets + layer->glyphRun.glyphCount);
                        }
                    } catch (...) {
                        enumeration_complete = false;
                        break;
                    }
                }
                if (enumeration_complete) {
                    for (size_t index = 0; index < color_layer_count; ++index) {
                        const auto& layer = color_layers_[index];
                        if (layer->palette_index == 0xffff) {
                            engine_->brush->SetColor(color(segment.foreground));
                        } else {
                            engine_->brush->SetColor(D2D1::ColorF(
                                layer->run_color.r,
                                layer->run_color.g,
                                layer->run_color.b,
                                layer->run_color.a));
                        }
                        const DWRITE_GLYPH_RUN color_run = layer->glyphRun();
                        engine_->setTag(frame_command_row_glyph, 1);
                        engine_->target->DrawGlyphRun(
                            D2D1::Point2F(layer->origin_x, layer->origin_y),
                            &color_run,
                            engine_->brush,
                            measuring_mode);
                        if (engine_->benchmark_active) ++engine_->benchmark.glyph_submissions;
                    }
                    rendered_color = color_layer_count != 0;
                }
                release(layers);
                if (cacheable_ != nullptr) *cacheable_ = false;
            } else if (color_result != DWRITE_E_NOCOLOR) {
                if (cacheable_ != nullptr) *cacheable_ = false;
            }
        }
        if (!rendered_color) {
            engine_->brush->SetColor(color(segment.foreground));
            engine_->setTag(frame_command_row_glyph, 2);
            engine_->target->DrawGlyphRun(
                D2D1::Point2F(origin_x, origin_y),
                &adjusted,
                engine_->brush,
                measuring_mode);
            if (engine_->benchmark_active) ++engine_->benchmark.glyph_submissions;
            if (plan_ != nullptr && cacheable_ != nullptr && *cacheable_) {
                try {
                    OwnedGlyphRun owned;
                    owned.font_face = adjusted.fontFace;
                    if (owned.font_face != nullptr) owned.font_face->AddRef();
                    owned.em_size = adjusted.fontEmSize;
                    owned.sideways = adjusted.isSideways;
                    owned.bidi_level = adjusted.bidiLevel;
                    const float segment_origin_x = engine_->row_origin_x +
                        static_cast<float>(segment_start_column_) * engine_->row_cell_width;
                    owned.origin_x = origin_x - segment_origin_x;
                    owned.origin_y = origin_y - engine_->row_top;
                    owned.measuring_mode = measuring_mode;
                    owned.indices.assign(adjusted.glyphIndices,
                        adjusted.glyphIndices + adjusted.glyphCount);
                    owned.advances.assign(adjusted.glyphAdvances,
                        adjusted.glyphAdvances + adjusted.glyphCount);
                    if (adjusted.glyphOffsets != nullptr) {
                        owned.offsets.assign(adjusted.glyphOffsets,
                            adjusted.glyphOffsets + adjusted.glyphCount);
                    }
                    plan_->runs.push_back(std::move(owned));
                } catch (...) {
                    *cacheable_ = false;
                    plan_->runs.clear();
                }
            }
        }
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
    const RowSegment* segment_ = nullptr;
    uint32_t segment_start_column_ = 0;
    ResolvedDrawPlan* plan_ = nullptr;
    bool* cacheable_ = nullptr;
    std::vector<FLOAT> advances_;
    std::vector<ClusterSpan> spans_;
    std::vector<UINT16> glyph_starts_;
    std::vector<std::unique_ptr<OwnedColorLayer>> color_layers_;
};

ZigonautTextEngine::~ZigonautTextEngine() {
    delete grid_renderer;
    release(selection_geometry);
    invalidateAtlas();
    discardTargetBitmap();
    clearBuiltinBitmaps();
    for (auto& slot : glyph_slots) { release(slot.view); release(slot.buffer); }
    release(glyph_sampler);
    release(glyph_blend); release(glyph_ps); release(glyph_vs);
    release(brush);
    release(target);
    release(d2d_device);
    release(swap_chain);
    if (frame_latency_waitable_object != nullptr) CloseHandle(frame_latency_waitable_object);
    release(d3d_context);
    release(d3d_device);
    release(d2d_factory);
    clearLayouts();
    for (auto*& format : formats) release(format);
    release(normal_face);
    release(symbol_fallback);
    release(fonts);
    release(rendering_params);
    release(factory2);
    release(factory);
}

HRESULT ZigonautTextEngine::drawSegment(const RowSegment& segment) {
    if (segment.text.empty()) return S_OK;
    uint32_t start_column = UINT32_MAX;
    uint32_t end_column = 0;
    for (uint32_t packed : segment.columns) {
        start_column = std::min(start_column, startColumn(packed));
        end_column = std::max(end_column, endColumn(packed));
    }
    if (start_column == UINT32_MAX || end_column <= start_column) return S_OK;

    IDWriteTextLayout* layout = nullptr;
    const size_t format_index = (segment.bold ? 1u : 0u) |
        (segment.italic ? 2u : 0u);
    const uint32_t width = static_cast<uint32_t>(std::lround(
        static_cast<float>(end_column - start_column) * row_cell_width));
    const uint32_t height = static_cast<uint32_t>(std::lround(row_cell_height));
    HRESULT hr = layoutFor(
        segment.text.data(),
        segment.text.size(),
        width,
        height,
        format_index,
        &layout);
    if (FAILED(hr)) return hr;

    const LayoutKeyView key{segment.text, width, height, static_cast<uint8_t>(format_index)};
    auto cached_layout = layouts.find(key);
    if (cached_layout == layouts.end()) return E_UNEXPECTED;
    auto& cached_plan = cached_layout->second.plan;
    const bool plan_matches = cached_plan != nullptr &&
        matchesNormalizedColumns(cached_plan->columns, segment.columns, start_column) &&
        cached_plan->cell_width == row_cell_width && cached_plan->cell_height == row_cell_height;
    if (plan_matches) {
        if (benchmark_active) ++benchmark.resolved_plan_hits;
    } else if (benchmark_active) {
        ++benchmark.resolved_plan_misses;
    }

    if (grid_renderer == nullptr) {
        grid_renderer = new (std::nothrow) GridTextRenderer(this);
        if (grid_renderer == nullptr) return E_OUTOFMEMORY;
    }
    if (plan_matches) {
        // Cached DWRITE_GLYPH_RUN replay can be rejected asynchronously by
        // Direct2D with E_INVALIDARG after sustained rendering. Keep the plan for
        // atlas rasterization, but let DirectWrite produce native fallback runs.
        grid_renderer->setSegment(&segment, start_column, nullptr, nullptr);
        if (benchmark_active) ++benchmark.layout_draws;
        const HRESULT draw = layout->Draw(nullptr, grid_renderer, 0.0f, 0.0f);
        grid_renderer->setSegment(nullptr, 0, nullptr, nullptr);
        return draw;
    }
    std::unique_ptr<ResolvedDrawPlan> pending;
    try {
        pending = std::make_unique<ResolvedDrawPlan>();
        pending->columns.reserve(segment.columns.size());
        for (uint32_t packed : segment.columns) {
            pending->columns.push_back(packedColumns(
                startColumn(packed) - start_column,
                endColumn(packed) - startColumn(packed)));
        }
    } catch (...) {
        return E_OUTOFMEMORY;
    }
    pending->cell_width = row_cell_width;
    pending->cell_height = row_cell_height;
    bool cacheable = true;
    grid_renderer->setSegment(&segment, start_column, pending.get(), &cacheable);
    if (benchmark_active) ++benchmark.layout_draws;
    hr = layout->Draw(nullptr, grid_renderer, 0.0f, 0.0f);
    grid_renderer->setSegment(nullptr, 0, nullptr, nullptr);
    if (FAILED(hr)) return hr;
    if (cacheable && !pending->runs.empty()) {
        cached_plan = std::move(pending);
    } else if (benchmark_active) {
        ++benchmark.resolved_plan_bypasses;
    }
    return S_OK;
}

HRESULT ZigonautTextEngine::endRow() {
    if (!row_active) return E_UNEXPECTED;
    flushRowBackground();
    if (selection_geometry != nullptr) {
        auto parameters = D2D1::LayerParameters1();
        parameters.geometricMask = selection_geometry;
        parameters.maskAntialiasMode = D2D1_ANTIALIAS_MODE_PER_PRIMITIVE;
        target->PushLayer(parameters, nullptr);
        for (const auto& cell : row_cells) {
            if (!cell.selection_background) continue;
            const float left = row_origin_x + cell.column * row_cell_width;
            const float width = row_cell_width *
                (cell.occupancy == ZIGONAUT_CELL_WIDE ? 2.0f : 1.0f);
            brush->SetColor(color(cell.background));
            target->FillRectangle(D2D1::RectF(left - selection_radius, row_top,
                left + width + selection_radius, row_top + row_cell_height), brush);
        }
        // Restore exact per-cell colours after adjacent expanded fills overlap.
        for (const auto& cell : row_cells) {
            if (!cell.selection_background) continue;
            const float left = row_origin_x + cell.column * row_cell_width;
            const float width = row_cell_width *
                (cell.occupancy == ZIGONAUT_CELL_WIDE ? 2.0f : 1.0f);
            brush->SetColor(color(cell.background));
            target->FillRectangle(D2D1::RectF(left, row_top,
                left + width, row_top + row_cell_height), brush);
        }
        target->PopLayer();
    }
    D2D1_RECT_F search_rect{};
    uint32_t search_color = 0;
    bool search_active = false;
    const auto flush_search = [&]() {
        if (!search_active) return;
        brush->SetColor(color(search_color));
        target->FillRoundedRectangle(
            D2D1::RoundedRect(search_rect, selection_radius, selection_radius), brush);
        search_active = false;
    };
    for (const auto& cell : row_cells) {
        if (!cell.search_background) {
            flush_search();
            continue;
        }
        const float left = row_origin_x + cell.column * row_cell_width;
        const float width = row_cell_width *
            (cell.occupancy == ZIGONAUT_CELL_WIDE ? 2.0f : 1.0f);
        if (search_active && search_color == cell.background && search_rect.right == left) {
            search_rect.right = left + width;
        } else {
            flush_search();
            search_rect = D2D1::RectF(left, row_top,
                left + width, row_top + row_cell_height);
            search_color = cell.background;
            search_active = true;
        }
    }
    flush_search();
    // Backgrounds are complete now. Draw decorations afterward so concave
    // colour bleed and the exact selection/search passes cannot cover them;
    // text and strikethrough are already emitted later in this method.
    for (const auto& cell : row_cells) {
        if (cell.underline == 0 && !cell.overline) continue;
        const float left = row_origin_x + cell.column * row_cell_width;
        const float width = row_cell_width *
            (cell.occupancy == ZIGONAUT_CELL_WIDE ? 2.0f : 1.0f);
        const float underline_y = row_top + row_cell_height - 1.5f;
        brush->SetColor(color(cell.underline_color));
        if (cell.underline == 4) {
            for (float x = left + 1.0f; x < left + width; x += 3.0f)
                target->DrawLine(D2D1::Point2F(x, underline_y),
                    D2D1::Point2F(x + 0.5f, underline_y), brush, 1.0f);
        } else if (cell.underline == 5) {
            for (float x = left; x < left + width; x += 6.0f)
                target->DrawLine(D2D1::Point2F(x, underline_y),
                    D2D1::Point2F(std::min(x + 3.0f, left + width), underline_y),
                    brush, 1.0f);
        } else if (cell.underline == 3) {
            for (float x = left; x < left + width; x += 4.0f) {
                target->DrawLine(D2D1::Point2F(x, underline_y - 1.0f),
                    D2D1::Point2F(std::min(x + 2.0f, left + width), underline_y),
                    brush, 1.0f);
                target->DrawLine(D2D1::Point2F(std::min(x + 2.0f, left + width), underline_y),
                    D2D1::Point2F(std::min(x + 4.0f, left + width), underline_y - 1.0f),
                    brush, 1.0f);
            }
        } else if (cell.underline != 0) {
            target->DrawLine(D2D1::Point2F(left, underline_y),
                D2D1::Point2F(left + width, underline_y), brush, 1.0f);
            if (cell.underline == 2) target->DrawLine(
                D2D1::Point2F(left, underline_y - 2.0f),
                D2D1::Point2F(left + width, underline_y - 2.0f), brush, 1.0f);
        }
        if (cell.overline) target->DrawLine(D2D1::Point2F(left, row_top + 1.0f),
            D2D1::Point2F(left + width, row_top + 1.0f), brush, 1.0f);
    }
    row_active = false;
    struct RowClipGuard {
        ZigonautTextEngine* engine;
        bool active = false;
        ~RowClipGuard() {
            if (active && engine->target != nullptr) {
                engine->target->PopAxisAlignedClip();
            }
        }
        void push() {
            // Full-rebuild frames transfer every pixel, so preserve the old un-clipped
            // fast path. Partial frames clip glyph overhang to their recorded row.
            if (active || engine->frame_damage.full || engine->target == nullptr ||
                    engine->scene_texture == nullptr) return;
            engine->setTag(frame_command_row_clip);
            engine->target->PushAxisAlignedClip(D2D1::RectF(0.0f, engine->row_top,
                static_cast<float>(engine->scene_width),
                engine->row_top + engine->row_cell_height),
                D2D1_ANTIALIAS_MODE_ALIASED);
            active = true;
        }
        void pop() {
            if (!active || engine->target == nullptr) return;
            engine->target->PopAxisAlignedClip();
            active = false;
        }
    } clip_guard{this};

    auto& segments = row_segments;
    size_t segment_count = 0;
    auto& order = row_order;
    order.clear();
    auto& segment = row_segment; segment.clear();
    bool has_segment = false;
    const auto flush = [&]() -> HRESULT {
        HRESULT hr = S_OK;
        if (has_segment) try {
            if (segment_count == segments.size()) segments.emplace_back();
            std::swap(segment, segments[segment_count++]);
            order.push_back(static_cast<int64_t>(segment_count - 1));
        } catch (...) { hr = E_OUTOFMEMORY; }
        segment.clear();
        has_segment = false;
        return hr;
    };

    for (size_t cell_index = 0; cell_index < row_cells.size(); ++cell_index) {
        const auto& cell = row_cells[cell_index];
        if (cell.occupancy == ZIGONAUT_CELL_WIDE_TAIL) continue;
        if (cell.kind == RowCell::Kind::builtin) {
            const HRESULT boundary = flush();
            if (FAILED(boundary)) return boundary;
            try { order.push_back(-1 - static_cast<int64_t>(cell_index)); }
            catch (...) { return E_OUTOFMEMORY; }
            continue;
        }
        const std::u16string_view cell_text = cell.text_length == 0
            ? std::u16string_view{}
            : std::u16string_view(row_text.data() + cell.text_offset, cell.text_length);
        if (has_segment &&
            (segment.foreground != cell.foreground ||
             segment.bold != cell.bold ||
             segment.italic != cell.italic)) {
            const HRESULT hr = flush();
            if (FAILED(hr)) return hr;
        }
        if (!has_segment) {
            segment.foreground = cell.foreground;
            segment.bold = cell.bold;
            segment.italic = cell.italic;
            has_segment = true;
        }

        const uint32_t span = cell.occupancy == ZIGONAUT_CELL_WIDE ? 2u : 1u;
        if (cell_text.empty() || cell.occupancy == ZIGONAUT_CELL_WRAP_SPACER) {
            segment.text.push_back(u' ');
            segment.columns.push_back(packedColumns(cell.column, span));
        } else {
            segment.text.append(cell_text);
            for (size_t index = 0; index < cell_text.size(); ++index) {
                segment.columns.push_back(packedColumns(cell.column, span));
            }
        }
    }
    HRESULT hr = flush();
    if (FAILED(hr)) return hr;
    const bool has_builtins = order.size() != segment_count;
    const bool atlas_eligible = text_antialiasing == ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE &&
        (has_builtins || segment_count >= 8);
    if (atlas_eligible && !atlas_disabled_for_frame && !atlas_allocator)
        initializeAtlas();
    bool batched = !atlas_disabled_for_frame && atlas_eligible && target3 && sprite_batch &&
        atlas_bitmap && atlas_allocator;
    if (batched && FAILED(initializeGlyphPipeline())) {
        batched = false;
        atlas_disabled_for_frame = true;
    }
    if (atlas_eligible && benchmark_active) ++benchmark.atlas_eligible_rows;
    auto& destinations = glyph_destinations;
    auto& sources = glyph_sources;
    auto& colors = glyph_colors;
    destinations.clear();
    sources.clear();
    colors.clear();
    if (batched) try {
        destinations.reserve(order.size());
        sources.reserve(order.size());
        colors.reserve(order.size());
        for (const int64_t ordered : order) {
            if (ordered < 0) {
                const auto& cell = row_cells[static_cast<size_t>(-1 - ordered)];
                const uint32_t span = cell.occupancy == ZIGONAUT_CELL_WIDE ? 2u : 1u;
                const BuiltinKey key{cell.builtin_codepoint,cell.builtin_width,cell.builtin_height,span,atlas_generation};
                auto found = builtin_placements.find(key);
                if (found == builtin_placements.end()) {
                    if (cell.builtin_mask.empty() || !cell.builtin_width || !cell.builtin_height ||
                        cell.builtin_stride < cell.builtin_width) { batched=false; break; }
                    GlyphAtlasAllocator::Rect slot{};
                    if (!atlas_allocator->reserve(cell.builtin_width,cell.builtin_height,slot)) {
                        rejectAtlasReservation(cell.builtin_width,cell.builtin_height,true); batched=false; break;
                    }
                    ID2D1Bitmap* mask = nullptr;
                    const auto props=D2D1::BitmapProperties(D2D1::PixelFormat(
                        DXGI_FORMAT_A8_UNORM,D2D1_ALPHA_MODE_STRAIGHT),96,96);
                    HRESULT upload=atlas_context->CreateBitmap(D2D1::SizeU(cell.builtin_width,cell.builtin_height),
                        cell.builtin_mask.data(),cell.builtin_stride,props,&mask);
                    if (SUCCEEDED(upload)) upload=beginAtlasDraw();
                    if (SUCCEEDED(upload)) {
                        const auto destination=D2D1::RectF(static_cast<float>(slot.x),static_cast<float>(slot.y),
                            static_cast<float>(slot.x+cell.builtin_width),static_cast<float>(slot.y+cell.builtin_height));
                        const auto aa=atlas_context->GetAntialiasMode();
                        atlas_context->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
                        atlas_context->FillOpacityMask(mask,atlas_brush,destination,
                            D2D1::RectF(0,0,static_cast<float>(cell.builtin_width),static_cast<float>(cell.builtin_height)));
                        atlas_context->SetAntialiasMode(aa);
                    }
                    release(mask);
                    if (FAILED(upload)) { batched=false; break; }
                    found=builtin_placements.emplace(key,BuiltinPlacement{{slot.x,slot.y,
                        slot.x+cell.builtin_width,slot.y+cell.builtin_height}}).first;
                    if (benchmark_active) { ++benchmark.atlas_placement_misses; ++benchmark.atlas_rasterizations; }
                } else if (benchmark_active) ++benchmark.atlas_placement_hits;
                const float left=row_origin_x+cell.column*row_cell_width;
                destinations.push_back({left,row_top,left+cell.builtin_width,row_top+cell.builtin_height});
                sources.push_back(found->second.source); colors.push_back(color(cell.foreground));
                continue;
            }
            if (text_antialiasing != ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE) { batched=false; break; }
            const size_t segment_index=static_cast<size_t>(ordered);
            auto& item = segments[segment_index];
            uint32_t start = UINT32_MAX, end = 0;
            for (uint32_t packed : item.columns) { start=std::min(start,startColumn(packed)); end=std::max(end,endColumn(packed)); }
            const uint32_t width = static_cast<uint32_t>(std::lround((end-start)*row_cell_width));
            const uint32_t height = static_cast<uint32_t>(std::lround(row_cell_height));
            const LayoutKeyView key{item.text,width,height,static_cast<uint8_t>((item.bold?1:0)|(item.italic?2:0))};
            auto found = layouts.find(key);
            if (found == layouts.end() || !found->second.plan ||
                !matchesNormalizedColumns(found->second.plan->columns,item.columns,start) ||
                found->second.plan->cell_width != row_cell_width || found->second.plan->cell_height != row_cell_height) { batched=false; break; }
            if (benchmark_active) ++benchmark.resolved_plan_hits;
            for (auto& owned : found->second.plan->runs) {
                if (!rasterize(owned)) { batched=false; break; }
                const auto& placement = owned.placement;
                if (placement.empty) continue;
                const float baseline_x = row_origin_x + start * row_cell_width + owned.origin_x;
                const float baseline_y = row_top + owned.origin_y;
                if (!std::isfinite(baseline_x) || !std::isfinite(baseline_y) ||
                    baseline_x != std::floor(baseline_x) || baseline_y != std::floor(baseline_y)) { batched=false; break; }
                const D2D1_RECT_F destination{baseline_x + placement.left, baseline_y + placement.top,
                    baseline_x + placement.left + placement.width, baseline_y + placement.top + placement.height};
                // Direct2D SpriteBatch does not define painter order for overlapping
                // sprites. D3D11 preserves primitive order through blending, so the
                // instanced path can retain shaping order without this quadratic scan.
                if (benchmark_legacy_sprite_batch) {
                    for (const auto& prior : destinations) if (destination.left < prior.right && destination.right > prior.left &&
                        destination.top < prior.bottom && destination.bottom > prior.top) { batched=false; break; }
                    if (!batched) break;
                }
                destinations.push_back(destination); sources.push_back(placement.source); colors.push_back(color(item.foreground));
            }
            if (!batched) break;
        }
    } catch (...) { batched=false; }
    // Submit all population commands for this row before either context samples
    // the atlas or native fallback is recorded on the scene context.
    if (atlas_draw_active && FAILED(endAtlasDraw())) {
        batched = false;
        atlas_disabled_for_frame = true;
    }
    const size_t row_instance_start=glyph_instances.size();
    if (batched && destinations.empty()) {
        if (benchmark_active) ++benchmark.atlas_batched_rows;
    } else if (batched) {
        if (benchmark_legacy_sprite_batch) {
            const UINT32 count=static_cast<UINT32>(destinations.size());
            if (destinations.size()>UINT32_MAX-sprite_count || sprite_batch->GetSpriteCount()!=sprite_count)
                { batched=false; atlas_disabled_for_frame=true; goto native_fallback; }
            hr=sprite_batch->AddSprites(count,destinations.data(),sources.data(),colors.data(),nullptr,
                sizeof(D2D1_RECT_F),sizeof(D2D1_RECT_U),sizeof(D2D1_COLOR_F),0);
            if (FAILED(hr)) { batched=false; atlas_disabled_for_frame=true; goto native_fallback; }
            const auto previous_antialias=target3->GetAntialiasMode();
            const auto previous_blend=target3->GetPrimitiveBlend();
            target3->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
            target3->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
            clip_guard.push();
            setTag(frame_command_row_sprite);
            target3->DrawSpriteBatch(sprite_batch,sprite_count,count,atlas_bitmap,
                D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,D2D1_SPRITE_OPTIONS_NONE);
            clip_guard.pop();
            target3->SetPrimitiveBlend(previous_blend); target3->SetAntialiasMode(previous_antialias);
            sprite_count+=count;
            if (benchmark_active) { ++benchmark.atlas_batched_rows; ++benchmark.atlas_sprite_batches; benchmark.atlas_sprites+=count; }
            goto row_complete;
        }
        try { for (size_t index=0; index<destinations.size(); ++index) {
            const auto& d=destinations[index]; const auto& s=sources[index]; const auto& c=colors[index];
            GlyphInstance instance{{d.left,d.top,d.right,d.bottom},
                {s.left/static_cast<float>(atlas_extent),s.top/static_cast<float>(atlas_extent),
                 s.right/static_cast<float>(atlas_extent),s.bottom/static_cast<float>(atlas_extent)},
                {c.r,c.g,c.b,c.a},{0,row_top,static_cast<float>(scene_width),row_top+row_cell_height},
                {static_cast<float>(scene_width),static_cast<float>(scene_height),0,0}};
            glyph_instances.push_back(instance);
            // Fail after a real partial append so rollback and native fallback
            // prove that no prefix can later be blended a second time.
            if (test_fault == TestFault::instance_append && index == 0) throw std::bad_alloc();
        }} catch (...) { glyph_instances.resize(row_instance_start); batched=false; atlas_disabled_for_frame=true; goto native_fallback; }
        if (benchmark_active) ++benchmark.atlas_batched_rows;
    }
native_fallback:
    if (!batched) {
        hr=flushGlyphInstances();
        if (FAILED(hr)) return hr;
        if (atlas_eligible && benchmark_active) ++benchmark.atlas_fallback_rows;
        clip_guard.push();
        for (const int64_t ordered : order) {
            if (ordered >= 0) hr = drawSegment(segments[static_cast<size_t>(ordered)]);
            else {
                const auto& cell=row_cells[static_cast<size_t>(-1-ordered)];
                ID2D1Bitmap* bitmap=nullptr;
                const uint32_t span=cell.occupancy == ZIGONAUT_CELL_WIDE ? 2u : 1u;
                hr=getBuiltinBitmap(cell.builtin_codepoint,cell.builtin_width,cell.builtin_height,
                    span,cell.builtin_mask.data(),cell.builtin_stride,&bitmap);
                if (SUCCEEDED(hr)) {
                    brush->SetColor(color(cell.foreground));
                    const float left=row_origin_x+cell.column*row_cell_width;
                    const auto aa=target->GetAntialiasMode();
                    setTag(frame_command_row_builtin, cell.builtin_codepoint);
                    target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
                    target->FillOpacityMask(bitmap,brush,
                        D2D1::RectF(left,row_top,left+cell.builtin_width,row_top+cell.builtin_height),
                        D2D1::RectF(0,0,static_cast<float>(cell.builtin_width),static_cast<float>(cell.builtin_height)));
                    target->SetAntialiasMode(aa);
                }
            }
            if (FAILED(hr)) return hr;
        }
        clip_guard.pop();
    }
row_complete:
    for (const auto& cell : row_cells) {
        if (!cell.strikethrough) continue;
        hr=flushGlyphInstances();
        if (FAILED(hr)) return hr;
        const float left = row_origin_x +
            static_cast<float>(cell.column) * row_cell_width;
        const float y = row_top + row_cell_height * 0.55f;
        brush->SetColor(color(cell.foreground));
        setTag(frame_command_row_strikethrough);
        target->DrawLine(
            D2D1::Point2F(left, y),
            D2D1::Point2F(left + row_cell_width, y),
            brush,
            1.0f);
    }
    row_cells.clear();
    return S_OK;
}

extern "C" HRESULT zigonaut_text_engine_create(
    const wchar_t* font_family,
    uint32_t font_size,
    uint16_t font_weight,
    uint16_t intense_font_weight,
    uint16_t line_height_percent,
    uint32_t dpi,
    int32_t antialiasing,
    ZigonautTextEngine** result) {
    if (font_family == nullptr || result == nullptr || font_size == 0 ||
        font_weight < 1 || font_weight > 999 || intense_font_weight < 1 ||
        intense_font_weight > 999 || line_height_percent < 75 ||
        line_height_percent > 200 || dpi == 0 ||
        (antialiasing != ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE &&
            antialiasing != ZIGONAUT_TEXT_AA_NATIVE_CLEARTYPE)) {
        return E_INVALIDARG;
    }
    *result = nullptr;

    auto* engine = new (std::nothrow) ZigonautTextEngine();
    if (engine == nullptr) return E_OUTOFMEMORY;
    engine->font_size = font_size;
    engine->font_weight = static_cast<DWRITE_FONT_WEIGHT>(font_weight);
    engine->intense_font_weight = static_cast<DWRITE_FONT_WEIGHT>(intense_font_weight);
    engine->line_height_percent = line_height_percent;
    engine->dpi = dpi;
    engine->text_antialiasing = static_cast<ZigonautTextAntialiasing>(antialiasing);
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

extern "C" HRESULT zigonaut_text_engine_set_symbol_fallback(
    ZigonautTextEngine* engine,
    const wchar_t* font_family) {
    if (engine == nullptr) return E_INVALIDARG;
    return engine->setSymbolFallback(font_family);
}

extern "C" HRESULT zigonaut_benchmark_layout_cache(
    uint32_t repetitions,
    ZigonautLayoutCacheBenchmark* result) {
    if (repetitions == 0 || result == nullptr) return E_INVALIDARG;
    *result = {};
    ZigonautTextEngine* engine = nullptr;
    HRESULT hr = zigonaut_text_engine_create(L"Consolas", 18,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_BOLD, 100, 96,
        ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
    if (FAILED(hr)) return hr;

    // Fill to capacity, make the final 248 entries hot, cross capacity, then
    // reuse them. Clear-all creates 2,596 layouts per repetition; bounded LRU
    // creates only the 2,348 distinct layouts.
    constexpr uint32_t cold_count = 1800;
    constexpr uint32_t hot_count = 248;
    constexpr uint32_t overflow_count = 300;
    for (uint32_t repetition = 0; repetition < repetitions; ++repetition) {
        engine->clearLayouts();
        for (uint32_t index = 0; index < cold_count + hot_count; ++index) {
            const std::u16string text = numberedLayoutText(u"layout-", index);
            IDWriteTextLayout* layout = nullptr;
            hr = engine->layoutFor(text.data(), text.size(), 720, 20, 0, &layout);
            if (FAILED(hr)) break;
        }
        for (uint32_t index = cold_count; SUCCEEDED(hr) && index < cold_count + hot_count; ++index) {
            const std::u16string text = numberedLayoutText(u"layout-", index);
            IDWriteTextLayout* layout = nullptr;
            hr = engine->layoutFor(text.data(), text.size(), 720, 20, 0, &layout);
        }
        for (uint32_t index = 0; SUCCEEDED(hr) && index < overflow_count; ++index) {
            const std::u16string text = numberedLayoutText(u"overflow-", index);
            IDWriteTextLayout* layout = nullptr;
            hr = engine->layoutFor(text.data(), text.size(), 720, 20, 0, &layout);
        }
        const uint64_t before_hot_reuse = engine->layout_creation_count;
        for (uint32_t index = cold_count; SUCCEEDED(hr) && index < cold_count + hot_count; ++index) {
            const std::u16string text = numberedLayoutText(u"layout-", index);
            IDWriteTextLayout* layout = nullptr;
            hr = engine->layoutFor(text.data(), text.size(), 720, 20, 0, &layout);
        }
        result->hot_reuse_creations += engine->layout_creation_count - before_hot_reuse;
        if (FAILED(hr)) break;
    }
    result->layout_creations = engine->layout_creation_count;
    result->cache_entries = static_cast<uint32_t>(engine->layouts.size());
    zigonaut_text_engine_destroy(engine);
    return hr;
}

extern "C" HRESULT zigonaut_benchmark_directwrite_pipeline(
    ZigonautDirectWriteBenchmark* result) {
    if (result == nullptr) return E_INVALIDARG;
    *result = {};
    LARGE_INTEGER frequency{};
    if (!QueryPerformanceFrequency(&frequency)) return HRESULT_FROM_WIN32(GetLastError());
    const auto now = [&]() -> uint64_t {
        LARGE_INTEGER value{};
        QueryPerformanceCounter(&value);
        return static_cast<uint64_t>(value.QuadPart);
    };
    const auto nanoseconds = [&](uint64_t ticks) -> uint64_t {
        return ticks * 1000000000ull / static_cast<uint64_t>(frequency.QuadPart);
    };

    // A real, private target gives monitor rendering-parameter lookup a valid
    // window without exposing benchmark UI or depending on the application shell.
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"STATIC", L"Zigonaut DirectWrite benchmark", WS_POPUP,
        0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (window == nullptr) return HRESULT_FROM_WIN32(GetLastError());
    ZigonautTextEngine* engine = nullptr;
    HRESULT hr = zigonaut_text_engine_create(L"Consolas", 18,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_BOLD, 100, 96,
        ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_set_window(engine,
        reinterpret_cast<uintptr_t>(window));
    if (FAILED(hr)) {
        zigonaut_text_engine_destroy(engine);
        DestroyWindow(window);
        return hr;
    }
    constexpr uint32_t width = 1920, height = 1080, columns = 120;
    BOOL rebuild = FALSE;
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_begin_frame(engine, width, height,
        0x181818, TRUE, &rebuild);

    const auto row = [&](bool fragmented, float top = 0.0f) -> HRESULT {
        engine->beginRow(0.0f, top,
            static_cast<float>(engine->metrics.width),
            static_cast<float>(engine->metrics.height));
        for (uint32_t column = 0; column < columns; ++column) {
            const uint16_t character = static_cast<uint16_t>(u'a' + column % 26);
            const uint32_t foreground = fragmented
                ? (0x4040ffu + (column * 0x010701u)) & 0xffffffu
                : 0xe0e0e0u;
            const HRESULT draw = engine->drawCell(&character, 1,
                static_cast<float>(column * engine->metrics.width), top,
                static_cast<float>(engine->metrics.width),
                static_cast<float>(engine->metrics.height), foreground, 0x181818,
                foreground, false, false, false, false, false, 0,
                ZIGONAUT_CELL_NARROW);
            if (FAILED(draw)) return draw;
        }
        return engine->endRow();
    };
    if (SUCCEEDED(hr)) {
        // Resolve layouts, glyph shaping, renderer buffers and D2D state first.
        for (uint32_t index = 0; index < 20 && SUCCEEDED(hr); ++index) hr = row(false);
        for (uint32_t index = 0; index < 4 && SUCCEEDED(hr); ++index) hr = row(true);
    }
    engine->benchmark = {};
    engine->benchmark_active = SUCCEEDED(hr);
    const auto measureRows = [&](uint32_t count, bool fragmented, uint64_t* elapsed) {
        const uint64_t start = now();
        for (uint32_t index = 0; index < count && SUCCEEDED(hr); ++index) hr = row(fragmented);
        *elapsed = nanoseconds(now() - start);
    };
    if (SUCCEEDED(hr)) measureRows(1500, false, &engine->benchmark.warm_row_nanoseconds);
    if (SUCCEEDED(hr)) {
        const uint64_t attempts = engine->benchmark.color_translate_attempts;
        const uint64_t successes = engine->benchmark.color_translate_successes;
        measureRows(1500, false, &engine->benchmark.monochrome_row_nanoseconds);
        engine->benchmark.monochrome_translate_attempts =
            engine->benchmark.color_translate_attempts - attempts;
        engine->benchmark.monochrome_translate_successes =
            engine->benchmark.color_translate_successes - successes;
    }
    const uint64_t before_uniform_submissions = engine->benchmark.glyph_submissions;
    if (SUCCEEDED(hr)) measureRows(400, false, &engine->benchmark.uniform_row_nanoseconds);
    engine->benchmark.uniform_native_glyph_submissions =
        engine->benchmark.glyph_submissions - before_uniform_submissions;
    if (SUCCEEDED(hr)) {
        const uint64_t hits = engine->benchmark.resolved_plan_hits;
        const uint64_t misses = engine->benchmark.resolved_plan_misses;
        const uint64_t submissions = engine->benchmark.glyph_submissions;
        measureRows(400, true, &engine->benchmark.fragmented_row_nanoseconds);
        engine->benchmark.fragmented_plan_hits = engine->benchmark.resolved_plan_hits - hits;
        engine->benchmark.fragmented_plan_misses = engine->benchmark.resolved_plan_misses - misses;
        engine->benchmark.fragmented_native_glyph_submissions =
            engine->benchmark.glyph_submissions - submissions;
    }
    engine->benchmark.warm_row_iterations = 1500;
    engine->benchmark.monochrome_row_iterations = 1500;
    engine->benchmark.uniform_row_iterations = 400;
    engine->benchmark.fragmented_row_iterations = 400;

    if (engine != nullptr && engine->frame_active) {
        HRESULT draw_hr = engine->flushGlyphInstances();
        if (SUCCEEDED(draw_hr)) draw_hr = engine->target->EndDraw();
        engine->frame_active = false;
        if (SUCCEEDED(hr)) hr = draw_hr;
    }
    constexpr uint32_t copies = 80;
    if (SUCCEEDED(hr)) {
        // Time the caller-thread cost of issuing endFrame's CopyResource path.
        // No GPU-completion query, frame-latency wait, or Present is included.
        for (uint32_t index = 0; index < 10 && SUCCEEDED(hr); ++index) {
            hr = engine->transferScene();
        }
        const uint64_t copy_count = engine->d3d_scene_copy_count;
        const uint64_t start = now();
        for (uint32_t index = 0; index < copies && SUCCEEDED(hr); ++index) {
            hr = engine->transferScene();
        }
        engine->benchmark.scene_copy_nanoseconds = nanoseconds(now() - start);
        engine->benchmark.scene_copy_d3d11_copies =
            engine->d3d_scene_copy_count - copy_count;
    }
    D3D11_BOX row_box{0, 0, 0, width, engine->metrics.height, 1};
    if (SUCCEEDED(hr)) {
        engine->damage_history_valid = true;
        engine->previous_present_damage.clear();
        engine->frame_damage.clear();
        engine->addDamage(engine->frame_damage, row_box.left, row_box.top,
            row_box.right, row_box.bottom);
        for (uint32_t index = 0; index < 10 && SUCCEEDED(hr); ++index)
            hr = engine->transferScene();
        const uint64_t copy_count = engine->d3d_scene_region_copy_count;
        const uint64_t copy_bytes = engine->d3d_scene_region_copy_bytes;
        const uint64_t start = now();
        for (uint32_t index = 0; index < copies && SUCCEEDED(hr); ++index)
            hr = engine->transferScene();
        engine->benchmark.scene_region_copy_nanoseconds = nanoseconds(now() - start);
        engine->benchmark.scene_region_copy_d3d11_copies = static_cast<uint32_t>(
            engine->d3d_scene_region_copy_count - copy_count);
        engine->benchmark.scene_region_copy_bytes =
            engine->d3d_scene_region_copy_bytes - copy_bytes;
    }
    const auto measureGpuCopies = [&](bool region, uint64_t* elapsed) -> HRESULT {
        D3D11_QUERY_DESC description{};
        ID3D11Query* disjoint = nullptr;
        ID3D11Query* start_query = nullptr;
        ID3D11Query* end_query = nullptr;
        description.Query = D3D11_QUERY_TIMESTAMP_DISJOINT;
        HRESULT value = engine->d3d_device->CreateQuery(&description, &disjoint);
        description.Query = D3D11_QUERY_TIMESTAMP;
        if (SUCCEEDED(value)) value = engine->d3d_device->CreateQuery(&description, &start_query);
        if (SUCCEEDED(value)) value = engine->d3d_device->CreateQuery(&description, &end_query);
        if (SUCCEEDED(value)) {
            engine->d3d_context->Begin(disjoint);
            engine->d3d_context->End(start_query);
            for (uint32_t index = 0; index < copies; ++index) {
                if (region) {
                    engine->d3d_context->CopySubresourceRegion(engine->backbuffer_texture, 0,
                        0, 0, 0, engine->scene_texture, 0, &row_box);
                } else {
                    engine->d3d_context->CopyResource(engine->backbuffer_texture,
                        engine->scene_texture);
                }
            }
            engine->d3d_context->End(end_query);
            engine->d3d_context->End(disjoint);
            engine->d3d_context->Flush();
            const uint64_t deadline = now() + static_cast<uint64_t>(frequency.QuadPart) * 5;
            const auto waitForQuery = [&](ID3D11Query* query, void* data,
                    UINT size) -> HRESULT {
                while (true) {
                    const HRESULT query_result = engine->d3d_context->GetData(
                        query, data, size, 0);
                    if (query_result == S_OK) return S_OK;
                    if (FAILED(query_result)) return query_result;
                    const HRESULT removed = engine->d3d_device->GetDeviceRemovedReason();
                    if (FAILED(removed)) return removed;
                    if (now() >= deadline) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
                    SwitchToThread();
                }
            };
            UINT64 start_ticks = 0, end_ticks = 0;
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT timing{};
            value = waitForQuery(end_query, &end_ticks, sizeof(end_ticks));
            if (SUCCEEDED(value)) value = waitForQuery(start_query,
                &start_ticks, sizeof(start_ticks));
            if (SUCCEEDED(value)) value = waitForQuery(disjoint, &timing,
                sizeof(timing));
            if (SUCCEEDED(value)) {
                if (timing.Disjoint || timing.Frequency == 0 || end_ticks < start_ticks) {
                    value = E_FAIL;
                } else {
                    *elapsed = static_cast<uint64_t>(
                        static_cast<long double>(end_ticks - start_ticks) *
                        1000000000.0L / timing.Frequency);
                }
            }
        }
        release(end_query);
        release(start_query);
        release(disjoint);
        return value;
    };
    engine->benchmark.scene_copy_iterations = copies;
    engine->benchmark.scene_width = width;
    engine->benchmark.scene_height = height;
    engine->benchmark.scene_region_height = engine->metrics.height;
    engine->benchmark_active = false;
    constexpr uint32_t frame_rows = 40;
    const auto fragmentedFrames = [&](bool legacy, uint32_t count, uint64_t* elapsed) {
        engine->benchmark_legacy_sprite_batch=legacy;
        const uint64_t start=now();
        for (uint32_t iteration=0; iteration<count && SUCCEEDED(hr); ++iteration) {
            hr=zigonaut_text_engine_begin_frame(engine,width,height,0x181818,TRUE,&rebuild);
            for (uint32_t index=0; index<frame_rows && SUCCEEDED(hr); ++index)
                hr=row(true,static_cast<float>(index*engine->metrics.height));
            if (SUCCEEDED(hr)) hr=engine->flushGlyphInstances();
            if (SUCCEEDED(hr)) hr=engine->target->EndDraw();
            engine->frame_active=false; engine->target->SetTarget(nullptr);
        }
        *elapsed=nanoseconds(now()-start);
    };
    constexpr uint32_t frame_iterations=20;
    uint64_t ignored=0;
    if (SUCCEEDED(hr)) fragmentedFrames(true,3,&ignored);
    if (SUCCEEDED(hr)) fragmentedFrames(false,3,&ignored);
    if (SUCCEEDED(hr)) fragmentedFrames(true,frame_iterations,&engine->benchmark.legacy_fragmented_frame_nanoseconds);
    const uint64_t slot_uses=engine->glyph_slot_uses;
    const uint64_t slot_wraps=engine->glyph_slot_wraps;
    const uint64_t buffer_creations=engine->glyph_buffer_creations;
    const uint64_t capacity_growths=engine->glyph_capacity_growths;
    // Alternate order so transient machine load and queued GPU work affect both
    // upload strategies evenly within this same-invocation comparison.
    for (uint32_t iteration=0; iteration<frame_iterations && SUCCEEDED(hr); ++iteration) {
        for (uint32_t pass=0; pass<2 && SUCCEEDED(hr); ++pass) {
            const bool immutable=((iteration+pass)&1)==0;
            engine->benchmark_immutable_instances=immutable;
            uint64_t elapsed=0; fragmentedFrames(false,1,&elapsed);
            if (immutable) engine->benchmark.immutable_instance_frame_nanoseconds+=elapsed;
            else engine->benchmark.dynamic_instance_frame_nanoseconds+=elapsed;
        }
    }
    engine->benchmark_immutable_instances=false;
    engine->benchmark.instanced_fragmented_frame_nanoseconds=engine->benchmark.dynamic_instance_frame_nanoseconds;
    engine->benchmark.glyph_slot_uses=engine->glyph_slot_uses-slot_uses;
    engine->benchmark.glyph_slot_wraps=engine->glyph_slot_wraps-slot_wraps;
    engine->benchmark.glyph_buffer_creations=engine->glyph_buffer_creations-buffer_creations;
    engine->benchmark.glyph_capacity_growths=engine->glyph_capacity_growths-capacity_growths;
    engine->benchmark_legacy_sprite_batch=false;
    engine->benchmark.atlas_warm_frame_nanoseconds=engine->benchmark.instanced_fragmented_frame_nanoseconds/frame_iterations;
    engine->benchmark.fragmented_frame_iterations=frame_iterations;
    engine->benchmark.atlas_warm_frame_rows = frame_rows;

#if defined(ZIGONAUT_BENCHMARK_PRESENT)
    // Exercise both glyph backends through the production frame-latency wait,
    // retained-scene transfer, nonblocking Present, and retry path. A real
    // DirectComposition target is required: an unattached composition swap chain
    // is not consumed by DWM and therefore cannot provide representative pacing.
    // Keep this on a separate engine so its paced GPU/resource state cannot
    // perturb the deterministic unpaced baselines that follow it.
    ZigonautTextEngine* pipeline_engine = engine;
    ZigonautTextEngine* paced_engine = nullptr;
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_create(L"Consolas", 18,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_BOLD, 100, 96,
        ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &paced_engine);
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_set_window(paced_engine,
        reinterpret_cast<uintptr_t>(window));
    if (SUCCEEDED(hr)) engine = paced_engine;
    IDCompositionDevice* composition_device = nullptr;
    IDCompositionTarget* composition_target = nullptr;
    IDCompositionVisual* composition_visual = nullptr;
    IDXGIDevice* composition_dxgi_device = nullptr;
    if (SUCCEEDED(hr)) hr = engine->d3d_device->QueryInterface(
        IID_PPV_ARGS(&composition_dxgi_device));
    if (SUCCEEDED(hr)) hr = DCompositionCreateDevice(composition_dxgi_device,
        IID_PPV_ARGS(&composition_device));
    if (SUCCEEDED(hr)) hr = composition_device->CreateTargetForHwnd(window, TRUE,
        &composition_target);
    if (SUCCEEDED(hr)) hr = composition_device->CreateVisual(&composition_visual);
    if (SUCCEEDED(hr)) hr = composition_visual->SetContent(engine->swap_chain);
    if (SUCCEEDED(hr)) hr = composition_target->SetRoot(composition_visual);
    if (SUCCEEDED(hr)) hr = composition_device->Commit();
    if (SUCCEEDED(hr)) hr = composition_device->WaitForCommitCompletion();
    if (SUCCEEDED(hr)) ShowWindow(window, SW_SHOWNOACTIVATE);

    constexpr uint32_t paced_warm_frames = 3;
    constexpr uint32_t paced_frame_iterations = 30;
    std::vector<uint64_t> legacy_paced_samples;
    std::vector<uint64_t> instanced_paced_samples;
    try {
        legacy_paced_samples.reserve(paced_frame_iterations);
        instanced_paced_samples.reserve(paced_frame_iterations);
    } catch (...) {
        hr = E_OUTOFMEMORY;
    }
    bool pending_backend_valid = false;
    bool pending_backend_legacy = false;
    bool pending_backend_measured = false;
    const auto waitForPacedFrame = [&]() {
        const uint64_t wait_start = now();
        const DWORD wait = WaitForSingleObject(engine->frame_latency_waitable_object, 5000);
        const uint64_t wait_elapsed = nanoseconds(now() - wait_start);
        if (wait != WAIT_OBJECT_0) {
            hr = wait == WAIT_FAILED ? HRESULT_FROM_WIN32(GetLastError()) : HRESULT_FROM_WIN32(WAIT_TIMEOUT);
            return;
        }
        // This signal releases the previously presented frame, not the frame
        // about to be rendered. Attribute its wait to that preceding backend.
        if (pending_backend_valid && pending_backend_measured) {
            if (pending_backend_legacy)
                engine->benchmark.paced_legacy_wait_nanoseconds += wait_elapsed;
            else
                engine->benchmark.paced_instanced_wait_nanoseconds += wait_elapsed;
        }
        pending_backend_valid = false;
    };
    const auto pacedFrame = [&](bool legacy, bool measured) {
        waitForPacedFrame();
        if (FAILED(hr)) return;
        engine->benchmark_legacy_sprite_batch = legacy;
        const uint64_t submit_start = now();
        hr = zigonaut_text_engine_begin_frame(engine, width, height, 0x181818,
            TRUE, &rebuild);
        for (uint32_t index = 0; index < frame_rows && SUCCEEDED(hr); ++index)
            hr = row(true, static_cast<float>(index * engine->metrics.height));
        if (SUCCEEDED(hr)) hr = zigonaut_text_engine_end_frame(engine);
        uint32_t retries = 0;
        const uint64_t retry_deadline = now() + static_cast<uint64_t>(frequency.QuadPart) * 5;
        while (hr == S_FALSE && now() < retry_deadline) {
            ++retries;
            SwitchToThread();
            hr = zigonaut_text_engine_retry_present(engine);
        }
        if (hr == S_FALSE) hr = HRESULT_FROM_WIN32(WAIT_TIMEOUT);
        const uint64_t submit_elapsed = nanoseconds(now() - submit_start);
        if (!measured || FAILED(hr)) return;
        auto& samples = legacy ? legacy_paced_samples : instanced_paced_samples;
        samples.push_back(submit_elapsed);
        pending_backend_valid = true;
        pending_backend_legacy = legacy;
        pending_backend_measured = measured;
        if (legacy) {
            engine->benchmark.paced_legacy_present_retries += retries;
        } else {
            engine->benchmark.paced_instanced_present_retries += retries;
        }
    };
    for (uint32_t iteration = 0; iteration < paced_warm_frames && SUCCEEDED(hr); ++iteration) {
        pacedFrame(true, false);
        if (SUCCEEDED(hr)) pacedFrame(false, false);
    }
    // Alternate first backend so thermal/transient load is distributed evenly.
    for (uint32_t iteration = 0; iteration < paced_frame_iterations && SUCCEEDED(hr); ++iteration) {
        const bool legacy_first = (iteration & 1) == 0;
        pacedFrame(legacy_first, true);
        if (SUCCEEDED(hr)) pacedFrame(!legacy_first, true);
    }
    // Drain and attribute the last measured Present before detaching the visual
    // or allowing later unpaced benchmarks to submit more GPU work.
    if (SUCCEEDED(hr) && pending_backend_valid) waitForPacedFrame();
    const auto summarizePaced = [&](std::vector<uint64_t>& samples,
            uint64_t* total, uint64_t* p95) {
        for (const uint64_t sample : samples) *total += sample;
        std::sort(samples.begin(), samples.end());
        if (!samples.empty()) {
            const size_t index = (samples.size() * 95 + 99) / 100 - 1;
            *p95 = samples[std::min(index, samples.size() - 1)];
        }
    };
    summarizePaced(legacy_paced_samples,
        &engine->benchmark.paced_legacy_submit_nanoseconds,
        &engine->benchmark.paced_legacy_submit_p95_nanoseconds);
    summarizePaced(instanced_paced_samples,
        &engine->benchmark.paced_instanced_submit_nanoseconds,
        &engine->benchmark.paced_instanced_submit_p95_nanoseconds);
    engine->benchmark.paced_frame_iterations = static_cast<uint32_t>(
        std::min(legacy_paced_samples.size(), instanced_paced_samples.size()));
    engine->benchmark_legacy_sprite_batch = false;
    HRESULT detach_hr = S_OK;
    if (composition_target != nullptr) detach_hr = composition_target->SetRoot(nullptr);
    if (SUCCEEDED(detach_hr) && composition_device != nullptr)
        detach_hr = composition_device->Commit();
    if (SUCCEEDED(detach_hr) && composition_device != nullptr)
        detach_hr = composition_device->WaitForCommitCompletion();
    if (SUCCEEDED(hr) && FAILED(detach_hr)) hr = detach_hr;
    release(composition_visual);
    release(composition_target);
    release(composition_device);
    release(composition_dxgi_device);
    ShowWindow(window, SW_HIDE);
    const ZigonautDirectWriteBenchmark paced_result = paced_engine != nullptr
        ? paced_engine->benchmark : ZigonautDirectWriteBenchmark{};
    zigonaut_text_engine_destroy(paced_engine);
    engine = pipeline_engine;
    engine->benchmark.paced_legacy_submit_nanoseconds = paced_result.paced_legacy_submit_nanoseconds;
    engine->benchmark.paced_instanced_submit_nanoseconds = paced_result.paced_instanced_submit_nanoseconds;
    engine->benchmark.paced_legacy_submit_p95_nanoseconds = paced_result.paced_legacy_submit_p95_nanoseconds;
    engine->benchmark.paced_instanced_submit_p95_nanoseconds = paced_result.paced_instanced_submit_p95_nanoseconds;
    engine->benchmark.paced_legacy_wait_nanoseconds = paced_result.paced_legacy_wait_nanoseconds;
    engine->benchmark.paced_instanced_wait_nanoseconds = paced_result.paced_instanced_wait_nanoseconds;
    engine->benchmark.paced_legacy_present_retries = paced_result.paced_legacy_present_retries;
    engine->benchmark.paced_instanced_present_retries = paced_result.paced_instanced_present_retries;
    engine->benchmark.paced_frame_iterations = paced_result.paced_frame_iterations;
#endif

    constexpr uint32_t scroll_iterations = 30;
    const auto scrollCase = [&](bool shifted, uint32_t count, uint64_t* elapsed) {
        const uint64_t start = now();
        for (uint32_t iteration = 0; iteration < count && SUCCEEDED(hr); ++iteration) {
            hr = zigonaut_text_engine_begin_frame(engine, width, height, 0x181818,
                shifted ? FALSE : TRUE, &rebuild);
            if (shifted && SUCCEEDED(hr)) hr = zigonaut_text_engine_shift_scene(engine,
                iteration & 1 ? -1 : 1, 0, 0, columns * engine->metrics.width,
                engine->metrics.height, frame_rows);
            const uint32_t first = shifted ? (iteration & 1 ? frame_rows - 1 : 0) : 0;
            const uint32_t count_rows = shifted ? 1 : frame_rows;
            for (uint32_t index = 0; index < count_rows && SUCCEEDED(hr); ++index)
                hr = row(true, static_cast<float>((first + index) * engine->metrics.height));
            if (SUCCEEDED(hr)) {
                hr = engine->flushGlyphInstances();
                if (SUCCEEDED(hr)) hr = engine->target->EndDraw();
                engine->frame_active = false;
                engine->target->SetTarget(nullptr);
            }
            if (SUCCEEDED(hr)) hr = engine->transferScene();
        }
        *elapsed = nanoseconds(now() - start);
    };
    // Warm both complete paths before measuring; each timed invocation includes
    // final scene transfer but excludes Present and GPU-completion waiting.
    if (SUCCEEDED(hr)) scrollCase(false, 3, &engine->benchmark.scroll_full_nanoseconds);
    if (SUCCEEDED(hr)) scrollCase(true, 3, &engine->benchmark.scroll_shift_nanoseconds);
    if (SUCCEEDED(hr)) scrollCase(false, scroll_iterations,
        &engine->benchmark.scroll_full_nanoseconds);
    if (SUCCEEDED(hr)) scrollCase(true, scroll_iterations,
        &engine->benchmark.scroll_shift_nanoseconds);
    engine->benchmark.scroll_iterations = scroll_iterations;
    if (SUCCEEDED(hr)) {
        // Plans stay hot while the atlas generation and resources start cold.
        // Include BeginDraw, lazy creation, rasterization/population, one fragmented
        // row submission, and EndDraw so population implementations are comparable.
        engine->invalidateAtlas();
        const ZigonautDirectWriteBenchmark measured = engine->benchmark;
        engine->benchmark = {};
        const uint64_t allocations = engine->atlas_resource_allocations;
        engine->benchmark_active = true;
        const uint64_t start = now();
        hr = zigonaut_text_engine_begin_frame(engine, width, height, 0x181818, TRUE, &rebuild);
        if (SUCCEEDED(hr)) hr = row(true);
        if (SUCCEEDED(hr)) {
            hr = engine->flushGlyphInstances();
            if (SUCCEEDED(hr)) hr = engine->target->EndDraw();
            engine->frame_active = false;
            engine->target->SetTarget(nullptr);
        }
        const uint64_t elapsed = nanoseconds(now() - start);
        engine->benchmark_active = false;
        const uint64_t rasterizations = engine->benchmark.atlas_rasterizations;
        const uint64_t uploads = engine->benchmark.atlas_uploads;
        engine->benchmark = measured;
        engine->benchmark.atlas_cold_frame_nanoseconds = elapsed;
        engine->benchmark.atlas_cold_rasterizations = rasterizations;
        engine->benchmark.atlas_cold_uploads = uploads;
        engine->benchmark.atlas_cold_resource_allocations = static_cast<uint32_t>(
            engine->atlas_resource_allocations - allocations);
    }
    // GPU timestamp copies run last so their bandwidth and explicit flush cannot
    // perturb the existing CPU-submission frame baselines above.
    if (SUCCEEDED(hr)) hr = measureGpuCopies(false,
        &engine->benchmark.scene_copy_gpu_nanoseconds);
    if (SUCCEEDED(hr)) hr = measureGpuCopies(true,
        &engine->benchmark.scene_region_copy_gpu_nanoseconds);
    // Run this command-submission A/B last: the legacy side deliberately records
    // 48,000 D2D fills and must not perturb the renderer and GPU copy baselines.
    constexpr uint32_t background_row_iterations = 400;
    const auto backgroundRow = [&]() -> HRESULT {
        engine->beginRow(0.0f, 0.0f, static_cast<float>(engine->metrics.width),
            static_cast<float>(engine->metrics.height));
        for (uint32_t column = 0; column < columns; ++column) {
            const uint16_t character = static_cast<uint16_t>(u'a' + column % 26);
            const HRESULT draw = engine->drawCell(&character, 1,
                static_cast<float>(column * engine->metrics.width), 0,
                static_cast<float>(engine->metrics.width),
                static_cast<float>(engine->metrics.height), 0xe0e0e0, 0x304050,
                0xe0e0e0, false, false, false, false, false, 0,
                ZIGONAUT_CELL_NARROW);
            if (FAILED(draw)) return draw;
        }
        return engine->endRow();
    };
    const auto measureBackgroundRows = [&](bool legacy, uint64_t* elapsed,
            uint64_t* fill_calls) {
        engine->benchmark_legacy_background_fills = legacy;
        const uint64_t calls = engine->background_fill_calls;
        const uint64_t start = now();
        for (uint32_t index = 0; index < background_row_iterations && SUCCEEDED(hr); ++index)
            hr = backgroundRow();
        *elapsed = nanoseconds(now() - start);
        *fill_calls = engine->background_fill_calls - calls;
    };
    if (SUCCEEDED(hr)) {
        hr = zigonaut_text_engine_begin_frame(engine, width, height, 0x181818,
            TRUE, &rebuild);
    }
    engine->benchmark_background_active = SUCCEEDED(hr);
    if (SUCCEEDED(hr)) measureBackgroundRows(true,
        &engine->benchmark.background_legacy_nanoseconds,
        &engine->benchmark.background_legacy_fill_calls);
    if (SUCCEEDED(hr)) measureBackgroundRows(false,
        &engine->benchmark.background_coalesced_nanoseconds,
        &engine->benchmark.background_coalesced_fill_calls);
    engine->benchmark_legacy_background_fills = false;
    engine->benchmark_background_active = false;
    engine->benchmark.background_row_iterations = background_row_iterations;
    if (engine->frame_active) {
        HRESULT background_hr = engine->target->EndDraw();
        engine->frame_active = false;
        engine->target->SetTarget(nullptr);
        if (SUCCEEDED(hr)) hr = background_hr;
    }
    engine->benchmark.atlas_extent = engine->atlas_extent;
    engine->benchmark.atlas_reserved_area = engine->atlas_reserved_area;
    engine->benchmark.atlas_rejected_area = engine->atlas_rejected_area;
    engine->benchmark.atlas_rejected_count = engine->atlas_rejected_count;
    engine->benchmark.atlas_pressure_resets = engine->atlas_pressure_resets;
    engine->benchmark.atlas_generation = engine->atlas_generation;
    engine->benchmark.atlas_resource_allocations = engine->atlas_resource_allocations;
    *result = engine->benchmark;
    zigonaut_text_engine_destroy(engine);
    DestroyWindow(window);
    return hr;
}

extern "C" HRESULT zigonaut_test_damage_aware_transfer(
    ZigonautDamageTransferTest* result) {
    if (result == nullptr) return E_INVALIDARG;
    *result = {};
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC",
        L"Zigonaut damage transfer test", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (window == nullptr) return HRESULT_FROM_WIN32(GetLastError());
    ZigonautTextEngine* engine = nullptr;
    HRESULT hr = zigonaut_text_engine_create(L"Consolas", 18,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_BOLD, 100, 96,
        ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_set_window(engine,
        reinterpret_cast<uintptr_t>(window));
    constexpr uint32_t width = 192;
    const uint32_t row_height = SUCCEEDED(hr) ? engine->metrics.height : 1;
    uint32_t height = row_height * 4;
    BOOL rebuild = FALSE;
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_begin_frame(engine, width, height,
        0x181818, TRUE, &rebuild);

    ID3D11Texture2D* buffers[2] = {};
    const auto createBuffers = [&]() -> HRESULT {
        D3D11_TEXTURE2D_DESC description{};
        engine->scene_texture->GetDesc(&description);
        HRESULT value = engine->d3d_device->CreateTexture2D(
            &description, nullptr, &buffers[0]);
        if (SUCCEEDED(value)) value = engine->d3d_device->CreateTexture2D(
            &description, nullptr, &buffers[1]);
        return value;
    };
    if (SUCCEEDED(hr)) hr = createBuffers();

    const auto equalTextures = [&](ID3D11Texture2D* left,
            ID3D11Texture2D* right) -> HRESULT {
        D3D11_TEXTURE2D_DESC description{};
        left->GetDesc(&description);
        description.Usage = D3D11_USAGE_STAGING;
        description.BindFlags = 0;
        description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        description.MiscFlags = 0;
        ID3D11Texture2D* staging_left = nullptr;
        ID3D11Texture2D* staging_right = nullptr;
        HRESULT value = engine->d3d_device->CreateTexture2D(
            &description, nullptr, &staging_left);
        if (SUCCEEDED(value)) value = engine->d3d_device->CreateTexture2D(
            &description, nullptr, &staging_right);
        if (SUCCEEDED(value)) {
            engine->d3d_context->CopyResource(staging_left, left);
            engine->d3d_context->CopyResource(staging_right, right);
            D3D11_MAPPED_SUBRESOURCE mapped_left{}, mapped_right{};
            value = engine->d3d_context->Map(staging_left, 0, D3D11_MAP_READ,
                0, &mapped_left);
            if (SUCCEEDED(value)) value = engine->d3d_context->Map(staging_right,
                0, D3D11_MAP_READ, 0, &mapped_right);
            if (SUCCEEDED(value)) {
                const size_t row_bytes = static_cast<size_t>(description.Width) * 4;
                for (uint32_t y = 0; y < description.Height; ++y) {
                    const auto* a = static_cast<const uint8_t*>(mapped_left.pData) +
                        y * mapped_left.RowPitch;
                    const auto* b = static_cast<const uint8_t*>(mapped_right.pData) +
                        y * mapped_right.RowPitch;
                    if (!std::equal(a, a + row_bytes, b)) {
                        value = E_FAIL;
                        break;
                    }
                }
            }
            if (mapped_right.pData != nullptr)
                engine->d3d_context->Unmap(staging_right, 0);
            if (mapped_left.pData != nullptr)
                engine->d3d_context->Unmap(staging_left, 0);
        }
        release(staging_right);
        release(staging_left);
        return value;
    };

    uint32_t buffer_index = 0;
    const auto finish = [&]() -> HRESULT {
        HRESULT value = engine->flushGlyphInstances();
        if (SUCCEEDED(value)) value = engine->target->EndDraw();
        engine->frame_active = false;
        if (SUCCEEDED(value)) value = engine->transferSceneTo(buffers[buffer_index]);
        if (SUCCEEDED(value)) value = equalTextures(buffers[buffer_index],
            engine->scene_texture);
        if (SUCCEEDED(value)) {
            engine->commitPresentedDamage();
            ++result->compared_frames;
            buffer_index ^= 1;
        }
        return value;
    };
    const auto begin = [&](bool full = false) -> HRESULT {
        return zigonaut_text_engine_begin_frame(engine, width, height, 0x181818,
            full ? TRUE : FALSE, &rebuild);
    };
    const auto paintRows = [&](uint32_t first, uint32_t count,
            uint32_t color_value) {
        zigonaut_text_engine_clear_rect(engine, 0.0f,
            static_cast<float>(first * row_height), static_cast<float>(width),
            static_cast<float>((first + count) * row_height), color_value);
    };
    const auto paintGlyphRow = [&]() -> HRESULT {
        engine->beginRow(0.0f, 0.0f, 12.0f, static_cast<float>(row_height));
        for (uint32_t column = 0; column < 16; ++column) {
            const uint16_t character = static_cast<uint16_t>(u'A' + column);
            const HRESULT value = engine->drawCell(&character, 1,
                static_cast<float>(column * 12), 0.0f, 12.0f,
                static_cast<float>(row_height),
                column & 1 ? 0x20e0e0 : 0xe020e0, 0x181818,
                0xe0e0e0, false, false, false, false, false, 0,
                ZIGONAUT_CELL_NARROW);
            if (FAILED(value)) return value;
        }
        return engine->endRow();
    };

    if (SUCCEEDED(hr)) hr = finish();                         // Seed buffer 0.
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) paintRows(0, 1, 0x202080);
    if (SUCCEEDED(hr)) hr = finish();                         // Seed buffer 1.
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) paintRows(1, 1, 0x208020);
    if (SUCCEEDED(hr)) hr = finish();                         // Adjacent history.
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) paintRows(3, 1, 0x802020);
    if (SUCCEEDED(hr)) hr = finish();                         // Disjoint history.
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) hr = finish();                         // Idle current damage.
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) paintRows(2, 1, 0x808020);
    if (SUCCEEDED(hr)) hr = finish();
    if (SUCCEEDED(hr)) hr = begin();
    bool glyph_paths_covered = false;
    if (SUCCEEDED(hr)) {
        engine->benchmark = {};
        engine->benchmark_active = true;
    }
    if (SUCCEEDED(hr)) hr = paintGlyphRow();               // Native glyph fallback.
    if (SUCCEEDED(hr)) hr = finish();
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) hr = paintGlyphRow();               // Atlas glyph path.
    if (SUCCEEDED(hr)) hr = finish();
    if (engine != nullptr) {
        engine->benchmark_active = false;
        glyph_paths_covered = engine->benchmark.atlas_fallback_rows > 0 &&
            engine->benchmark.atlas_batched_rows > 0;
    }

    // Adjacent-row equivalence: a full rebuild and a partial repaint of only
    // the upper row must be pixel-identical even when a combining mark can
    // vertically overhang into a contrasting lower-row background. Both draws
    // use populated placements and therefore execute production DrawInstanced.
    ID3D11Texture2D* adjacent_expected = nullptr;
    const auto paintOverhangRow = [&]() -> HRESULT {
        engine->beginRow(0.0f, 0.0f, 12.0f, static_cast<float>(row_height));
        static constexpr uint16_t text = u'g'; // descender exercises vertical overhang
        for (uint32_t column = 0; column < 16; ++column) {
            const uint32_t foreground = column & 1 ? 0xf0e020 : 0x20e0f0;
            const HRESULT value = engine->drawCell(&text, 1, static_cast<float>(column * 12),
                0.0f, 12.0f, static_cast<float>(row_height), foreground, 0x301020,
                foreground, false, false, false, false, false, 0, ZIGONAUT_CELL_NARROW);
            if (FAILED(value)) return value;
        }
        return engine->endRow();
    };
    const auto finishAdjacent = [&]() -> HRESULT {
        HRESULT value = engine->flushGlyphInstances();
        if (SUCCEEDED(value)) value = engine->target->EndDraw();
        engine->frame_active = false;
        engine->target->SetTarget(nullptr);
        return value;
    };
    if (engine) engine->benchmark_active = SUCCEEDED(hr);
    if (SUCCEEDED(hr)) hr = begin(true); // Resolve the combining-glyph plan first.
    if (SUCCEEDED(hr)) hr = paintOverhangRow();
    if (SUCCEEDED(hr)) hr = finishAdjacent();
    uint64_t adjacent_batches = engine ? engine->benchmark.atlas_sprite_batches : 0;
    // Build the reference with the old per-cell fill path, then compare it with
    // the production coalesced path below.
    if (engine) engine->benchmark_legacy_background_fills = true;
    if (SUCCEEDED(hr)) hr = begin(true);
    if (SUCCEEDED(hr)) paintRows(0, 1, 0x301020);
    if (SUCCEEDED(hr)) paintRows(1, 1, 0x1050a0);
    if (SUCCEEDED(hr)) hr = paintOverhangRow();
    if (SUCCEEDED(hr)) hr = finishAdjacent();
    if (SUCCEEDED(hr)) {
        D3D11_TEXTURE2D_DESC description{}; engine->scene_texture->GetDesc(&description);
        hr = engine->d3d_device->CreateTexture2D(&description, nullptr, &adjacent_expected);
        if (SUCCEEDED(hr)) engine->d3d_context->CopyResource(adjacent_expected, engine->scene_texture);
    }
    if (engine) engine->benchmark_legacy_background_fills = false;
    if (SUCCEEDED(hr)) hr = begin(false);
    if (SUCCEEDED(hr)) paintRows(0, 1, 0x301020);
    if (SUCCEEDED(hr)) hr = paintOverhangRow();
    if (SUCCEEDED(hr)) hr = finishAdjacent();
    if (SUCCEEDED(hr)) hr = equalTextures(adjacent_expected, engine->scene_texture);
    if (SUCCEEDED(hr) && engine->benchmark.atlas_sprite_batches < adjacent_batches + 2) hr = E_FAIL;
    if (engine) engine->benchmark_active = false;
    release(adjacent_expected);
    if (SUCCEEDED(hr)) hr = begin();
    if (SUCCEEDED(hr)) paintRows(0, 3, 0x204080);
    if (SUCCEEDED(hr)) hr = finish();                         // High-area fallback.

    // Verify both shift directions against independently fully repainted
    // textures. Four distinct row colors make reversed direction or an
    // off-by-one copy immediately visible.
    const uint32_t colors[4] = {0x201040, 0x204010, 0x401020, 0x404010};
    const auto paintFour = [&](const uint32_t values[4]) {
        for (uint32_t row_index = 0; row_index < 4; ++row_index)
            paintRows(row_index, 1, values[row_index]);
    };
    const auto saveExpected = [&](ID3D11Texture2D* destination) -> HRESULT {
        HRESULT value = engine->target->EndDraw();
        engine->frame_active = false;
        if (SUCCEEDED(value)) engine->d3d_context->CopyResource(destination,
            engine->scene_texture);
        return value;
    };
    if (SUCCEEDED(hr) && (engine->scene_shift_scratch == engine->scene_texture ||
            engine->scene_shift_scratch == buffers[0])) hr = E_FAIL;
    const uint32_t positive[4] = {0x102030, colors[0], colors[1], colors[2]};
    if (SUCCEEDED(hr)) hr = begin(true);
    if (SUCCEEDED(hr)) paintFour(positive);
    if (SUCCEEDED(hr)) hr = saveExpected(buffers[0]);
    if (SUCCEEDED(hr)) hr = begin(true);
    if (SUCCEEDED(hr)) paintFour(colors);
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_shift_scene(engine, 1, 0, 0,
        width, row_height, 4);
    if (SUCCEEDED(hr)) paintRows(0, 1, positive[0]);
    if (SUCCEEDED(hr)) {
        hr = engine->target->EndDraw();
        engine->frame_active = false;
    }
    if (SUCCEEDED(hr)) hr = equalTextures(buffers[0], engine->scene_texture);
    if (SUCCEEDED(hr) && !engine->frame_damage.full) hr = E_FAIL;

    const uint32_t negative[4] = {colors[1], colors[2], colors[3], 0x302010};
    if (SUCCEEDED(hr)) hr = begin(true);
    if (SUCCEEDED(hr)) paintFour(negative);
    if (SUCCEEDED(hr)) hr = saveExpected(buffers[1]);
    if (SUCCEEDED(hr)) hr = begin(true);
    if (SUCCEEDED(hr)) paintFour(colors);
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_shift_scene(engine, -1, 0, 0,
        width, row_height, 4);
    if (SUCCEEDED(hr)) paintRows(3, 1, negative[3]);
    if (SUCCEEDED(hr)) {
        hr = engine->target->EndDraw();
        engine->frame_active = false;
    }
    if (SUCCEEDED(hr)) hr = equalTextures(buffers[1], engine->scene_texture);
    if (SUCCEEDED(hr) && !engine->frame_damage.full) hr = E_FAIL;

    if (SUCCEEDED(hr)) {
        release(buffers[1]);
        release(buffers[0]);
        height += row_height;
        hr = begin();                                         // Resize resets history.
        if (SUCCEEDED(hr)) hr = createBuffers();
        if (SUCCEEDED(hr)) hr = finish();
    }
    if (engine != nullptr) {
        result->full_copies = static_cast<uint32_t>(engine->d3d_scene_full_copy_count);
        result->region_copies = static_cast<uint32_t>(engine->d3d_scene_region_copy_count);
        result->region_copy_bytes = engine->d3d_scene_region_copy_bytes;
    }
    if (SUCCEEDED(hr) && (result->compared_frames != 10 ||
            result->full_copies != 4 || result->region_copies != 8 ||
            !glyph_paths_covered ||
            result->region_copy_bytes != static_cast<uint64_t>(width) *
                row_height * 9 * 4)) hr = E_FAIL;
    if (engine != nullptr && engine->frame_active) engine->target->EndDraw();
    release(buffers[1]);
    release(buffers[0]);
    zigonaut_text_engine_destroy(engine);
    DestroyWindow(window);
    return hr;
}

extern "C" HRESULT zigonaut_test_atlas_policy_and_faults() {
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC",
        L"Zigonaut atlas policy test", WS_POPUP, 0, 0, 64, 64, nullptr, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (!window) return HRESULT_FROM_WIN32(GetLastError());
    HRESULT hr = S_OK;

    const auto create = [&](int32_t policy, ZigonautTextEngine** result) -> HRESULT {
        HRESULT value = zigonaut_text_engine_create(L"Consolas", 18, 400, 700, 100, 96,
            policy, result);
        if (SUCCEEDED(value)) value = zigonaut_text_engine_set_window(*result,
            reinterpret_cast<uintptr_t>(window));
        return value;
    };
    const auto begin = [&](ZigonautTextEngine* engine, uint32_t rows = 3,
            uint32_t background = 0x181818, uint32_t columns = 16) -> HRESULT {
        BOOL rebuild = FALSE;
        return zigonaut_text_engine_begin_frame(engine, engine->metrics.width * columns,
            engine->metrics.height * rows, background, TRUE, &rebuild);
    };
    const auto row = [&](ZigonautTextEngine* engine, float top, uint16_t first = u'A',
            float origin = 0.0f) -> HRESULT {
        engine->beginRow(origin, top, static_cast<float>(engine->metrics.width),
            static_cast<float>(engine->metrics.height));
        for (uint32_t column = 0; column < 16; ++column) {
            const uint16_t character = static_cast<uint16_t>(first + column % 16);
            // Alternating colors deliberately produce sixteen independently shaped segments.
            const uint32_t foreground = column % 2 ? 0x20ff20 : 0xff4040;
            const HRESULT value = engine->drawCell(&character, 1,
                origin + column * engine->metrics.width, top,
                static_cast<float>(engine->metrics.width), static_cast<float>(engine->metrics.height),
                foreground, 0x181818, foreground, false, false, false, false, false, 0,
                ZIGONAUT_CELL_NARROW);
            if (FAILED(value)) return value;
        }
        return engine->endRow();
    };
    const auto finish = [&](ZigonautTextEngine* engine) -> HRESULT {
        HRESULT value = engine->flushGlyphInstances();
        if (SUCCEEDED(value)) value = engine->target->EndDraw();
        engine->frame_active = false;
        engine->target->SetTarget(nullptr);
        return value;
    };
    const auto ink = [&](ZigonautTextEngine* engine, uint32_t top, uint32_t bottom,
            uint8_t background, uint64_t* count) -> HRESULT {
        *count = 0;
        D3D11_TEXTURE2D_DESC description{};
        engine->scene_texture->GetDesc(&description);
        description.Usage = D3D11_USAGE_STAGING;
        description.BindFlags = 0;
        description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        description.MiscFlags = 0;
        ID3D11Texture2D* staging = nullptr;
        HRESULT value = engine->d3d_device->CreateTexture2D(&description, nullptr, &staging);
        if (SUCCEEDED(value)) {
            engine->d3d_context->CopyResource(staging, engine->scene_texture);
            D3D11_MAPPED_SUBRESOURCE mapped{};
            value = engine->d3d_context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped);
            if (SUCCEEDED(value)) {
                for (uint32_t y = top; y < std::min(bottom, description.Height); ++y) {
                    const uint8_t* scan = static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch;
                    for (uint32_t x = 0; x < description.Width; ++x) {
                        const uint8_t* pixel = scan + x * 4;
                        if (pixel[0] != background || pixel[1] != background ||
                                pixel[2] != background) ++*count;
                    }
                }
                engine->d3d_context->Unmap(staging, 0);
            }
        }
        release(staging);
        return value;
    };
    const auto atlasHasPartialAlpha = [&](ZigonautTextEngine* engine, bool* partial) -> HRESULT {
        *partial = false;
        if (!engine->atlas_texture || engine->atlas_draw_active) return E_HANDLE;
        D3D11_TEXTURE2D_DESC description{}; engine->atlas_texture->GetDesc(&description);
        description.Usage = D3D11_USAGE_STAGING; description.BindFlags = 0;
        description.CPUAccessFlags = D3D11_CPU_ACCESS_READ; description.MiscFlags = 0;
        ID3D11Texture2D* staging = nullptr;
        HRESULT value = engine->d3d_device->CreateTexture2D(&description, nullptr, &staging);
        if (SUCCEEDED(value)) {
            engine->d3d_context->CopyResource(staging, engine->atlas_texture);
            D3D11_MAPPED_SUBRESOURCE mapped{};
            value = engine->d3d_context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped);
            if (SUCCEEDED(value)) {
                for (uint32_t y=0; y<description.Height && !*partial; ++y) {
                    const uint8_t* scan=static_cast<const uint8_t*>(mapped.pData)+y*mapped.RowPitch;
                    for (uint32_t x=0; x<description.Width; ++x)
                        if (scan[x*4+3] > 0 && scan[x*4+3] < 255) { *partial=true; break; }
                }
                engine->d3d_context->Unmap(staging, 0);
            }
        }
        release(staging); return value;
    };

    // Accelerated mode starts lazy, warms native plans, then really allocates,
    // rasterizes, populates, and submits the 1024 atlas on the second eligible row.
    {
        ZigonautTextEngine* engine = nullptr;
        if (SUCCEEDED(hr)) hr = create(ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
        if (SUCCEEDED(hr)) hr = begin(engine);
        if (SUCCEEDED(hr) && (engine->atlas_allocator || engine->atlas_bitmap || engine->atlas_texture ||
                engine->atlas_context || engine->atlas_brush || engine->sprite_batch || engine->target3)) hr = E_FAIL;
        if (SUCCEEDED(hr) && engine->target->GetTextAntialiasMode() != D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE) hr = E_FAIL;
        engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
        if (SUCCEEDED(hr)) hr = row(engine, 0);
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height));
        if (SUCCEEDED(hr)) hr = finish(engine);
        engine->benchmark_active = false;
        bool partial = false;
        if (SUCCEEDED(hr)) hr = atlasHasPartialAlpha(engine, &partial);
        D3D11_TEXTURE2D_DESC atlas_description{};
        if (engine->atlas_texture) engine->atlas_texture->GetDesc(&atlas_description);
        if (SUCCEEDED(hr) && (!engine->atlas_allocator || !engine->atlas_bitmap ||
                !engine->atlas_texture || !engine->atlas_context || !engine->atlas_brush ||
                !engine->sprite_batch || !engine->target3 || engine->atlas_extent != 1024 ||
                atlas_description.Width != 1024 || atlas_description.Height != 1024 ||
                atlas_description.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
                (atlas_description.BindFlags & (D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE)) !=
                    (D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE) ||
                engine->atlas_resource_allocations != 1 || engine->benchmark.atlas_sprite_batches == 0 ||
                engine->benchmark.atlas_sprites == 0 || !partial)) hr = E_FAIL;
        uint64_t changed = 0;
        if (SUCCEEDED(hr)) hr = ink(engine, 0, engine->metrics.height * 2, 0x18, &changed);
        if (SUCCEEDED(hr) && changed == 0) hr = E_FAIL;
        zigonaut_text_engine_destroy(engine);
    }
    if (FAILED(hr)) { DestroyWindow(window); return hr; }

    // ClearType always uses native whole-row drawing, even after repeated eligible rows.
    {
        ZigonautTextEngine* engine = nullptr;
        if (SUCCEEDED(hr)) hr = create(ZIGONAUT_TEXT_AA_NATIVE_CLEARTYPE, &engine);
        if (SUCCEEDED(hr)) hr = begin(engine);
        engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
        if (SUCCEEDED(hr)) hr = row(engine, 0);
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height));
        std::vector<uint8_t> mask(SUCCEEDED(hr)
            ? engine->metrics.width * engine->metrics.height
            : 1, 255);
        const uint64_t bitmap_creations = engine ? engine->builtin_bitmap_creations : 0;
        for (uint32_t column = 0; column < 2 && SUCCEEDED(hr); ++column) {
            hr = zigonaut_text_engine_draw_builtin_cell(engine, 0x2588, mask.data(),
                engine->metrics.width, engine->metrics.height, engine->metrics.width,
                static_cast<float>(column * engine->metrics.width), 0,
                static_cast<float>(engine->metrics.width), static_cast<float>(engine->metrics.height),
                0x20ff20);
        }
        engine->benchmark_active = false;
        if (SUCCEEDED(hr) && (engine->target->GetTextAntialiasMode() != D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE ||
                engine->atlas_allocator || engine->atlas_bitmap || engine->atlas_texture || engine->atlas_context ||
                engine->atlas_brush || engine->sprite_batch || engine->target3 ||
                engine->benchmark.atlas_eligible_rows || engine->benchmark.atlas_fallback_rows ||
                engine->benchmark.atlas_sprite_batches || engine->benchmark.atlas_sprites ||
                engine->builtin_bitmap_creations != bitmap_creations + 1 ||
                engine->builtin_bitmaps.size() != 1)) hr = E_FAIL;
        if (SUCCEEDED(hr)) hr = finish(engine);
        uint64_t changed = 0;
        if (SUCCEEDED(hr)) hr = ink(engine, 0, engine->metrics.height * 2, 0x18, &changed);
        if (SUCCEEDED(hr) && changed == 0) hr = E_FAIL;
        zigonaut_text_engine_destroy(engine);
    }
    if (FAILED(hr)) { DestroyWindow(window); return hr; }

    // Each injected failure is reached by endRow, and must produce a visible native fallback.
    for (const auto fault : {ZigonautTextEngine::TestFault::atlas_resource,
            ZigonautTextEngine::TestFault::atlas_texture,
            ZigonautTextEngine::TestFault::rasterize, ZigonautTextEngine::TestFault::upload,
            ZigonautTextEngine::TestFault::instance_append}) {
        ZigonautTextEngine* engine = nullptr;
        if (SUCCEEDED(hr)) hr = create(ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
        if (SUCCEEDED(hr)) hr = begin(engine);
        if (fault == ZigonautTextEngine::TestFault::atlas_resource ||
                fault == ZigonautTextEngine::TestFault::atlas_texture) engine->test_fault = fault;
        if (SUCCEEDED(hr)) hr = row(engine, 0); // plan warmup (and resource-fault attempt)
        if (fault != ZigonautTextEngine::TestFault::atlas_resource &&
                fault != ZigonautTextEngine::TestFault::atlas_texture) engine->test_fault = fault;
        engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
        const uint64_t uploads = engine->benchmark.atlas_uploads;
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height));
        engine->test_fault = ZigonautTextEngine::TestFault::none;
        if (SUCCEEDED(hr) && (engine->benchmark.atlas_fallback_rows == 0 ||
                engine->benchmark.glyph_submissions == 0 || engine->benchmark.atlas_sprite_batches != 0 ||
                engine->benchmark.atlas_sprites != 0)) hr = E_FAIL;
        if (SUCCEEDED(hr) && fault == ZigonautTextEngine::TestFault::upload &&
                engine->benchmark.atlas_uploads != uploads) hr = E_FAIL;
        if (SUCCEEDED(hr) && (fault == ZigonautTextEngine::TestFault::upload ||
                fault == ZigonautTextEngine::TestFault::instance_append)) {
            if (!engine->atlas_disabled_for_frame) hr = E_FAIL;
            const uint64_t eligible = engine->benchmark.atlas_eligible_rows;
            if (SUCCEEDED(hr)) hr = row(engine, engine->metrics.height * 2.0f);
            if (SUCCEEDED(hr) && engine->benchmark.atlas_eligible_rows != eligible + 1) hr = E_FAIL;
        }
        engine->benchmark_active = false;
        if (SUCCEEDED(hr)) hr=finish(engine);
        uint64_t changed = 0;
        if (SUCCEEDED(hr) && fault != ZigonautTextEngine::TestFault::upload) hr = ink(engine, engine->metrics.height,
            engine->metrics.height * 2, 0x18, &changed);
        if (SUCCEEDED(hr) && fault != ZigonautTextEngine::TestFault::upload && changed == 0) hr = E_FAIL;
        if (SUCCEEDED(hr) && fault == ZigonautTextEngine::TestFault::upload) {
            const uint64_t generation = engine->atlas_generation;
            if (!engine->atlas_invalidation_pending) hr = E_FAIL;
            if (SUCCEEDED(hr)) hr = begin(engine);
            if (SUCCEEDED(hr) && (engine->atlas_generation != generation + 1 ||
                    engine->atlas_invalidation_pending)) hr = E_FAIL;
            engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
            if (SUCCEEDED(hr)) hr = row(engine, 0);
            engine->benchmark_active = false;
            if (SUCCEEDED(hr) && (engine->benchmark.atlas_placement_misses == 0 ||
                    engine->benchmark.atlas_rasterizations == 0)) hr = E_FAIL;
            if (engine && engine->frame_active) finish(engine);
        }
        zigonaut_text_engine_destroy(engine);
        if (FAILED(hr)) break;
    }
    if (FAILED(hr)) { DestroyWindow(window); return hr; }

    // Once instances have been queued, failure of their actual D3D upload drops
    // those commands and is sticky: end-frame fails rather than presenting a
    // coherent-looking frame with missing glyphs.
    {
        ZigonautTextEngine* engine = nullptr;
        hr = create(ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
        if (SUCCEEDED(hr)) hr = begin(engine, 2);
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'A');
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'k');
        if (SUCCEEDED(hr)) hr = finish(engine); // establish populated placements
        if (SUCCEEDED(hr)) hr = begin(engine, 2);
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'A');
        if (SUCCEEDED(hr) && engine->glyph_instances.empty()) hr = E_FAIL;
        engine->test_fault = ZigonautTextEngine::TestFault::instance_upload;
        const HRESULT frame_hr = SUCCEEDED(hr) ? zigonaut_text_engine_end_frame(engine) : hr;
        engine->test_fault = ZigonautTextEngine::TestFault::none;
        if (SUCCEEDED(hr) && (SUCCEEDED(frame_hr) || SUCCEEDED(engine->glyph_frame_failure) ||
                engine->frame_active || engine->scene_texture != nullptr)) hr = E_FAIL;
        zigonaut_text_engine_destroy(engine);
    }
    if (FAILED(hr)) { DestroyWindow(window); return hr; }

    // A later pre-submit failure must not invalidate an atlas command already
    // retained by the active draw scope; both rows must survive EndDraw.
    {
        ZigonautTextEngine* engine = nullptr;
        hr = create(ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
        if (SUCCEEDED(hr)) hr = begin(engine, 2);
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'A');
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'k');
        if (SUCCEEDED(hr)) hr = finish(engine);
        if (SUCCEEDED(hr)) hr = begin(engine, 2);
        engine->benchmark = {};
        engine->benchmark_active = SUCCEEDED(hr);
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'A');
        const uint64_t generation = engine->atlas_generation;
        const uint64_t allocations = engine->atlas_resource_allocations;
        engine->test_fault = ZigonautTextEngine::TestFault::instance_append;
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'k');
        engine->test_fault = ZigonautTextEngine::TestFault::none;
        engine->benchmark_active = false;
        if (SUCCEEDED(hr) && (engine->benchmark.atlas_sprite_batches != 1 ||
                engine->benchmark.atlas_fallback_rows == 0 ||
                engine->atlas_generation != generation ||
                engine->atlas_resource_allocations != allocations)) hr = E_FAIL;
        if (SUCCEEDED(hr)) hr = finish(engine);
        for (uint32_t index = 0; index < 2 && SUCCEEDED(hr); ++index) {
            uint64_t changed = 0;
            hr = ink(engine, index * engine->metrics.height,
                (index + 1) * engine->metrics.height, 0x18, &changed);
            if (SUCCEEDED(hr) && changed == 0) hr = E_FAIL;
        }
        zigonaut_text_engine_destroy(engine);
    }
    if (FAILED(hr)) { DestroyWindow(window); return hr; }

    // Exercise a compact visual corpus through the same shaping, fallback, atlas,
    // and retained-scene readback paths used by terminal rows. Missing system glyphs
    // are allowed to render their fallback box, but every row must retain visible ink.
    {
        ZigonautTextEngine* engine = nullptr;
        hr = create(ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
        constexpr uint32_t corpus_rows = 8;
        if (SUCCEEDED(hr)) hr = begin(engine, corpus_rows);
        const auto corpusRow = [&](uint32_t row_index) -> HRESULT {
            const float top = static_cast<float>(row_index * engine->metrics.height);
            const float origin = row_index == 6 ? 0.5f : 0.0f;
            engine->beginRow(origin, top, static_cast<float>(engine->metrics.width),
                static_cast<float>(engine->metrics.height));
            static constexpr uint16_t ascii[] = {u'i',u'l',u'1',u'M',u'W',u'@',u'#'};
            static constexpr uint16_t boxes[] = {0x2500,0x2502,0x250c,0x2510,0x2580,0x2584,0x2588,0x2591};
            static constexpr uint16_t combining[] = {u'e',0x0301};
            static constexpr uint16_t emoji[] = {0xd83d,0xde00};
            const uint32_t cell_span = row_index == 3 ? 2 : 1;
            const uint32_t count = 16 / cell_span;
            for (uint32_t item = 0; item < count; ++item) {
                const uint32_t column = item * cell_span;
                const uint16_t single = row_index == 1 ? boxes[item % 8] :
                    row_index == 3 ? 0x754c :
                    row_index == 4 ? static_cast<uint16_t>(0x05d0 + item % 16) :
                    ascii[item % 7];
                const uint16_t* text = row_index == 2 ? combining :
                    row_index == 5 ? emoji : &single;
                const uint32_t length = row_index == 2 || row_index == 5 ? 2 : 1;
                const uint32_t foreground = row_index == 7 ?
                    (item % 3 == 0 ? 0xff2020 : item % 3 == 1 ? 0x20ff20 : 0x2020ff) :
                    (item % 2 ? 0x20ff20 : 0xff4040);
                const HRESULT value = engine->drawCell(text, length,
                    origin + column * engine->metrics.width, top,
                    static_cast<float>(cell_span * engine->metrics.width),
                    static_cast<float>(engine->metrics.height), foreground, 0x181818,
                    foreground, row_index == 0 && (item & 1),
                    row_index == 0 && (item & 2), false, false, false, 0,
                    cell_span == 2 ? ZIGONAUT_CELL_WIDE : ZIGONAUT_CELL_NARROW);
                if (FAILED(value)) return value;
            }
            return engine->endRow();
        };
        // Resolve plans in a separate frame so the readback below cannot pass on
        // native warmup pixels left underneath the atlas/fallback output.
        for (uint32_t index = 0; index < corpus_rows && SUCCEEDED(hr); ++index)
            hr = corpusRow(index);
        if (SUCCEEDED(hr)) hr = finish(engine);
        if (SUCCEEDED(hr)) hr = begin(engine, corpus_rows);
        engine->benchmark = {};
        engine->benchmark_active = SUCCEEDED(hr);
        for (uint32_t index = 0; index < corpus_rows && SUCCEEDED(hr); ++index) {
            hr = corpusRow(index);
        }
        engine->benchmark_active = false;
        if (SUCCEEDED(hr) && (engine->benchmark.atlas_eligible_rows == 0 ||
                engine->benchmark.atlas_fallback_rows == 0 ||
                engine->benchmark.atlas_sprite_batches == 0 ||
                engine->target->GetTextAntialiasMode() != D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE)) hr = E_FAIL;
        if (SUCCEEDED(hr)) hr = finish(engine);
        for (uint32_t index = 0; index < corpus_rows && SUCCEEDED(hr); ++index) {
            uint64_t changed = 0;
            hr = ink(engine, index * engine->metrics.height,
                (index + 1) * engine->metrics.height, 0x18, &changed);
            if (SUCCEEDED(hr) && changed == 0) hr = E_FAIL;
        }
        // Saturated foregrounds also remain visible against an opaque light target.
        if (SUCCEEDED(hr)) hr = begin(engine, 1, 0xf0f0f0);
        if (SUCCEEDED(hr)) hr = corpusRow(0);
        if (SUCCEEDED(hr)) hr = finish(engine);
        uint64_t changed = 0;
        if (SUCCEEDED(hr)) hr = ink(engine, 0, engine->metrics.height, 0xf0, &changed);
        if (SUCCEEDED(hr) && changed == 0) hr = E_FAIL;
        zigonaut_text_engine_destroy(engine);
    }
    if (FAILED(hr)) { DestroyWindow(window); return hr; }

    ZigonautTextEngine* invalid = nullptr;
    if (SUCCEEDED(hr) && zigonaut_text_engine_create(L"Consolas", 18, 400, 700, 100, 96,
            -1, &invalid) != E_INVALIDARG) hr = E_FAIL;
    if (SUCCEEDED(hr) && zigonaut_text_engine_create(L"Consolas", 18, 400, 700, 100, 96,
            2, &invalid) != E_INVALIDARG) hr = E_FAIL;

    // Exhaustion is only setup; real rows request and real begin_frame calls consume resets.
    if (SUCCEEDED(hr)) {
        ZigonautTextEngine* engine = nullptr;
        hr = create(ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
        if (SUCCEEDED(hr)) hr = begin(engine, 2);
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'a');
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'a');
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'k');
        GlyphAtlasAllocator::Rect placement{};
        engine->atlas_allocator = std::make_unique<GlyphAtlasAllocator>(1024);
        if (SUCCEEDED(hr) && !engine->atlas_allocator->reserve(1022, 1022, placement)) hr = E_FAIL;
        const uint64_t generation = engine->atlas_generation;
        engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'k');
        if (SUCCEEDED(hr) && (!engine->atlas_reset_pending || engine->atlas_generation != generation ||
                engine->benchmark.atlas_fallback_rows == 0)) hr = E_FAIL;
        engine->benchmark_active = false;
        if (SUCCEEDED(hr)) hr = finish(engine);
        const uint64_t resets = engine->atlas_pressure_resets;
        if (SUCCEEDED(hr)) hr = begin(engine, 2, 0x181818, 17);
        if (SUCCEEDED(hr) && (engine->atlas_extent != 2048 || engine->atlas_generation != generation + 1 ||
                engine->atlas_pressure_resets != resets + 1 || engine->atlas_reset_pending ||
                engine->atlas_reserved_area != 0)) hr = E_FAIL;
        engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
        if (SUCCEEDED(hr)) hr = row(engine, 0, u'a'); // stale 1024 placement must miss/rasterize
        const uint64_t misses = engine->benchmark.atlas_placement_misses;
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'a');
        if (SUCCEEDED(hr) && (misses == 0 || engine->benchmark.atlas_rasterizations == 0 ||
                engine->benchmark.atlas_placement_hits == 0)) hr = E_FAIL;
        // Full pressure at the maximum extent resets the generation in place,
        // again only after the current frame has completed.
        engine->atlas_allocator = std::make_unique<GlyphAtlasAllocator>(2048);
        if (SUCCEEDED(hr) && !engine->atlas_allocator->reserve(2046, 2046, placement)) hr = E_FAIL;
        const uint64_t max_generation = engine->atlas_generation;
        const uint64_t max_fallbacks = engine->benchmark.atlas_fallback_rows;
        if (SUCCEEDED(hr)) hr = row(engine, static_cast<float>(engine->metrics.height), u'k');
        if (SUCCEEDED(hr) && (!engine->atlas_reset_pending ||
                engine->atlas_generation != max_generation ||
                engine->benchmark.atlas_fallback_rows != max_fallbacks + 1)) hr = E_FAIL;
        engine->benchmark_active = false;
        if (SUCCEEDED(hr)) hr = finish(engine);
        const uint64_t max_resets = engine->atlas_pressure_resets;
        if (SUCCEEDED(hr)) hr = begin(engine, 2, 0x181818, 17);
        if (SUCCEEDED(hr) && (engine->atlas_extent != 2048 ||
                engine->atlas_generation != max_generation + 1 ||
                engine->atlas_pressure_resets != max_resets + 1 || engine->atlas_reset_pending)) hr = E_FAIL;
        // A run too large for even the maximum atlas is permanently native and
        // must not cause generation churn on every subsequent frame.
        if (SUCCEEDED(hr)) engine->rejectAtlasReservation(2047, 1, false);
        if (SUCCEEDED(hr) && engine->atlas_reset_pending) hr = E_FAIL;
        if (engine && engine->frame_active) finish(engine);
        zigonaut_text_engine_destroy(engine);
    }
    DestroyWindow(window);
    return hr;
}

extern "C" HRESULT zigonaut_test_glyph_atlas_pixels(ZigonautGlyphAtlasPixelsTest* result) {
    if (result == nullptr) return E_INVALIDARG;
    *result = {};
    constexpr uint32_t background = 0x181818, columns = 16;
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC",
        L"Zigonaut glyph atlas test", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (window == nullptr) return HRESULT_FROM_WIN32(GetLastError());
    ZigonautTextEngine* engine = nullptr;
    HRESULT hr = zigonaut_text_engine_create(L"Consolas", 18,
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_WEIGHT_BOLD, 100, 96,
        ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE, &engine);
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_set_window(engine,
        reinterpret_cast<uintptr_t>(window));
    const uint32_t width = SUCCEEDED(hr) ? columns * engine->metrics.width : 1;
    const uint32_t height = SUCCEEDED(hr) ? engine->metrics.height : 1;
    std::vector<uint8_t> builtin_mask(SUCCEEDED(hr) ? engine->metrics.width * height : 1, 255);
    const auto row = [&](bool spaces) -> HRESULT {
        engine->beginRow(0, 0, static_cast<float>(engine->metrics.width),
            static_cast<float>(engine->metrics.height));
        for (uint32_t column = 0; column < columns; ++column) {
            const uint16_t character = spaces ? u' ' : static_cast<uint16_t>(u'A' + column % 26);
            const uint32_t foreground = 0x2020ff;
            const HRESULT draw = engine->drawCell(&character, 1,
                static_cast<float>(column * engine->metrics.width), 0,
                static_cast<float>(engine->metrics.width), static_cast<float>(engine->metrics.height),
                foreground, background, foreground, false, false, false, false, false, 0,
                ZIGONAUT_CELL_NARROW);
            if (FAILED(draw)) return draw;
            // Exercise procedural placement beside shaped segments. The repeated
            // key proves one upload followed by warm placement hits without
            // manufacturing a glyph id for U+2588.
            if (!spaces && column % 4 == 1) {
                const HRESULT builtin=zigonaut_text_engine_draw_builtin_cell(engine,0x2588,
                    builtin_mask.data(),engine->metrics.width,height,engine->metrics.width,
                    static_cast<float>(column*engine->metrics.width),0,
                    static_cast<float>(engine->metrics.width),static_cast<float>(height),0x20ff20);
                if (FAILED(builtin)) return builtin;
            }
        }
        return engine->endRow();
    };
    const auto finish = [&]() -> HRESULT {
        HRESULT value = engine->flushGlyphInstances();
        if (SUCCEEDED(value)) value = engine->target->EndDraw();
        engine->frame_active = false;
        engine->target->SetTarget(nullptr);
        return value;
    };
    const auto inspect = [&](uint64_t* changed, uint64_t* red, uint64_t* green) -> HRESULT {
        D3D11_TEXTURE2D_DESC description{};
        engine->scene_texture->GetDesc(&description);
        description.Usage = D3D11_USAGE_STAGING;
        description.BindFlags = 0;
        description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        description.MiscFlags = 0;
        ID3D11Texture2D* staging = nullptr;
        HRESULT value = engine->d3d_device->CreateTexture2D(&description, nullptr, &staging);
        if (SUCCEEDED(value)) {
            engine->d3d_context->CopyResource(staging, engine->scene_texture);
            D3D11_MAPPED_SUBRESOURCE mapped{};
            value = engine->d3d_context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped);
            if (SUCCEEDED(value)) {
                for (uint32_t y = 0; y < height; ++y) {
                    const uint8_t* scan = static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch;
                    for (uint32_t x = 0; x < width; ++x) {
                        const uint8_t b = scan[x * 4], g = scan[x * 4 + 1], r = scan[x * 4 + 2];
                        if (r != 0x18 || g != 0x18 || b != 0x18) ++*changed;
                        if (red && r > g + 8 && r > b + 8) ++*red;
                        if (green && g > r + 8 && g > b + 8) ++*green;
                    }
                }
                engine->d3d_context->Unmap(staging, 0);
            }
        }
        release(staging);
        return value;
    };
    BOOL rebuild = FALSE;
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_begin_frame(engine, width, height, background, TRUE, &rebuild);
    if (SUCCEEDED(hr)) hr = row(false); // Resolve plans through the native fallback.
    if (SUCCEEDED(hr)) hr = finish();
    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_begin_frame(engine, width, height, background, TRUE, &rebuild);
    engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
    if (SUCCEEDED(hr)) hr = row(false); // Populate and draw an atlas-only frame.
    if (SUCCEEDED(hr)) hr = finish();
    engine->benchmark_active = false;
    result->first_sprite_batches = engine->benchmark.atlas_sprite_batches;
    result->first_sprites = engine->benchmark.atlas_sprites;
    result->first_uploads = engine->benchmark.atlas_uploads;
    result->first_rasterizations = engine->benchmark.atlas_rasterizations;
    if (SUCCEEDED(hr)) hr = inspect(&result->first_changed_pixels,
        &result->first_red_dominant_pixels, &result->first_green_dominant_pixels);

    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_begin_frame(engine, width, height, background, TRUE, &rebuild);
    if (SUCCEEDED(hr)) hr = row(true); // Warm empty placements without emitting ink.
    engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
    if (SUCCEEDED(hr)) hr = row(true); // Empty placements must not call AddSprites(0).
    if (SUCCEEDED(hr)) hr = finish();
    engine->benchmark_active = false;
    result->empty_sprite_batches = engine->benchmark.atlas_sprite_batches;
    result->empty_sprites = engine->benchmark.atlas_sprites;
    if (SUCCEEDED(hr)) hr = inspect(&result->empty_changed_pixels, nullptr, nullptr);

    if (SUCCEEDED(hr)) hr = zigonaut_text_engine_begin_frame(engine, width, height, background, TRUE, &rebuild);
    engine->benchmark = {}; engine->benchmark_active = SUCCEEDED(hr);
    if (SUCCEEDED(hr)) hr = row(false);
    if (SUCCEEDED(hr)) hr = finish();
    engine->benchmark_active = false;
    result->second_sprite_batches = engine->benchmark.atlas_sprite_batches;
    result->second_sprites = engine->benchmark.atlas_sprites;
    result->second_placement_hits = engine->benchmark.atlas_placement_hits;
    result->second_uploads = engine->benchmark.atlas_uploads;
    result->second_rasterizations = engine->benchmark.atlas_rasterizations;
    if (SUCCEEDED(hr)) hr = inspect(&result->second_changed_pixels, nullptr, nullptr);
    zigonaut_text_engine_destroy(engine);
    DestroyWindow(window);
    return hr;
}

extern "C" HRESULT zigonaut_text_engine_set_dpi(
    ZigonautTextEngine* engine,
    uint32_t dpi) {
    if (engine == nullptr || dpi == 0) return E_INVALIDARG;
    if (engine->frame_active || engine->present_pending) return E_UNEXPECTED;
    engine->dpi = dpi;
    HRESULT hr = engine->updateSwapChainTransform();
    if (FAILED(hr)) return hr;
    hr = engine->createFormats();
    if (FAILED(hr)) return hr;
    engine->updateMetrics();
    return engine->refreshRenderingParams();
}

extern "C" HRESULT zigonaut_text_engine_refresh_rendering_params(
    ZigonautTextEngine* engine) {
    if (engine == nullptr) return E_INVALIDARG;
    if (engine->frame_active || engine->present_pending) return E_UNEXPECTED;
    return engine->refreshRenderingParams();
}

extern "C" ZigonautCellMetrics zigonaut_text_engine_get_cell_metrics(
    const ZigonautTextEngine* engine) {
    if (engine == nullptr) return {9, 18, 14, 1};
    return engine->metrics;
}

extern "C" HRESULT zigonaut_text_engine_set_window(
    ZigonautTextEngine* engine,
    uintptr_t hwnd) {
    if (engine == nullptr || hwnd == 0) return E_INVALIDARG;
    if (engine->frame_active || engine->present_pending) return E_UNEXPECTED;
    engine->hwnd = reinterpret_cast<HWND>(hwnd);
    return engine->refreshRenderingParams();
}

extern "C" void* zigonaut_text_engine_get_swap_chain(
    ZigonautTextEngine* engine) {
    return engine == nullptr ? nullptr : engine->swap_chain;
}

extern "C" HANDLE zigonaut_text_engine_get_frame_latency_waitable_object(
    ZigonautTextEngine* engine) {
    return engine == nullptr ? nullptr : engine->frame_latency_waitable_object;
}

extern "C" HRESULT zigonaut_text_engine_begin_frame(
    ZigonautTextEngine* engine,
    uint32_t width,
    uint32_t height,
    uint32_t background,
    BOOL full_rebuild,
    BOOL* full_rebuild_required) {
    if (engine == nullptr || width == 0 || height == 0 || full_rebuild_required == nullptr) return E_INVALIDARG;
    if (engine->frame_active || engine->present_pending) return E_UNEXPECTED;
    const bool pressure_reset = engine->atlas_reset_pending;
    const bool failure_invalidation = engine->atlas_invalidation_pending;
    const uint64_t atlas_generation = engine->atlas_generation;
    const bool recreate = engine->scene_bitmap == nullptr ||
        engine->scene_bitmap->GetPixelSize().width != width ||
        engine->scene_bitmap->GetPixelSize().height != height;
    const HRESULT hr = engine->ensureTarget(width, height);
    if (FAILED(hr)) {
        engine->atlas_reset_pending = pressure_reset;
        engine->atlas_invalidation_pending = failure_invalidation;
        return hr;
    }
    if (pressure_reset || failure_invalidation) {
        if (pressure_reset && engine->atlas_extent < 2048) engine->atlas_extent = 2048;
        // A target resize already invalidates atlas resources. Otherwise consume
        // the pending generation now, before the new scene draw scope begins.
        if (engine->atlas_generation == atlas_generation) engine->invalidateAtlas();
        if (pressure_reset) ++engine->atlas_pressure_resets;
    }
    if (engine->sprite_batch != nullptr) engine->sprite_batch->Clear();
    engine->sprite_count = 0;
    engine->glyph_instances.clear();
    engine->glyph_frame_failure = S_OK;
    engine->atlas_disabled_for_frame = false;
    *full_rebuild_required = recreate ? TRUE : FALSE;
    engine->frame_damage.clear();
    if (full_rebuild || recreate) engine->markFullDamage(engine->frame_damage);
    engine->frame_background = background;
    ++engine->image_frame;
    if (engine->image_frame == 0) ++engine->image_frame;
    engine->target->SetTarget(engine->scene_bitmap);
    engine->target->BeginDraw();
    engine->setTag(frame_command_begin);
    engine->target->SetTransform(D2D1::Matrix3x2F::Identity());
    if (full_rebuild || recreate) engine->target->Clear(color(background));
    engine->frame_active = true;
    return S_OK;
}

extern "C" void zigonaut_text_engine_clear_rect(ZigonautTextEngine* engine,
    float left, float top, float right, float bottom, uint32_t background) {
    if (engine == nullptr || !engine->frame_active || engine->brush == nullptr) return;
    engine->setTag(frame_command_clear);
    engine->addDamage(engine->frame_damage, left, top, right, bottom);
    engine->brush->SetColor(color(background));
    engine->target->FillRectangle(D2D1::RectF(left, top, right, bottom), engine->brush);
}

extern "C" HRESULT zigonaut_text_engine_shift_scene(ZigonautTextEngine* engine,
    int32_t row_delta, uint32_t left, uint32_t top, uint32_t width,
    uint32_t row_height, uint32_t row_count) {
    const int64_t signed_delta = row_delta;
    const uint64_t amount64 = signed_delta < 0 ? static_cast<uint64_t>(-signed_delta) :
        static_cast<uint64_t>(signed_delta);
    const uint64_t grid_right = static_cast<uint64_t>(left) + width;
    const uint64_t grid_bottom = static_cast<uint64_t>(top) +
        static_cast<uint64_t>(row_height) * row_count;
    if (!engine || !engine->frame_active || !engine->scene_texture ||
        !engine->scene_shift_scratch || row_delta == 0 || width == 0 || row_height == 0 ||
        row_count == 0 || amount64 >= row_count || grid_right > engine->scene_width ||
        grid_bottom > engine->scene_height)
        return E_INVALIDARG;
    HRESULT hr = engine->flushGlyphInstances();
    if (FAILED(hr)) return hr;
    hr = engine->target->EndDraw();
    if (FAILED(hr)) {
        engine->markFullDamage(engine->frame_damage);
        engine->target->BeginDraw();
        return hr;
    }
    engine->target->SetTarget(nullptr);
    const uint32_t amount = static_cast<uint32_t>(amount64);
    const uint32_t pixels = amount * row_height;
    const uint32_t retained = (row_count - amount) * row_height;
    D3D11_BOX source{left, top + (row_delta > 0 ? 0u : pixels), 0,
        left + width, top + (row_delta > 0 ? retained : pixels + retained), 1};
    // The two operations deliberately use a distinct resource: overlapping
    // CopySubresourceRegion on scene_texture is undefined by D3D11.
    engine->d3d_context->CopySubresourceRegion(engine->scene_shift_scratch, 0,
        left, top, 0, engine->scene_texture, 0, &source);
    D3D11_BOX scratch{left, top, 0, left + width, top + retained, 1};
    engine->d3d_context->CopySubresourceRegion(engine->scene_texture, 0, left,
        top + (row_delta > 0 ? pixels : 0u), 0, engine->scene_shift_scratch, 0, &scratch);
    engine->markFullDamage(engine->frame_damage);
    engine->target->SetTarget(engine->scene_bitmap);
    engine->target->BeginDraw();
    hr = engine->d3d_device->GetDeviceRemovedReason();
    if (FAILED(hr)) engine->markFullDamage(engine->frame_damage);
    return hr;
}

extern "C" void zigonaut_text_engine_abort_frame(ZigonautTextEngine* engine) {
    if (engine == nullptr || engine->target == nullptr || !engine->frame_active) return;
    engine->row_active = false;
    engine->glyph_instances.clear();
    if (engine->atlas_draw_active) engine->endAtlasDraw();
    engine->target->EndDraw();
    engine->frame_active = false;
    engine->discardTargetBitmap();
}

extern "C" void zigonaut_text_engine_begin_row(
    ZigonautTextEngine* engine,
    uint32_t,
    float origin_x,
    float top,
    float cell_width,
    float cell_height,
    uint32_t previous_start,
    uint32_t previous_end,
    uint32_t current_start,
    uint32_t current_end,
    uint32_t next_start,
    uint32_t next_end,
    BOOL top_clipped,
    BOOL bottom_clipped) {
    if (engine == nullptr || cell_width <= 0.0f || cell_height <= 0.0f) return;
    const auto interval = [](uint32_t start, uint32_t end) {
        return SelectionInterval{start, end,
            start != UINT32_MAX && end != UINT32_MAX && start < end};
    };
    engine->beginRow(origin_x, top, cell_width, cell_height,
        interval(previous_start, previous_end),
        interval(current_start, current_end),
        interval(next_start, next_end),
        top_clipped != FALSE, bottom_clipped != FALSE);
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
    uint32_t ordinary_background,
    BOOL selection_background,
    BOOL search_background,
    uint32_t underline_color,
    BOOL bold,
    BOOL italic,
    BOOL faint,
    BOOL strikethrough,
    BOOL overline,
    uint8_t underline,
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
        underline_color,
        bold != FALSE,
        italic != FALSE,
        faint != FALSE,
        strikethrough != FALSE,
        overline != FALSE,
        underline,
        occupancy,
        ordinary_background,
        selection_background != FALSE,
        search_background != FALSE);
}

extern "C" HRESULT zigonaut_text_engine_draw_builtin_cell(
    ZigonautTextEngine* engine, uint32_t codepoint, const uint8_t* mask,
    uint32_t mask_width, uint32_t mask_height, uint32_t mask_stride,
    float left, float top, float width, float height, uint32_t foreground) {
    if (!engine || !mask || codepoint < 0x2500 || codepoint > 0x259f ||
        !mask_width || !mask_height || mask_stride < mask_width || !engine->target || !engine->brush)
        return E_INVALIDARG;
    if (engine->row_active) {
        if (engine->row_cells.empty()) return E_UNEXPECTED;
        auto& cell=engine->row_cells.back();
        try {
            cell.builtin_mask.assign(mask,
                mask + static_cast<size_t>(mask_stride) * mask_height);
        } catch (...) {
            return E_OUTOFMEMORY;
        }
        cell.kind=RowCell::Kind::builtin;
        cell.foreground=foreground;
        cell.builtin_codepoint=codepoint;
        cell.builtin_width=mask_width; cell.builtin_height=mask_height; cell.builtin_stride=mask_stride;
        return S_OK;
    }
    engine->setTag(frame_command_builtin, codepoint);
    // A8 opacity masks are supported in every text AA policy and provide the
    // deterministic fallback when the glyph atlas is unavailable.
    ID2D1Bitmap* bitmap = nullptr;
    const uint32_t span = width > static_cast<float>(engine->metrics.width) ? 2u : 1u;
    HRESULT hr = engine->getBuiltinBitmap(codepoint, mask_width, mask_height,
        span, mask, mask_stride, &bitmap);
    if (FAILED(hr)) return hr;
    engine->brush->SetColor(color(foreground));
    const auto destination = D2D1::RectF(left, top, left + width, top + height);
    const auto aa=engine->target->GetAntialiasMode();
    engine->target->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    engine->target->FillOpacityMask(bitmap, engine->brush,
        D2D1_OPACITY_MASK_CONTENT_GRAPHICS, destination,
        D2D1::RectF(0, 0, static_cast<float>(mask_width), static_cast<float>(mask_height)));
    engine->target->SetAntialiasMode(aa);
    return S_OK;
}

extern "C" HRESULT zigonaut_text_engine_draw_image(ZigonautTextEngine* engine,
    uint32_t image_id, uint64_t generation, const uint8_t* rgba, size_t rgba_length,
    uint32_t image_width, uint32_t image_height,
    float dl, float dt, float dw, float dh, float sl, float st, float sw, float sh,
    float cl, float ct, float cr, float cb) {
    if (!engine || !engine->target || !image_id || !generation || !rgba || !image_width || !image_height ||
        image_width > UINT32_MAX / 4 ||
        !std::isfinite(dl) || !std::isfinite(dt) || !std::isfinite(dw) || !std::isfinite(dh) ||
        !std::isfinite(sl) || !std::isfinite(st) || !std::isfinite(sw) || !std::isfinite(sh) ||
        !std::isfinite(cl) || !std::isfinite(ct) || !std::isfinite(cr) || !std::isfinite(cb) ||
        dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0 || sl < 0 || st < 0 ||
        sl > image_width || st > image_height || sw > image_width - sl || sh > image_height - st ||
        cl >= cr || ct >= cb || !std::isfinite(dl + dw) || !std::isfinite(dt + dh) ||
        !std::isfinite(sl + sw) || !std::isfinite(st + sh)) return E_INVALIDARG;
    HRESULT pending=engine->flushGlyphInstances();
    if (FAILED(pending)) return pending;
    constexpr size_t max_image_bytes = 32u * 1024u * 1024u;
    if (static_cast<size_t>(image_width) > max_image_bytes / 4u / image_height) return E_INVALIDARG;
    const size_t byte_length = static_cast<size_t>(image_width) * image_height * 4;
    if (rgba_length != byte_length) return E_INVALIDARG;
    decltype(engine->images)::iterator iterator;
    bool inserted = false;
    try {
        const auto result = engine->images.try_emplace(image_id);
        iterator = result.first;
        inserted = result.second;
    } catch (...) {
        return E_OUTOFMEMORY;
    }
    auto& cached = iterator->second;
    if (cached.generation != generation) {
        std::unique_ptr<uint8_t[]> premultiplied(new (std::nothrow) uint8_t[byte_length]);
        if (!premultiplied) {
            if (inserted) engine->images.erase(iterator);
            return E_OUTOFMEMORY;
        }
        std::copy_n(rgba, byte_length, premultiplied.get());
        for (size_t index = 0; index < byte_length; index += 4) {
            const uint32_t alpha = premultiplied[index + 3];
            premultiplied[index] = static_cast<uint8_t>((premultiplied[index] * alpha + 127) / 255);
            premultiplied[index + 1] = static_cast<uint8_t>((premultiplied[index + 1] * alpha + 127) / 255);
            premultiplied[index + 2] = static_cast<uint8_t>((premultiplied[index + 2] * alpha + 127) / 255);
        }
        D2D1_BITMAP_PROPERTIES1 properties = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_NONE,
            D2D1::PixelFormat(DXGI_FORMAT_R8G8B8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
        ID2D1Bitmap1* bitmap = nullptr;
        const HRESULT hr = engine->target->CreateBitmap(D2D1::SizeU(image_width, image_height),
            premultiplied.get(), image_width * 4, properties, &bitmap);
        if (FAILED(hr)) {
            if (inserted) engine->images.erase(iterator);
            return hr;
        }
        release(cached.bitmap);
        cached.bitmap = bitmap;
        cached.generation = generation;
    }
    cached.last_seen_frame = engine->image_frame;
    engine->setTag(frame_command_image, image_id);
    engine->addDamage(engine->frame_damage,
        std::max(dl, cl), std::max(dt, ct),
        std::min(dl + dw, cr), std::min(dt + dh, cb));
    engine->target->PushAxisAlignedClip(D2D1::RectF(cl, ct, cr, cb), D2D1_ANTIALIAS_MODE_ALIASED);
    engine->target->DrawBitmap(cached.bitmap, D2D1::RectF(dl, dt, dl + dw, dt + dh), 1.0f,
        D2D1_INTERPOLATION_MODE_LINEAR, D2D1::RectF(sl, st, sl + sw, st + sh));
    engine->target->PopAxisAlignedClip();
    return S_OK;
}

extern "C" HRESULT zigonaut_text_engine_end_row(ZigonautTextEngine* engine) {
    if (engine == nullptr) return E_INVALIDARG;
    engine->setTag(frame_command_row);
    return engine->endRow();
}

extern "C" void zigonaut_text_engine_draw_cursor(
    ZigonautTextEngine* engine,
    float left,
    float top,
    float width,
    float height,
    uint32_t cursor_color,
    uint8_t style) {
    if (engine == nullptr || engine->target == nullptr || engine->brush == nullptr) return;
    if (FAILED(engine->flushGlyphInstances())) { engine->markFullDamage(engine->frame_damage); return; }
    engine->setTag(frame_command_cursor, style);
    engine->addDamage(engine->frame_damage,
        left - 1.0f, top - 1.0f, left + width + 1.0f, top + height + 1.0f);
    engine->brush->SetColor(color(cursor_color));
    if (style == 1) {
        engine->target->FillRectangle(D2D1::RectF(left, top, left + width, top + height), engine->brush);
    } else if (style == 2) {
        const float bar_width = width / 8.0f > 2.0f ? width / 8.0f : 2.0f;
        engine->target->FillRectangle(D2D1::RectF(left, top, left + bar_width, top + height), engine->brush);
    } else if (style == 3) {
        engine->target->FillRectangle(D2D1::RectF(left, top + height - 2.0f, left + width, top + height), engine->brush);
    } else {
        engine->target->DrawRectangle(
            D2D1::RectF(left + 0.5f, top + 0.5f, left + width - 0.5f, top + height - 0.5f),
            engine->brush,
            1.0f);
    }
}

extern "C" HRESULT zigonaut_text_engine_draw_preedit(ZigonautTextEngine* engine,
    const uint16_t* text, uint32_t text_length, uint32_t caret, float left,
    float top, float max_width, float height, uint32_t foreground, uint32_t background, float* caret_x) {
    if (!engine || !text || !text_length || !caret_x || !engine->target ||
        !std::isfinite(left) || !std::isfinite(top) || !std::isfinite(max_width) ||
        !std::isfinite(height) || max_width <= 0 || height <= 0) return E_INVALIDARG;
    HRESULT pending=engine->flushGlyphInstances();
    if (FAILED(pending)) return pending;
    engine->setTag(frame_command_preedit);
    IDWriteTextLayout* layout = nullptr;
    auto hr = engine->factory->CreateTextLayout(reinterpret_cast<const wchar_t*>(text), text_length,
        engine->formats[0], std::max(max_width, 1.0f), std::max(height, 1.0f), &layout);
    if (FAILED(hr)) return hr;
    DWRITE_TEXT_RANGE all{0, text_length};
    hr = layout->SetUnderline(TRUE, all);
    if (FAILED(hr)) { release(layout); return hr; }
    DWRITE_TEXT_METRICS text_metrics{};
    hr = layout->GetMetrics(&text_metrics);
    if (FAILED(hr)) { release(layout); return hr; }
    const auto preedit_rect = D2D1::RectF(left, top, left + max_width,
        top + std::max(text_metrics.height, height));
    engine->addDamage(engine->frame_damage, preedit_rect.left, preedit_rect.top,
        preedit_rect.right, preedit_rect.bottom);
    engine->target->PushAxisAlignedClip(preedit_rect, D2D1_ANTIALIAS_MODE_ALIASED);
    engine->brush->SetColor(color(background));
    engine->target->FillRectangle(D2D1::RectF(left, top,
        left + std::max(text_metrics.widthIncludingTrailingWhitespace, 1.0f),
        top + std::max(text_metrics.height, height)), engine->brush);
    engine->brush->SetColor(color(foreground));
    engine->target->DrawTextLayout(D2D1::Point2F(left, top), layout, engine->brush,
        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    engine->target->PopAxisAlignedClip();
    FLOAT x = 0, y = 0; DWRITE_HIT_TEST_METRICS metrics{};
    hr = layout->HitTestTextPosition(std::min(caret, text_length), FALSE, &x, &y, &metrics);
    *caret_x = left + x;
    release(layout);
    return hr;
}

extern "C" HRESULT zigonaut_text_engine_end_frame(ZigonautTextEngine* engine) {
    if (engine == nullptr || engine->target == nullptr || !engine->frame_active) return E_INVALIDARG;
    engine->frame_failure = {};
    HRESULT hr = engine->flushGlyphInstances();
    if (FAILED(hr)) {
        engine->frame_failure = {1, 0, hr};
        engine->frame_active=false; engine->discardTargetBitmap(); return hr;
    }
    D2D1_TAG tag1 = 0, tag2 = 0;
    hr = engine->frame_diagnostics
        ? engine->target->EndDraw(&tag1, &tag2)
        : engine->target->EndDraw();
    engine->frame_active = false;
    if (FAILED(hr)) {
        engine->frame_failure = {
            2,
            static_cast<uint32_t>((tag1 & 0xff) | (tag2 & 0xffff) << 8),
            hr,
        };
        // EndDraw failures are not transactional: earlier scene commands may have
        // executed. Recreate the retained target and require a coherent full replay.
        engine->row_active = false;
        engine->discardTargetBitmap();
        return hr;
    }
    engine->evictUnusedImages();
    const HRESULT copy_hr = engine->transferScene();
    if (FAILED(copy_hr)) {
        engine->frame_failure = {3, 0, copy_hr};
        engine->discardTargetBitmap();
        return copy_hr;
    }
    const HRESULT present = classifyPresentResult(
        engine->swap_chain->Present(0, DXGI_PRESENT_DO_NOT_WAIT));
    if (present == S_FALSE) {
        engine->present_pending = true;
        return S_FALSE;
    }
    if (present == S_OK) {
        engine->commitPresentedDamage();
        return S_OK;
    }
    engine->frame_failure = {4, 0, present};
    engine->discardTargetBitmap();
    return present;
}

extern "C" void zigonaut_text_engine_get_frame_failure(
    const ZigonautTextEngine* engine, ZigonautFrameFailure* failure) {
    if (failure != nullptr) *failure = engine == nullptr
        ? ZigonautFrameFailure{}
        : engine->frame_failure;
}

extern "C" void zigonaut_text_engine_set_frame_diagnostics(
    ZigonautTextEngine* engine, BOOL enabled) {
    if (engine != nullptr) engine->frame_diagnostics = enabled != FALSE;
}

extern "C" HRESULT zigonaut_text_engine_retry_present(ZigonautTextEngine* engine) {
    if (engine == nullptr || !engine->present_pending) return E_INVALIDARG;
    const HRESULT present = classifyPresentResult(
        engine->swap_chain->Present(0, DXGI_PRESENT_DO_NOT_WAIT));
    if (present == S_FALSE) return S_FALSE;
    if (present == S_OK) {
        engine->present_pending = false;
        engine->commitPresentedDamage();
        return S_OK;
    }
    engine->present_pending = false;
    engine->discardTargetBitmap();
    return present;
}

extern "C" void zigonaut_text_engine_abandon_pending_present(
    ZigonautTextEngine* engine) {
    if (engine != nullptr) engine->present_pending = false;
}
