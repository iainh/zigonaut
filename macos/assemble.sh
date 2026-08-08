#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
app="$root/zig-out/Zigonaut.app/Contents"
rm -rf "$root/zig-out/Zigonaut.app"
mkdir -p "$app/MacOS" "$app/Frameworks"
cp "$root/macos/.build/debug/ZigonautMac" "$app/MacOS/ZigonautMac"
cp "$root/zig-out/bin/zigonaut-pty-helper" "$app/MacOS/zigonaut-pty-helper"
cp "$root/zig-out/lib/libzigonaut-core.dylib" "$app/Frameworks/"
cp "$root/macos/Info.plist" "$app/Info.plist"
# Keep local builds unsigned by a developer identity, while satisfying modern
# macOS validation after all bundle mutations.
codesign --force --deep --sign - "$root/zig-out/Zigonaut.app"
