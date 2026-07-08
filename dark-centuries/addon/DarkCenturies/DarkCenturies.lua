-- Dark Centuries client addon
-- Draws coloured zone overlays on the Azeroth world map
-- Receives zone state via addon messages from the server (Eluna)

local DC = {}

-- Faction constants matching server side
DC.N = 0  -- neutral / contested
DC.A = 1  -- Alliance
DC.H = 2  -- Horde

-- Zone state cache: [zoneId] = { faction=N/A/H, progress=0-100 }
DC.zoneState = {}

-- ── Zone overlay regions ──────────────────────────────────────
-- Positions are fractions of the Azeroth overview map (1002x668 px)
-- { left, top, width, height } as 0-1 fractions
-- Eastern Kingdoms is the right ~40% of the map; Kalimdor the left ~40%
DC.ZONE_REGIONS = {
    [267]  = { 0.615, 0.335, 0.072, 0.060 },  -- Hillsbrad Foothills
    [45]   = { 0.620, 0.265, 0.075, 0.058 },  -- Arathi Highlands
    [33]   = { 0.600, 0.520, 0.058, 0.160 },  -- Stranglethorn Vale
    [36]   = { 0.608, 0.295, 0.058, 0.038 },  -- Alterac Mountains
    [139]  = { 0.655, 0.190, 0.090, 0.070 },  -- Eastern Plaguelands
    [28]   = { 0.618, 0.210, 0.072, 0.062 },  -- Western Plaguelands
    [1377] = { 0.165, 0.720, 0.060, 0.090 },  -- Silithus
    [3]    = { 0.632, 0.430, 0.065, 0.050 },  -- Badlands
    [46]   = { 0.625, 0.470, 0.065, 0.048 },  -- Burning Steppes
}

DC.FACTION_COLOR = {
    [DC.N] = { r=1.0, g=0.8, b=0.0, a=0.35 },  -- yellow (contested)
    [DC.A] = { r=0.2, g=0.4, b=1.0, a=0.35 },  -- blue   (Alliance)
    [DC.H] = { r=1.0, g=0.2, b=0.2, a=0.35 },  -- red    (Horde)
}

DC.FACTION_TEXT = {
    [DC.N] = "|cffFFCC00Contested|r",
    [DC.A] = "|cff4477FFAlliance|r",
    [DC.H] = "|cffFF4444Horde|r",
}

-- ── Overlay frames ────────────────────────────────────────────
DC.overlays = {}

local function GetOrCreateOverlay(zoneId)
    if DC.overlays[zoneId] then return DC.overlays[zoneId] end

    local region = DC.ZONE_REGIONS[zoneId]
    if not region then return nil end

    local f = CreateFrame("Frame", "DCOverlay_"..zoneId, WorldMapDetailFrame)
    f:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 2)

    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(f)
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetBlendMode("ADD")
    f.tex = tex

    -- Tooltip on hover
    f:SetScript("OnEnter", function()
        local s = DC.zoneState[zoneId]
        if not s then return end
        GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
        GameTooltip:SetText("|cffFFD700[Dark Centuries]|r", 1, 1, 1)
        local zoneName = GetMapNameByID and GetMapNameByID(zoneId) or ("Zone "..zoneId)
        GameTooltip:AddLine(zoneName, 1, 1, 1)
        GameTooltip:AddLine(DC.FACTION_TEXT[s.faction] .. " control", 1, 1, 1)
        local aProgress = 100 - s.progress
        local hProgress = s.progress
        GameTooltip:AddLine(string.format("Alliance: %d%%   Horde: %d%%", aProgress, hProgress), 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    DC.overlays[zoneId] = f
    return f
end

local function PositionOverlays()
    local mw = WorldMapDetailFrame:GetWidth()
    local mh = WorldMapDetailFrame:GetHeight()

    for zoneId, region in pairs(DC.ZONE_REGIONS) do
        local f = GetOrCreateOverlay(zoneId)
        if f then
            f:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT",
                region[1] * mw,
               -region[2] * mh)
            f:SetWidth(region[3]  * mw)
            f:SetHeight(region[4] * mh)
        end
    end
end

local function UpdateOverlayColor(zoneId)
    local f = DC.overlays[zoneId]
    if not f then return end
    local s = DC.zoneState[zoneId]
    if not s then f:Hide(); return end

    local c = DC.FACTION_COLOR[s.faction]
    f.tex:SetVertexColor(c.r, c.g, c.b, c.a)
    f:Show()
end

local function RefreshAllOverlays()
    -- Only show on the Azeroth continent map (mapId 0)
    local mapId = GetCurrentMapContinent and GetCurrentMapContinent() or -1
    if mapId ~= 1 then  -- 1 = Azeroth (both continents overview)
        for _, f in pairs(DC.overlays) do f:Hide() end
        return
    end
    PositionOverlays()
    for zoneId, _ in pairs(DC.ZONE_REGIONS) do
        UpdateOverlayColor(zoneId)
    end
end

-- ── Addon message handling ────────────────────────────────────
-- Server sends: "ZONE|zoneId|faction|progress"
local function OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= "DarkCenturies" then return end

    local msgType, zoneIdStr, factionStr, progressStr = msg:match("^(%u+)|(%d+)|(%d+)|(%d+)$")
    if not msgType then return end

    if msgType == "ZONE" then
        local zoneId  = tonumber(zoneIdStr)
        local faction = tonumber(factionStr)
        local progress = tonumber(progressStr)

        DC.zoneState[zoneId] = { faction = faction, progress = progress }

        -- Update overlay if world map is open
        if WorldMapFrame:IsShown() then
            local f = GetOrCreateOverlay(zoneId)
            if f then
                PositionOverlays()
                UpdateOverlayColor(zoneId)
            end
        end
    end
end

-- ── Event frame ──────────────────────────────────────────────
local frame = CreateFrame("Frame", "DarkCenturiesFrame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("WORLD_MAP_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "WORLD_MAP_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        if WorldMapFrame:IsShown() then
            RefreshAllOverlays()
        end
    end
end)

-- Hook world map open/close to show/hide overlays
hooksecurefunc("ShowUIPanel", function(panel)
    if panel == WorldMapFrame then
        RefreshAllOverlays()
    end
end)

-- ── Slash command ─────────────────────────────────────────────
SLASH_DARKCENTURIES1 = "/dc"
SlashCmdList["DARKCENTURIES"] = function(msg)
    if msg == "status" then
        print("|cffFFD700[Dark Centuries]|r Zone control status:")
        for zoneId, s in pairs(DC.zoneState) do
            local zoneName = GetMapNameByID and GetMapNameByID(zoneId) or ("Zone "..zoneId)
            print(string.format("  %s — %s (%d%%H / %d%%A)",
                zoneName,
                DC.FACTION_TEXT[s.faction],
                s.progress,
                100 - s.progress))
        end
    else
        print("|cffFFD700[Dark Centuries]|r  /dc status — show all zone control")
    end
end

-- Register addon message prefix
RegisterAddonMessagePrefix("DarkCenturies")

DEFAULT_CHAT_FRAME:AddMessage("|cffFFD700[Dark Centuries]|r Zone control active. Open your world map to see contested zones.")
