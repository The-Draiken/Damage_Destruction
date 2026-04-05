-- DD_DeathBlocksRaiseDead.lua (SERVER)
-- Escalates Raise-Dead blocking statuses on corpses each Long Rest:
--   none -> DD_DEATH_BLOCKS_RAISE_DEAD -> _1 -> _2 -> _3 -> _4 (caps)
--
-- Important: Do NOT rely on IsCharacterInCombat(dead) style checks here.
-- We use DB_Dead (same approach as 5eSpells) so it works for all NPCs and party.
--
-- This file is intentionally verbose in logging for debugging.

Ext.Utils.Print("[DD DeathBlocksRaiseDead] Loaded")

local TIERS = {
    "DD_DEATH_BLOCKS_RAISE_DEAD",
    "DD_DEATH_BLOCKS_RAISE_DEAD_1",
    "DD_DEATH_BLOCKS_RAISE_DEAD_2",
    "DD_DEATH_BLOCKS_RAISE_DEAD_3",
    "DD_DEATH_BLOCKS_RAISE_DEAD_4",
}

local FORCE = 1
-- We manage tier persistence explicitly. Statuses themselves have FreezeDuration/IgnoreResting.
local DURATION = -1.0

-- Keep a set of UUIDs we have ever seen dead (for cleanup when revived/despawned)
local known = {}

local function CharExists(uuid)
    return uuid ~= nil and uuid ~= "" and Osi.CharacterExists(uuid) == 1
end

local function IsDead(uuid)
    return Osi.IsDead(uuid) == 1
end

local function HasTier(uuid, tier)
    -- Use HasActiveStatus; HasStatus can be unreliable for some statuses on dead entities.
    return Osi.HasActiveStatus(uuid, tier) == 1
end

local function GetCurrentTierIndex(uuid)
    for i = #TIERS, 1, -1 do
        if HasTier(uuid, TIERS[i]) then
            return i
        end
    end
    return 0
end

local function RemoveAllTiers(uuid)
    for i = 1, #TIERS do
        if HasTier(uuid, TIERS[i]) then
            Osi.RemoveStatus(uuid, TIERS[i])
        end
    end
end

local function ApplyTier(uuid, tierIndex)
    if tierIndex < 1 then return end
    if tierIndex > #TIERS then tierIndex = #TIERS end

    -- Tier statuses already remove lower tiers via Boosts, but we keep this anyway for safety.
    RemoveAllTiers(uuid)

    Osi.ApplyStatus(uuid, TIERS[tierIndex], DURATION, FORCE)
    Ext.Utils.Print(string.format(
        "[DD DeathBlocksRaiseDead] Applied tier %d (%s) to %s",
        tierIndex, TIERS[tierIndex], uuid
    ))
end

local function AdvanceOrSeed(uuid)
    if not CharExists(uuid) then
        known[uuid] = nil
        return
    end

    if not IsDead(uuid) then
        -- Revived: clean up tiers
        RemoveAllTiers(uuid)
        known[uuid] = nil
        return
    end

    known[uuid] = true

    local cur = GetCurrentTierIndex(uuid)
    if cur == 0 then
        -- First long rest after death => seed base tier
        ApplyTier(uuid, 1)
        return
    end

    if cur >= #TIERS then
        -- Already capped
        return
    end

    ApplyTier(uuid, cur + 1)
end

-- Track deaths (NPCs included). NOTE: Died is arity 3 in your logs.
Ext.Osiris.RegisterListener("Died", 3, "after", function(dead, killer, extra)
    if dead and dead ~= "" then
        known[dead] = true
        -- We intentionally do not apply tiers here; this system advances on LongRestFinished.
        Ext.Utils.Print(string.format("[DD DeathBlocksRaiseDead] Died seen: %s", dead))
    end
end)

local function CleanupKnown()
    -- Remove tiers for anyone we used to know about that is no longer dead (revived) or gone
    local toCheck = {}
    for uuid, _ in pairs(known) do
        toCheck[#toCheck+1] = uuid
    end

    for i = 1, #toCheck do
        local uuid = toCheck[i]
        if not CharExists(uuid) then
            known[uuid] = nil
        elseif not IsDead(uuid) then
            RemoveAllTiers(uuid)
            known[uuid] = nil
        end
    end
end

-- Main driver: Long Rest finished
local function HandleLongRestFinished(...)
    Ext.Utils.Print("[DD DeathBlocksRaiseDead] LongRestFinished handler running")

    CleanupKnown()

    local deadRows = Osi.DB_Dead:Get(nil)
    local count = 0
    if deadRows then
        for _, row in pairs(deadRows) do
            local uuid = row[1]
            if uuid and uuid ~= "" and CharExists(uuid) and IsDead(uuid) then
                count = count + 1
                AdvanceOrSeed(uuid)
            end
        end
    end

    Ext.Utils.Print(string.format("[DD DeathBlocksRaiseDead] Processed %d DB_Dead corpses", count))
end

-- Main driver: Long Rest finished (Osiris)
Ext.Osiris.RegisterListener("LongRestFinished", 0, "after", function()
    Ext.Utils.Print("[DD DeathBlocksRaiseDead] LongRestFinished fired (arity0)")
    HandleLongRestFinished()
end)

-- Some builds expose LongRestFinished with an argument; register arity 1 too.
Ext.Osiris.RegisterListener("LongRestFinished", 1, "after", function(a)
    Ext.Utils.Print("[DD DeathBlocksRaiseDead] LongRestFinished fired (arity1)")
    HandleLongRestFinished(a)
end)

-- Script Extender event (if available)
if Ext and Ext.Events and Ext.Events.LongRestFinished then
    Ext.Events.LongRestFinished:Subscribe(function(e)
        Ext.Utils.Print("[DD DeathBlocksRaiseDead] Ext.Events.LongRestFinished fired")
        HandleLongRestFinished(e)
    end)
end
