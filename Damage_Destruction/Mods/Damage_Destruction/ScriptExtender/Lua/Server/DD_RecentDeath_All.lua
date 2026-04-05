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

    Author: DD overhaul
]]

local MOD_PREFIX = "[DD]"

-- Status definitions
local DEAD_TECHNICAL    = "DEAD_TECHNICAL"
local DEAD_ONE_TIME     = "DEAD_ONE_TIME"
local DEAD_COMBAT_BLOCK = "DEAD_COMBAT_BLOCK"
local GENTLE_REPOSE     = "GENTLE_REPOSE"
local S5E_PASSIVE       = "S5E_NoInstantDeath"


-- Table of corpses whose recent death timers are being tracked in turn-based rounds
-- When a character dies during turn-based combat or forced turn mode, their UUID is added
-- here with the number of rounds remaining (initially 10). Outside of turn-based, the
-- engine's real-time countdown handles the duration, so we don't store them here.
local PendingExpireTB = {}

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


-- EnteredCombat: apply the combat block to all dead characters with the recent death status.
Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function (character, combatguid)
    local dead = Osi.DB_Dead:Get(nil)
    for _, d in pairs(dead) do
        local ch = d[1]
        if IsValidChar(ch) and Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
            -- Prevent corpses from rejoining combat
            Osi.ApplyStatus(ch, DEAD_COMBAT_BLOCK, -1.0, 1)
        end
    end
end)

-- CombatStarted: increment the active combat counter
Ext.Osiris.RegisterListener("CombatStarted", 1, "after", function(combatguid)
    ActiveCombatCount = ActiveCombatCount + 1
    Ext.Utils.Print(string.format("%s CombatStarted: combat=%s ActiveCombatCount=%d", MOD_PREFIX, tostring(combatguid), ActiveCombatCount))
end)

-- CombatEnded: remove the combat block from all corpses when combat ends.
Ext.Osiris.RegisterListener("CombatEnded", 1, "after", function (combatguid)
    -- Decrement the combat counter
    if ActiveCombatCount > 0 then
        ActiveCombatCount = ActiveCombatCount - 1
    end
    -- If no more combats and force TB is not active, convert tracked turn-based timers to real-time
    if ActiveCombatCount == 0 and not IsForceTB then
        for uuid, roundsLeft in pairs(PendingExpireTB) do
            local entryRounds = roundsLeft
            -- remove from tracking before conversion to avoid re-entry into this loop
            PendingExpireTB[uuid] = nil
            -- find the character from DB_Dead
            local dead = Osi.DB_Dead:Get(nil)
            for _, d in pairs(dead) do
                local ch = d[1]
                if IsValidChar(ch) and GetUUIDSafe(ch) == uuid then
                    -- Remove the indefinite status
                    if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
                        Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    end
                    -- Apply a timed status for the remaining rounds (6 seconds per round)
                    local seconds = math.max(entryRounds * 6.0, 1.0)
                    Osi.ApplyStatus(ch, DEAD_TECHNICAL, seconds, 1)
                    Ext.Utils.Print(string.format("%s RecentDeath: converted TB -> RT with %.0f s on %s", MOD_PREFIX, seconds, tostring(ch)))
                    break
                end
            end
        end
    end
    -- Always remove combat block status from all corpses when combat ends
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
        for uuid, roundsLeft in pairs(PendingExpireTB) do
            PendingExpireTB[uuid] = nil
            local dead = Osi.DB_Dead:Get(nil)
            for _, d in pairs(dead) do
                local ch = d[1]
                if IsValidChar(ch) and GetUUIDSafe(ch) == uuid then
                    if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
                        Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                    end
                    local seconds = math.max(roundsLeft * 6.0, 1.0)
                    Osi.ApplyStatus(ch, DEAD_TECHNICAL, seconds, 1)
                    Ext.Utils.Print(string.format("%s RecentDeath: converted TB -> RT with %.0f s on %s (force TB off)", MOD_PREFIX, seconds, tostring(ch)))
                    break
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

    -- Check whether the character died during turn-based combat or forced turn mode.
    local inCombat = IsCharacterInCombat(character)
    local useTurnBased = inCombat or IsForceTB or (ActiveCombatCount > 0)

    -- Always apply the passive to prevent the engine removing our custom status
    SafeAddPassive(character)

    local uuid = GetUUIDSafe(character)
    Ext.Utils.Print(string.format("%s Died: inCombat=%s IsForceTB=%s ActiveCombatCount=%d useTurnBased=%s", MOD_PREFIX, tostring(inCombat), tostring(IsForceTB), ActiveCombatCount or -1, tostring(useTurnBased)))
    if useTurnBased then
        -- In turn-based contexts, apply an indefinite status and track rounds manually
        Osi.ApplyStatus(character, DEAD_TECHNICAL, 60.0, 1)
        -- Also apply the combat block immediately to prevent corpses being pulled back into combat
        Osi.ApplyStatus(character, DEAD_COMBAT_BLOCK, -1.0, 1)
        -- Initialize or reset the round counter (10 rounds)
        if uuid then
            PendingExpireTB[uuid] = 10
        end
        Ext.Utils.Print(string.format("%s RecentDeath(TB): applied %s(-1) and started 10-round countdown on %s", MOD_PREFIX, DEAD_TECHNICAL, tostring(character)))
    else
        -- Outside of turn-based, apply a timed status for 60 seconds
        Osi.ApplyStatus(character, DEAD_TECHNICAL, 60.0, 1)
        Ext.Utils.Print(string.format("%s RecentDeath(RT): applied %s(60s) on %s", MOD_PREFIX, DEAD_TECHNICAL, tostring(character)))
    end
end)

-- CombatRoundStarted: reduce remaining turns on recent death for all corpses.
Ext.Osiris.RegisterListener("CombatRoundStarted", 2, "after", function (combatguid, round)
    local dead = Osi.DB_Dead:Get(nil)
    for _, d in pairs(dead) do
        local ch = d[1]
        if not IsValidChar(ch) then
            goto continue
        end
        if Osi.HasActiveStatus(ch, GENTLE_REPOSE) == 1 then
            goto continue
        end
        -- Compute UUID once
        local uuid = GetUUIDSafe(ch)
        -- Case 1: this corpse's timer is tracked in rounds (died during turn-based)
        if uuid and PendingExpireTB[uuid] then
            -- Ensure they stay out of combat
            Osi.ApplyStatus(ch, DEAD_COMBAT_BLOCK, -1.0, 1)
            -- Refresh the passive to prevent engine cleanup
            SafeAddPassive(ch)
            -- Always remove the long-dead state during countdown
            if Osi.HasActiveStatus(ch, DEAD_ONE_TIME) == 1 then
                Osi.RemoveStatus(ch, DEAD_ONE_TIME)
            end
            -- Decrement the remaining rounds
            PendingExpireTB[uuid] = PendingExpireTB[uuid] - 1
            local roundsLeft = PendingExpireTB[uuid]
            if roundsLeft <= 0 then
                -- Countdown finished: remove the technical status and mark the corpse as long dead
                if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
                    Osi.RemoveStatus(ch, DEAD_TECHNICAL)
                end
                Osi.ApplyStatus(ch, DEAD_ONE_TIME, -1.0, 1)
                Osi.RemoveStatus(ch, DEAD_COMBAT_BLOCK)
                SafeRemovePassive(ch)
                PendingExpireTB[uuid] = nil
                Ext.Utils.Print(string.format("%s RecentDeath(TB): expired -> %s applied on %s", MOD_PREFIX, DEAD_ONE_TIME, tostring(ch)))
            end
        else
            -- Case 2: corpse is using real-time status; handle like 5eSpells
            if Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1 then
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
                        Ext.Utils.Print(string.format("%s RecentDeath: expired -> %s applied on %s", MOD_PREFIX, DEAD_ONE_TIME, tostring(ch)))
                    end
                end
            end
        end
        ::continue::
    end
end)

-- TurnStarted: when any combatant's turn begins, convert any real-time recent death timers
-- into turn-based timers if a combat or forced turn-based mode is active. This ensures that
-- corpses killed in combat switch from counting down in seconds to counting down in rounds
-- as soon as the next turn starts, rather than waiting until the next combat round. The
-- conversion is only performed once per corpse: if the corpse is already being tracked
-- in PendingExpireTB, it is skipped. Outside of combat or force TB, no conversion is
-- performed, so real-time timers continue to tick normally.
Ext.Osiris.RegisterListener("TurnStarted", 2, "after", function (char)
    Ext.Utils.Print(string.format("%s TurnStarted: char=%s ActiveCombatCount=%d IsForceTB=%s", MOD_PREFIX, tostring(char), ActiveCombatCount or -1, tostring(IsForceTB)))
    -- Only perform conversions if a combat is active or force TB is engaged
    if ActiveCombatCount > 0 or IsForceTB then
        local dead = Osi.DB_Dead:Get(nil)
        for _, d in pairs(dead) do
            local ch = d[1]
            if IsValidChar(ch)
                and Osi.IsDead(ch) == 1
                and Osi.HasActiveStatus(ch, GENTLE_REPOSE) == 0
                and Osi.HasActiveStatus(ch, DEAD_TECHNICAL) == 1
            then
                local uuid = GetUUIDSafe(ch)
                -- If not already tracked in turn-based, convert the real-time timer
                if uuid and not PendingExpireTB[uuid] then
                    -- Convert only if the status currently has a finite number of turns
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
                        -- Initialise the round countdown to 10 rounds
                        PendingExpireTB[uuid] = 10
                        Ext.Utils.Print(string.format("%s RecentDeath(Turn): converted RT -> TB (10 rounds) on %s", MOD_PREFIX, tostring(ch)))
                    end
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
    Osi.RemoveStatus(character, DEAD_ONE_TIME)
    Osi.RemoveStatus(character, DEAD_COMBAT_BLOCK)
    -- Remove the passive
    SafeRemovePassive(character)
    -- Clear any pending turn-based tracking
    local uuid = GetUUIDSafe(character)
    Ext.Utils.Print(string.format("%s Died: inCombat=%s IsForceTB=%s ActiveCombatCount=%d useTurnBased=%s", MOD_PREFIX, tostring(inCombat), tostring(IsForceTB), ActiveCombatCount or -1, tostring(useTurnBased)))
    if uuid then
        PendingExpireTB[uuid] = nil
    end
    Ext.Utils.Print(string.format("%s RecentDeath: cleanup on resurrection of %s", MOD_PREFIX, tostring(character)))
end)

Ext.Utils.Print(MOD_PREFIX .. " DD_RecentDeath_All.lua LOADED (server)")