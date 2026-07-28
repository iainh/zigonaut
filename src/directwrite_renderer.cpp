#include "directwrite_renderer.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <d2d1_1.h>
#include <d3d11.h>
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

struct LayoutEntry {
    IDWriteTextLayout* layout;
    std::list<const LayoutKey*>::iterator recency;
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
};

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

uint32_t packedColumns(uint32_t start, uint32_t span) {
    return start | ((span - 1) << 16);
}

uint32_t startColumn(uint32_t packed) {
    return packed & 0xffff;
}

uint32_t endColumn(uint32_t packed) {
    return startColumn(packed) + 1 + ((packed >> 16) & 1);
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

class GridTextRenderer;

struct ZigonautTextEngine {
    IDWriteFactory* factory = nullptr;
    IDWriteFactory2* factory2 = nullptr;
    IDWriteRenderingParams* rendering_params = nullptr;
    IDWriteFontCollection* fonts = nullptr;
    IDWriteFontFace* normal_face = nullptr;
    IDWriteTextFormat* formats[4] = {};
    ID2D1Factory1* d2d_factory = nullptr;
    ID3D11Device* d3d_device = nullptr;
    ID2D1Device* d2d_device = nullptr;
    ID2D1DeviceContext* target = nullptr;
    IDXGISwapChain1* swap_chain = nullptr;
    ID2D1Bitmap1* target_bitmap = nullptr;
    ID2D1SolidColorBrush* brush = nullptr;
    std::map<LayoutKey, LayoutEntry, LayoutKeyLess> layouts;
    std::list<const LayoutKey*> layout_recency;
    uint64_t layout_creation_count = 0;
    std::vector<RowCell> row_cells;
    std::u16string row_text;
    RowSegment row_segment;
    GridTextRenderer* grid_renderer = nullptr;
    std::wstring family;
    std::wstring locale;
    HWND hwnd = nullptr;
    uint32_t font_size = 18;
    uint32_t dpi = 96;
    ZigonautCellMetrics metrics = {9, 18, 14};
    float row_origin_x = 0.0f;
    float row_top = 0.0f;
    float row_cell_width = 0.0f;
    float row_cell_height = 0.0f;
    uint32_t frame_background = 0;
    bool row_active = false;

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

        IDXGIDevice* dxgi_device = nullptr;
        hr = d3d_device->QueryInterface(IID_PPV_ARGS(&dxgi_device));
        if (FAILED(hr)) return hr;
        hr = d2d_factory->CreateDevice(dxgi_device, &d2d_device);
        if (SUCCEEDED(hr)) {
            hr = d2d_device->CreateDeviceContext(
                D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                &target);
        }

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
                locale.c_str(),
                &formats[index]);
            if (FAILED(hr)) return hr;
            formats[index]->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        }
        return S_OK;
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
        if (target != nullptr) target->SetTarget(nullptr);
        release(target_bitmap);
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
            layout_recency.splice(layout_recency.end(), layout_recency,
                existing->second.recency);
            *result = existing->second.layout;
            return S_OK;
        }
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
            LayoutEntry{layout, {}}).first;
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
        return S_OK;
    }

    HRESULT ensureTarget(uint32_t width, uint32_t height) {
        if (target == nullptr || swap_chain == nullptr) return E_HANDLE;
        if (target_bitmap != nullptr &&
            target_bitmap->GetPixelSize().width == width &&
            target_bitmap->GetPixelSize().height == height) return S_OK;

        discardTargetBitmap();
        HRESULT hr = swap_chain->ResizeBuffers(
            2,
            width,
            height,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            0);
        if (FAILED(hr)) return hr;

        IDXGISurface* surface = nullptr;
        hr = swap_chain->GetBuffer(0, IID_PPV_ARGS(&surface));
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
        if (SUCCEEDED(hr)) target->SetTarget(target_bitmap);
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
        uint32_t underline_color,
        bool bold,
        bool italic,
        bool faint,
        bool strikethrough,
        bool overline,
        uint8_t underline,
        ZigonautCellOccupancy occupancy) {
        if (target == nullptr || brush == nullptr) return E_UNEXPECTED;
        const auto rect = D2D1::RectF(left, top, left + width, top + height);
        if (background != frame_background) {
            brush->SetColor(color(background));
            target->FillRectangle(rect, brush);
        }
        if (faint) {
            foreground = blend(foreground, background);
            underline_color = blend(underline_color, background);
        }
        brush->SetColor(color(underline_color));
        const float underline_y = top + height - 1.5f;
        if (underline != 0) {
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
        if (overline) {
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
        float cell_height) {
        row_cells.clear();
        row_text.clear();
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
    explicit GridTextRenderer(ZigonautTextEngine* engine)
        : engine_(engine) {}

    void setSegment(const RowSegment* segment) {
        segment_ = segment;
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
        const auto& segment = *segment_;

        std::vector<FLOAT> advances(
            glyph_run->glyphAdvances,
            glyph_run->glyphAdvances + glyph_run->glyphCount);
        float origin_x = engine_->row_origin_x;

        if (description != nullptr && description->clusterMap != nullptr &&
            description->stringLength > 0) {
            std::vector<ClusterSpan> spans(glyph_run->glyphCount);
            std::vector<UINT16> glyph_starts;
            glyph_starts.reserve(std::min<UINT32>(
                description->stringLength,
                glyph_run->glyphCount));
            uint32_t run_start_column = UINT32_MAX;
            uint32_t run_end_column = 0;
            for (UINT32 index = 0; index < description->stringLength; ++index) {
                const uint32_t text_index = description->textPosition + index;
                if (text_index >= segment.columns.size()) break;
                const UINT16 glyph_start = description->clusterMap[index];
                if (glyph_start >= glyph_run->glyphCount) continue;
                auto& span = spans[glyph_start];
                if (!span.used) {
                    span.used = true;
                    glyph_starts.push_back(glyph_start);
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

            std::sort(glyph_starts.begin(), glyph_starts.end());
            for (size_t index = 0; index < glyph_starts.size(); ++index) {
                const UINT32 glyph_start = glyph_starts[index];
                const UINT32 glyph_end = index + 1 < glyph_starts.size()
                    ? glyph_starts[index + 1]
                    : glyph_run->glyphCount;
                if (glyph_start >= glyph_end) continue;
                const auto& span = spans[glyph_start];
                const uint32_t cluster_left = startColumn(
                    segment.columns[span.first_text_index]);
                const uint32_t cluster_right =
                    span.text_end < segment.columns.size()
                    ? startColumn(segment.columns[span.text_end])
                    : endColumn(segment.columns[span.text_end - 1]);
                const float expected = static_cast<float>(
                    cluster_right - cluster_left) * engine_->row_cell_width;
                zigonaut_fit_cluster_advances(
                    advances.data() + glyph_start,
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
        adjusted.glyphAdvances = advances.data();
        const float origin_y = engine_->row_top +
            static_cast<float>(engine_->metrics.baseline);
        bool rendered_color = false;
        if (engine_->factory2 != nullptr) {
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
                std::vector<std::unique_ptr<OwnedColorLayer>> owned_layers;
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
                        auto owned = std::make_unique<OwnedColorLayer>();
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
                        owned_layers.push_back(std::move(owned));
                    } catch (...) {
                        enumeration_complete = false;
                        break;
                    }
                }
                if (enumeration_complete) {
                    for (const auto& layer : owned_layers) {
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
                        engine_->target->DrawGlyphRun(
                            D2D1::Point2F(layer->origin_x, layer->origin_y),
                            &color_run,
                            engine_->brush,
                            measuring_mode);
                    }
                    rendered_color = !owned_layers.empty();
                }
                release(layers);
            }
        }
        if (!rendered_color) {
            engine_->brush->SetColor(color(segment.foreground));
            engine_->target->DrawGlyphRun(
                D2D1::Point2F(origin_x, origin_y),
                &adjusted,
                engine_->brush,
                measuring_mode);
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
};

ZigonautTextEngine::~ZigonautTextEngine() {
    delete grid_renderer;
    discardTargetBitmap();
    release(brush);
    release(target);
    release(d2d_device);
    release(swap_chain);
    release(d3d_device);
    release(d2d_factory);
    clearLayouts();
    for (auto*& format : formats) release(format);
    release(normal_face);
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

    if (grid_renderer == nullptr) {
        grid_renderer = new (std::nothrow) GridTextRenderer(this);
        if (grid_renderer == nullptr) return E_OUTOFMEMORY;
    }
    grid_renderer->setSegment(&segment);
    return layout->Draw(nullptr, grid_renderer, 0.0f, 0.0f);
}

void ZigonautTextEngine::endRow() {
    if (!row_active) return;
    row_active = false;

    auto& segment = row_segment;
    segment.clear();
    bool has_segment = false;
    const auto flush = [&]() {
        if (has_segment) drawSegment(segment);
        segment.clear();
        has_segment = false;
    };

    for (const auto& cell : row_cells) {
        if (cell.occupancy == ZIGONAUT_CELL_WIDE_TAIL) continue;
        const std::u16string_view cell_text = cell.text_length == 0
            ? std::u16string_view{}
            : std::u16string_view(row_text.data() + cell.text_offset, cell.text_length);
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
    flush();
    for (const auto& cell : row_cells) {
        if (!cell.strikethrough) continue;
        const float left = row_origin_x +
            static_cast<float>(cell.column) * row_cell_width;
        const float y = row_top + row_cell_height * 0.55f;
        brush->SetColor(color(cell.foreground));
        target->DrawLine(
            D2D1::Point2F(left, y),
            D2D1::Point2F(left + row_cell_width, y),
            brush,
            1.0f);
    }
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

extern "C" HRESULT zigonaut_benchmark_layout_cache(
    uint32_t repetitions,
    ZigonautLayoutCacheBenchmark* result) {
    if (repetitions == 0 || result == nullptr) return E_INVALIDARG;
    *result = {};
    ZigonautTextEngine* engine = nullptr;
    HRESULT hr = zigonaut_text_engine_create(L"Consolas", 18, 96, &engine);
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

extern "C" HRESULT zigonaut_text_engine_set_dpi(
    ZigonautTextEngine* engine,
    uint32_t dpi) {
    if (engine == nullptr || dpi == 0) return E_INVALIDARG;
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
    return engine->refreshRenderingParams();
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
    engine->hwnd = reinterpret_cast<HWND>(hwnd);
    return engine->refreshRenderingParams();
}

extern "C" void* zigonaut_text_engine_get_swap_chain(
    ZigonautTextEngine* engine) {
    return engine == nullptr ? nullptr : engine->swap_chain;
}

extern "C" HRESULT zigonaut_text_engine_begin_frame(
    ZigonautTextEngine* engine,
    uint32_t width,
    uint32_t height,
    uint32_t background) {
    if (engine == nullptr || width == 0 || height == 0) return E_INVALIDARG;
    const HRESULT hr = engine->ensureTarget(width, height);
    if (FAILED(hr)) return hr;
    engine->frame_background = background;
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
        occupancy);
}

extern "C" HRESULT zigonaut_text_engine_draw_image(ZigonautTextEngine* engine,
    const uint8_t* rgba, size_t rgba_length, uint32_t image_width, uint32_t image_height,
    float dl, float dt, float dw, float dh, float sl, float st, float sw, float sh,
    float cl, float ct, float cr, float cb) {
    if (!engine || !engine->target || !rgba || !image_width || !image_height ||
        image_width > UINT32_MAX / 4 ||
        !std::isfinite(dl) || !std::isfinite(dt) || !std::isfinite(dw) || !std::isfinite(dh) ||
        !std::isfinite(sl) || !std::isfinite(st) || !std::isfinite(sw) || !std::isfinite(sh) ||
        !std::isfinite(cl) || !std::isfinite(ct) || !std::isfinite(cr) || !std::isfinite(cb) ||
        dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0 || sl < 0 || st < 0 ||
        sl > image_width || st > image_height || sw > image_width - sl || sh > image_height - st ||
        cl >= cr || ct >= cb || !std::isfinite(dl + dw) || !std::isfinite(dt + dh) ||
        !std::isfinite(sl + sw) || !std::isfinite(st + sh)) return E_INVALIDARG;
    constexpr size_t max_image_bytes = 32u * 1024u * 1024u;
    if (static_cast<size_t>(image_width) > max_image_bytes / 4u / image_height) return E_INVALIDARG;
    const size_t byte_length = static_cast<size_t>(image_width) * image_height * 4;
    if (rgba_length != byte_length) return E_INVALIDARG;
    std::unique_ptr<uint8_t[]> premultiplied(new (std::nothrow) uint8_t[byte_length]);
    if (!premultiplied) return E_OUTOFMEMORY;
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
    HRESULT hr = engine->target->CreateBitmap(D2D1::SizeU(image_width, image_height),
        premultiplied.get(), image_width * 4, properties, &bitmap);
    if (FAILED(hr)) return hr;
    engine->target->PushAxisAlignedClip(D2D1::RectF(cl, ct, cr, cb), D2D1_ANTIALIAS_MODE_ALIASED);
    engine->target->DrawBitmap(bitmap, D2D1::RectF(dl, dt, dl + dw, dt + dh), 1.0f,
        D2D1_INTERPOLATION_MODE_LINEAR, D2D1::RectF(sl, st, sl + sw, st + sh));
    engine->target->PopAxisAlignedClip();
    release(bitmap);
    return S_OK;
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
    uint32_t cursor_color,
    uint8_t style) {
    if (engine == nullptr || engine->target == nullptr || engine->brush == nullptr) return;
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
    engine->brush->SetColor(color(background));
    engine->target->FillRectangle(D2D1::RectF(left, top,
        left + std::max(text_metrics.widthIncludingTrailingWhitespace, 1.0f),
        top + std::max(text_metrics.height, height)), engine->brush);
    engine->brush->SetColor(color(foreground));
    engine->target->DrawTextLayout(D2D1::Point2F(left, top), layout, engine->brush,
        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    FLOAT x = 0, y = 0; DWRITE_HIT_TEST_METRICS metrics{};
    hr = layout->HitTestTextPosition(std::min(caret, text_length), FALSE, &x, &y, &metrics);
    *caret_x = left + x;
    release(layout);
    return hr;
}

extern "C" HRESULT zigonaut_text_engine_end_frame(ZigonautTextEngine* engine) {
    if (engine == nullptr || engine->target == nullptr) return E_INVALIDARG;
    const HRESULT hr = engine->target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) engine->discardTargetBitmap();
    if (FAILED(hr)) return hr;
    return engine->swap_chain->Present(1, 0);
}

extern "C" void zigonaut_fit_cluster_advances(
    float* advances,
    uint32_t glyph_count,
    float expected_width) {
    if (advances == nullptr || glyph_count == 0) return;
    float natural_width = 0.0f;
    for (uint32_t index = 0; index < glyph_count; ++index) {
        natural_width += advances[index];
    }
    advances[glyph_count - 1] += expected_width - natural_width;
}
