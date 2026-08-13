# Windows GPU acceleration audit

Zigonaut's Windows renderer already keeps the expensive pixel work on the GPU. Direct2D renders text, images, backgrounds and decorations into a device-local scene texture. D3D11 composites cached glyphs, shifts retained scroll content and copies damaged scene regions to the swap-chain buffer. The remaining useful change is to reduce CPU-side Direct2D command submission for adjacent cell backgrounds.

## Candidates

| Candidate | Test | Result |
| --- | --- | --- |
| Coalesce adjacent equal-colour cell backgrounds | A/B 400 rows of 120 highlighted cells; compare legacy and coalesced GPU textures in the damage-transfer test | Implemented. Fill calls fell from 48,000 to 400. CPU row submission improved by 74–76% in two final ReleaseFast runs. |
| Upload straight-alpha images and let Direct2D premultiply | Compare a 4×4 partial-alpha corpus with the existing CPU-premultiplied output, then benchmark 512×512 generation updates | Rejected. The hardware device returns `WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT` for a straight-alpha `DXGI_FORMAT_R8G8B8A8_UNORM` bitmap. A custom D3D conversion pass would add resource allocation, an `EndDraw` boundary and cross-API synchronization to each new generation. |

The following ideas did not become implementation candidates:

- **Batch decorations in D3D11.** Direct2D already rasterizes them on the GPU. A new pipeline would mainly reduce API calls, while adding painter-order and pixel-alignment risk for five underline styles, overlines and strikethroughs. Profile decorated workloads before reconsidering it.
- **Generate pseudographics in a shader.** The CPU generates each mask once per codepoint, span and cell metric. Both the Direct2D bitmap and atlas placement are cached, so a shader would add a second pseudographic implementation for little warm-path benefit.
- **Expand compact glyph records on the GPU.** Warm fragmented rows already use one `DrawInstanced` call and a reused triple-buffered `D3D11_MAP_WRITE_DISCARD` upload. Moving more instance construction into shaders would not remove DirectWrite shaping or cache lookup.
- **Move row shaping to DirectX.** DirectWrite shaping, terminal-cell segmentation and colour policy are semantic CPU work, not rasterization. They are not suitable GPU jobs.
- **Accelerate scene transfer or scrolling.** These paths already use `CopyResource` and `CopySubresourceRegion`; damage-aware transfer and retained scrolling have pixel-equivalence tests and CPU/GPU benchmarks.

## Retained change

The row builder now holds one pending background rectangle. It extends the rectangle while subsequent cells are adjacent, have the same colour and share vertical bounds. It flushes at colour gaps and before underlines or overlines, preserving painter order. Non-row drawing is unchanged.

ReleaseFast A/B results on the same machine:

| Run | Per-cell fills | Coalesced fills | Change |
| --- | ---: | ---: | ---: |
| 1 | 56.75 µs/row | 13.53 µs/row | 76.15% faster |
| 2 | 53.59 µs/row | 13.66 µs/row | 74.50% faster |

This is intentionally a Direct2D submission optimization, not a claim that background pixels were previously rasterized on the CPU.
