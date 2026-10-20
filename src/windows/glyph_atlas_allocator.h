// Native lifetime wrapper for glyph_atlas_allocator.zig; skyline policy and
// storage live in Zig. DirectWrite/COM and GPU resources remain native.
#pragma once

#include <cstddef>
#include <cstdint>
#include <new>

struct ZigonautAtlasNode { uint32_t x, y, width; };
struct ZigonautAtlasState {
    ZigonautAtlasNode* nodes;
    size_t length, capacity;
    uint32_t extent;
};
struct ZigonautAtlasRect { uint32_t x, y, width, height; };

extern "C" bool zigonaut_atlas_init(ZigonautAtlasState*, uint32_t extent);
extern "C" void zigonaut_atlas_deinit(ZigonautAtlasState*);
extern "C" bool zigonaut_atlas_reserve(ZigonautAtlasState*, uint32_t width,
    uint32_t height, ZigonautAtlasRect*);

class GlyphAtlasAllocator {
public:
    using Rect = ZigonautAtlasRect;

    explicit GlyphAtlasAllocator(uint32_t extent) {
        if (!zigonaut_atlas_init(&state_, extent)) throw std::bad_alloc();
    }
    ~GlyphAtlasAllocator() { zigonaut_atlas_deinit(&state_); }
    GlyphAtlasAllocator(const GlyphAtlasAllocator&) = delete;
    GlyphAtlasAllocator& operator=(const GlyphAtlasAllocator&) = delete;

    // Monotonic and transactional: failure never changes the skyline.
    bool reserve(uint32_t width, uint32_t height, Rect& result) {
        return zigonaut_atlas_reserve(&state_, width, height, &result);
    }

    size_t nodeCount() const { return state_.length; }
    uint32_t extent() const { return state_.extent; }
private:
    ZigonautAtlasState state_{};
};
