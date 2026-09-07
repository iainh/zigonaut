# Research: macOS icon HIG audit

**Date**: 2026-09-06
**Question**: Do the realistic cosmonaut release and debug icons meet Apple's current app-icon guidance?
**Status**: Complete

## Context

The current icons combine a detailed helmet PNG, a native glass visor SVG and a native glass terminal-prompt SVG. This review assesses the latest assets after the lower-left locking-ring cutout repair. No icon assets or configuration were changed during the audit.

Apple's app-icon HIG was fetched live; its latest listed revision is 2026-06-08. Distinguish specifications from recommendations such as “prefer” and “consider.” Asset compilation is not HIG certification or an App Review decision.

## Findings

### Structure aligns with the documented format

- Both helmet PNGs are 1024×1024 RGBA; both SVG layers use a 1024×1024 canvas.
- Each document has three foreground groups, within Icon Composer's documented maximum of four.
- Backgrounds are opaque gradients defined in Icon Composer. The source layers do not bake in the rounded-square canvas mask.
- The helmet has transparent surroundings. Foreground transparency is appropriate; the background must be opaque.
- The prompt uses vector outlines, not a font dependency or a screenshot of terminal UI.
- Final assets compiled into `Assets.car` and ICNS fallbacks in the preceding repair verification.
- Source PNGs have no embedded colour-profile metadata. Background colours explicitly use sRGB; SVG hex colours use the normal sRGB interpretation. Explicitly tagging PNGs with their intended profile would improve colour reproducibility, but missing metadata alone does not establish a HIG violation.

### Composition and identity are sound

The repaired native default and clear-light renders show complete helmet silhouettes, including the locking ring. The source alpha bounds are approximately x=104–917 and y=60–922. Content appears horizontally centred and untruncated. Exact conformity to Apple's production-template grid was not measured.

The helmet and `>_` convey the space/terminal identity. The prompt is meaningful iconography, not redundant app-name text. Default, dark, clear and tinted treatments retain the same core geometry. Release and debug share the design and differ in colour.

### Realism is a deliberate trade-off, not a prohibited format

Apple says “Embrace simplicity” and “Prefer illustrations to photos.” This is a photorealistic illustration rather than a photograph, but its dense seams, fasteners and weathering incur the same small-size risks. Existing 32px and 64px renders retain the helmet and prompt; fine detail collapses into texture at 32px.

PNG is explicitly recommended for raster artwork. The HIG does not require every layer to be vector or glass. Keeping the physical shell non-glass is supported by Icon Composer's per-layer Effects toggle. Returning to the rejected flat pictogram is not necessary.

### Static visor reflections deserve refinement

The helmet PNG still includes visor reflections and material shading. A native glass coating adds system specular highlights and refraction above it. This creates a potential conflict between fixed and dynamic lighting, although no obvious overlay misalignment is visible in the static previews.

The rounded-square background lighting is system-generated, not baked into the helmet PNG. The physical shell's material shading should also be distinguished from decorative icon-level drop shadows and glows.

The HIG recommends letting the system handle effects, but explicitly permits intentional custom effects when carefully tested. Reduce the strong baked visor reflections before removing realistic shell detail. Refraction has no visible effect before OS version 27, according to Icon Composer documentation.

### Appearance tuning is the main outstanding issue

- Default: strongest balance of identity, contrast and material detail.
- Dark: prompt remains clear, but the light shell is comparatively bright and the lower silhouette loses separation.
- Clear light: pale visor, shell and background compress contrast; the helmet's construction loses definition.
- Clear dark: recognisable, with some dark-on-dark loss around the lower silhouette.
- Tinted light: prompt reads well; pale helmet details flatten.
- Tinted dark: the purple prompt, especially the underscore, is too subdued against the dark visor for comfortable small-size recognition.

Automatically generated appearances are allowed. They are not necessarily well-tuned appearances. The HIG requires the design goal of visibility, legibility and recognition in every appearance; it does not prescribe an app-icon contrast ratio here.

## Options considered

| Option | Benefits | Costs |
| --- | --- | --- |
| Keep the current design unchanged | Preserves realism; valid layered assets | Leaves contrast and fixed-lighting weaknesses |
| Refine appearances and baked visor reflections | Preserves requested realism while improving HIG alignment | Requires targeted artwork and material tuning |
| Return to a simplified vector helmet | Maximizes simplicity and independent shape control | Discards the explicitly requested realistic cosmonaut identity |

## Recommendation

Keep the realistic helmet. Prioritize brighter prompt separation in tinted dark, stronger visor/shell separation in clear light, and restrained dark-mode shell highlights. Then reduce baked visor reflections so native glass contributes the dominant optical highlights. Retain meaningful mechanical structure; remove only microtexture that adds visual noise.

## Open questions and verification limits

- Dynamic lighting, wallpaper interaction and placement beside system icons in Dock/Finder have not been evaluated in this audit.
- The six-appearance and 32px/64px sheets predate only the locking-ring alpha repair; their material settings and geometry otherwise match the current design. Current repaired default and clear-light renders were inspected separately.
- Native 16px output and a range of user-selected tint colours still need focused review.
- This is a HIG design assessment, not an App Store approval guarantee or a full App Review Guidelines audit.

## Implementation follow-up

The subsequent implementation preserves the realistic helmet and the repaired locking-ring alpha channel exactly. It applies mild edge-preserving denoising, reduces blue visor highlight intensity, embeds an sRGB profile in both PNGs and brightens/thickens the vector prompt. The underscore is now 44 canvas pixels high rather than 34. These changes retain the native glass coating and mechanical construction.

Both variants compile successfully with `actool`. Fresh CLI renders cover all six appearances, 16px/32px/64px sizes, and tinted-dark hue positions 0, 0.33 and 0.66 at strengths 0.25 and 0.75. At 32px and 64px the prompt is clear; 16px remains primarily a silhouette with tiny terminal marks. Low-strength blue tints still have weak contrast. Clear-light tuning gives the visor modestly darker, more uniform separation, rather than restoring default-mode contrast.

Interactive Composer editing clarified the opacity schema: `opacity-specializations` replaces scalar `opacity` and includes an explicit default value. The visor now uses 0.3 by default and 0.82 for the tinted specialization, with a dark monochrome fill and multiply blend. The prompt uses a light monochrome fill and plus-lighter blend. The corrected visor settings visibly affect clear-light output. Earlier byte-identical exports do not establish a renderer bug, and the final settings do not substantially brighten tinted-dark output. User-selected tint remains a material contrast limitation.

Permission was granted and actual Finder and Icon Composer previews were inspected. Finder showed both current icons beside system-app aliases, with complete silhouettes and readable prompts. Composer 2.0 (125) on macOS 27 was inspected with warm orange/pink and purple wallpapers, including clear-light, clear-dark and tinted-dark states. These supplement the six-appearance and small-size sheets; they are not a Dock test. Moving-light verification remains incomplete: a temporary copy was opened in Composer 1.6 (99.1), but a changed light angle was not verified. Intermittent runner disconnections interrupted the final capture.

On the tested macOS 27 build (26A5425a), the permission formerly labelled Accessibility is under **System Settings → Privacy & Security → Device Control and Data Access**. Screen capture uses **Screen & System Audio Recording**. Zigonaut was already listed; permission troubleshooting is complete. The installed `/Applications/Zigonaut.app` was not replaced, avoiding another ad-hoc-signature permission reset.

The implementation improves HIG alignment without sacrificing the requested realism. It is not a claim of full HIG compliance: very dark tints, 16px detail and unverified moving-light behaviour remain limitations. The initial findings above describe the pre-refinement audit; this follow-up records the current result.

Inspected implementation previews are in `/tmp/zigonaut-hig-live/`: `final-appearances.jpg`, `final-small-tints.jpg`, `finder.jpg`, `wallpaper.jpg`, `clear-dark-wallpaper.jpg` and `tinted-dark-wallpaper.jpg`. These are temporary local review artefacts, not committed assets.

## Final art direction

Subsequent requested refinements supersede the prompt and coating settings described above:

- Both visor SVGs now use midnight blue (`#14283e`) to separate the glass from the background without changing its opacity in the default appearance.
- The prompt uses white bitmap-style vector outlines and a square underscore. Two successive 20% reductions leave it at 64% of the original bitmap design's dimensions, with its centre unchanged.
- Front-to-back group order is glass visor, terminal display, helmet. The prompt has no glass effect, specular highlight or drop shadow of its own, so it sits behind the native glass like a CRT display.
- The monochrome visor opacity is reduced from 0.82 to 0.3 to avoid obscuring the underlying prompt. Default opacity remains 0.3.

Both final icons compile with `actool`. Native macOS 27 renders of all six appearances and default 32px/64px samples were inspected after the layering change. The prompt remains recognisable; tinted dark still has the weakest contrast. Final comparison and appearance sheets are `/tmp/zigonaut-crt-glass/comparison.jpg` and `/tmp/zigonaut-crt-glass/review-final.jpg`. The earlier wallpaper and Finder checks predate these final refinements; moving-light verification remains incomplete.

## References

- [Apple HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- Source: `assets/icons/macos/Zigonaut.icon/` and `assets/icons/macos/ZigonautDebug.icon/`.
- Integration: `macos/assemble.sh`.
- Inspected previews: `/tmp/zigonaut-ring-fixed/repaired-icons.jpg`, `/tmp/zigonaut-cosmonaut-review/appearances.jpg`, `/tmp/zigonaut-cosmonaut-review/small-and-fallback.png`.
