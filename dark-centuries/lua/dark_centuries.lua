-- ============================================================
-- World of Warcraft: Dark Centuries
-- Zone Control Warfare — every zone of Azeroth belongs to a faction
-- AzerothCore + Eluna (server side)
-- ============================================================

local DC = {}

-- ── Config ──────────────────────────────────────────────────
DC.CAPTURE_PER_KILL  = 1      -- progress points per PvP kill (1 kill = 1%)
DC.DECAY_PER_TICK    = 0      -- decay disabled: progress never depletes on its own
DC.DECAY_TICK_MS     = 30000  -- (unused while decay is 0)
-- Autonomous war: contested zones shift on their own, simulating the
-- hundreds of bots skirmishing across the world (bot-vs-bot kills also
-- count for real via OnKillPlayer — bots are Player objects)
DC.WAR_TICK_MS       = 180000 -- a war pulse every 3 minutes
DC.WAR_SHIFT_CHANCE  = 0.35   -- chance per contested zone per pulse
DC.WAR_SHIFT_MAX     = 2      -- shift magnitude 1..2 points
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
    else return "|cffB84DFFContested|r" end
end

local function FactionColor(f)
    if f == DC.A then return "|cff4477FF"
    elseif f == DC.H then return "|cffFF4444"
    else return "|cffB84DFF" end
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

    if newFaction == DC.N then
        -- A faction lost its grip; the zone falls back into contention
        SendWorldMessage(string.format(
            "|cffFFD700[Dark Centuries]|r %s has lost its hold on %s — the zone is contested once more!",
            FactionName(oldFaction), zname))
    else
        SendWorldMessage(string.format(
            "|cffFFD700[Dark Centuries]|r %s has claimed %s for its faction! (changed hands %d times)",
            FactionName(newFaction), zname, s.flips))
    end

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
    if DC.DECAY_PER_TICK <= 0 then return end
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

local WarTick  -- forward declaration (defined below)

-- ── Admin commands (.dc ...) ─────────────────────────────────
-- .dc status            zone-by-zone control report
-- .dc randomize         advance the war: some zones captured, others
--                       contested at various states
-- .dc reset             all contested zones back to 50 (even)
-- .dc set <zone> <pct>  set a zone's progress (0=A .. 100=H)
-- .dc war               run one war pulse immediately
local function RefreshEveryone()
    for _, p in ipairs(GetPlayersInWorld()) do
        SendFullState(p)
        UpdateZoneBuff(p)
    end
end

local function ApplyProgress(zoneId, progress)
    local zone = DC.ZONES[zoneId]
    if not zone or zone.locked then return false end
    local st = DC.state[zoneId]
    local oldFac = ZoneFaction(zoneId)
    st.progress = math.max(0, math.min(100, progress))
    local newFac = ZoneFaction(zoneId)
    if newFac ~= oldFac then
        st.faction = newFac
        st.flips = st.flips + 1
    end
    SaveZone(zoneId)
    return true
end

local function OnCommand(event, player, command)
    local cmd = command:lower()
    if cmd ~= "dc" and cmd:sub(1, 3) ~= "dc " then return end

    if player:GetGMRank() < 3 then
        player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r You do not have permission for .dc commands.")
        return false
    end

    local args = {}
    for w in cmd:gmatch("%S+") do table.insert(args, w) end
    local sub = args[2]

    if sub == "status" then
        player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r World control:")
        for zoneId, zone in pairs(DC.ZONES) do
            local st = DC.state[zoneId]
            local f = ZoneFaction(zoneId)
            local tag = zone.locked and " (home)" or ""
            player:SendBroadcastMessage(string.format("  %d %s — %s A%d%%/H%d%%%s",
                zoneId, zone.name, FactionName(f), 100 - st.progress, st.progress, tag))
        end
    elseif sub == "randomize" then
        for zoneId, zone in pairs(DC.ZONES) do
            if not zone.locked then
                local roll = math.random()
                local progress
                if roll < 0.3 then progress = math.random(5, 30)       -- Alliance-held
                elseif roll < 0.6 then progress = math.random(70, 95)  -- Horde-held
                else progress = math.random(31, 69) end                -- contested
                ApplyProgress(zoneId, progress)
            end
        end
        RefreshEveryone()
        SendWorldMessage("|cffFFD700[Dark Centuries]|r The tides of war have shifted dramatically across Azeroth!")
        player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r World randomized.")
    elseif sub == "reset" then
        for zoneId, zone in pairs(DC.ZONES) do
            if not zone.locked then
                ApplyProgress(zoneId, 50)
                DC.state[zoneId].faction = DC.N
                SaveZone(zoneId)
            end
        end
        RefreshEveryone()
        player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r All contested zones reset to even.")
    elseif sub == "set" and args[3] and args[4] then
        local zoneId, pct = tonumber(args[3]), tonumber(args[4])
        if zoneId and pct and ApplyProgress(zoneId, pct) then
            RefreshEveryone()
            player:SendBroadcastMessage(string.format(
                "|cffFFD700[Dark Centuries]|r %s set to A%d%%/H%d%% (%s).",
                DC.ZONES[zoneId].name, 100 - DC.state[zoneId].progress,
                DC.state[zoneId].progress, FactionName(ZoneFaction(zoneId))))
        else
            player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r Usage: .dc set <zoneId> <0-100> (contested zones only).")
        end
    elseif sub == "war" then
        WarTick()
        RefreshEveryone()
        player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r War pulse executed.")
    else
        player:SendBroadcastMessage("|cffFFD700[Dark Centuries]|r Commands: .dc status | randomize | reset | set <zone> <pct> | war")
    end
    return false
end

-- ── Bootstrap ────────────────────────────────────────────────
LoadState()

-- Eluna PlayerEvents (correct IDs — see Eluna Hooks.h):
--   3 = ON_LOGIN, 6 = ON_KILL_PLAYER, 12 = ON_GIVE_XP, 27 = ON_UPDATE_ZONE
RegisterPlayerEvent(6,  OnKillPlayer)
RegisterPlayerEvent(12, OnGiveXP)
RegisterPlayerEvent(27, OnUpdateZone)
RegisterPlayerEvent(3,  OnLogin)
RegisterPlayerEvent(42, OnCommand)  -- .dc admin commands
RegisterPlayerEvent(36, function(_, player) UpdateZoneBuff(player) end)  -- reapply buff on resurrect

CreateLuaEvent(DecayTick, DC.DECAY_TICK_MS, 0)

-- The war rages even when nobody is watching: each pulse, some
-- contested front lines move as off-screen battles are won and lost
WarTick = function()
    for zoneId, st in pairs(DC.state) do
        local zone = DC.ZONES[zoneId]
        if zone and not zone.locked and math.random() < DC.WAR_SHIFT_CHANCE then
            local oldFac = ZoneFaction(zoneId)
            local delta = math.random(1, DC.WAR_SHIFT_MAX)
            if math.random(2) == 1 then delta = -delta end
            st.progress = math.max(0, math.min(100, st.progress + delta))
            local newFac = ZoneFaction(zoneId)
            if newFac ~= oldFac then
                OnZoneFlip(zoneId, newFac, oldFac)
            else
                SaveZone(zoneId)
                BroadcastZoneState(zoneId)
            end
        end
    end
end
CreateLuaEvent(WarTick, DC.WAR_TICK_MS, 0)

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
