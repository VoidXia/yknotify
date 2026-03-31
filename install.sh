#!/bin/bash
set -euo pipefail

APP_NAME="yknotify"
APP_DIR="$HOME/Applications/$APP_NAME.app"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "$APP_DIR"
    echo "yknotify uninstalled"
    exit 0
fi

# Build
swiftc -O -o "$APP_NAME" yknotify.swift

# Create .app bundle
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$APP_NAME" "$APP_DIR/Contents/MacOS/"
cat > "$APP_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.user.yknotify</string>
    <key>CFBundleName</key>
    <string>yknotify</string>
    <key>CFBundleExecutable</key>
    <string>yknotify</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

rm -f "$APP_NAME"
echo "Installed to $APP_DIR"
echo "Open it with: open $APP_DIR"
