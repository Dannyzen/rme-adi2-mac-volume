# RME ADI-2 DAC — macOS Keyboard Volume Control

Bind your Mac keyboard's native **Volume Up (`F12`)**, **Volume Down (`F11`)**, and **Mute (`F10`)** keys directly to your **RME ADI-2 DAC** hardware volume via USB MIDI—while keeping your audio 100% bit-perfect.

---

## Why Do My Mac Volume Keys Stop Working with the ADI-2 DAC?

When you plug an **RME ADI-2 DAC** into a Mac over USB, RME intentionally tells macOS that the DAC has **no USB software volume slider** (`output volume: missing value`).

RME does this on purpose so that:
1. macOS sends an unattenuated, **100% bit-perfect (`0 dBFS`)** digital signal to the DAC.
2. All volume changes happen inside the DAC's own hardware DSP and **Auto Ref Level** analog relay stages (preserving full dynamic range and signal-to-noise ratio).

The downside is that **macOS disables your keyboard's `F10` / `F11` / `F12` volume buttons** and shows the `🚫` icon whenever you press them.

---

## How This Fixes It (Without Losing Bit-Perfect Audio)

Instead of routing your audio through a lossy virtual software mixer, this project pairs **Hammerspoon** (`hs.eventtap` + `hs.canvas`) with a tiny, memory-safe native C **CoreMIDI helper** (`adi2_midi_helper.c`) to talk directly to the **RME ADI-2 DAC's built-in MIDI remote protocol** (the exact same USB MIDI SysEx protocol used by RME's official **ADI-2 Remote** app):

- **Turns the actual hardware volume on the DAC:** Pressing Volume Up/Down on your Mac keyboard changes the real `dB` value on the ADI-2 DAC's front OLED display and triggers hardware **Auto Ref Level** relays.
- **Two-way real-time sync:**
  - If you turn the physical volume knob on the ADI-2 DAC or drag the slider in **ADI-2 Remote.app**, Hammerspoon instantly updates its internal state.
  - If you press Volume Up/Down/Mute on your keyboard, both the physical DAC screen and the **ADI-2 Remote** app update simultaneously.
- **Smart Output Detection (`Line Out` / `Phones` / `IEM`):** Reads the DAC's live status heartbeat in C (filtering redundant heartbeats so Hammerspoon stays at 0% idle CPU) and automatically controls whichever output (`Line Out`, `Phones`, or `IEM`) is currently active on the DAC.
- **Sleep/Wake, Crash & KVM Resilient:**
  - Bypasses Hammerspoon's built-in `hs.midi` (`MIKMIDI`), which has a known `MIDIPacketListAdd` stack-overflow crash when USB MIDI resets on macOS wake-from-sleep.
  - Installs a `launchd` `KeepAlive` LaunchAgent (`org.hammerspoon.Hammerspoon.keepalive.plist`) so Hammerspoon starts automatically at login and auto-restarts within seconds if it is ever killed.
- **Passthrough for Other Audio Devices:** Only intercepts volume keys when **ADI-2 DAC** is your active macOS Default Output Device. If you switch to **MacBook Pro Speakers** or **AirPods**, native macOS volume keys work as usual.
- **Native-Style On-Screen HUD:** Displays a bottom-center HUD pill showing the active channel (`ADI-2 DAC • Line Out` or `Phones`) and exact hardware `dB` level.

---

## Keyboard Controls

| Key Combination | Action | Step Size |
| :--- | :--- | :--- |
| **`F12` (Volume Up)** | Increase ADI-2 DAC hardware volume (auto-unmutes if muted) | **`+1.0 dB`** |
| **`F11` (Volume Down)** | Decrease ADI-2 DAC hardware volume | **`-1.0 dB`** |
| **`F10` (Mute)** | Toggle hardware mute on the active ADI-2 DAC output | **Mute / Unmute** |
| **`Option + Shift + F11 / F12`** | Fine hardware volume adjustment | **`±0.5 dB`** |
| **`Shift + F11 / F12`** | Fast hardware volume adjustment | **`±2.0 dB`** |

> **Safety Ceiling:** Keyboard volume is capped at **`0.0 dB`** maximum so a held key can never accidentally blast your speakers/headphones into `+6.0 dB` boost territory.

---

## Prerequisites (One-Time DAC Setup)

For macOS to see the ADI-2 DAC's MIDI control port alongside its USB audio port:

1. **Firmware v62 or Newer:**
   - If your DAC is on older firmware, update it using the official [RME Firmware Update Tool for macOS (`fut_madiface_mac.zip`)](https://www.rme-audio.de/downloads/fut_madiface_mac.zip).
2. **Enable MIDI Control on the DAC Front Panel:**
   - Press the physical **SETUP** button on your ADI-2 DAC.
   - Turn the bottom knob to **Options** → **Hardware/Diagnosis** (or **Remap Keys / Diag**).
   - Set **MIDI Control** to **ON**.
3. **Hammerspoon:**
   - Installed via Homebrew (`brew install --cask hammerspoon`) with **Accessibility** permissions enabled in **System Settings → Privacy & Security → Accessibility**.
4. *(Optional)* **RME ADI-2 Remote for macOS:**
   - Official companion GUI app: [adi2remote_mac.zip](https://www.rme-audio.de/downloads/adi2remote_mac.zip) (works side-by-side with this script).

---

## Installation

Clone the repository and run the installer script:

```bash
git clone https://github.com/Dannyzen/rme-adi2-mac-volume.git
cd rme-adi2-mac-volume
chmod +x install.sh
./install.sh
```

### What `install.sh` Does
1. Compiles `adi2_midi_helper.c` with `clang` to `~/.hammerspoon/bin/adi2_midi_helper`.
2. Copies `adi2_volume.lua` to `~/.hammerspoon/adi2_volume.lua` and ensures `require("adi2_volume")` is in `~/.hammerspoon/init.lua`.
3. Installs and loads `~/Library/LaunchAgents/org.hammerspoon.Hammerspoon.keepalive.plist` so Hammerspoon starts at login and auto-restarts if it ever crashes.
4. Verifies live CoreMIDI state synchronization with the ADI-2 DAC.

---

## Troubleshooting

- **Pressing Volume Up/Down still shows the macOS `🚫` icon:**
  1. Check that **Hammerspoon** is running and has **Accessibility** permissions toggled ON in **System Settings → Privacy & Security → Accessibility**.
  2. Reload Hammerspoon:
     ```bash
     osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"'
     ```
- **HUD appears on screen, but the DAC volume doesn't change:**
  1. Verify that **MIDI Control** is set to **ON** on the ADI-2 DAC (`SETUP` → `Options` → `Hardware/Diagnosis`).
  2. Check that macOS CoreMIDI sees the DAC:
     ```bash
     osascript -e 'tell application "Hammerspoon" to execute lua code "return hs.inspect(hs.midi.devices())"'
     ```
     You should see `"ADI-2 DAC (59920649)"` (your unit's serial suffix) in the returned list.
