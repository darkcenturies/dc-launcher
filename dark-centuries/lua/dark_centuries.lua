-- ============================================================
-- World of Warcraft: Dark Centuries
-- Zone Control Warfare — every zone of Azeroth belongs to a faction
-- AzerothCore + Eluna (server side)
-- ============================================================

local DC = {}

-- ── Config ──────────────────────────────────────────────────
DC.CAPTURE_PER_KILL  = 6      -- progress points per PvP kill
DC.DECAY_PER_TICK    = 1      -- points back toward 50 per tick (when no fighting)
DC.DECAY_TICK_MS     = 30000  -- 30 seconds
DC.CONTROL_THRESHOLD = 30     -- <=30 = Alliance control, >=70 = Horde control
DC.XP_BONUS_PCT      = 0.25   -- 25% bonus XP in zones your faction controls

-- Faction constants
DC.A = 1  -- Alliance
DC.H = 2  -- Horde
DC.N = 0  -- Neutral / contested

-- ── The world map (GTA:SA style — every zone has an owner) ──
-- [area_id] = { name, locked = DC.A/DC.H (home turf, can never flip) }
DC.ZONES = {
    -- Eastern Kingdoms — Alliance territory (locked, cannot be fought for)
    [1]    = { name = "Dun Morogh",            locked = DC.A },
    [11]   = { name = "Wetlands",              locked = DC.A },
    [10]   = { name = "Duskwood",              locked = DC.A },
    [12]   = { name = "Elwynn Forest",         locked = DC.A },
    [38]   = { name = "Loch Modan",            locked = DC.A },
    [40]   = { name = "Westfall",              locked = DC.A },
    [44]   = { name = "Redridge Mountains",    locked = DC.A },
    [1519] = { name = "Stormwind City",        locked = DC.A },
    [1537] = { name = "Ironforge",             locked = DC.A },
    -- Eastern Kingdoms — Horde territory (locked)
    [85]   = { name = "Tirisfal Glades",       locked = DC.H },
    [130]  = { name = "Silverpine Forest",     locked = DC.H },
    [1497] = { name = "Undercity",             locked = DC.H },
    [3430] = { name = "Eversong Woods",        locked = DC.H },
    [3433] = { name = "Ghostlands",            locked = DC.H },
    [3487] = { name = "Silvermoon City",       locked = DC.H },
    -- Eastern Kingdoms — contested warfronts (capturable via PvP)
    [3]    = { name = "Badlands" },
    [4]    = { name = "Blasted Lands" },
    [8]    = { name = "Swamp of Sorrows" },
    [28]   = { name = "Western Plaguelands" },
    [36]   = { name = "Alterac Mountains" },
    [45]   = { name = "Arathi Highlands" },
    [46]   = { name = "Burning Steppes" },
    [47]   = { name = "The Hinterlands" },
    [51]   = { name = "Searing Gorge" },
    [139]  = { name = "Eastern Plaguelands" },
    [267]  = { name = "Hillsbrad Foothills" },
    -- Kalimdor — Alliance territory (locked)
    [141]  = { name = "Teldrassil",            locked = DC.A },
    [148]  = { name = "Darkshore",             locked = DC.A },
    [1657] = { name = "Darnassus",             locked = DC.A },
    [3524] = { name = "Azuremyst Isle",        locked = DC.A },
    [3525] = { name = "Bloodmyst Isle",        locked = DC.A },
    [3557] = { name = "The Exodar",            locked = DC.A },
    -- Kalimdor — Horde territory (locked)
    [14]   = { name = "Durotar",               locked = DC.H },
    [17]   = { name = "The Barrens",           locked = DC.H },
    [215]  = { name = "Mulgore",               locked = DC.H },
    [1637] = { name = "Orgrimmar",             locked = DC.H },
    [1638] = { name = "Thunder Bluff",         locked = DC.H },
    -- Kalimdor — contested warfronts (capturable via PvP)
    [15]   = { name = "Dustwallow Marsh" },
    [16]   = { name = "Azshara" },
    [331]  = { name = "Ashenvale" },
    [357]  = { name = "Feralas" },
    [361]  = { name = "Felwood" },
    [400]  = { name = "Thousand Needles" },
    [405]  = { name = "Desolace" },
    [406]  = { name = "Stonetalon Mountains" },
    -- Truly neutral zones take no part in the war and are not listed:
    -- Moonglade, Stranglethorn Vale, Tanaris, Winterspring, Un'Goro
    -- Crater, Silithus, Deadwind Pass
}

-- ── State ────────────────────────────────────────────────────
-- [zone_id] = { progress = 0-100 (0=full Alliance, 100=full Horde), faction, flips }
DC.state = {}

-- ── Helpers ──────────────────────────────────────────────────
local function PlayerFaction(player)
    return (player:GetTeam() == 0) and DC.A or DC.H
end

local function ZoneFaction(zoneId)
    local z = DC.ZONES[zoneId]
    if z and z.locked then return z.locked end
    local s = DC.state[zoneId]
    if not s then return DC.N end
    if s.progress <= DC.CONTROL_THRESHOLD then return DC.A
    elseif s.progress >= (100 - DC.CONTROL_THRESHOLD) then return DC.H
    else return DC.N end
end

local function FactionName(f)
    if f == DC.A then return "|cff4477FFAlliance|r"
    elseif f == DC.H then return "|cffFF4444Horde|r"
    else return "|cffFFCC00Contested|r" end
end

local function FactionColor(f)
    if f == DC.A then return "|cff4477FF"
    elseif f == DC.H then return "|cffFF4444"
    else return "|cffFFCC00" end
end

-- ── Persistence ──────────────────────────────────────────────
local function SaveZone(zoneId)
    local s = DC.state[zoneId]
    local name = DC.ZONES[zoneId] and DC.ZONES[zoneId].name or ""
    -- Upsert so zones missing from the seed data still persist
    WorldDBExecute(string.format(
        "INSERT INTO dc_zone_control (zone_id, zone_name, capture_progress, controlling_faction, flip_count) " ..
        "VALUES (%d, '%s', %d, %d, %d) " ..
        "ON DUPLICATE KEY UPDATE capture_progress=%d, controlling_faction=%d, flip_count=%d",
        zoneId, name:gsub("'", "''"), s.progress, s.faction, s.flips,
        s.progress, s.faction, s.flips))
end

local function LoadState()
    local result = WorldDBQuery("SELECT zone_id, capture_progress, controlling_faction, flip_count FROM dc_zone_control")
    if result then
        repeat
            local zid  = result:GetUInt32(0)
            local prog = result:GetUInt32(1)
            local fac  = result:GetUInt32(2)
            local flps = result:GetUInt32(3)
            DC.state[zid] = { progress = prog, faction = fac, flips = flps }
        until not result:NextRow()
    end
    -- Fill missing zones; force locked home zones to their owner
    for zid, z in pairs(DC.ZONES) do
        if not DC.state[zid] then
            DC.state[zid] = { progress = 50, faction = DC.N, flips = 0 }
        end
        if z.locked then
            DC.state[zid].progress = (z.locked == DC.A) and 0 or 100
            DC.state[zid].faction  = z.locked
        end
    end
end

-- ── Client sync ──────────────────────────────────────────────
local function NotifyPlayer(player, zoneId)
    local s = DC.state[zoneId]
    if not s then return end
    local msg = string.format("ZONE|%d|%d|%d", zoneId, ZoneFaction(zoneId), s.progress)
    player:SendAddonMessage("DarkCenturies", msg, 7, player)
end

local function BroadcastZoneState(zoneId)
    for _, p in ipairs(GetPlayersInWorld()) do
        NotifyPlayer(p, zoneId)
    end
end

local function SendFullState(player)
    for zoneId, _ in pairs(DC.ZONES) do
        NotifyPlayer(player, zoneId)
    end
end

-- ── Territory buff ───────────────────────────────────────────
-- No chat spam: control is shown as a visible aura on the player.
-- 57940 = Essence of Wintergrasp (exists in the 3.3.5a client,
-- "your faction controls this territory" marker; the +25% XP is
-- applied by OnGiveXP whenever this condition holds).
DC.BUFF_SPELL = 57940

local function UpdateZoneBuff(player)
    local zoneId = player:GetZoneId()
    local zone = DC.ZONES[zoneId]
    if zone and ZoneFaction(zoneId) == PlayerFaction(player) then
        if not player:HasAura(DC.BUFF_SPELL) then
            player:AddAura(DC.BUFF_SPELL, player)
        end
    else
        if player:HasAura(DC.BUFF_SPELL) then
            player:RemoveAura(DC.BUFF_SPELL)
        end
    end
end

-- ── Zone flip ────────────────────────────────────────────────
local function OnZoneFlip(zoneId, newFaction, oldFaction)
    local s     = DC.state[zoneId]
    local zname = DC.ZONES[zoneId].name
    s.faction   = newFaction
    s.flips     = s.flips + 1

    SendWorldMessage(string.format(
        "|cffFFD700[Dark Centuries]|r %s%s|r has claimed %s! (captured %d times)",
        FactionColor(newFaction), FactionName(newFaction), zname, s.flips))

    SaveZone(zoneId)
    BroadcastZoneState(zoneId)

    -- Grant/strip the territory buff for everyone in the zone
    for _, p in ipairs(GetPlayersInWorld()) do
        if p:GetZoneId() == zoneId then
            UpdateZoneBuff(p)
        end
    end
end

-- ── PvP kill capture ─────────────────────────────────────────
local function OnKillPlayer(event, killer, killed)
    if not killer or not killed then return end
    if killer:GetGUIDLow() == killed:GetGUIDLow() then return end

    local zoneId = killer:GetZoneId()
    local zone = DC.ZONES[zoneId]
    if not zone or zone.locked then return end

    local killerFac = PlayerFaction(killer)
    if killerFac == PlayerFaction(killed) then return end

    local s = DC.state[zoneId]
    if not s then return end

    local oldFac = ZoneFaction(zoneId)

    if killerFac == DC.H then
        s.progress = math.min(100, s.progress + DC.CAPTURE_PER_KILL)
    else
        s.progress = math.max(0, s.progress - DC.CAPTURE_PER_KILL)
    end

    local newFac = ZoneFaction(zoneId)

    local aPct = 100 - s.progress
    local blueBlocks   = math.floor(aPct / 10)
    local redBlocks    = math.floor(s.progress / 10)
    local yellowBlocks = 10 - blueBlocks - redBlocks
    local bar = string.rep("|cff4477FF#|r", blueBlocks)
              ..string.rep("|cffFFCC00-|r", yellowBlocks)
              ..string.rep("|cffFF4444#|r", redBlocks)
    killer:SendBroadcastMessage(string.format(
        "|cffFFD700[Dark Centuries]|r %s  [%s]  A %d%% / H %d%%",
        zone.name, bar, aPct, s.progress))

    if newFac ~= oldFac then
        OnZoneFlip(zoneId, newFac, oldFac)
    else
        SaveZone(zoneId)
        NotifyPlayer(killer, zoneId)
        NotifyPlayer(killed, zoneId)
    end
end

-- ── XP bonus in controlled territory ─────────────────────────
local function OnGiveXP(event, player, amount, victim)
    if not victim then return end  -- only kill XP
    local zoneId = player:GetZoneId()
    if not DC.ZONES[zoneId] then return end
    if ZoneFaction(zoneId) == PlayerFaction(player) then
        return math.floor(amount * (1 + DC.XP_BONUS_PCT))
    end
end

-- ── Zone change / login ──────────────────────────────────────
local function OnUpdateZone(event, player, newZone, newArea)
    if DC.ZONES[newZone] then
        NotifyPlayer(player, newZone)
    end
    UpdateZoneBuff(player)
end

local function OnLogin(event, player)
    SendFullState(player)
    UpdateZoneBuff(player)
end

-- ── Decay tick ───────────────────────────────────────────────
local function DecayTick()
    for zoneId, s in pairs(DC.state) do
        local zone = DC.ZONES[zoneId]
        if zone and not zone.locked and s.progress ~= 50 then
            local oldFac = ZoneFaction(zoneId)

            if s.progress > 50 then
                s.progress = math.max(50, s.progress - DC.DECAY_PER_TICK)
            else
                s.progress = math.min(50, s.progress + DC.DECAY_PER_TICK)
            end

            local newFac = ZoneFaction(zoneId)
            if newFac ~= oldFac then
                OnZoneFlip(zoneId, newFac, oldFac)
            else
                SaveZone(zoneId)
            end
        end
    end
end

-- ── Bootstrap ────────────────────────────────────────────────
LoadState()

-- Eluna PlayerEvents (correct IDs — see Eluna Hooks.h):
--   3 = ON_LOGIN, 6 = ON_KILL_PLAYER, 12 = ON_GIVE_XP, 27 = ON_UPDATE_ZONE
RegisterPlayerEvent(6,  OnKillPlayer)
RegisterPlayerEvent(12, OnGiveXP)
RegisterPlayerEvent(27, OnUpdateZone)
RegisterPlayerEvent(3,  OnLogin)

CreateLuaEvent(DecayTick, DC.DECAY_TICK_MS, 0)

-- Full-state rebroadcast so clients that /reload (clearing their addon
-- cache mid-session) resync within a minute without relogging
local function ResyncTick()
    for _, p in ipairs(GetPlayersInWorld()) do
        SendFullState(p)
    end
end
CreateLuaEvent(ResyncTick, 20000, 0)

-- Sync everyone already online (script reload / server restart)
for _, p in ipairs(GetPlayersInWorld()) do
    SendFullState(p)
end

local zoneCount, lockedCount = 0, 0
for _, z in pairs(DC.ZONES) do
    zoneCount = zoneCount + 1
    if z.locked then lockedCount = lockedCount + 1 end
end
print(string.format("[Dark Centuries] World control loaded — %d zones (%d home, %d contestable)",
    zoneCount, lockedCount, zoneCount - lockedCount))
