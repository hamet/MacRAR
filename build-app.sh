#!/bin/bash
# Builds MacRAR.app with icon and zip/7z/rar file associations.
# Put MacRAR-icon.png (1024x1024) next to this script to get the icon.
set -e
cd "$(dirname "$0")"

APP="MacRAR.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# compile straight into the bundle (no loose binary is left around)
swiftc -O -o "$APP/Contents/MacOS/MacRAR" MacRAR.swift

# PkgInfo helps LaunchServices identify the bundle as an application
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- icon: PNG -> .iconset -> .icns (sips + iconutil ship with macOS) ---
ICON_SRC="MacRAR-icon.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET="MacRAR.iconset"
    rm -rf "$ICONSET"; mkdir "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz             "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"      >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png"   >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/MacRAR.icns"
    rm -rf "$ICONSET"
else
    echo "note: $ICON_SRC not found, building without icon"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MacRAR</string>
    <key>CFBundleDisplayName</key>       <string>MacRAR</string>
    <key>CFBundleIdentifier</key>        <string>local.macrar</string>
    <key>CFBundleVersion</key>           <string>2.2</string>
    <key>CFBundleShortVersionString</key><string>2.2</string>
    <key>CFBundleExecutable</key>        <string>MacRAR</string>
    <key>CFBundleIconFile</key>          <string>MacRAR</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>11.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>  <string>ZIP archive</string>
            <key>CFBundleTypeRole</key>  <string>Editor</string>
            <key>LSHandlerRank</key>     <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.zip-archive</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>  <string>7-Zip archive</string>
            <key>CFBundleTypeRole</key>  <string>Editor</string>
            <key>LSHandlerRank</key>     <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>org.7-zip.7-zip-archive</string></array>
            <key>CFBundleTypeExtensions</key>
            <array><string>7z</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>  <string>RAR archive</string>
            <key>CFBundleTypeRole</key>  <string>Viewer</string>
            <key>LSHandlerRank</key>     <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>com.rarlab.rar-archive</string></array>
            <key>CFBundleTypeExtensions</key>
            <array><string>rar</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>  <string>tar archive</string>
            <key>CFBundleTypeRole</key>  <string>Editor</string>
            <key>LSHandlerRank</key>     <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.tar-archive</string></array>
            <key>CFBundleTypeExtensions</key>
            <array><string>tar</string><string>tgz</string><string>tbz2</string><string>tbz</string><string>gz</string><string>bz2</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

# ad-hoc signature so Gatekeeper doesn't complain about an unsigned local binary
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# refresh the LaunchServices registration for this bundle
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP" 2>/dev/null || true

echo "Built $APP — launch this bundle, not a bare binary."
echo "If Finder still shows the old icon: move the app, or run: killall Finder; killall Dock"
