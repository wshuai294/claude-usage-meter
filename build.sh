#!/bin/zsh
# Builds build/ClaudeUsage.app.
#   ./build.sh --install [dir]   also copies it to <dir>/"Claude Usage.app" (default ~/Applications) and launches it.
set -euo pipefail
cd "${0:A:h}"

APP=build/ClaudeUsage.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    Sources/*.swift -o "$APP/Contents/MacOS/ClaudeUsage"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.claude-usage-meter</string>
    <key>CFBundleName</key><string>ClaudeUsage</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
    DIR="${2:-$HOME/Applications}"
    mkdir -p "$DIR"
    DEST="$DIR/Claude Usage.app"
    pkill -x ClaudeUsage 2>/dev/null || true
    while pgrep -x ClaudeUsage >/dev/null; do sleep 0.2; done
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST" 2>/dev/null || { sleep 1; open "$DEST"; }   # LaunchServices can briefly refuse right after quit
    echo "Installed to $DEST"
else
    echo "Built $APP"
fi
