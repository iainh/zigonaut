#!/bin/sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
case "$configuration" in
    debug) icon_name="ZigonautDebug" ;;
    release) icon_name="Zigonaut" ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac
icon_path="${2:-$root/assets/icons/macos/$icon_name.icon}"
app="$root/zig-out/Zigonaut.app/Contents"
rm -rf "$root/zig-out/Zigonaut.app"
mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources"
cp "$root/macos/.build/$configuration/ZigonautMac" "$app/MacOS/ZigonautMac"
cp "$root/zig-out/bin/zigonaut-pty-helper" "$app/MacOS/zigonaut-pty-helper"
cp "$root/zig-out/lib/libzigonaut-core.dylib" "$app/Frameworks/"
xcrun actool "$icon_path" \
    --compile "$app/Resources" \
    --output-format human-readable-text \
    --notices \
    --warnings \
    --output-partial-info-plist "$app/assetcatalog_generated_info.plist" \
    --app-icon "$icon_name" \
    --include-all-app-icons \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 15.0 \
    --platform macosx
rm "$app/assetcatalog_generated_info.plist"
mkdir -p "$app/Resources/Themes"
cp "$root/themes/"*.json "$app/Resources/Themes/"
mkdir -p "$app/Resources/ShellIntegration/zsh"
cp "$root/assets/shell-integration/zsh/.zshenv" "$root/assets/shell-integration/zsh/zigonaut.zsh" \
    "$app/Resources/ShellIntegration/zsh/"
mkdir -p "$app/Resources/ShellIntegration/bash" "$app/Resources/ShellIntegration/fish"
cp "$root/assets/shell-integration/bash/zigonaut.bash" "$app/Resources/ShellIntegration/bash/"
cp "$root/assets/shell-integration/fish/zigonaut.fish" "$app/Resources/ShellIntegration/fish/"
cp "$root/macos/Info.plist" "$app/Info.plist"
plutil -replace CFBundleIconFile -string "$icon_name" "$app/Info.plist"
plutil -insert CFBundleIconName -string "$icon_name" "$app/Info.plist"
if [ "$configuration" = release ]; then
    plutil -replace CFBundleIdentifier -string com.spiralpoint.zigonaut "$app/Info.plist"
fi
# Keep local builds unsigned by a developer identity, while satisfying modern
# macOS validation after all bundle mutations.
codesign --force --deep --sign - "$root/zig-out/Zigonaut.app"
