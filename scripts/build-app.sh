#!/bin/bash
#
# Builds AgentBell.app from the Swift package.
#
#   scripts/build-app.sh            build release into build/AgentBell.app and launch it
#   scripts/build-app.sh --install     replace the installed copy and launch it
#   scripts/build-app.sh --no-launch   build, package and sign without opening the app
#
# Notifications only work from inside an app bundle, so run the .app rather than
# `swift run` when testing anything beyond the panel.

set -euo pipefail

INSTALL=0
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --no-launch) LAUNCH=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/AgentBell.app"
BUNDLE_ID="com.agentbell.AgentBell"
VERSION="1.1.0"

cd "$ROOT"

echo "==> swift build -c release"
swift build -c release --product AgentBell
swift build -c release --product agent-bell-hook
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBell" "$APP/Contents/MacOS/AgentBell"
# Copied to ~/Library/Application Support/AgentBell/bin on connect; settings.json points there.
cp "$BIN_DIR/agent-bell-hook" "$APP/Contents/MacOS/agent-bell-hook"
# Packaged by scripts/make-icon.swift; notification banners show it.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Resources/DesktopMascot" "$APP/Contents/Resources/DesktopMascot"
cp -R "$ROOT/Resources/Donate" "$APP/Contents/Resources/Donate"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>AgentBell</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AgentBell</string>
    <key>CFBundleDisplayName</key><string>AgentBell</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentBell 要控制你的终端（Ghostty、iTerm2 或「终端」），回到会话所在的窗口和标签页，或在那里打开新会话。</string>
</dict>
</plist>
PLIST

echo "==> signing"
# macOS keys the "control Ghostty" grant to the code signature. An ad-hoc signature
# changes on every build, so each rebuild would ask again. A development identity keeps
# the signature stable; without one we fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "    no signing identity, using ad-hoc; Ghostty permission resets on rebuild"
else
  echo "    $IDENTITY"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.hook" "$APP/Contents/MacOS/agent-bell-hook"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

quit_running_copy() {
  pkill -x AgentBell 2>/dev/null && sleep 0.5 || true
}

if [ "$INSTALL" = 1 ]; then
  echo "==> installing into /Applications"
  DEST="/Applications/AgentBell.app"
  STAGING="$(mktemp -d "/Applications/.AgentBell-install.XXXXXX")"
  BACKUP="$STAGING/previous.app"
  STAGED_APP="$STAGING/AgentBell.app"
  REPLACING=0
  COMMITTED=0

  cleanup_install() {
    local status=$?
    if [ "$COMMITTED" = 0 ]; then
      if [ "$REPLACING" = 1 ] && [ ! -e "$STAGED_APP" ]; then
        rm -rf "$DEST"
      fi
      if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
        if ! mv "$BACKUP" "$DEST"; then
          echo "    could not restore the previous app; it is available at $BACKUP" >&2
          return 1
        fi
      fi
    fi
    rm -rf "$STAGING"
    return "$status"
  }
  trap cleanup_install EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ditto "$APP" "$STAGED_APP"
  codesign --verify --strict "$STAGED_APP/Contents/MacOS/agent-bell-hook"
  codesign --verify --strict "$STAGED_APP"
  quit_running_copy
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    mv "$DEST" "$BACKUP"
  fi
  REPLACING=1
  mv "$STAGED_APP" "$DEST"
  if [ "$LAUNCH" = 1 ]; then open "$DEST"; fi
  COMMITTED=1
  echo "==> done: $DEST"
else
  if [ "$LAUNCH" = 1 ]; then
    quit_running_copy
    open "$APP"
  fi
  echo "==> done: $APP"
fi
