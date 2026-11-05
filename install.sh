#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="${HOME}/.hammerspoon"
INIT_LUA="${HS_DIR}/init.lua"
TARGET_LUA="${HS_DIR}/adi2_volume.lua"

echo "==> Installing RME ADI-2 DAC macOS Volume Control..."

if ! [ -d "/Applications/Hammerspoon.app" ]; then
    echo "Hammerspoon.app not found in /Applications. Installing via Homebrew..."
    brew install --cask hammerspoon
fi

mkdir -p "${HS_DIR}"
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

# Ensure Hammerspoon is running in background without opening the Console window
pgrep -x Hammerspoon >/dev/null 2>&1 || open -g -a Hammerspoon
sleep 0.5
osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"' >/dev/null 2>&1 || true
sleep 1.2

echo "==> Verifying ADI-2 DAC connection via Hammerspoon..."
STATUS="$(osascript -e 'tell application "Hammerspoon" to execute lua code "return hs.inspect({device = ADI2Volume and ADI2Volume.midiDeviceName, activeAddr = ADI2Volume and ADI2Volume.activeAddr, tapEnabled = ADI2Volume and ADI2Volume.eventTap and ADI2Volume.eventTap:isEnabled()})"' 2>/dev/null || echo "Hammerspoon AppleScript unavailable")"
echo "${STATUS}"
echo "==> Done! Try pressing Volume Up (F12), Volume Down (F11), or Mute (F10)."
