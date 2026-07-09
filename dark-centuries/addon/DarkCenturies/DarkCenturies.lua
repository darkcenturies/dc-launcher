-- ============================================================
-- World of Warcraft: Dark Centuries (client addon, WoW 3.3.5a)
-- GTA:SA-style territory map: every zone of Azeroth is tinted
-- by its controlling faction on the continent world maps.
--
-- Zone rectangles are exact, extracted from the client's own
-- WorldMapArea.dbc (including the map-530 transforms for the
-- TBC zones), so every zone paints fully and in the right place.
-- ============================================================

local DC = {}

DC.N = 0  -- contested
DC.A = 1  -- Alliance
DC.H = 2  -- Horde

-- Server state cache: [zoneId] = { faction, progress (0=A, 100=H) }
DC.zoneState = {}

DC.COLOR = {
    [DC.N] = { r = 0.62, g = 0.22, b = 0.90 },  -- purple  contested
    [DC.A] = { r = 0.20, g = 0.45, b = 0.95 },  -- blue    Alliance
    [DC.H] = { r = 0.90, g = 0.15, b = 0.10 },  -- red     Horde
}
DC.ALPHA = 0.32

-- Additive tints: pure single-hue so zones color-shift instead of
-- whiting out (additive light on a bright map clips if every channel
-- gets energy; one channel alone just shifts the hue)
DC.ADD_COLOR = {
    [DC.N] = { r = 0.85, g = 0.55, b = 0.00 },  -- amber   contested
    [DC.A] = { r = 0.00, g = 0.15, b = 1.00 },  -- blue    Alliance
    [DC.H] = { r = 1.00, g = 0.00, b = 0.00 },  -- red     Horde
}

DC.FACTION_TEXT = {
    [DC.N] = "|cffB84DFFContested|r",
    [DC.A] = "|cff4477FFAlliance|r",
    [DC.H] = "|cffFF4444Horde|r",
}

-- ── Zone rectangles (from WorldMapArea.dbc) ───────────────────
-- [areaId] = { c = continent (1 Kalimdor, 2 Eastern Kingdoms),
--              l, t, w, h = exact fractions of the continent map }
DC.MAP = {
    [331] = { c = 1, l = 0.4176, t = 0.3313, w = 0.1567, h = 0.1567, name = "Ashenvale" },
    [16] = { c = 1, l = 0.5528, t = 0.3040, w = 0.1378, h = 0.1378, name = "Azshara" },
    [3524] = { c = 1, l = 0.2708, t = 0.2226, w = 0.1106, h = 0.1106, name = "Azuremyst Isle" },
    [3525] = { c = 1, l = 0.2593, t = 0.1396, w = 0.0887, h = 0.0887, name = "Bloodmyst Isle" },
    [148] = { c = 1, l = 0.3838, t = 0.1821, w = 0.1780, h = 0.1780, name = "Darkshore" },
    [1657] = { c = 1, l = 0.3839, t = 0.1044, w = 0.0288, h = 0.0288, name = "Darnassus" },
    [405] = { c = 1, l = 0.3487, t = 0.5033, w = 0.1222, h = 0.1222, name = "Desolace" },
    [14] = { c = 1, l = 0.5171, t = 0.4480, w = 0.1437, h = 0.1437, name = "Durotar" },
    [15] = { c = 1, l = 0.4903, t = 0.6046, w = 0.1427, h = 0.1427, name = "Dustwallow Marsh" },
    [361] = { c = 1, l = 0.4192, t = 0.2310, w = 0.1563, h = 0.1563, name = "Felwood" },
    [357] = { c = 1, l = 0.3159, t = 0.6182, w = 0.1889, h = 0.1889, name = "Feralas" },
    [493] = { c = 1, l = 0.5013, t = 0.1756, w = 0.0627, h = 0.0628, name = "Moonglade" },
    [215] = { c = 1, l = 0.4081, t = 0.5329, w = 0.1396, h = 0.1396, name = "Mulgore" },
    [1637] = { c = 1, l = 0.5638, t = 0.4291, w = 0.0381, h = 0.0381, name = "Orgrimmar" },
    [1377] = { c = 1, l = 0.3948, t = 0.7646, w = 0.0947, h = 0.0947, name = "Silithus" },
    [406] = { c = 1, l = 0.3756, t = 0.4029, w = 0.1327, h = 0.1327, name = "Stonetalon Mountains" },
    [440] = { c = 1, l = 0.4697, t = 0.7612, w = 0.1875, h = 0.1875, name = "Tanaris" },
    [141] = { c = 1, l = 0.3601, t = 0.0395, w = 0.1384, h = 0.1383, name = "Teldrassil" },
    [17] = { c = 1, l = 0.3925, t = 0.4560, w = 0.2754, h = 0.2754, name = "The Barrens" },
    [3557] = { c = 1, l = 0.2862, t = 0.2558, w = 0.0287, h = 0.0287, name = "The Exodar" },
    [400] = { c = 1, l = 0.4755, t = 0.6834, w = 0.1196, h = 0.1196, name = "Thousand Needles" },
    [1638] = { c = 1, l = 0.4497, t = 0.5564, w = 0.0284, h = 0.0284, name = "Thunder Bluff" },
    [490] = { c = 1, l = 0.4493, t = 0.7649, w = 0.1005, h = 0.1005, name = "Un'Goro Crater" },
    [618] = { c = 1, l = 0.4724, t = 0.1739, w = 0.1929, h = 0.1929, name = "Winterspring" },
    [36] = { c = 2, l = 0.4268, t = 0.3564, w = 0.0687, h = 0.0688, name = "Alterac Mountains" },
    [45] = { c = 2, l = 0.4673, t = 0.4166, w = 0.0884, h = 0.0884, name = "Arathi Highlands" },
    [3] = { c = 2, l = 0.4971, t = 0.6286, w = 0.0611, h = 0.0611, name = "Badlands" },
    [4] = { c = 2, l = 0.4765, t = 0.8009, w = 0.0822, h = 0.0823, name = "Blasted Lands" },
    [46] = { c = 2, l = 0.4526, t = 0.6706, w = 0.0719, h = 0.0719, name = "Burning Steppes" },
    [41] = { c = 2, l = 0.4665, t = 0.7751, w = 0.0614, h = 0.0614, name = "Deadwind Pass" },
    [1] = { c = 2, l = 0.4018, t = 0.5545, w = 0.1209, h = 0.1209, name = "Dun Morogh" },
    [10] = { c = 2, l = 0.4256, t = 0.7695, w = 0.0663, h = 0.0663, name = "Duskwood" },
    [139] = { c = 2, l = 0.5022, t = 0.2752, w = 0.0989, h = 0.0990, name = "Eastern Plaguelands" },
    [12] = { c = 2, l = 0.4083, t = 0.7041, w = 0.0852, h = 0.0853, name = "Elwynn Forest" },
    [3430] = { c = 2, l = 0.4973, t = 0.0934, w = 0.1209, h = 0.1209, name = "Eversong Woods" },
    [3433] = { c = 2, l = 0.5168, t = 0.1956, w = 0.0810, h = 0.0810, name = "Ghostlands" },
    [267] = { c = 2, l = 0.4199, t = 0.3969, w = 0.0785, h = 0.0786, name = "Hillsbrad Foothills" },
    [1537] = { c = 2, l = 0.4635, t = 0.5800, w = 0.0194, h = 0.0194, name = "Ironforge" },
    [38] = { c = 2, l = 0.4950, t = 0.5769, w = 0.0677, h = 0.0678, name = "Loch Modan" },
    [44] = { c = 2, l = 0.4846, t = 0.7275, w = 0.0533, h = 0.0533, name = "Redridge Mountains" },
    [51] = { c = 2, l = 0.4540, t = 0.6363, w = 0.0548, h = 0.0548, name = "Searing Gorge" },
    [3487] = { c = 2, l = 0.5442, t = 0.1261, w = 0.0297, h = 0.0297, name = "Silvermoon City" },
    [130] = { c = 2, l = 0.3614, t = 0.3503, w = 0.1031, h = 0.1031, name = "Silverpine Forest" },
    [1519] = { c = 2, l = 0.4037, t = 0.7062, w = 0.0426, h = 0.0427, name = "Stormwind City" },
    [33] = { c = 2, l = 0.3915, t = 0.8230, w = 0.1566, h = 0.1567, name = "Stranglethorn Vale" },
    [8] = { c = 2, l = 0.5006, t = 0.7660, w = 0.0563, h = 0.0563, name = "Swamp of Sorrows" },
    [47] = { c = 2, l = 0.4847, t = 0.3576, w = 0.0945, h = 0.0945, name = "The Hinterlands" },
    [85] = { c = 2, l = 0.3716, t = 0.2703, w = 0.1109, h = 0.1110, name = "Tirisfal Glades" },
    [1497] = { c = 2, l = 0.4246, t = 0.3425, w = 0.0235, h = 0.0236, name = "Undercity" },
    [28] = { c = 2, l = 0.4358, t = 0.2877, w = 0.1055, h = 0.1056, name = "Western Plaguelands" },
    [40] = { c = 2, l = 0.3720, t = 0.7579, w = 0.0859, h = 0.0859, name = "Westfall" },
    [11] = { c = 2, l = 0.4556, t = 0.4908, w = 0.1015, h = 0.1015, name = "Wetlands" },
}

-- Paint big zones first so small zones (cities, islands) stay on top
DC.DRAW_ORDER = {}
for zoneId in pairs(DC.MAP) do table.insert(DC.DRAW_ORDER, zoneId) end
table.sort(DC.DRAW_ORDER, function(a, b)
    local ma, mb = DC.MAP[a], DC.MAP[b]
    return (ma.w * ma.h) > (mb.w * mb.h)
end)

-- ── Overlay pool ──────────────────────────────────────────────
DC.overlays = {}

local overlayParent = CreateFrame("Frame", "DarkCenturiesOverlayFrame", WorldMapDetailFrame)
overlayParent:SetAllPoints(WorldMapDetailFrame)
overlayParent:SetFrameLevel(WorldMapDetailFrame:GetFrameLevel() + 1)

local function GetOverlay(zoneId, layer)
    local o = DC.overlays[zoneId]
    if o then return o end
    o = {}
    -- sublayer by draw order so big zones sit under small ones
    o.tex = overlayParent:CreateTexture(nil, "ARTWORK", nil, layer or 0)
    o.tex:Hide()
    -- Second copy stacked on top: additive passes accumulate, making the
    -- faction color saturate instead of washing into the map's own tones
    o.tex2 = overlayParent:CreateTexture(nil, "ARTWORK", nil, layer or 0)
    o.tex2:Hide()
    o.pct = overlayParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    o.pct:Hide()
    DC.overlays[zoneId] = o
    return o
end

local function HideAllOverlays()
    for _, o in pairs(DC.overlays) do
        o.tex:Hide(); o.tex2:Hide(); o.pct:Hide()
    end
end

-- Loose name match: "Un'Goro Crater" == "UnGoro Crater" etc.
local function NameKey(n)
    return string.lower(string.gsub(n or "", "[^%a]", ""))
end

-- Truly neutral zones: shown grey on hover, no overlay, no capture
DC.NEUTRAL_NAMES = {
    ["moonglade"] = true, ["stranglethornvale"] = true, ["tanaris"] = true,
    ["winterspring"] = true, ["ungorocrater"] = true, ["silithus"] = true,
    ["deadwindpass"] = true,
}

-- Probe points inside a zone's rect (fractions of the rect)
local RECT_PROBES = {
    { 0.5, 0.5 }, { 0.35, 0.5 }, { 0.65, 0.5 }, { 0.5, 0.35 }, { 0.5, 0.65 },
    { 0.3, 0.3 }, { 0.7, 0.7 }, { 0.3, 0.7 }, { 0.7, 0.3 }, { 0.5, 0.25 },
}

-- ── The core: tint each zone with its faction color ──────────
local function RefreshOverlays()
    HideAllOverlays()
    DC.lastShaped, DC.lastRect = 0, 0

    -- Only draw on the two Azeroth continent maps, zoomed out
    local cont = GetCurrentMapContinent()
    if (cont ~= 1 and cont ~= 2) or GetCurrentMapZone() ~= 0 then return end

    local width  = WorldMapDetailFrame:GetWidth()
    local height = WorldMapDetailFrame:GetHeight()
    if width == 0 or height == 0 then return end

    for order = 1, #DC.DRAW_ORDER do
        local zoneId = DC.DRAW_ORDER[order]
        local m = DC.MAP[zoneId]
        if m.c == cont and DC.zoneState[zoneId] then
            local s = DC.zoneState[zoneId]
            local col = DC.COLOR[s.faction] or DC.COLOR[DC.N]
            local o = GetOverlay(zoneId, math.min(7, math.floor(order / 8)))
            local wantKey = NameKey(m.name)
            local shaped = false

            -- Try the engine's zone-shaped highlight art. 3.3.5 returns
            -- EIGHT values; the first is the localized zone NAME — we use
            -- it to verify the probe actually hit this zone.
            for i = 1, #RECT_PROBES do
                local px = m.l + m.w * RECT_PROBES[i][1]
                local py = m.t + m.h * RECT_PROBES[i][2]
                local name, fileName, texPctX, texPctY, texX, texY, scrollX, scrollY =
                    UpdateMapHighlight(px, py)
                if name and fileName and NameKey(name) == wantKey then
                    local tX = texX * width
                    local tY = texY * height
                    if tX > 0 and tY > 0 then
                        -- Alpha-masked zone shape shipped with the addon
                        -- (shapes/*.tga, white with normalized alpha).
                        -- Normal blending + vertex color = solid faction
                        -- color in the exact zone outline. The client's own
                        -- highlight blps can't do this: their art peaks at
                        -- ~16% brightness, so additive tinting is invisible
                        -- and desaturation breaks tinting on this client.
                        local sep = string.char(92)
                        local path = "Interface" .. sep .. "AddOns" .. sep
                            .. "DarkCenturies" .. sep .. "shapes" .. sep .. fileName
                        local okTex = o.tex:SetTexture(path)
                        if okTex and o.tex:GetTexture() then
                            o.tex2:Hide()
                            o.tex:SetBlendMode("BLEND")
                            o.tex:SetDesaturated(nil)
                            o.tex:SetTexCoord(0, texPctX, 0, texPctY)
                            o.tex:SetVertexColor(col.r, col.g, col.b, 0.6)
                            o.tex:ClearAllPoints()
                            o.tex:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT",
                                scrollX * width, -scrollY * height)
                            o.tex:SetWidth(tX)
                            o.tex:SetHeight(tY)
                            o.tex:Show()
                            shaped = true
                            DC.lastShaped = DC.lastShaped + 1
                        end
                    end
                    break
                end
            end

            if not shaped then
                -- Exact-rect turf block from WorldMapArea.dbc
                o.tex2:Hide()
                o.tex:SetBlendMode("BLEND")
                o.tex:SetTexture("Interface/Buttons/WHITE8X8")
                o.tex:SetTexCoord(0, 1, 0, 1)
                o.tex:SetVertexColor(col.r, col.g, col.b, DC.ALPHA)
                o.tex:ClearAllPoints()
                o.tex:SetPoint("TOPLEFT", WorldMapDetailFrame, "TOPLEFT",
                    m.l * width, -m.t * height)
                o.tex:SetWidth(m.w * width)
                o.tex:SetHeight(m.h * height)
                o.tex:Show()
                DC.lastRect = DC.lastRect + 1
            end

            -- Contested zones show the current balance
            if s.faction == DC.N and s.progress ~= 50 then
                o.pct:ClearAllPoints()
                o.pct:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT",
                    (m.l + m.w / 2) * width, -(m.t + m.h / 2) * height)
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

-- ── Legend on the world map ───────────────────────────────────
local legend = overlayParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
legend:SetPoint("BOTTOMLEFT", WorldMapDetailFrame, "BOTTOMLEFT", 8, 6)
legend:SetText("|cffFFD700Dark Centuries:|r |cff4477FFAlliance|r  |cffFF4444Horde|r  |cffB84DFFContested|r  |cffAAAAAANeutral|r")
legend:Hide()

local function RefreshLegend()
    local cont = GetCurrentMapContinent()
    if (cont == 1 or cont == 2) and GetCurrentMapZone() == 0 then
        legend:Show()
    else
        legend:Hide()
    end
end

-- ── Hover status line ────────────────────────────────────────
-- Colored control status under the hovered zone's name
local hoverStatus = WorldMapButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
hoverStatus:SetPoint("TOP", WorldMapFrameAreaLabel, "BOTTOM", 0, -4)
hoverStatus:Hide()

-- name (lowercased letters only) -> zoneId, for hover lookup
local nameToZone = {}
for zoneId, m in pairs(DC.MAP) do
    nameToZone[NameKey(m.name)] = zoneId
end

WorldMapButton:HookScript("OnUpdate", function()
    local label = WorldMapFrameAreaLabel:GetText()
    if not label or label == "" then hoverStatus:Hide(); return end
    local key = NameKey(label)
    if DC.NEUTRAL_NAMES[key] then
        hoverStatus:SetText("|cffAAAAAANeutral|r")
        hoverStatus:Show()
        return
    end
    local zoneId = nameToZone[key]
    local st = zoneId and DC.zoneState[zoneId]
    if st then
        if st.faction == DC.N then
            hoverStatus:SetText(string.format("|cffB84DFFContested|r  |cff4477FF%d%%|r / |cffFF4444%d%%|r",
                100 - st.progress, st.progress))
        else
            hoverStatus:SetText(DC.FACTION_TEXT[st.faction])
        end
        hoverStatus:Show()
    else
        hoverStatus:Hide()
    end
end)

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
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("WORLD_MAP_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "DarkCenturies" then
            -- Survive /reload: restore the last known world state and
            -- keep writing into the saved table (server refreshes it
            -- on login and every resync tick anyway)
            DarkCenturiesDB = DarkCenturiesDB or {}
            DarkCenturiesDB.zoneState = DarkCenturiesDB.zoneState or {}
            for zoneId, st in pairs(DarkCenturiesDB.zoneState) do
                DC.zoneState[zoneId] = st
            end
            DarkCenturiesDB.zoneState = DC.zoneState
        end
    elseif event == "CHAT_MSG_ADDON" then
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
    elseif msg == "debug" then
        local n = 0
        for _ in pairs(DC.zoneState) do n = n + 1 end
        print("|cffFFD700[DC debug]|r zones cached from server: " .. n)
        print("  continent=" .. tostring(GetCurrentMapContinent())
            .. " zone=" .. tostring(GetCurrentMapZone())
            .. " mapShown=" .. tostring(WorldMapFrame:IsShown()))
        print("  last draw: shaped=" .. tostring(DC.lastShaped or "?")
            .. " rect=" .. tostring(DC.lastRect or "?"))
        local sep = string.char(92)
        local test = overlayParent:CreateTexture(nil, "ARTWORK")
        local ok = test:SetTexture("Interface" .. sep .. "AddOns" .. sep
            .. "DarkCenturies" .. sep .. "shapes" .. sep .. "Elwynn")
        print("  shape file test (Elwynn): SetTexture=" .. tostring(ok)
            .. " GetTexture=" .. tostring(test:GetTexture()))
        test:Hide()
    else
        print("|cffFFD700[Dark Centuries]|r commands:")
        print("  /dc status — faction totals + contested zone breakdown")
        print("  /dc map — open the territory map")
        print("  /dc debug — diagnostic info")
    end
end

DEFAULT_CHAT_FRAME:AddMessage(
    "|cffFFD700World of Warcraft: Dark Centuries|r — territory war active. Open your map (M) to see the front lines.")
