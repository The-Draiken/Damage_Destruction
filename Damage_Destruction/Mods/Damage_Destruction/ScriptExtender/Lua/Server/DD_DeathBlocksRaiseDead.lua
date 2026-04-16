-- DD_DeathBlocksRaiseDead.lua (SERVER)
-- Escalates Raise Dead blocking statuses on corpses once per completed Long
-- Rest:
--   none -> DD_DEATH_BLOCKS_RAISE_DEAD -> _1 -> _2 -> _3 -> _4
--
-- This file is the single source of truth for the long-rest ladder. We keep
-- a small debounce because some BG3SE builds fire multiple LongRestFinished
-- callbacks for the same actual rest.

Ext.Utils.Print("[DD DeathBlocksRaiseDead] Loaded")

local TIERS = {
    "DD_DEATH_BLOCKS_RAISE_DEAD",
    "DD_DEATH_BLOCKS_RAISE_DEAD_1",
    "DD_DEATH_BLOCKS_RAISE_DEAD_2",
    "DD_DEATH_BLOCKS_RAISE_DEAD_3",
    "DD_DEATH_BLOCKS_RAISE_DEAD_4",
}

local HIDDEN_BLOCK = "DD_DEATH_BLOCKS_RAISE_DEAD_Hidden"
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
    return nil
end

local function CharExists(uuid)
    return uuid ~= nil and uuid ~= "" and Osi.CharacterExists(uuid) == 1
end

local function IsDead(uuid)
    return CharExists(uuid) and Osi.IsDead(uuid) == 1
end

local function HasStatus(uuid, status)
    return CharExists(uuid) and Osi.HasActiveStatus(uuid, status) == 1
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
            Osi.RemoveStatus(uuid, TIERS[i])
        end
    end
end

local function ApplyTier(uuid, tierIndex)
    if not CharExists(uuid) or tierIndex < 1 then
        return
    end

    if tierIndex > #TIERS then
        tierIndex = #TIERS
    end

    RemoveAllTiers(uuid)
    Osi.ApplyStatus(uuid, TIERS[tierIndex], DURATION, FORCE)

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

local function CollectDeadCandidates()
    local candidates = {}

    local deadRows = Osi.DB_Dead:Get(nil)
    if deadRows then
        for _, row in pairs(deadRows) do
            AddCandidate(candidates, row[1])
        end
    end

    local playerRows = Osi.DB_Players:Get(nil)
    if playerRows then
        for _, row in pairs(playerRows) do
            AddCandidate(candidates, row[1])
        end
    end

    for uuid in pairs(known) do
        AddCandidate(candidates, uuid)
    end

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
