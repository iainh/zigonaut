#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac
app="$root/zig-out/Zigonaut.app/Contents"
rm -rf "$root/zig-out/Zigonaut.app"
mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources"
cp "$root/macos/.build/$configuration/ZigonautMac" "$app/MacOS/ZigonautMac"
cp "$root/zig-out/bin/zigonaut-pty-helper" "$app/MacOS/zigonaut-pty-helper"
cp "$root/zig-out/lib/libzigonaut-core.dylib" "$app/Frameworks/"
if [ "$configuration" = debug ]; then
    iconset="$app/Resources/Zigonaut.iconset"
    mkdir "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$root/assets/icons/zigonaut-debug-master.png" \
            --out "$iconset/icon_${size}x${size}.png" >/dev/null
        double_size=$((size * 2))
        sips -z "$double_size" "$double_size" "$root/assets/icons/zigonaut-debug-master.png" \
            --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Resources/Zigonaut.icns"
    rm -rf "$iconset"
else
    cp "$root/macos/Resources/Zigonaut.icns" "$app/Resources/Zigonaut.icns"
fi
mkdir -p "$app/Resources/Themes"
cp "$root/themes/"*.json "$app/Resources/Themes/"
cp "$root/macos/Info.plist" "$app/Info.plist"
if [ "$configuration" = release ]; then
    plutil -replace CFBundleIdentifier -string com.spiralpoint.zigonaut "$app/Info.plist"
fi
# Keep local builds unsigned by a developer identity, while satisfying modern
# macOS validation after all bundle mutations.
codesign --force --deep --sign - "$root/zig-out/Zigonaut.app"
