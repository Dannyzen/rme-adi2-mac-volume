-- ~/.hammerspoon/adi2_volume.lua
-- Direct hardware volume & mute control for RME ADI-2 DAC via USB MIDI SysEx.
-- Syncs bidirectionally with the physical DAC knob and RME ADI-2 Remote.app.

local M = {}

-- Clean up any previous instance or test globals on reload
if _G.TestMidi then
    pcall(function() _G.TestMidi:callback(nil) end)
    _G.TestMidi = nil
    _G.TestMidiLog = nil
end
if _G.ADI2Volume then
    pcall(function() _G.ADI2Volume:stop() end)
end

local CHANNEL_NAMES = {
    [3] = "Line Out",
    [6] = "Phones",
    [9] = "IEM",
}

-- Map status byte6 (bits 1..0) to channel address
local ACTIVE_OUT_TO_ADDR = {
    [0] = 3, -- Line Out
    [1] = 6, -- Phones
    [2] = 9, -- IEM
}

M.midiDevice = nil
M.midiDeviceName = nil
M.activeAddr = 3 -- Default to Line Out (addr 3)
M.channels = {
    [3] = { vol = -150, muted = false }, -- vol in 0.1 dB units (-150 = -15.0 dB)
    [6] = { vol = -150, muted = false },
    [9] = { vol = -150, muted = false },
}

M.MIN_VOL = -1145 -- -114.5 dB
M.MAX_VOL = 0     -- Cap keyboard volume at 0.0 dB for safety (hardware goes to +6.0 dB)

M.hudCanvas = nil
M.hudTimer = nil
M.eventTap = nil
M.usbWatcher = nil

-- Encode a 3-byte RME parameter container for channel settings (addr 3, 6, 9)
local function encodeChannelParam(addr, index, val)
    local raw12 = val < 0 and (4096 + val) or val
    raw12 = math.max(0, math.min(4095, math.floor(raw12 + 0.5)))
    local b1 = ((addr & 0x0F) << 3) | ((index >> 2) & 0x07)
    local b2 = ((index & 0x03) << 5) | ((raw12 >> 7) & 0x1F)
    local b3 = raw12 & 0x7F
    return string.format("%02x%02x%02x", b1, b2, b3)
end

-- Send a parameter to the ADI-2 DAC (Device ID 0x71, Command 0x02)
function M:sendParam(addr, index, val)
    if not self.midiDevice then
        if not self:connectMidi() then return false end
    end
    local container = encodeChannelParam(addr, index, val)
    local sysex = "f000200d7102" .. container .. "f7"
    self.midiDevice:sendSysex(sysex)
    return true
end

-- Request full state dump from ADI-2 DAC (Command 0x03 0x09)
function M:requestAllSettings()
    if self.midiDevice then
        self.midiDevice:sendSysex("f000200d710309f7")
    end
end

-- Parse incoming SysEx strings from hs.midi
function M:handleSysex(hexStr)
    if not hexStr or #hexStr < 8 then return end
    local clean = hexStr:gsub("%s+", ""):lower()
    -- hs.midi strips leading f000 and trailing f7 on 3-byte manufacturer IDs,
    -- but handle both stripped ("200d71...") and full ("f000200d71...") formats
    if clean:sub(1, 4) == "f000" then
        clean = clean:sub(5)
    end
    if clean:sub(-2) == "f7" then
        clean = clean:sub(1, -3)
    end

    local prefix = clean:sub(1, 8)
    if prefix == "200d7101" or prefix == "200d7102" then
        -- 3-byte parameter containers
        for i = 9, #clean - 5, 6 do
            local b1 = tonumber(clean:sub(i, i + 1), 16)
            local b2 = tonumber(clean:sub(i + 2, i + 3), 16)
            local b3 = tonumber(clean:sub(i + 4, i + 5), 16)
            if b1 and b2 and b3 then
                local addr = (b1 >> 3) & 0x0F
                if self.channels[addr] then
                    local idx = ((b1 & 0x07) << 2) | ((b2 >> 5) & 0x03)
                    local raw12 = ((b2 & 0x1F) << 7) | (b3 & 0x7F)
                    local val = raw12 >= 2048 and (raw12 - 4096) or raw12
                    if idx == 12 then
                        self.channels[addr].vol = val
                    elseif idx == 15 then
                        self.channels[addr].muted = (val ~= 0)
                    end
                end
            end
        end
    elseif prefix == "200d7107" and #clean >= 10 then
        -- Periodic status message: byte 6 bits 1..0 indicate active DAC output
        local b6 = tonumber(clean:sub(9, 10), 16)
        if b6 then
            local activeOut = b6 & 0x03
            local mappedAddr = ACTIVE_OUT_TO_ADDR[activeOut]
            if mappedAddr then
                self.activeAddr = mappedAddr
            end
        end
    end
end

-- Connect (or reconnect) to ADI-2 DAC MIDI device
function M:connectMidi()
    local devices = hs.midi.devices() or {}
    local targetName = nil
    for _, name in ipairs(devices) do
        if name:match("^ADI%-2 DAC") then
            targetName = name
            break
        end
    end
    if not targetName then
        self.midiDevice = nil
        self.midiDeviceName = nil
        return false
    end
    if self.midiDevice and self.midiDeviceName == targetName then
        return true
    end

    local dev = hs.midi.new(targetName)
    if not dev then return false end

    self.midiDevice = dev
    self.midiDeviceName = targetName
    dev:callback(function(_, _, cmdType, _, metadata)
        if cmdType == "systemExclusive" and metadata and metadata.sysexData then
            self:handleSysex(metadata.sysexData)
        end
    end)

    -- Query initial volume & mute settings
    self:requestAllSettings()
    return true
end

-- Check if ADI-2 DAC is currently the active macOS audio output
function M:isADI2DefaultOutput()
    local out = hs.audiodevice.defaultOutputDevice()
    if not out then return false end
    local name = out:name() or ""
    return name:match("^ADI%-2 DAC") ~= nil
end

-- Render a sleek on-screen HUD showing the active output channel and dB volume
function M:showHUD(addr)
    local ch = self.channels[addr] or self.channels[3]
    local chName = CHANNEL_NAMES[addr] or "Line Out"
    local dbVal = ch.vol / 10.0
    local muted = ch.muted

    -- Map -80.0 dB .. 0.0 dB onto 0.0 .. 1.0 bar fill for visual clarity
    local norm = math.max(0.0, math.min(1.0, (dbVal + 80.0) / 80.0))
    if muted or dbVal <= -114.0 then norm = 0.0 end

    local icon = "🔊"
    if muted or dbVal <= -114.0 then
        icon = "🔇"
    elseif dbVal < -35.0 then
        icon = "🔈"
    elseif dbVal < -15.0 then
        icon = "🔉"
    end

    local valueText = muted and string.format("MUTE (%.1f dB)", dbVal) or string.format("%.1f dB", dbVal)

    local screen = hs.screen.mainScreen()
    local frame = screen:fullFrame()
    local width = 280
    local height = 74
    local x = frame.x + math.floor((frame.w - width) / 2)
    local y = frame.y + frame.h - 140

    if self.hudCanvas then
        self.hudCanvas:delete()
        self.hudCanvas = nil
    end

    local c = hs.canvas.new({ x = x, y = y, w = width, h = height })
    c:level(hs.canvas.windowLevels.overlay)
    c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Background pill
    c[1] = {
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 16, yRadius = 16 },
        fillColor = { red = 0.08, green = 0.08, blue = 0.10, alpha = 0.88 },
    }
    -- Border
    c[2] = {
        type = "rectangle",
        action = "stroke",
        roundedRectRadii = { xRadius = 16, yRadius = 16 },
        strokeColor = { red = 1, green = 1, blue = 1, alpha = 0.16 },
        strokeWidth = 1,
    }
    -- Title label
    c[3] = {
        type = "text",
        text = string.format("%s  ADI-2 DAC • %s", icon, chName),
        textFont = ".AppleSystemUIFont",
        textSize = 13,
        textColor = { red = 0.85, green = 0.87, blue = 0.90, alpha = 0.95 },
        frame = { x = 18, y = 12, w = 155, h = 20 },
    }
    -- dB Value readout
    c[4] = {
        type = "text",
        text = valueText,
        textAlignment = "right",
        textFont = ".AppleSystemUIFontBold",
        textSize = 13,
        textColor = muted and { red = 1.0, green = 0.42, blue = 0.42, alpha = 1.0 }
                           or { red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0 },
        frame = { x = 165, y = 12, w = 97, h = 20 },
    }
    -- Track bar background
    local barX, barY, barW, barH = 18, 44, width - 36, 10
    c[5] = {
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 5, yRadius = 5 },
        fillColor = { red = 1, green = 1, blue = 1, alpha = 0.15 },
        frame = { x = barX, y = barY, w = barW, h = barH },
    }
    -- Track bar fill
    local fillW = math.max(0, math.floor(barW * norm))
    if fillW > 0 then
        c[6] = {
            type = "rectangle",
            action = "fill",
            roundedRectRadii = { xRadius = 5, yRadius = 5 },
            fillColor = { red = 0.25, green = 0.78, blue = 0.98, alpha = 0.95 },
            frame = { x = barX, y = barY, w = fillW, h = barH },
        }
    end

    c:show()
    self.hudCanvas = c

    if self.hudTimer then
        self.hudTimer:stop()
    end
    self.hudTimer = hs.timer.doAfter(1.4, function()
        if self.hudCanvas then
            self.hudCanvas:delete()
            self.hudCanvas = nil
        end
    end)
end

-- Adjust volume by deltaTenthsDb (e.g. +10 = +1.0 dB, -5 = -0.5 dB)
function M:adjustVolume(deltaTenthsDb)
    local addr = self.activeAddr or 3
    local ch = self.channels[addr]
    if not ch then return end

    -- If muted and pressing Volume Up, unmute first
    if ch.muted and deltaTenthsDb > 0 then
        ch.muted = false
        self:sendParam(addr, 15, 0)
    end

    -- Snap to 0.5 dB (5 tenths) grid
    local newVol = math.floor((ch.vol + deltaTenthsDb) / 5 + 0.5) * 5
    newVol = math.max(self.MIN_VOL, math.min(self.MAX_VOL, newVol))
    ch.vol = newVol

    self:sendParam(addr, 12, newVol)
    self:showHUD(addr)
end

-- Toggle mute on active ADI-2 DAC output
function M:toggleMute()
    local addr = self.activeAddr or 3
    local ch = self.channels[addr]
    if not ch then return end

    ch.muted = not ch.muted
    self:sendParam(addr, 15, ch.muted and 1 or 0)
    self:showHUD(addr)
end

function M:start()
    self:connectMidi()

    -- Reconnect automatically when USB devices change (e.g. KVM switch or DAC power cycle)
    self.usbWatcher = hs.usb.watcher.new(function(data)
        if data and data.productName and data.productName:match("^ADI%-2 DAC") then
            if data.eventType == "added" then
                hs.timer.doAfter(1.0, function() self:connectMidi() end)
            elseif data.eventType == "removed" then
                self.midiDevice = nil
                self.midiDeviceName = nil
            end
        end
    end)
    self.usbWatcher:start()

    -- Intercept media keys (F10 Mute, F11 Vol Down, F12 Vol Up) when ADI-2 DAC is default output
    self.eventTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(event)
        local sysKey = event:systemKey()
        if not sysKey or not sysKey.down then
            return false
        end

        local key = sysKey.key
        if key ~= "SOUND_UP" and key ~= "SOUND_DOWN" and key ~= "MUTE" then
            return false
        end

        if not self:isADI2DefaultOutput() then
            return false
        end

        -- Determine step size:
        -- Option+Shift = 0.5 dB (5 tenths), Normal = 1.0 dB (10 tenths), Shift alone = 2.0 dB (20 tenths)
        local flags = event:getFlags()
        local step = 10 -- 1.0 dB default
        if flags.alt and flags.shift then
            step = 5    -- 0.5 dB fine step
        elseif flags.shift then
            step = 20   -- 2.0 dB coarse step
        end

        if key == "SOUND_UP" then
            self:adjustVolume(step)
            return true
        elseif key == "SOUND_DOWN" then
            self:adjustVolume(-step)
            return true
        elseif key == "MUTE" then
            if not sysKey["repeat"] then
                self:toggleMute()
            end
            return true
        end

        return false
    end)
    self.eventTap:start()

    return self
end

function M:stop()
    if self.eventTap then
        self.eventTap:stop()
        self.eventTap = nil
    end
    if self.usbWatcher then
        self.usbWatcher:stop()
        self.usbWatcher = nil
    end
    if self.hudTimer then
        self.hudTimer:stop()
        self.hudTimer = nil
    end
    if self.hudCanvas then
        self.hudCanvas:delete()
        self.hudCanvas = nil
    end
    if self.midiDevice then
        pcall(function() self.midiDevice:callback(nil) end)
        self.midiDevice = nil
        self.midiDeviceName = nil
    end
end

_G.ADI2Volume = M:start()
return M
