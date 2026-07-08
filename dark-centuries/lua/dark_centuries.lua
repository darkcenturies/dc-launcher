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

-- Faction constants (matches GetTeam(): 0=Alliance, 1=Horde)
DC.A = 1  -- Alliance faction ID (internal)
DC.H = 2  -- Horde faction ID (internal)
DC.N = 0  -- Neutral

-- ── Contested zones ─────────────────────────────────────────
-- [zone_id] = { name }
DC.ZONES = {
    [267] = { name = "Hillsbrad Foothills" },
    [45] = { name = "Arathi Highlands" },
    [33] = { name = "Stranglethorn Vale" },
    [36] = { name = "Alterac Mountains" },
    [139] = { name = "Eastern Plaguelands" },
    [28] = { name = "Western Plaguelands" },
    [1377] = { name = "Silithus" },
    [3] = { name = "Badlands" },
    [46] = { name = "Burning Steppes" },
}

-- ── State ────────────────────────────────────────────────────
-- [zone_id] = { progress=50, faction=0 }
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
        DC.state[zid] = { progress = prog, faction = fac, flips = flps }
    until not result:NextRow()
    -- Fill any missing zones with default neutral state
    for zid, _ in pairs(DC.ZONES) do
        if not DC.state[zid] then
            DC.state[zid] = { progress = 50, faction = DC.N, flips = 0 }
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
