-- ============================================================
-- World of Warcraft: Dark Centuries (client addon, WoW 3.3.5a)
-- GTA:SA-style territory map: every zone of Azeroth is tinted
-- by its controlling faction on the continent world maps.
--
-- Zone shapes come from the game's own hover-highlight art via
-- UpdateMapHighlight(x, y). Each anchor point is probed (with
-- small offsets as backup) and the returned highlight texture is
-- tinted with the faction color. If no highlight can be resolved,
-- a small colored marker is drawn instead — never a black box.
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
--              x, y = a point INSIDE the zone as fractions of the
--              continent map (x from left, y from top) }
-- Cities are NOT listed: they sit inside home zones and would
-- double-paint the parent zone's highlight.
DC.MAP = {
    -- Eastern Kingdoms (continent 2)
    [3430] = { c = 2, x = 0.555, y = 0.075, name = "Eversong Woods" },
    [3433] = { c = 2, x = 0.565, y = 0.130, name = "Ghostlands" },
    [139]  = { c = 2, x = 0.560, y = 0.230, name = "Eastern Plaguelands" },
    [28]   = { c = 2, x = 0.475, y = 0.240, name = "Western Plaguelands" },
    [85]   = { c = 2, x = 0.390, y = 0.245, name = "Tirisfal Glades" },
    [130]  = { c = 2, x = 0.370, y = 0.315, name = "Silverpine Forest" },
    [36]   = { c = 2, x = 0.475, y = 0.295, name = "Alterac Mountains" },
    [267]  = { c = 2, x = 0.450, y = 0.340, name = "Hillsbrad Foothills" },
    [45]   = { c = 2, x = 0.530, y = 0.355, name = "Arathi Highlands" },
    [47]   = { c = 2, x = 0.575, y = 0.320, name = "The Hinterlands" },
    [11]   = { c = 2, x = 0.510, y = 0.435, name = "Wetlands" },
    [38]   = { c = 2, x = 0.560, y = 0.510, name = "Loch Modan" },
    [1]    = { c = 2, x = 0.455, y = 0.530, name = "Dun Morogh" },
    [51]   = { c = 2, x = 0.505, y = 0.585, name = "Searing Gorge" },
    [3]    = { c = 2, x = 0.575, y = 0.575, name = "Badlands" },
    [46]   = { c = 2, x = 0.520, y = 0.630, name = "Burning Steppes" },
    [44]   = { c = 2, x = 0.560, y = 0.680, name = "Redridge Mountains" },
    [12]   = { c = 2, x = 0.480, y = 0.680, name = "Elwynn Forest" },
    [40]   = { c = 2, x = 0.415, y = 0.720, name = "Westfall" },
    [10]   = { c = 2, x = 0.470, y = 0.740, name = "Duskwood" },
    [41]   = { c = 2, x = 0.525, y = 0.740, name = "Deadwind Pass" },
    [8]    = { c = 2, x = 0.585, y = 0.715, name = "Swamp of Sorrows" },
    [4]    = { c = 2, x = 0.560, y = 0.790, name = "Blasted Lands" },
    [33]   = { c = 2, x = 0.435, y = 0.825, name = "Stranglethorn Vale" },
    -- Kalimdor (continent 1)
    [141]  = { c = 1, x = 0.395, y = 0.115, name = "Teldrassil" },
    [3525] = { c = 1, x = 0.315, y = 0.105, name = "Bloodmyst Isle" },
    [3524] = { c = 1, x = 0.315, y = 0.165, name = "Azuremyst Isle" },
    [148]  = { c = 1, x = 0.445, y = 0.175, name = "Darkshore" },
    [493]  = { c = 1, x = 0.560, y = 0.155, name = "Moonglade" },
    [618]  = { c = 1, x = 0.610, y = 0.205, name = "Winterspring" },
    [361]  = { c = 1, x = 0.495, y = 0.235, name = "Felwood" },
    [331]  = { c = 1, x = 0.500, y = 0.305, name = "Ashenvale" },
    [16]   = { c = 1, x = 0.635, y = 0.275, name = "Azshara" },
    [406]  = { c = 1, x = 0.435, y = 0.360, name = "Stonetalon Mountains" },
    [14]   = { c = 1, x = 0.615, y = 0.395, name = "Durotar" },
    [17]   = { c = 1, x = 0.535, y = 0.455, name = "The Barrens" },
    [405]  = { c = 1, x = 0.395, y = 0.455, name = "Desolace" },
    [215]  = { c = 1, x = 0.470, y = 0.475, name = "Mulgore" },
    [15]   = { c = 1, x = 0.600, y = 0.525, name = "Dustwallow Marsh" },
    [357]  = { c = 1, x = 0.400, y = 0.590, name = "Feralas" },
    [400]  = { c = 1, x = 0.505, y = 0.575, name = "Thousand Needles" },
    [490]  = { c = 1, x = 0.465, y = 0.665, name = "Un'Goro Crater" },
    [440]  = { c = 1, x = 0.560, y = 0.655, name = "Tanaris" },
    [1377] = { c = 1, x = 0.400, y = 0.680, name = "Silithus" },
}

-- Probe offsets: primary anchor first, then nearby points as backup
local PROBES = {
    { 0, 0 },
    {  0.015, 0 }, { -0.015, 0 }, { 0,  0.015 }, { 0, -0.015 },
    {  0.025,  0.02 }, { -0.025, -0.02 }, {  0.03, 0 }, { -0.03, 0 },
}

-- ── Overlay pool ──────────────────────────────────────────────
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
    o.dot:SetTexture("Interface\\Buttons\\WHITE8X8")  -- pure white: tints correctly
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
    if (cont ~= 1 and cont ~= 2) or GetCurrentMapZone() ~= 0 then return end

    local width  = WorldMapDetailFrame:GetWidth()
    local height = WorldMapDetailFrame:GetHeight()
    if width == 0 or height == 0 then return end

    local painted = {}  -- fileName -> true, prevents double-painting a zone

    for zoneId, m in pairs(DC.MAP) do
        if m.c == cont then
            local s = DC.zoneState[zoneId]
            if s then
                local col = DC.COLOR[s.faction] or DC.COLOR[DC.N]
                local o = GetOverlay(zoneId)
                local drawn = false

                for i = 1, #PROBES do
                    local px = m.x + PROBES[i][1]
                    local py = m.y + PROBES[i][2]
                    local fileName, texPctX, texPctY, texX, texY, scrollX, scrollY =
                        UpdateMapHighlight(px, py)

                    -- Guard exactly like Blizzard's WorldMapFrame does:
                    -- both dimensions must be positive, and the texture
                    -- file must actually load (missing file = black box).
                    if fileName and not painted[fileName]
                        and texX and texX > 0 and texY and texY > 0 then
                        local okTex = o.tex:SetTexture(
                            "Interface\\WorldMap\\" .. fileName .. "\\" .. fileName .. "Highlight")
                        if okTex then
                            o.tex:SetTexCoord(0, texPctX, 0, texPctY)
                            o.tex:SetVertexColor(col.r, col.g, col.b, DC.ALPHA)
                            o.tex:ClearAllPoints()
                            o.tex:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT",
                                scrollX * width, -scrollY * height)
                            o.tex:SetWidth(texX * width)
                            o.tex:SetHeight(texY * height)
                            o.tex:Show()
                            painted[fileName] = true
                            drawn = true
                            break
                        end
                    end
                end

                if not drawn then
                    -- Visible colored marker, never a black box
                    o.dot:SetVertexColor(col.r, col.g, col.b, 0.85)
                    o.dot:ClearAllPoints()
                    o.dot:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
                        m.x * width, -m.y * height)
                    o.dot:SetWidth(12); o.dot:SetHeight(12)
                    o.dot:Show()
                end

                -- Contested zones show the current balance
                if s.faction == DC.N and s.progress ~= 50 then
                    o.pct:ClearAllPoints()
                    o.pct:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
                        m.x * width, -m.y * height)
                    if s.progress > 50 then
                        o.pct:SetText("|cffFF4444" .. s.progress .. "%|r")
                    else
                        o.pct:SetText("|cff4477FF" .. (100 - s.progress) .. "%|r")
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
