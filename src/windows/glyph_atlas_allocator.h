// Fixed skyline allocator translated and adapted from Ghostty src/font/Atlas.zig
// at commit f5880782fe34faccd30bb0c903055987171b6370.
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors; MIT license:
// licenses/Ghostty-LICENSE.txt. The original cites Jukka Jylanki's
// RectangleBinPack work and freetype-gl's texture-atlas skyline implementation;
// those provenance references are intentionally preserved here. This adaptation
// keeps a one-pixel guard around every reservation rather than only the atlas edge.
#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>
#include <vector>

class GlyphAtlasAllocator {
public:
    struct Rect { uint32_t x, y, width, height; };

    explicit GlyphAtlasAllocator(uint32_t extent) : extent_(extent) {
        nodes_.push_back({0, 0, extent_});
    }

    // Monotonic and transactional: failure never changes the skyline.
    bool reserve(uint32_t width, uint32_t height, Rect& result) {
        if (extent_ < 3 || !width || !height || width > extent_ - 2 || height > extent_ - 2 ||
            width > std::numeric_limits<uint32_t>::max() - 2 ||
            height > std::numeric_limits<uint32_t>::max() - 2) return false;
        const uint32_t w = width + 2, h = height + 2;
        size_t best = nodes_.size(); uint32_t best_y = UINT32_MAX, best_x = UINT32_MAX;
        for (size_t i = 0; i < nodes_.size(); ++i) {
            uint32_t y = 0;
            if (fit(i, w, h, y) && (y < best_y || (y == best_y && nodes_[i].width < nodes_[best].width))) {
                best = i; best_y = y; best_x = nodes_[i].x;
            }
        }
        if (best == nodes_.size()) return false;
        auto next = nodes_;
        next.insert(next.begin() + best, {best_x, best_y + h, w});
        for (size_t i = best + 1; i < next.size();) {
            const uint32_t previous_end = next[i - 1].x + next[i - 1].width;
            if (next[i].x >= previous_end) break;
            const uint32_t shrink = previous_end - next[i].x;
            if (shrink >= next[i].width) next.erase(next.begin() + i);
            else { next[i].x += shrink; next[i].width -= shrink; break; }
        }
        for (size_t i = 0; i + 1 < next.size();) {
            if (next[i].y == next[i + 1].y) {
                next[i].width += next[i + 1].width;
                next.erase(next.begin() + i + 1);
            } else ++i;
        }
        nodes_.swap(next);
        result = {best_x + 1, best_y + 1, width, height};
        return true;
    }

    size_t nodeCount() const { return nodes_.size(); }
    uint32_t extent() const { return extent_; }
private:
    struct Node { uint32_t x, y, width; };
    uint32_t extent_;
    std::vector<Node> nodes_;
    bool fit(size_t index, uint32_t width, uint32_t height, uint32_t& y) const {
        const uint32_t x = nodes_[index].x;
        if (x > extent_ - width) return false;
        uint32_t remaining = width; y = nodes_[index].y;
        for (size_t i = index; remaining; ++i) {
            if (i == nodes_.size()) return false;
            y = std::max(y, nodes_[i].y);
            if (y > extent_ - height) return false;
            if (nodes_[i].width >= remaining) break;
            remaining -= nodes_[i].width;
        }
        return true;
    }
};
