--[[
    DD_RecentDeath_All.lua

    This script implements the “recent death” behaviour for Baldur's Gate 3 in the style
    of the 5eSpells mod, but without any mod settings or player‑only restrictions. Any
    creature that dies will be assigned a temporary status that prevents them from
    immediately transitioning to the long‑dead state. The status lasts for ten combat
    rounds (roughly 60 seconds) and is reduced by one round at the start of each
    combat round. Outside of combat the timer counts down in seconds. When the
    countdown expires the corpse is transitioned to the long‑dead state. Corpses are
    blocked from re‑entering combat while this timer is active.

    Key features:
      * Works for all characters (players, allies, enemies, neutrals).
      * No MCM or passive gating – behaviour is always enabled.
      * Uses combat rounds to tick the countdown during turn‑based combat. Outside of
        combat the countdown progresses in real time.
      * Applies a combat‑block status to prevent corpses from being pulled back into
        combat.
      * Cleans up statuses and passives on resurrection.

    PERFORMANCE NOTE (added during an optimisation pass):
    The original version of this file re-queried `Osi.DB_Dead:Get(nil)` — every corpse
    currently known to the story database — inside `CombatRoundStarted` and
    `TurnStarted`. Those two events fire once per round and once per combatant's turn
    respectively, so in an 8-person fight that's a full scan of every corpse in the
    loaded area happening roughly a dozen times a round. Since Osiris runs every mod's
    listeners for a given event synchronously and in sequence, that scan was sitting in
    front of every other Script Extender mod's own handlers for the same events, which
    is almost certainly what people meant by "this mod slows down other SE mods". Worse,
    the scan gets bigger the more corpses are lying around, so it was slowest exactly
    when a fight was biggest.

    This version keeps its own small bookkeeping tables — `PendingExpireTB` for corpses
    counting down in combat rounds and `PendingExpireRT` for corpses counting down in
    real time — populated when we personally apply the countdown (in `Died`) and cleared
    when it resolves. `CombatRoundStarted` and `TurnStarted` now iterate only those
    tables (which only ever contain corpses that recently died and are still within
    their countdown window — normally a handful, never "every corpse in the game"),
    instead of the whole story database.

    Author: DD overhaul
]]

local MOD_PREFIX = "[DD]"

-- Verbose tracing for this file. Several of the original Ext.Utils.Print calls here
-- ran unconditionally on every combat round and every turn, regardless of whether
-- anyone wanted to see them. Gate everything behind this flag (default off) so normal
-- play doesn't pay for log writes nobody is reading. Flip to true when debugging.
local DEBUG = false
local function DPrint(msg)
    if DEBUG then Ext.Utils.Print(MOD_PREFIX .. " " .. tostring(msg)) end
end

-- Status definitions
local DEAD_TECHNICAL    = "DEAD_TECHNICAL"
local DEAD_ONE_MINUTE   = "DEAD_ONE_MINUTE"
local DEAD_ONE_TIME     = "DEAD_ONE_TIME"
local DEAD_COMBAT_BLOCK = "DEAD_COMBAT_BLOCK"
local GENTLE_REPOSE     = "GENTLE_REPOSE"
local S5E_PASSIVE       = "S5E_NoInstantDeath"
local FINAL_DEATH_BLOCK = "DD_DEATH_BLOCKS_RAISE_DEAD_4"
local HIDDEN_DEATH_BLOCK = "DD_DEATH_BLOCKS_RAISE_DEAD_Hidden"


-- Table of corpses whose recent death timers are being tracked in turn-based rounds.
-- Keyed by uuid -> { rounds = <roundsLeft>, char = <character reference> }. When a
-- character dies during turn-based combat or forced turn mode, their UUID is added
-- here with the number of rounds remaining (initially 10) and the character reference
-- needed to call Osi functions on them directly (avoiding a DB_Dead lookup later).
local PendingExpireTB = {}

-- Table of corpses currently counting down in real time (DEAD_TECHNICAL applied with a
-- timed duration) that have not yet been converted to turn-based tracking. Keyed by
-- uuid -> character reference. Outside of turn-based, the engine's own real-time
-- countdown handles the status expiry; we only need this table so CombatRoundStarted
-- and TurnStarted can find these corpses without scanning the whole dead database.
local PendingExpireRT = {}

-- Helper: return true if the supplied object appears to be a valid character UUID.
-- Defined here so it can be referenced by IsCharacterInCombat below.
local function IsValidChar(ch)
    return ch ~= nil
        and ch ~= ""
        and ch ~= "NULL_00000000-0000-0000-0000-000000000000"
        and Osi.IsCharacter(ch) == 1
end

-- Helper: attempt to extract a stable UUID string from an object. Falls back to
-- Osi.GetUUID if needed. Returns nil if no UUID can be determined.
local function GetUUIDSafe(obj)
    if not obj then return nil end
    local s = tostring(obj)
    local u = s:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
    if u and u ~= "" then return u end
    local ok, v = pcall(function() return Osi.GetUUID(obj) end)
    if ok and v and v ~= "" then return v end
    return nil
end

-- Flags to track whether we are currently in force turn-based mode or in a combat
local IsForceTB = false
local ActiveCombatCount = 0

-- Helper: return true if the given character is currently in a combat
local function IsCharacterInCombat(ch)
    if not IsValidChar(ch) then return false end
    local combatGuid = Osi.CombatGetGuidFor(ch)
    return combatGuid ~= nil and combatGuid ~= "" and combatGuid ~= "NULL_00000000-0000-0000-0000-000000000000"
end

-- Helper: safely add the passive that prevents the engine from stripping our statuses.
local function SafeAddPassive(ch)
    pcall(function()
        if Osi.HasPassive(ch, S5E_PASSIVE) == 0 then
            Osi.AddPassive(ch, S5E_PASSIVE)
        end
    end)
end

-- Helper: safely remove the passive when it is no longer needed.
local function SafeRemovePassive(ch)
    pcall(function()
        if Osi.HasPassive(ch, S5E_PASSIVE) == 1 then
            Osi.RemovePassive(ch, S5E_PASSIVE)
        end
    end)
end

local function SafeHasStatus(ch, status)
    local ok, result = pcall(function()
        return Osi.HasActiveStatus(ch, status)
    end)
    return ok and result == 1
end

local function HasTerminalDeathBlock(ch)
    return SafeHasStatus(ch, FINAL_DEATH_BLOCK) or SafeHasStatus(ch, HIDDEN_DEATH_BLOCK)
end

local function CleanupRecentDeath(ch)
    if not IsValidChar(ch) then return end

    pcall(Osi.RemoveStatus, ch, DEAD_ONE_MINUTE)
    pcall(Osi.RemoveStatus, ch, DEAD_TECHNICAL)
    pcall(Osi.RemoveStatus, ch, DEAD_COMBAT_BLOCK)
    SafeRemovePassive(ch)

    local uuid = GetUUIDSafe(ch)
    if uuid then
        PendingExpireTB[uuid] = nil
        PendingExpireRT[uuid] = nil
    end
end


-- EnteredCombat: apply the combat block to all dead characters with the recent death status.
-- This only runs once per combat entry (not per round/turn), so a DB_Dead scan here is fine.
Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function (character, combatguid)
    local dead = Osi.DB_Dead:Get(nil)
    for _, d in pairs(dead) do
        local ch = d[1]
        if IsValidChar(ch) and HasTerminalDeathBlock(ch) then
            CleanupRecentDeath(ch)
        elseif IsValidChar(ch) and Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
            -- Prevent corpses from rejoining combat
            Osi.ApplyStatus(ch, DEAD_COMBAT_BLOCK, -1.0, 1)
        end
    end
end)

-- CombatStarted: increment the active combat counter
Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(combatguid)
    ActiveCombatCount = ActiveCombatCount + 1
    DPrint(string.format("CombatStarted: combat=%s ActiveCombatCount=%d", tostring(combatguid), ActiveCombatCount))
end)

-- CombatEnded: remove the combat block from all corpses when combat ends, and convert any
-- turn-based recent-death timers back into real-time timers.
Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function (combatguid)
    -- Decrement the combat counter
    if ActiveCombatCount > 0 then
        ActiveCombatCount = ActiveCombatCount - 1
    end
    -- If no more combats and force TB is not active, convert tracked turn-based timers to real-time.
    -- We already know exactly which corpses these are (and hold their character reference), so this
    -- no longer needs to scan DB_Dead to find them.
    if ActiveCombatCount == 0 and not IsForceTB then
        for uuid, info in pairs(PendingExpireTB) do
            PendingExpireTB[uuid] = nil
            local ch = info.char
            if IsValidChar(ch) then
                if HasTerminalDeathBlock(ch) then
                    CleanupRecentDeath(ch)
                else
                    -- Remove the indefinite status
                    if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
                        Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    end
                    -- Apply a timed status for the remaining rounds (6 seconds per round)
                    local seconds = math.max((info.rounds or 10) * 6.0, 1.0)
                    Osi.ApplyStatus(ch, DEAD_TECHNICAL, seconds, 1)
                    PendingExpireRT[uuid] = ch
                    DPrint(string.format("RecentDeath: converted TB -> RT with %.0f s on %s", seconds, tostring(ch)))
                end
            end
        end
    end
    -- Always remove combat block status from all corpses when combat ends. This fires once per
    -- combat end (not per round/turn), so scanning DB_Dead here is acceptable.
    local dead = Osi.DB_Dead:Get(nil)
    for _, d in pairs(dead) do
        local ch = d[1]
        if IsValidChar(ch) then
            Osi.RemoveStatus(ch, DEAD_COMBAT_BLOCK)
        end
    end
end)

-- EnteredForceTurnBased: set the force TB flag
Ext.Osiris.RegisterListener("EnteredForceTurnBased", 1, "after", function (_)
    IsForceTB = true
end)

-- LeftForceTurnBased: clear the force TB flag and convert any tracked TB timers to real-time if no combats remain
Ext.Osiris.RegisterListener("LeftForceTurnBased", 1, "after", function (_)
    IsForceTB = false
    if ActiveCombatCount == 0 then
        for uuid, info in pairs(PendingExpireTB) do
            PendingExpireTB[uuid] = nil
            local ch = info.char
            if IsValidChar(ch) then
                if HasTerminalDeathBlock(ch) then
                    CleanupRecentDeath(ch)
                else
                    if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
                        Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    end
                    local seconds = math.max((info.rounds or 10) * 6.0, 1.0)
                    Osi.ApplyStatus(ch, DEAD_TECHNICAL, seconds, 1)
                    PendingExpireRT[uuid] = ch
                    DPrint(string.format("RecentDeath: converted TB -> RT with %.0f s on %s (force TB off)", seconds, tostring(ch)))
                end
            end
        end
    end
end)

-- Died: when any character dies, apply the recent death status.
Ext.Osiris.RegisterListener("Died", 1, "after", function (character)
    if not IsValidChar(character) then return end
    -- If the corpse is already long dead or under gentle repose, skip.
    if Osi.HasActiveStatus(character, DEAD_ONE_TIME) == 1 then return end
    if Osi.HasActiveStatus(character, GENTLE_REPOSE) == 1 then return end
    if HasTerminalDeathBlock(character) then
        CleanupRecentDeath(character)
        return
    end

    -- Check whether the character died during turn-based combat or forced turn mode.
    local inCombat = IsCharacterInCombat(character)
    local useTurnBased = inCombat or IsForceTB or (ActiveCombatCount > 0)

    -- Always apply the passive to prevent the engine removing our custom status
    SafeAddPassive(character)

    local uuid = GetUUIDSafe(character)
    DPrint(string.format("Died: inCombat=%s IsForceTB=%s ActiveCombatCount=%d useTurnBased=%s", tostring(inCombat), tostring(IsForceTB), ActiveCombatCount or -1, tostring(useTurnBased)))
    if useTurnBased then
        -- In turn-based contexts, apply an indefinite status and track rounds manually
        Osi.ApplyStatus(character, DEAD_TECHNICAL, 60.0, 1)
        -- Also apply the combat block immediately to prevent corpses being pulled back into combat
        Osi.ApplyStatus(character, DEAD_COMBAT_BLOCK, -1.0, 1)
        -- Initialize or reset the round counter (10 rounds), and remember the character
        -- reference alongside it so later handlers never need to re-derive it from DB_Dead.
        if uuid then
            PendingExpireTB[uuid] = { rounds = 10, char = character }
            PendingExpireRT[uuid] = nil
        end
        DPrint(string.format("RecentDeath(TB): applied %s(-1) and started 10-round countdown on %s", DEAD_TECHNICAL, tostring(character)))
    else
        -- Outside of turn-based, apply a timed status for 60 seconds
        Osi.ApplyStatus(character, DEAD_TECHNICAL, 60.0, 1)
        if uuid then
            PendingExpireRT[uuid] = character
            PendingExpireTB[uuid] = nil
        end
        DPrint(string.format("RecentDeath(RT): applied %s(60s) on %s", DEAD_TECHNICAL, tostring(character)))
    end
end)

-- CombatRoundStarted: reduce remaining turns on recent death for all tracked corpses.
--
-- This used to call Osi.DB_Dead:Get(nil) and loop over every dead character currently
-- known to the story database, once per round, for every active combat. That scan grows
-- with how many corpses are lying around in the loaded area and runs very frequently, so
-- it was the single biggest per-round cost in this file (and, because Osiris listeners
-- run synchronously, a source of frame-time delay for every other mod hooked to the same
-- event). We only ever care about corpses we ourselves are counting down, which is what
-- PendingExpireTB / PendingExpireRT already track, so we iterate those instead.
Ext.Osiris.RegisterListener("CombatRoundStarted", 2, "after", function (combatguid, round)
    -- Case 1: corpses whose recent-death timer is tracked in combat rounds.
    for uuid, info in pairs(PendingExpireTB) do
        local ch = info.char
        if not IsValidChar(ch) then
            PendingExpireTB[uuid] = nil
        elseif Osi.HasActiveStatus(ch, GENTLE_REPOSE) == 1 then
            -- leave gentle-repose'd corpses alone
        elseif HasTerminalDeathBlock(ch) then
            CleanupRecentDeath(ch)
        else
            -- Ensure they stay out of combat
            Osi.ApplyStatus(ch, DEAD_COMBAT_BLOCK, -1.0, 1)
            -- Refresh the passive to prevent engine cleanup
            SafeAddPassive(ch)
            -- Always remove the long-dead state during countdown
            if Osi.HasActiveStatus(ch, DEAD_ONE_TIME) == 1 then
                Osi.RemoveStatus(ch, DEAD_ONE_TIME)
            end
            -- Decrement the remaining rounds
            info.rounds = (info.rounds or 10) - 1
            if info.rounds <= 0 then
                -- Countdown finished: remove the technical status and mark the corpse as long dead
                if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
                    Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                end
                Osi.ApplyStatus(ch, DEAD_ONE_TIME, -1.0, 1)
                Osi.RemoveStatus(ch, DEAD_COMBAT_BLOCK)
                SafeRemovePassive(ch)
                PendingExpireTB[uuid] = nil
                DPrint(string.format("RecentDeath(TB): expired -> %s applied on %s", DEAD_ONE_TIME, tostring(ch)))
            end
        end
    end

    -- Case 2: corpses still using a real-time recent-death status (e.g. they died before
    -- this combat started and haven't been converted to turn-based tracking yet by
    -- TurnStarted). Handled like 5eSpells: decrement the status's remaining turns.
    for uuid, ch in pairs(PendingExpireRT) do
        if not IsValidChar(ch) then
            PendingExpireRT[uuid] = nil
        elseif Osi.HasActiveStatus(ch, GENTLE_REPOSE) == 1 then
            -- leave gentle-repose'd corpses alone
        elseif HasTerminalDeathBlock(ch) then
            CleanupRecentDeath(ch)
        elseif Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
            -- Ensure the corpse cannot be dragged back into combat
            Osi.ApplyStatus(ch, DEAD_COMBAT_BLOCK, -1.0, 1)
            -- Refresh the passive to ensure the engine does not strip our status
            SafeAddPassive(ch)
            -- Query current turn count and decrement
            local turns = Osi.GetStatusTurns(ch, DEAD_TECHNICAL)
            if turns ~= nil then
                local newTurns = turns - 1.0
                if newTurns > 0.0 then
                    -- Remove the old status and reapply with updated duration in seconds
                    Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    Osi.ApplyStatus(ch, DEAD_TECHNICAL, newTurns * 6.0, 1)
                else
                    -- Countdown finished: transition to the long‑dead state
                    Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    Osi.ApplyStatus(ch, DEAD_ONE_TIME, -1.0, 1)
                    -- Also remove the combat block, since the corpse is now long dead
                    Osi.RemoveStatus(ch, DEAD_COMBAT_BLOCK)
                    -- Remove the passive so the game can behave normally
                    SafeRemovePassive(ch)
                    PendingExpireRT[uuid] = nil
                    DPrint(string.format("RecentDeath: expired -> %s applied on %s", DEAD_ONE_TIME, tostring(ch)))
                end
            end
        else
            -- Status is gone for some other reason (cleared externally); stop tracking.
            PendingExpireRT[uuid] = nil
        end
    end
end)

-- TurnStarted: when any combatant's turn begins, convert any real-time recent death timers
-- into turn-based timers if a combat or forced turn-based mode is active. This ensures that
-- corpses killed in combat switch from counting down in seconds to counting down in rounds
-- as soon as the next turn starts, rather than waiting until the next combat round.
--
-- Previously this scanned Osi.DB_Dead:Get(nil) on every single combatant's turn (the most
-- frequent event this file listens to) to find candidates. We now iterate PendingExpireRT
-- directly, since that table already holds exactly the corpses that could need converting.
Ext.Osiris.RegisterListener("TurnStarted", 2, "after", function (char)
    if ActiveCombatCount > 0 or IsForceTB then
        for uuid, ch in pairs(PendingExpireRT) do
            if not IsValidChar(ch) or Osi.IsDead(ch) ~= 1 then
                PendingExpireRT[uuid] = nil
            elseif Osi.HasActiveStatus(ch, GENTLE_REPOSE) == 1 then
                -- leave gentle-repose'd corpses alone; do not convert
            elseif Osi.HasActiveStatus(ch, DEAD_TECHNICAL) ~= 1 then
                -- Status is gone (cleared externally, e.g. resurrection); stop tracking.
                PendingExpireRT[uuid] = nil
            elseif HasTerminalDeathBlock(ch) then
                CleanupRecentDeath(ch)
            else
                -- Convert only if the status currently has a finite number of turns.
                local currentTurns = Osi.GetStatusTurns(ch, DEAD_TECHNICAL)
                -- currentTurns may be nil if the status is already indefinite (-1)
                if currentTurns ~= nil and currentTurns > 0.0 then
                    -- Remove the existing timed status
                    Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    -- Apply an indefinite status so it does not tick in real time
                    Osi.ApplyStatus(ch, DEAD_TECHNICAL, 60.0, 1)
                    -- Ensure the corpse cannot rejoin combat
                    Osi.ApplyStatus(ch, DEAD_COMBAT_BLOCK, -1.0, 1)
                    -- Reapply the passive to prevent engine cleanup
                    SafeAddPassive(ch)
                    -- Initialise the round countdown to 10 rounds, now tracked with the
                    -- character reference so future handlers don't need to look it up again.
                    PendingExpireTB[uuid] = { rounds = 10, char = ch }
                    PendingExpireRT[uuid] = nil
                    DPrint(string.format("RecentDeath(Turn): converted RT -> TB (10 rounds) on %s", tostring(ch)))
                end
            end
        end
    end
end)

-- Resurrected: clean up statuses and passive when a character is revived.
Ext.Osiris.RegisterListener("Resurrected", 1, "after", function (character)
    if not IsValidChar(character) then return end
    -- Remove all death-related statuses
    Osi.RemoveStatus(character, DEAD_TECHNICAL)
    Osi.RemoveStatus(character, DEAD_ONE_MINUTE)
    Osi.RemoveStatus(character, DEAD_ONE_TIME)
    Osi.RemoveStatus(character, DEAD_COMBAT_BLOCK)
    -- Remove the passive
    SafeRemovePassive(character)
    -- Clear any pending tracking
    local uuid = GetUUIDSafe(character)
    if uuid then
        PendingExpireTB[uuid] = nil
        PendingExpireRT[uuid] = nil
    end
    DPrint(string.format("RecentDeath: cleanup on resurrection of %s", tostring(character)))
end)

Ext.Utils.Print(MOD_PREFIX .. " DD_RecentDeath_All.lua LOADED (server)")
