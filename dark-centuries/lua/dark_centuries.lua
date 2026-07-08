-- ============================================================
-- Dark Centuries — Zone Control Warfare
-- AzerothCore + Eluna
-- ============================================================

local DC = {}

-- ── Config ──────────────────────────────────────────────────
DC.CAPTURE_PER_KILL  = 6      -- progress points per PvP kill
DC.DECAY_PER_TICK    = 1      -- points back toward 50 per tick (when no fighting)
DC.DECAY_TICK_MS     = 30000  -- 30 seconds
DC.CONTROL_THRESHOLD = 30     -- <30 = Alliance control, >70 = Horde control
DC.XP_BONUS_PCT      = 0.25   -- 25% bonus XP in controlled zones
DC.GUARD_ENTRY_A     = 900001 -- Alliance Guardian NPC entry
DC.GUARD_ENTRY_H     = 900002 -- Horde Guardian NPC entry
DC.GUARDS_PER_ZONE   = 3      -- patrol guards spawned on capture

-- Faction constants (matches GetTeam(): 0=Alliance, 1=Horde)
DC.A = 1  -- Alliance faction ID (internal)
DC.H = 2  -- Horde faction ID (internal)
DC.N = 0  -- Neutral

-- ── Contested zones ─────────────────────────────────────────
-- [zone_id] = { name, patrol spawn points {x,y,z,o} }
DC.ZONES = {
    [267]  = { name = "Hillsbrad Foothills", spawns = {
        { 326.4, -609.5,  58.8, 1.57 },
        { 962.7, -475.2,  57.4, 4.71 },
        { 118.3, -780.1,  62.1, 3.14 },
    }},
    [45]   = { name = "Arathi Highlands", spawns = {
        {-1268.8, -2195.7, 100.3, 3.14 },
        { -769.3, -2253.0,  54.3, 1.57 },
        {-1050.2, -2100.5,  47.8, 0.0  },
    }},
    [33]   = { name = "Stranglethorn Vale", spawns = {
        {-1260.0, -3400.0,  35.0, 1.57 },
        {-1455.3, -3895.4,  34.7, 4.71 },
        {-1370.8, -3640.2,  35.1, 3.14 },
    }},
    [36]   = { name = "Alterac Mountains", spawns = {
        { 289.4,  -695.2, 363.0, 1.57 },
        {  42.7,  -551.8, 352.3, 4.71 },
        {-180.5,  -480.1, 340.0, 0.0  },
    }},
    [139]  = { name = "Eastern Plaguelands", spawns = {
        { 2438.0, -5265.7,  75.4, 1.57 },
        { 3375.0, -3426.0, 144.3, 4.71 },
        { 2800.0, -4100.0,  95.2, 3.14 },
    }},
    [28]   = { name = "Western Plaguelands", spawns = {
        {-1185.0, -1727.0,  52.0, 1.57 },
        { -800.0, -1400.0,  80.0, 3.14 },
        {-1050.0, -1550.0,  65.0, 4.71 },
    }},
    [1377] = { name = "Silithus", spawns = {
        {-7103.0,  846.0,  23.0, 4.71 },
        {-7350.0,  680.0,  25.0, 1.57 },
        {-7200.0,  760.0,  24.0, 0.0  },
    }},
    [3]    = { name = "Badlands", spawns = {
        {-6456.0, -1280.0, 223.0, 1.57 },
        {-6800.0, -1050.0, 218.0, 4.71 },
        {-7000.0, -1200.0, 215.0, 0.0  },
    }},
    [46]   = { name = "Burning Steppes", spawns = {
        {-7524.0, -1019.0, 297.0, 1.57 },
        {-7107.0, -1231.0, 285.0, 3.14 },
        {-7300.0, -1100.0, 290.0, 4.71 },
    }},
}

-- ── State ────────────────────────────────────────────────────
-- [zone_id] = { progress=50, faction=0, guards={} }
DC.state = {}

-- ── Helpers ──────────────────────────────────────────────────
local function PlayerFaction(player)
    return (player:GetTeam() == 0) and DC.A or DC.H
end

local function ZoneFaction(zoneId)
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
    WorldDBExecute(string.format(
        "UPDATE dc_zone_control SET capture_progress=%d, controlling_faction=%d, flip_count=%d WHERE zone_id=%d",
        s.progress, s.faction, s.flips, zoneId))
end

local function LoadState()
    local result = WorldDBQuery("SELECT zone_id, capture_progress, controlling_faction, flip_count FROM dc_zone_control")
    if not result then return end
    repeat
        local zid  = result:GetUInt32(0)
        local prog = result:GetUInt32(1)
        local fac  = result:GetUInt32(2)
        local flps = result:GetUInt32(3)
        DC.state[zid] = { progress = prog, faction = fac, flips = flps, guards = {} }
    until not result:NextRow()
    -- Fill any missing zones with default neutral state
    for zid, _ in pairs(DC.ZONES) do
        if not DC.state[zid] then
            DC.state[zid] = { progress = 50, faction = DC.N, flips = 0, guards = {} }
        end
    end
end

-- ── Guard spawning ───────────────────────────────────────────
local function DespawnGuards(zoneId)
    local s = DC.state[zoneId]
    if not s then return end
    for _, creature in ipairs(s.guards) do
        if creature and creature:IsInWorld() then
            creature:DespawnOrUnsummon(0)
        end
    end
    s.guards = {}
end

local function SpawnGuards(zoneId, faction)
    local zone = DC.ZONES[zoneId]
    if not zone then return end
    local entry = (faction == DC.A) and DC.GUARD_ENTRY_A or DC.GUARD_ENTRY_H
    local s = DC.state[zoneId]
    s.guards = {}

    -- Find a player in the zone to get the map reference
    local map = nil
    local players = GetPlayersInWorld()
    for _, p in ipairs(players) do
        if p:GetZoneId() == zoneId then
            map = p:GetMap()
            break
        end
    end
    if not map then return end  -- No players in zone right now; guards spawn on next player entry

    local count = math.min(DC.GUARDS_PER_ZONE, #zone.spawns)
    for i = 1, count do
        local sp = zone.spawns[i]
        local creature = map:SpawnCreature(entry, sp[1], sp[2], sp[3], sp[4], 0)
        if creature then
            table.insert(s.guards, creature)
        end
    end
end

-- ── Buff management ──────────────────────────────────────────
-- We apply/remove an Eluna-managed XP bonus rather than a spell aura.
-- The server sends the player's zone state via addon message so the
-- client can display the coloured overlay. No server-side aura needed.

local function NotifyPlayer(player, zoneId)
    local f = ZoneFaction(zoneId)
    local s = DC.state[zoneId]
    local zoneName = DC.ZONES[zoneId] and DC.ZONES[zoneId].name or "Unknown"
    local msg = string.format("ZONE|%d|%d|%d", zoneId, f, s.progress)
    player:SendAddonMessage("DarkCenturies", msg, 7, player)
end

local function BroadcastZoneState(zoneId)
    local players = GetPlayersInWorld()
    for _, p in ipairs(players) do
        NotifyPlayer(p, zoneId)
    end
end

-- ── Zone flip ────────────────────────────────────────────────
local function OnZoneFlip(zoneId, newFaction, oldFaction)
    local s     = DC.state[zoneId]
    local zname = DC.ZONES[zoneId].name
    s.faction   = newFaction
    s.flips     = s.flips + 1

    -- Server-wide announcement
    SendWorldMessage(string.format(
        "|cffFFD700[Dark Centuries]|r %s%s|r has claimed %s! (captured %d times)",
        FactionColor(newFaction), FactionName(newFaction), zname, s.flips))

    -- Swap patrol guards
    DespawnGuards(zoneId)
    if newFaction ~= DC.N then
        SpawnGuards(zoneId, newFaction)
    end

    SaveZone(zoneId)
    BroadcastZoneState(zoneId)
end

-- ── PvP kill handler ─────────────────────────────────────────
local function OnKillPlayer(event, killer, killed)
    if not killer or not killed then return end
    if killer:GetGUIDLow() == killed:GetGUIDLow() then return end

    local zoneId = killer:GetZoneId()
    if not DC.ZONES[zoneId] then return end

    local killerFac = PlayerFaction(killer)
    local killedFac = PlayerFaction(killed)
    if killerFac == killedFac then return end

    local s = DC.state[zoneId]
    if not s then return end

    local oldFac = ZoneFaction(zoneId)

    -- Push meter toward killer's faction
    if killerFac == DC.H then
        s.progress = math.min(100, s.progress + DC.CAPTURE_PER_KILL)
    else
        s.progress = math.max(0, s.progress - DC.CAPTURE_PER_KILL)
    end

    local newFac = ZoneFaction(zoneId)

    -- Feedback to killer
    local bar = string.rep("|cff4477FF█|r", math.floor((100 - s.progress) / 10))
              ..string.rep("|cffFFCC00░|r", 10 - math.floor((100 - s.progress) / 10) - math.floor(s.progress / 10))
              ..string.rep("|cffFF4444█|r", math.floor(s.progress / 10))
    killer:SendBroadcastMessage(string.format(
        "|cffFFD700[Dark Centuries]|r %s  [%s]  %d%%H / %d%%A",
        DC.ZONES[zoneId].name, bar, s.progress, 100 - s.progress))

    if newFac ~= oldFac then
        OnZoneFlip(zoneId, newFac, oldFac)
    else
        SaveZone(zoneId)
        -- Notify both players in zone of new progress
        NotifyPlayer(killer, zoneId)
        NotifyPlayer(killed, zoneId)
    end
end

-- ── XP bonus ─────────────────────────────────────────────────
local function OnGiveXP(event, player, amount, victim)
    if not victim then return end  -- only PvE kills
    local zoneId = player:GetZoneId()
    if not DC.ZONES[zoneId] then return end
    if ZoneFaction(zoneId) == PlayerFaction(player) then
        return math.floor(amount * (1 + DC.XP_BONUS_PCT))
    end
end

-- ── Zone change / login ──────────────────────────────────────
local function OnUpdateZone(event, player, newZone, newArea)
    if not DC.ZONES[newZone] then return end
    NotifyPlayer(player, newZone)

    local f = ZoneFaction(newZone)
    local pf = PlayerFaction(player)
    local zname = DC.ZONES[newZone].name

    if f == DC.N then
        player:SendBroadcastMessage(string.format(
            "|cffFFD700[Dark Centuries]|r %s is |cffFFCC00contested|r. Fight to claim it for your faction.",
            zname))
    elseif f == pf then
        player:SendBroadcastMessage(string.format(
            "|cffFFD700[Dark Centuries]|r Your faction controls %s. |cff00FF00+%d%% XP bonus active.|r",
            zname, DC.XP_BONUS_PCT * 100))
    else
        player:SendBroadcastMessage(string.format(
            "|cffFFD700[Dark Centuries]|r %s is held by the enemy. Reclaim it for your faction.",
            zname))
    end
end

local function OnLogin(event, player)
    -- Send full state of all zones on login
    for zoneId, _ in pairs(DC.ZONES) do
        if DC.state[zoneId] then
            NotifyPlayer(player, zoneId)
        end
    end
end

-- ── Decay tick ───────────────────────────────────────────────
-- Progress slowly drifts back to 50 (contested) when no PvP is happening
local function DecayTick()
    for zoneId, s in pairs(DC.state) do
        if not DC.ZONES[zoneId] then goto continue end
        local oldFac = ZoneFaction(zoneId)

        if s.progress > 50 then
            s.progress = math.max(50, s.progress - DC.DECAY_PER_TICK)
        elseif s.progress < 50 then
            s.progress = math.min(50, s.progress + DC.DECAY_PER_TICK)
        else
            goto continue
        end

        local newFac = ZoneFaction(zoneId)
        if newFac ~= oldFac then
            OnZoneFlip(zoneId, newFac, oldFac)
        else
            SaveZone(zoneId)
        end

        ::continue::
    end
end

-- ── Bootstrap ────────────────────────────────────────────────
LoadState()

RegisterPlayerEvent(7,  OnKillPlayer)   -- PLAYER_EVENT_ON_KILL_PLAYER
RegisterPlayerEvent(13, OnGiveXP)       -- PLAYER_EVENT_ON_GIVE_EXP  (return = new amount)
RegisterPlayerEvent(28, OnUpdateZone)   -- PLAYER_EVENT_ON_UPDATE_ZONE
RegisterPlayerEvent(4,  OnLogin)        -- PLAYER_EVENT_ON_LOAD

CreateLuaEvent(DecayTick, DC.DECAY_TICK_MS, 0)  -- 0 = repeat forever

local zoneCount = 0
for _ in pairs(DC.ZONES) do zoneCount = zoneCount + 1 end
print("[Dark Centuries] Zone control loaded — " .. zoneCount .. " zones active")
