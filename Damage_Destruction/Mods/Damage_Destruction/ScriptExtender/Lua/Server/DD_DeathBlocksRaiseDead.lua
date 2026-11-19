-- DD_DeathBlocksRaiseDead.lua (SERVER)
-- Escalates Raise Dead blocking statuses on corpses once per completed Long
-- Rest:
--   none -> DD_DEATH_BLOCKS_RAISE_DEAD -> _1 -> _2 -> _3 -> _4
--
-- This file is the single source of truth for the long-rest ladder.
--
-- DEAD CHARACTER DISCOVERY:
-- We use THREE strategies to find dead characters, because DB_Dead:Get(nil)
-- is unreliable on some BG3SE builds:
--   1. Ext.Entity.GetAllEntitiesWithComponent("Health") - scan all loaded entities
--   2. Osi.DB_Dead:Get(nil) - query the story database
--   3. The `known` table - characters we have seen die during this session

Ext.Utils.Print("[DD DeathBlocksRaiseDead] Loaded")

local TIERS = {
    "DD_DEATH_BLOCKS_RAISE_DEAD",
    "DD_DEATH_BLOCKS_RAISE_DEAD_1",
    "DD_DEATH_BLOCKS_RAISE_DEAD_2",
    "DD_DEATH_BLOCKS_RAISE_DEAD_3",
    "DD_DEATH_BLOCKS_RAISE_DEAD_4",
}

local HIDDEN_BLOCK = "DD_DEATH_BLOCKS_RAISE_DEAD_Hidden"
local DEAD_ONE_MINUTE = "DEAD_ONE_MINUTE"
local DEAD_TECHNICAL = "DEAD_TECHNICAL"
local DEAD_COMBAT_BLOCK = "DEAD_COMBAT_BLOCK"
local FORCE = 1
local DURATION = -1.0
local LONG_REST_DEBOUNCE_MS = 2000

-- Keep a set of UUIDs we have seen dead so loaded NPC corpses can continue to
-- progress even if DB_Dead is inconsistent on a particular build.
local known = {}
local lastLongRestProcessMs = nil

local function NowMs()
    if Ext and Ext.Utils and Ext.Utils.MonotonicTime then
        local ok, now = pcall(Ext.Utils.MonotonicTime)
        if ok and type(now) == "number" then
            return now
        end
    end
    if os and os.clock then
        local ok, now = pcall(os.clock)
        if ok and type(now) == "number" then
            return now * 1000
        end
    end
    return nil
end

local function SafeOsi(fnName, ...)
    local fn = Osi and Osi[fnName]
    if type(fn) ~= "function" then
        return nil
    end

    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end

    return nil
end

local function CharExists(uuid)
    if uuid == nil or uuid == "" or uuid == "NULL_00000000-0000-0000-0000-000000000000" then
        return false
    end

    local exists = SafeOsi("CharacterExists", uuid)
    if exists ~= nil then
        return exists == 1
    end

    local isCharacter = SafeOsi("IsCharacter", uuid)
    if isCharacter ~= nil then
        return isCharacter == 1
    end

    return false
end

local function IsDead(uuid)
    return CharExists(uuid) and SafeOsi("IsDead", uuid) == 1
end

local function HasStatus(uuid, status)
    return CharExists(uuid) and SafeOsi("HasActiveStatus", uuid, status) == 1
end

local function HasTier(uuid, tier)
    return HasStatus(uuid, tier)
end

local function HasHiddenBlock(uuid)
    return HasStatus(uuid, HIDDEN_BLOCK)
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
    if not CharExists(uuid) then
        return
    end

    for i = 1, #TIERS do
        if HasTier(uuid, TIERS[i]) then
            SafeOsi("RemoveStatus", uuid, TIERS[i])
        end
    end
end

local function RemoveRecentDeathStatuses(uuid)
    if not CharExists(uuid) then
        return
    end

    SafeOsi("RemoveStatus", uuid, DEAD_ONE_MINUTE)
    SafeOsi("RemoveStatus", uuid, DEAD_TECHNICAL)
    SafeOsi("RemoveStatus", uuid, DEAD_COMBAT_BLOCK)
end

local function ApplyTier(uuid, tierIndex)
    if not CharExists(uuid) or tierIndex < 1 then
        return
    end

    if tierIndex > #TIERS then
        tierIndex = #TIERS
    end

    RemoveAllTiers(uuid)
    RemoveRecentDeathStatuses(uuid)
    SafeOsi("ApplyStatus", uuid, TIERS[tierIndex], DURATION, FORCE)

    Ext.Utils.Print(string.format(
        "[DD DeathBlocksRaiseDead] Applied tier %d (%s) to %s",
        tierIndex,
        TIERS[tierIndex],
        tostring(uuid)
    ))
end

local function ClearTracking(uuid, reason)
    if uuid == nil or uuid == "" then
        return
    end

    RemoveAllTiers(uuid)
    known[uuid] = nil

    if reason then
        Ext.Utils.Print(string.format(
            "[DD DeathBlocksRaiseDead] Cleared ladder for %s (%s)",
            tostring(uuid),
            tostring(reason)
        ))
    end
end

local function AdvanceOrSeed(uuid)
    if not CharExists(uuid) then
        known[uuid] = nil
        return
    end

    if not IsDead(uuid) then
        ClearTracking(uuid, "no longer dead")
        return
    end

    known[uuid] = true

    -- Hidden corpse-block cases are managed elsewhere and should not enter
    -- the visible long-rest ladder.
    if HasHiddenBlock(uuid) then
        RemoveAllTiers(uuid)
        RemoveRecentDeathStatuses(uuid)
        Ext.Utils.Print(string.format(
            "[DD DeathBlocksRaiseDead] Skipping hidden corpse %s",
            tostring(uuid)
        ))
        return
    end

    local cur = GetCurrentTierIndex(uuid)
    if cur == 0 then
        ApplyTier(uuid, 1)
        return
    end

    if cur >= #TIERS then
        RemoveRecentDeathStatuses(uuid)
        Ext.Utils.Print(string.format(
            "[DD DeathBlocksRaiseDead] %s already at terminal tier %s",
            tostring(uuid),
            TIERS[#TIERS]
        ))
        return
    end

    ApplyTier(uuid, cur + 1)
end

local function CleanupKnown()
    local toCheck = {}
    for uuid in pairs(known) do
        toCheck[#toCheck + 1] = uuid
    end

    for i = 1, #toCheck do
        local uuid = toCheck[i]
        if not CharExists(uuid) then
            known[uuid] = nil
        elseif not IsDead(uuid) then
            ClearTracking(uuid, "cleanup")
        end
    end
end

local function AddCandidate(candidates, uuid)
    if uuid ~= nil and uuid ~= "" and IsDead(uuid) then
        candidates[uuid] = true
        known[uuid] = true
    end
end

-- Collect dead characters using THREE strategies for maximum reliability.
local function CollectDeadCandidates()
    local candidates = {}
    local sources = { entityScan = 0, dbDead = 0, dbPlayers = 0, knownTable = 0 }

    -- STRATEGY 1: Scan all loaded entities with Health component.
    -- This is the most reliable method on all BG3SE builds.
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if ok and type(ents) == "table" then
        for _, e in pairs(ents) do
            local uuid = e and e.Uuid
            if uuid and uuid ~= "" then
                if IsDead(uuid) then
                    AddCandidate(candidates, uuid)
                    sources.entityScan = sources.entityScan + 1
                end
            end
        end
    end

    -- STRATEGY 2: Query DB_Dead (may be empty/unreliable on some builds).
    local okDead, deadRows = pcall(function()
        return Osi.DB_Dead:Get(nil)
    end)
    if okDead and type(deadRows) == "table" then
        for _, row in pairs(deadRows) do
            local uuid = type(row) == "table" and row[1] or row
            if uuid and uuid ~= "" and not candidates[uuid] then
                AddCandidate(candidates, uuid)
                sources.dbDead = sources.dbDead + 1
            end
        end
    end

    -- STRATEGY 3: Query DB_Players to catch player corpses.
    local okPlayers, playerRows = pcall(function()
        return Osi.DB_Players:Get(nil)
    end)
    if okPlayers and type(playerRows) == "table" then
        for _, row in pairs(playerRows) do
            local uuid = type(row) == "table" and row[1] or row
            if uuid and uuid ~= "" and not candidates[uuid] then
                AddCandidate(candidates, uuid)
                sources.dbPlayers = sources.dbPlayers + 1
            end
        end
    end

    -- STRATEGY 4: Our known table (characters we saw die this session).
    for uuid in pairs(known) do
        if not candidates[uuid] and IsDead(uuid) then
            candidates[uuid] = true
            sources.knownTable = sources.knownTable + 1
        end
    end

    Ext.Utils.Print(string.format(
        "[DD DeathBlocksRaiseDead] CollectDeadCandidates: entityScan=%d dbDead=%d dbPlayers=%d knownTable=%d total=%d",
        sources.entityScan, sources.dbDead, sources.dbPlayers, sources.knownTable,
        sources.entityScan + sources.dbDead + sources.dbPlayers + sources.knownTable
    ))

    return candidates
end

local function ShouldProcessLongRest(source)
    local now = NowMs()
    if now ~= nil and lastLongRestProcessMs ~= nil then
        if (now - lastLongRestProcessMs) < LONG_REST_DEBOUNCE_MS then
            Ext.Utils.Print(string.format(
                "[DD DeathBlocksRaiseDead] Ignoring duplicate LongRestFinished from %s",
                tostring(source)
            ))
            return false
        end
    end

    lastLongRestProcessMs = now
    return true
end

local function HandleLongRestFinished(source)
    if not ShouldProcessLongRest(source) then
        return
    end

    Ext.Utils.Print(string.format(
        "[DD DeathBlocksRaiseDead] LongRestFinished handler running (%s)",
        tostring(source)
    ))

    CleanupKnown()

    local candidates = CollectDeadCandidates()
    local count = 0

    for uuid in pairs(candidates) do
        count = count + 1
        AdvanceOrSeed(uuid)
    end

    Ext.Utils.Print(string.format(
        "[DD DeathBlocksRaiseDead] Processed %d dead characters",
        count
    ))
end

local function OnDied(dead, killer, extra)
    if dead and dead ~= "" then
        known[dead] = true
        Ext.Utils.Print(string.format(
            "[DD DeathBlocksRaiseDead] Died seen: %s (killer=%s extra=%s)",
            tostring(dead),
            tostring(killer),
            tostring(extra)
        ))
    end
end

Ext.Osiris.RegisterListener("Died", 1, "after", function(dead)
    OnDied(dead, nil, "arity1")
end)

Ext.Osiris.RegisterListener("Died", 2, "after", function(dead, killer)
    OnDied(dead, killer, "arity2")
end)

Ext.Osiris.RegisterListener("Died", 3, "after", function(dead, killer, extra)
    OnDied(dead, killer, extra)
end)

Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(character)
    ClearTracking(character, "Resurrected event")
end)

Ext.Osiris.RegisterListener("LongRestFinished", 0, "after", function()
    HandleLongRestFinished("Osiris0")
end)

Ext.Osiris.RegisterListener("LongRestFinished", 1, "after", function(_)
    HandleLongRestFinished("Osiris1")
end)

if Ext and Ext.Events and Ext.Events.LongRestFinished then
    Ext.Events.LongRestFinished:Subscribe(function(_)
        HandleLongRestFinished("ExtEvent")
    end)
end
