#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="${HOME}/.hammerspoon"
HS_BIN_DIR="${HS_DIR}/bin"
INIT_LUA="${HS_DIR}/init.lua"
TARGET_LUA="${HS_DIR}/adi2_volume.lua"
TARGET_BIN="${HS_BIN_DIR}/adi2_midi_helper"
PLIST_NAME="org.hammerspoon.Hammerspoon.keepalive.plist"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
TARGET_PLIST="${LAUNCH_AGENTS_DIR}/${PLIST_NAME}"

echo "==> Installing RME ADI-2 DAC macOS Volume Control..."

if ! [ -d "/Applications/Hammerspoon.app" ]; then
    echo "Hammerspoon.app not found in /Applications. Installing via Homebrew..."
    brew install --cask hammerspoon
fi

mkdir -p "${HS_BIN_DIR}" "${LAUNCH_AGENTS_DIR}"

echo "==> Compiling C CoreMIDI helper (adi2_midi_helper)..."
clang -O2 -Wall -Wextra "${SCRIPT_DIR}/adi2_midi_helper.c" \
    -framework CoreMIDI -framework CoreFoundation \
    -o "${TARGET_BIN}"
echo "✓ Built ${TARGET_BIN}"

cp "${SCRIPT_DIR}/adi2_volume.lua" "${TARGET_LUA}"
echo "✓ Copied adi2_volume.lua to ${TARGET_LUA}"

if ! [ -f "${INIT_LUA}" ]; then
    cat << 'EOF' > "${INIT_LUA}"
hs.logger.defaultLogLevel = "nothing"
hs.allowAppleScript(true)
require("hs.ipc")
require("adi2_volume")
hs.console.clearConsole()
local cwin = hs.console.hswindow()
if cwin then cwin:close() end
EOF
    echo "✓ Created ${INIT_LUA}"
else
    if ! grep -q 'require("adi2_volume")' "${INIT_LUA}" && ! grep -q "require('adi2_volume')" "${INIT_LUA}"; then
        printf '\nrequire("adi2_volume")\n' >> "${INIT_LUA}"
        echo "✓ Added require(\"adi2_volume\") to ${INIT_LUA}"
    else
        echo "✓ ${INIT_LUA} already loads adi2_volume"
    fi
fi

# Install launchd KeepAlive LaunchAgent so Hammerspoon starts at login and auto-restarts on crash
cp "${SCRIPT_DIR}/${PLIST_NAME}" "${TARGET_PLIST}"
USER_UID="$(id -u)"
if ! launchctl print "gui/${USER_UID}/org.hammerspoon.Hammerspoon.keepalive" >/dev/null 2>&1; then
    # Cleanly quit any standalone Hammerspoon instance before launchd takes ownership
    osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
    sleep 0.6
    launchctl bootstrap "gui/${USER_UID}" "${TARGET_PLIST}"
    echo "✓ Loaded launchd KeepAlive agent (${TARGET_PLIST})"
else
    osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' >/dev/null 2>&1 || true
    echo "✓ Reloaded Hammerspoon under launchd KeepAlive agent"
fi

sleep 1.5

echo "==> Verifying ADI-2 DAC connection via Hammerspoon..."
STATUS="$(osascript -e 'tell application "Hammerspoon" to execute lua code "return hs.inspect({device = ADI2Volume and ADI2Volume.midiDeviceName, activeAddr = ADI2Volume and ADI2Volume.activeAddr, channels = ADI2Volume and ADI2Volume.channels, helperRunning = ADI2Volume and ADI2Volume.helperTask and ADI2Volume.helperTask:isRunning(), tapEnabled = ADI2Volume and ADI2Volume.eventTap and ADI2Volume.eventTap:isEnabled()})"' 2>/dev/null || echo "Hammerspoon AppleScript unavailable")"
echo "${STATUS}"
echo "==> Done! Try pressing Volume Up (F12), Volume Down (F11), or Mute (F10)."
