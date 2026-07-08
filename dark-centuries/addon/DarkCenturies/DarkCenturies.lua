-- ============================================================
-- World of Warcraft: Dark Centuries (client addon, WoW 3.3.5a)
-- GTA:SA-style territory map: every zone of Azeroth is tinted
-- by its controlling faction on the continent world maps.
--
-- Zone shapes come from the game's own hover-highlight art via
-- UpdateMapHighlight(x, y), tinted with the faction color, so
-- each zone is colored in its exact shape.
-- ============================================================

local DC = {}

DC.N = 0  -- contested
DC.A = 1  -- Alliance
DC.H = 2  -- Horde

-- Server state cache: [zoneId] = { faction, progress (0=A, 100=H) }
DC.zoneState = {}

DC.COLOR = {
    [DC.N] = { r = 1.00, g = 0.80, b = 0.10 },  -- yellow  contested
    [DC.A] = { r = 0.15, g = 0.40, b = 1.00 },  -- blue    Alliance
    [DC.H] = { r = 1.00, g = 0.15, b = 0.15 },  -- red     Horde
}
DC.ALPHA = 0.40

DC.FACTION_TEXT = {
    [DC.N] = "|cffFFCC00Contested|r",
    [DC.A] = "|cff4477FFAlliance|r",
    [DC.H] = "|cffFF4444Horde|r",
}

-- ── Zone anchor points ────────────────────────────────────────
-- [areaId] = { c = continent (1 Kalimdor, 2 Eastern Kingdoms),
--              x, y = a point INSIDE the zone, as fractions of the
--              continent map (x from left, y from top) }
-- The point is fed to UpdateMapHighlight() to fetch the zone's
-- exact highlight shape.
DC.MAP = {
    -- Eastern Kingdoms (continent 2)
    [3430] = { c = 2, x = 0.55, y = 0.065, name = "Eversong Woods" },
    [3487] = { c = 2, x = 0.60, y = 0.040, name = "Silvermoon City" },
    [3433] = { c = 2, x = 0.57, y = 0.125, name = "Ghostlands" },
    [139]  = { c = 2, x = 0.62, y = 0.235, name = "Eastern Plaguelands" },
    [28]   = { c = 2, x = 0.50, y = 0.250, name = "Western Plaguelands" },
    [85]   = { c = 2, x = 0.39, y = 0.265, name = "Tirisfal Glades" },
    [1497] = { c = 2, x = 0.43, y = 0.305, name = "Undercity" },
    [130]  = { c = 2, x = 0.36, y = 0.335, name = "Silverpine Forest" },
    [36]   = { c = 2, x = 0.49, y = 0.310, name = "Alterac Mountains" },
    [267]  = { c = 2, x = 0.46, y = 0.360, name = "Hillsbrad Foothills" },
    [45]   = { c = 2, x = 0.55, y = 0.380, name = "Arathi Highlands" },
    [47]   = { c = 2, x = 0.60, y = 0.345, name = "The Hinterlands" },
    [11]   = { c = 2, x = 0.52, y = 0.460, name = "Wetlands" },
    [38]   = { c = 2, x = 0.55, y = 0.535, name = "Loch Modan" },
    [1]    = { c = 2, x = 0.45, y = 0.555, name = "Dun Morogh" },
    [1537] = { c = 2, x = 0.475, y = 0.525, name = "Ironforge" },
    [51]   = { c = 2, x = 0.50, y = 0.600, name = "Searing Gorge" },
    [3]    = { c = 2, x = 0.56, y = 0.590, name = "Badlands" },
    [46]   = { c = 2, x = 0.50, y = 0.650, name = "Burning Steppes" },
    [44]   = { c = 2, x = 0.54, y = 0.700, name = "Redridge Mountains" },
    [12]   = { c = 2, x = 0.47, y = 0.715, name = "Elwynn Forest" },
    [1519] = { c = 2, x = 0.435, y = 0.685, name = "Stormwind City" },
    [40]   = { c = 2, x = 0.41, y = 0.755, name = "Westfall" },
    [10]   = { c = 2, x = 0.47, y = 0.775, name = "Duskwood" },
    [41]   = { c = 2, x = 0.52, y = 0.770, name = "Deadwind Pass" },
    [8]    = { c = 2, x = 0.58, y = 0.750, name = "Swamp of Sorrows" },
    [4]    = { c = 2, x = 0.56, y = 0.825, name = "Blasted Lands" },
    [33]   = { c = 2, x = 0.43, y = 0.865, name = "Stranglethorn Vale" },
    -- Kalimdor (continent 1)
    [141]  = { c = 1, x = 0.385, y = 0.080, name = "Teldrassil" },
    [1657] = { c = 1, x = 0.355, y = 0.060, name = "Darnassus" },
    [3525] = { c = 1, x = 0.290, y = 0.085, name = "Bloodmyst Isle" },
    [3524] = { c = 1, x = 0.285, y = 0.130, name = "Azuremyst Isle" },
    [3557] = { c = 1, x = 0.250, y = 0.125, name = "The Exodar" },
    [148]  = { c = 1, x = 0.440, y = 0.140, name = "Darkshore" },
    [493]  = { c = 1, x = 0.560, y = 0.140, name = "Moonglade" },
    [618]  = { c = 1, x = 0.600, y = 0.185, name = "Winterspring" },
    [361]  = { c = 1, x = 0.490, y = 0.200, name = "Felwood" },
    [331]  = { c = 1, x = 0.490, y = 0.280, name = "Ashenvale" },
    [16]   = { c = 1, x = 0.620, y = 0.250, name = "Azshara" },
    [406]  = { c = 1, x = 0.430, y = 0.330, name = "Stonetalon Mountains" },
    [14]   = { c = 1, x = 0.600, y = 0.380, name = "Durotar" },
    [1637] = { c = 1, x = 0.605, y = 0.330, name = "Orgrimmar" },
    [17]   = { c = 1, x = 0.520, y = 0.420, name = "The Barrens" },
    [405]  = { c = 1, x = 0.380, y = 0.420, name = "Desolace" },
    [215]  = { c = 1, x = 0.465, y = 0.465, name = "Mulgore" },
    [1638] = { c = 1, x = 0.455, y = 0.440, name = "Thunder Bluff" },
    [15]   = { c = 1, x = 0.600, y = 0.520, name = "Dustwallow Marsh" },
    [357]  = { c = 1, x = 0.380, y = 0.550, name = "Feralas" },
    [400]  = { c = 1, x = 0.500, y = 0.560, name = "Thousand Needles" },
    [490]  = { c = 1, x = 0.460, y = 0.650, name = "Un'Goro Crater" },
    [440]  = { c = 1, x = 0.550, y = 0.650, name = "Tanaris" },
    [1377] = { c = 1, x = 0.380, y = 0.660, name = "Silithus" },
}

-- ── Overlay pool ──────────────────────────────────────────────
-- One tinted highlight texture + one fallback dot per zone.
DC.overlays = {}

local overlayParent = CreateFrame("Frame", "DarkCenturiesOverlayFrame", WorldMapDetailFrame)
overlayParent:SetAllPoints(WorldMapDetailFrame)
overlayParent:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 1)

local function GetOverlay(zoneId)
    local o = DC.overlays[zoneId]
    if o then return o end
    o = {}
    o.tex = overlayParent:CreateTexture(nil, "ARTWORK")
    o.tex:Hide()
    o.dot = overlayParent:CreateTexture(nil, "ARTWORK")
    o.dot:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    o.dot:Hide()
    o.pct = overlayParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    o.pct:Hide()
    DC.overlays[zoneId] = o
    return o
end

local function HideAllOverlays()
    for _, o in pairs(DC.overlays) do
        o.tex:Hide(); o.dot:Hide(); o.pct:Hide()
    end
end

-- ── The core: tint each zone with its faction color ──────────
local function RefreshOverlays()
    HideAllOverlays()

    -- Only draw on the two Azeroth continent maps, zoomed out
    local cont = GetCurrentMapContinent()
    local zone = GetCurrentMapZone()
    if (cont ~= 1 and cont ~= 2) or zone ~= 0 then return end

    local width  = WorldMapDetailFrame:GetWidth()
    local height = WorldMapDetailFrame:GetHeight()
    if width == 0 or height == 0 then return end

    for zoneId, m in pairs(DC.MAP) do
        if m.c == cont then
            local s = DC.zoneState[zoneId]
            if s then
                local col = DC.COLOR[s.faction] or DC.COLOR[DC.N]
                local o = GetOverlay(zoneId)

                -- Ask the client for the zone's exact highlight shape
                local fileName, texPctX, texPctY, texX, texY, scrollX, scrollY =
                    UpdateMapHighlight(m.x, m.y)

                if fileName then
                    o.tex:SetTexture("Interface\\WorldMap\\" .. fileName .. "\\" .. fileName .. "Highlight")
                    o.tex:SetTexCoord(0, texPctX, 0, texPctY)
                    o.tex:SetVertexColor(col.r, col.g, col.b, DC.ALPHA)
                    o.tex:ClearAllPoints()
                    o.tex:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT",
                        scrollX * width, -scrollY * height)
                    o.tex:SetWidth(texX * width)
                    o.tex:SetHeight(texY * height)
                    o.tex:Show()
                else
                    -- Fallback: colored dot at the anchor point
                    o.dot:SetVertexColor(col.r, col.g, col.b, 0.9)
                    o.dot:ClearAllPoints()
                    o.dot:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
                        m.x * width, -m.y * height)
                    o.dot:SetWidth(14); o.dot:SetHeight(14)
                    o.dot:Show()
                end

                -- Contested zones show the current balance
                if s.faction == DC.N and s.progress ~= 50 then
                    local aPct = 100 - s.progress
                    o.pct:ClearAllPoints()
                    o.pct:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
                        m.x * width, -m.y * height)
                    if s.progress > 50 then
                        o.pct:SetText("|cffFF4444" .. s.progress .. "%|r")
                    else
                        o.pct:SetText("|cff4477FF" .. aPct .. "%|r")
                    end
                    o.pct:Show()
                end
            end
        end
    end
end

-- ── Legend on the world map ───────────────────────────────────
local legend = overlayParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
legend:SetPoint("BOTTOMLEFT", WorldMapDetailFrame, "BOTTOMLEFT", 8, 6)
legend:SetText("|cffFFD700Dark Centuries:|r |cff4477FFAlliance|r  |cffFF4444Horde|r  |cffFFCC00Contested|r")
legend:Hide()

local function RefreshLegend()
    local cont = GetCurrentMapContinent()
    if (cont == 1 or cont == 2) and GetCurrentMapZone() == 0 then
        legend:Show()
    else
        legend:Hide()
    end
end

-- ── Server messages ───────────────────────────────────────────
-- "ZONE|zoneId|faction|progress"
local function OnAddonMessage(prefix, msg)
    if prefix ~= "DarkCenturies" then return end
    local msgType, zoneIdStr, factionStr, progressStr = string.match(msg, "^(%u+)|(%d+)|(%d+)|(%d+)$")
    if msgType ~= "ZONE" then return end

    local zoneId = tonumber(zoneIdStr)
    DC.zoneState[zoneId] = {
        faction  = tonumber(factionStr),
        progress = tonumber(progressStr),
    }

    if WorldMapFrame:IsShown() then
        RefreshOverlays()
    end
end

-- ── Events ───────────────────────────────────────────────────
local frame = CreateFrame("Frame", "DarkCenturiesFrame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("WORLD_MAP_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    else
        if WorldMapFrame:IsShown() then
            RefreshOverlays()
            RefreshLegend()
        end
    end
end)

WorldMapFrame:HookScript("OnShow", function()
    RefreshOverlays()
    RefreshLegend()
end)

-- ── Slash commands ────────────────────────────────────────────
SLASH_DARKCENTURIES1 = "/dc"
SlashCmdList["DARKCENTURIES"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "status" then
        local a, h, n = 0, 0, 0
        print("|cffFFD700[Dark Centuries]|r World control:")
        for zoneId, s in pairs(DC.zoneState) do
            local m = DC.MAP[zoneId]
            local zname = (m and m.name) or ("Zone " .. zoneId)
            if s.faction == DC.A then a = a + 1
            elseif s.faction == DC.H then h = h + 1
            else
                n = n + 1
                print(string.format("  %s — %s (A %d%% / H %d%%)",
                    zname, DC.FACTION_TEXT[s.faction], 100 - s.progress, s.progress))
            end
        end
        print(string.format("  Totals: |cff4477FFAlliance %d|r  |cffFF4444Horde %d|r  |cffFFCC00Contested %d|r", a, h, n))
    elseif msg == "map" then
        ToggleWorldMap()
    else
        print("|cffFFD700[Dark Centuries]|r commands:")
        print("  /dc status — faction totals + contested zone breakdown")
        print("  /dc map — open the territory map")
    end
end

DEFAULT_CHAT_FRAME:AddMessage(
    "|cffFFD700World of Warcraft: Dark Centuries|r — territory war active. Open your map (M) to see the front lines.")
