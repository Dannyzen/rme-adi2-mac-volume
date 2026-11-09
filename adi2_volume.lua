-- ~/.hammerspoon/adi2_volume.lua
-- Direct hardware volume & mute control for RME ADI-2 DAC via USB MIDI SysEx.
-- Uses a dedicated C CoreMIDI helper (~/.hammerspoon/bin/adi2_midi_helper) instead of hs.midi
-- to avoid MIKMIDI's sleep/wake MIDIPacketListAdd stack-overflow crash.

local M = {}

if _G.ADI2Volume then
    pcall(function() _G.ADI2Volume:stop() end)
end

local CHANNEL_NAMES = {
    [3] = "Line Out",
    [6] = "Phones",
    [9] = "IEM",
}

M.HELPER_PATH = os.getenv("HOME") .. "/.hammerspoon/bin/adi2_midi_helper"
M.helperTask = nil
M.midiDeviceName = nil
M.stdoutBuf = ""

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
M.sleepWatcher = nil
M.watchdogTimer = nil
M.stopping = false

-- Parse a single line from adi2_midi_helper stdout
function M:handleHelperLine(line)
    if not line or line == "" then return end

    local connectedModel = line:match("^CONNECTED%s+(.+)$")
    if connectedModel then
        self.midiDeviceName = connectedModel
        return
    end

    if line == "DISCONNECTED" then
        self.midiDeviceName = nil
        return
    end

    local activeStr = line:match("^ACTIVE%s+(%d+)$")
    if activeStr then
        local addr = tonumber(activeStr)
        if addr and self.channels[addr] then
            self.activeAddr = addr
        end
        return
    end

    local addrStr, idxStr, valStr = line:match("^PARAM%s+(%d+)%s+(%d+)%s+(-?%d+)$")
    if addrStr and idxStr and valStr then
        local addr = tonumber(addrStr)
        local idx = tonumber(idxStr)
        local val = tonumber(valStr)
        if addr and self.channels[addr] then
            if idx == 12 and val then
                self.channels[addr].vol = val
            elseif idx == 15 and val then
                self.channels[addr].muted = (val ~= 0)
            end
        end
    end
end

-- Process streaming stdout chunks from hs.task
function M:onHelperOutput(chunk)
    if not chunk or chunk == "" then return end
    self.stdoutBuf = self.stdoutBuf .. chunk
    while true do
        local nl = self.stdoutBuf:find("\n", 1, true)
        if not nl then break end
        local line = self.stdoutBuf:sub(1, nl - 1):gsub("\r$", "")
        self.stdoutBuf = self.stdoutBuf:sub(nl + 1)
        self:handleHelperLine(line)
    end
end

-- Start (or restart) the persistent C CoreMIDI helper process
function M:startHelper()
    if self.helperTask and self.helperTask:isRunning() then
        return true
    end

    self.helperTask = nil
    self.midiDeviceName = nil
    self.stdoutBuf = ""

    local task = hs.task.new(
        self.HELPER_PATH,
        function()
            -- Termination callback: auto-respawn unless module is stopping
            self.helperTask = nil
            self.midiDeviceName = nil
            if not self.stopping then
                hs.timer.doAfter(1.0, function()
                    if not self.stopping then self:startHelper() end
                end)
            end
        end,
        function(_, stdOut, _)
            if stdOut then self:onHelperOutput(stdOut) end
            return true
        end
    )

    if not task then return false end
    if not task:start() then return false end
    self.helperTask = task
    return true
end

-- Send a parameter to the ADI-2 DAC via adi2_midi_helper stdin pipe
function M:sendParam(addr, index, val)
    if not self.helperTask or not self.helperTask:isRunning() then
        if not self:startHelper() then return false end
    end
    self.helperTask:setInput(string.format("SET %d %d %d\n", addr, index, math.floor(val + 0.5)))
    return true
end

-- Request full state re-sync from ADI-2 DAC
function M:requestAllSettings()
    if self.helperTask and self.helperTask:isRunning() then
        self.helperTask:setInput("SYNC\n")
    else
        self:startHelper()
    end
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

function M:ensureHealthy()
    if self.eventTap and not self.eventTap:isEnabled() then
        self.eventTap:start()
    end
    if not self.helperTask or not self.helperTask:isRunning() then
        self:startHelper()
    end
end

function M:start()
    self.stopping = false
    self:startHelper()

    -- Re-enable eventTap & re-sync MIDI state after macOS sleep/wake
    self.sleepWatcher = hs.caffeinate.watcher.new(function(eventType)
        if eventType == hs.caffeinate.watcher.systemDidWake
            or eventType == hs.caffeinate.watcher.screensDidWake then
            hs.timer.doAfter(1.5, function()
                if not self.stopping then
                    self:ensureHealthy()
                    self:requestAllSettings()
                end
            end)
        end
    end)
    self.sleepWatcher:start()

    -- Periodic watchdog in case macOS disables CGEventTap on timeout
    self.watchdogTimer = hs.timer.doEvery(30, function()
        if not self.stopping then
            self:ensureHealthy()
        end
    end)

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
    self.stopping = true
    if self.watchdogTimer then
        self.watchdogTimer:stop()
        self.watchdogTimer = nil
    end
    if self.sleepWatcher then
        self.sleepWatcher:stop()
        self.sleepWatcher = nil
    end
    if self.eventTap then
        self.eventTap:stop()
        self.eventTap = nil
    end
    if self.hudTimer then
        self.hudTimer:stop()
        self.hudTimer = nil
    end
    if self.hudCanvas then
        self.hudCanvas:delete()
        self.hudCanvas = nil
    end
    if self.helperTask then
        pcall(function() self.helperTask:terminate() end)
        self.helperTask = nil
        self.midiDeviceName = nil
    end
end

_G.ADI2Volume = M:start()
return M
