#!/bin/bash
# Builds BridgeCtl.app into ~/Applications, links the `bridgectl` CLI into ~/.local/bin and
# (re)starts the app as a login item (a LaunchAgent, which also relaunches it if it crashes).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$HOME/Applications/BridgeCtl.app"
LABEL=com.abhaybd.bridgectl
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/.local/bin"

swift build -c release
BUILD="$(swift build -c release --show-bin-path)"

# Stop the running app first (it shuts its tunnels down); launchd-managed or not.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x BridgeCtl 2>/dev/null || true
# bootout returns before the job is gone, and bootstrapping it again too early fails.
for _ in $(seq 50); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || pgrep -x BridgeCtl >/dev/null || break
  sleep 0.2
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/BridgeCtlApp" "$APP/Contents/MacOS/BridgeCtl"
# Not next to BridgeCtl in MacOS/: the filesystem is case-insensitive, so the names would collide.
cp "$BUILD/bridgectl" "$APP/Contents/Helpers/bridgectl"
codesign --force --sign - "$APP"

mkdir -p "$BIN"
ln -sf "$APP/Contents/Helpers/bridgectl" "$BIN/bridgectl"

mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/BridgeCtl</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installed $APP (running now, and at login)."
if [[ ":$PATH:" == *":$BIN:"* ]]; then echo "CLI: $BIN/bridgectl"; else echo "CLI: $BIN/bridgectl (add $BIN to your PATH)"; fi
