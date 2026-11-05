# AGENT.md — Technical Specification & Operational Guide for AI Agents

This document provides complete architectural, protocol, requirement, installation, and verification instructions for AI agents maintaining or deploying `rme-adi2-mac-volume`.

---

## 1. Problem Statement & System Context

1. **CoreAudio Behavior:**
   - The **RME ADI-2 DAC** (`USB VID 0x2a39`, `PID 0x3fd3`) operates in USB Audio Class 2.0 (UAC2) Class-Compliant mode on macOS without exposing a USB Audio Feature Unit volume descriptor.
   - Consequently, `osascript -e 'get volume settings'` returns `output volume:missing value, output muted:missing value` when `ADI-2 DAC` is the active default output device, and macOS locks out `NX_KEYTYPE_SOUND_UP`, `NX_KEYTYPE_SOUND_DOWN`, and `NX_KEYTYPE_MUTE`.
2. **CoreMIDI Hardware Control Path:**
   - On ADI-2 DAC firmware **>= v62** with **MIDI Control** enabled on the hardware unit (`SETUP` → `Options` → `Hardware/Diagnosis` → `MIDI Control: ON`), the device exposes USB Interface 4 (`bInterfaceClass = 1`, `bInterfaceSubClass = 3`, USB MIDI Streaming) to macOS `MIDIServer`.
   - CoreMIDI allows multiple simultaneous clients (`Hammerspoon` and `ADI-2 Remote.app`) to send and receive MIDI System Exclusive (SysEx) datagrams in real time without exclusive device locking.

---

## 2. Requirements & Pre-Flight Verification

Before installing or debugging, an agent MUST verify the following four requirements:

### 2.1 Hardware & USB Topology Check
Verify that the ADI-2 DAC is connected and exposes **Interface 4** (`bInterfaceClass = 1`, `bInterfaceSubClass = 3` owned by `MIDIServer`):

```bash
/usr/sbin/ioreg -r -n "ADI-2 DAC (59920649)" -l -w 0 | rg "bInterfaceNumber|bInterfaceClass|bInterfaceSubClass|IOUserClientCreator"
```

- **Expected Interfaces:**
  - `bInterfaceNumber = 0`: `bInterfaceClass = 1, bInterfaceSubClass = 1` (`usbaudiod` Audio Control)
  - `bInterfaceNumber = 1..2`: `bInterfaceClass = 1, bInterfaceSubClass = 2` (`usbaudiod` Audio Streaming)
  - `bInterfaceNumber = 3`: `bInterfaceClass = 255, bInterfaceSubClass = 0` (RME Vendor / FUT interface)
  - `bInterfaceNumber = 4`: `bInterfaceClass = 1, bInterfaceSubClass = 3` (`MIDIServer` CoreMIDI endpoint)
- **If Interface 4 is missing:** The DAC either needs a firmware update via `fut_madiface_mac.zip` (Firmware >= 62) or needs `MIDI Control` toggled `ON` on the hardware front panel.

### 2.2 Hammerspoon & IPC Check
Verify Hammerspoon is installed, running, and AppleScript IPC is enabled (`hs.allowAppleScript(true)` in `~/.hammerspoon/init.lua`):

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "return hs.inspect(hs.midi.devices())"'
```

- **Expected Output:** Must include `"ADI-2 DAC (<serial>)"`, e.g.:
  `{ "Bluetooth", "Network", "UMP Network", "ADI-2 DAC (59920649)" }`

### 2.3 Active Audio Output Check
Verify that the ADI-2 DAC is set as the macOS Default Output Device:

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "return hs.audiodevice.defaultOutputDevice():name()"'
```

---

## 3. RME ADI-2 DAC MIDI SysEx Protocol Specification

Reference: Official RME `MIDITable_ADI-2_261030.ods` (Version 1.2, Firmware ADI-2 DAC >= 62).

### 3.1 SysEx Frame Layout
```text
F0 00 20 0D [DeviceID] [CommandID] [Payload...] F7
```
- `F0`: SysEx start byte
- `00 20 0D`: RME Manufacturer ID (3-byte ID)
  - *Note on Hammerspoon `hs.midi`:* In incoming `systemExclusive` callbacks, `metadata.sysexData` strips `F0 00` and `F7`, delivering hex strings starting with `"200d71..."`. When calling `midiDevice:sendSysex(...)`, always pass the full frame `"f000200d71...f7"`.
- `DeviceID`:
  - `0x71` = **ADI-2 DAC**
  - `0x72` = ADI-2 Pro
  - `0x73` = ADI-2/4 Pro SE/EX
- `CommandID`:
  - `0x01` = Device $\rightarrow$ Remote parameter update (3-byte containers)
  - `0x02` = Remote $\rightarrow$ Device parameter set (3-byte containers)
  - `0x03` = Request to device (`0x03 0x09` = Request all settings dump)
  - `0x07` = Periodic status heartbeat sent by device every ~1s after receiving first valid message

### 3.2 3-Byte Parameter Container Encoding (`CommandID 0x01 / 0x02`)
Each parameter is encoded in 3 consecutive 7-bit MIDI data bytes (`b1`, `b2`, `b3`):

- **Channel Addresses (`addr`, 4 bits):**
  - `3` (`0011`) = **Line Out** Channel Settings
  - `6` (`0110`) = **Phones 1/2** Channel Settings
  - `9` (`1001`) = **IEM / Phones 3/4** Channel Settings
- **Parameter Indices (`index`, 5 bits):**
  - `12` (`01100`) = **Volume** (`-114.5 dB` to `+6.0 dB`, transmitted in `0.1 dB` increments as signed 12-bit integer `-1145` to `+60`)
  - `15` (`01111`) = **Mute** (`0` = unmuted, `1` = muted)
- **Value (`val`, 12-bit signed two's complement):**
  - `raw12 = (val < 0) ? (4096 + val) : val`
- **Bit Packing:**
  - `b1 = ((addr & 0x0F) << 3) | ((index >> 2) & 0x07)`
    - For `Volume` (`index = 12`) or `Mute` (`index = 15`), `index >> 2` is `3`:
      - Line Out (`addr = 3`): `b1 = 0x1B`
      - Phones (`addr = 6`): `b1 = 0x33`
      - IEM (`addr = 9`): `b1 = 0x4B`
  - `b2 = ((index & 0x03) << 5) | ((raw12 >> 7) & 0x1F)`
  - `b3 = raw12 & 0x7F`

#### Example Encodings
- Set **Line Out (`addr = 3`) Volume (`index = 12`)** to **`-7.5 dB`** (`val = -75`, `raw12 = 4021 = 0xFB5`):
  - `b1 = 0x1B`, `b2 = 0x1F`, `b3 = 0x35`
  - Full SysEx: `f000200d71021b1f35f7`
- Set **Line Out (`addr = 3`) Mute (`index = 15`)** to **ON (`val = 1`)**:
  - `b1 = 0x1B`, `b2 = 0x60`, `b3 = 0x01`
  - Full SysEx: `f000200d71021b6001f7`

### 3.3 Periodic Status Message (`CommandID 0x07`)
- Frame: `F0 00 20 0D 71 07 [Byte6] ... F7`
- `Byte6 & 0x03` (bits `1..0`) indicates the currently active hardware output on the ADI-2 DAC:
  - `0` $\rightarrow$ **Line Out** (`addr = 3`)
  - `1` $\rightarrow$ **Phones** (`addr = 6`)
  - `2` $\rightarrow$ **IEM** (`addr = 9`)

---

## 4. Installation & Verification Procedure for Agents

### 4.1 Automated Install
Run the idempotent installer:

```bash
./install.sh
```

### 4.2 Manual / Programmatic Install
1. Copy `adi2_volume.lua` to `~/.hammerspoon/adi2_volume.lua`.
2. Ensure `~/.hammerspoon/init.lua` contains:
   ```lua
   hs.allowAppleScript(true)
   require("hs.ipc")
   require("adi2_volume")
   ```
3. Reload Hammerspoon:
   ```bash
   osascript -e 'tell application "Hammerspoon" to execute lua code "hs.reload()"'
   ```

### 4.3 Live State Verification
Verify that `ADI2Volume` is loaded, connected to CoreMIDI, synced with the DAC's current dB state, and has its `hs.eventtap` enabled:

```bash
osascript -e 'tell application "Hammerspoon" to execute lua code "
return hs.inspect({
    device = ADI2Volume.midiDeviceName,
    activeAddr = ADI2Volume.activeAddr,
    channels = ADI2Volume.channels,
    isDefault = ADI2Volume:isADI2DefaultOutput(),
    tapEnabled = ADI2Volume.eventTap and ADI2Volume.eventTap:isEnabled()
})
"'
```

Expected output structure:
```lua
{
  activeAddr = 3,
  channels = {
    [3] = { muted = false, vol = -75 },
    [6] = { muted = false, vol = -5 },
    [9] = { muted = false, vol = -100 }
  },
  device = "ADI-2 DAC (59920649)",
  isDefault = true,
  tapEnabled = true
}
```
*(Note: `vol` is stored in `0.1 dB` integer units, so `-75` = `-7.5 dB`.)*
