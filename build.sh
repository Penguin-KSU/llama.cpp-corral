#!/bin/sh
# build Corral.app from main.swift + icon.swift + dashboard.swift + l10n.swift
set -e
cd "$(dirname "$0")"

APP=Corral.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# app + status bar icons ship pre-rendered in icons/ (see icons/README)
cp icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp icons/status_idle.png icons/status_loaded.png "$APP/Contents/Resources/"

swiftc -O -o "$APP/Contents/MacOS/corral" main.swift icon.swift dashboard.swift l10n.swift proxy.swift \
    -target "$(uname -m)-apple-macos14.0" \
    -framework AppKit -framework ServiceManagement -framework SwiftUI -framework Network

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>corral</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.penguinM.corral</string>
    <key>CFBundleName</key>
    <string>Corral</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Corral model config</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.penguinM.corral.model-config</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.penguinM.corral.model-config</string>
            <key>UTTypeDescription</key>
            <string>Corral model config</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>llm</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# register the bundle (and its .llm document type) with LaunchServices so
# double-clicking a config file in Finder opens it with this app
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -f "$PWD/$APP"

echo "built: $PWD/$APP"
