-- DD_DeadPartyMembers.lua
--
-- Server-side support for the "Dead Party Members" MCM tab. Damage_Destruction
-- only (not used by Raise The Dead).
--
-- Damage Destruction's permadeath statuses can leave a party member dead and
-- un-resurrectable until the player has the right spell/scroll and enough
-- gold, or until Withers has appeared in camp - which takes time and can
-- block resting/progression in the meantime. This gives the player a manual
-- way to resolve a dead party member early, replicating exactly what talking
-- to Withers would do:
--
--   * "Send to Camp"        - reuses Withers' own dismiss behaviour
--                              (PROC_GLO_Jergal_DismissCharacter, straight
--                              from the game's own GLO_Jergal.txt story
--                              goal - Withers is internally
--                              S_GLO_JergalAvatar). This teleports the body
--                              to the character's camp spot. Origin
--                              companions and hirelings only - see below.
--   * "Leave Body, Remove"  - drops them from the party on the spot, leaving
--                              the corpse exactly where it died
--                              (PROC_GLO_PartyMembers_Remove).
--
-- Both proc names are called directly via Osi.<Name>(...), which can invoke
-- any loaded Osiris symbol by name - the same approach already used
-- elsewhere in this mod's RTD_Improved.lua fixes to reuse the game's own
-- per-NPC restoration logic instead of reimplementing it.
--
-- Custom player characters ("Avatars" internally - this includes Tav/Durge)
-- are handled as a special case: BOTH buttons just remove them from the
-- party on the spot, identically to "Leave Body, Remove". They never get
-- routed through PROC_GLO_Jergal_DismissCharacter's teleport-to-camp path.
-- This is deliberate, not a shortcut: vanilla Avatars have no fixed camp
-- spot to teleport to in the first place (Withers' own dismiss script just
-- removes them too, nothing more), and the dedicated "Toggle Avatar On
-- Party Members" mod's own author explicitly found that trying to turn a
-- dead Tav into a working "companion" state causes real bugs (becoming
-- non-dismissable, dialogue issues) and deliberately left Tav/Durge
-- unsupported for exactly that reason. We're not attempting anything
-- beyond a plain party removal for this case.

local MOD_PREFIX = "[Damage Destruction]"

local REQ_CHANNEL   = ModuleUUID .. "_DeadPartyMembers_Request"
local LIST_CHANNEL  = ModuleUUID .. "_DeadPartyMembers_List"
local CAMP_CHANNEL  = ModuleUUID .. "_DeadPartyMembers_SendToCamp"
local LEAVE_CHANNEL = ModuleUUID .. "_DeadPartyMembers_LeaveBody"

local NULL_UUID = "NULL_00000000-0000-0000-0000-000000000000"

local function ReadDisplayNameComponent(entity)
    if not entity or not entity.DisplayName or not entity.DisplayName.Name then
        return nil
    end
    local name = entity.DisplayName.Name
    if type(name) == "string" and name ~= "" then
        return name
    end
    if type(name) == "userdata" or type(name) == "table" then
        local ok, value = pcall(function() return name:Get() end)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function GetCharacterName(guid)
    if not guid or guid == "" or guid == NULL_UUID then
        return "Unknown character"
    end
    if Ext and Ext.Entity and type(Ext.Entity.Get) == "function" then
        local ok, entity = pcall(Ext.Entity.Get, guid)
        if ok and entity then
            local name = ReadDisplayNameComponent(entity)
            if name then return name end
        end
    end
    return guid
end

-- Every character currently in the active party, dead or alive.
--
-- DB_Players IS the active party (camp companions and summons aren't in it),
-- so it's used directly. The previous version also filtered each row through
-- Osi.IsPartyMember(char), but that query takes TWO inputs in BG3
-- (IsPartyMember(_Char, includeSummons, result) - see GLO_Spells.txt /
-- GLO_Checkpoints.txt). Called with one argument it errors, the pcall hid
-- the error, and every character was treated as "not in party" - so the list
-- was always empty.
local function GetPartyMembers()
    local members = {}
    local ok, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if not ok or type(rows) ~= "table" then
        print(MOD_PREFIX .. " Dead Party Members: could not read DB_Players")
        return members
    end
    for _, row in pairs(rows) do
        local char = type(row) == "table" and row[1] or nil
        if char then
            table.insert(members, char)
        end
    end
    return members
end

local function IsCharacterDead(char)
    local dead = false
    pcall(function() dead = (Osi.IsDead(char) == 1) end)
    if dead then return true end
    -- Fallback: the game's own story-side record of death.
    pcall(function()
        local rows = Osi.DB_Dead:Get(char)
        dead = (type(rows) == "table" and #rows > 0)
    end)
    return dead
end

-- Dead party members only, as a list of {UUID=..., Name=...} entries.
local function GetDeadPartyMembers()
    local dead = {}
    for _, char in ipairs(GetPartyMembers()) do
        if IsCharacterDead(char) then
            table.insert(dead, { UUID = char, Name = GetCharacterName(char) })
        end
    end
    table.sort(dead, function(a, b) return (a.Name or "") < (b.Name or "") end)
    return dead
end

local function SendDeadListTo(user)
    local list = GetDeadPartyMembers()
    local ok, json = pcall(Ext.Json.Stringify, list)
    if not ok then json = "[]" end
    print(MOD_PREFIX .. " Dead Party Members: found " .. tostring(#list) .. " dead party member(s)")
    -- Try the current SE API first, then the legacy one, then a broadcast,
    -- so a single renamed function can't silently drop the reply.
    if user then
        if pcall(function() Ext.Net.PostMessageToUser(user, LIST_CHANNEL, json) end) then return end
        if pcall(function() Ext.ServerNet.PostMessageToUser(user, LIST_CHANNEL, json) end) then return end
    end
    if pcall(function() Ext.Net.BroadcastMessage(LIST_CHANNEL, json) end) then return end
    print(MOD_PREFIX .. " Dead Party Members: could not send the list to the client")
end

Ext.RegisterNetListener(REQ_CHANNEL, function(_, _, user)
    SendDeadListTo(user)
end)

------------------------------------------------------------
-- Auto re-join on revival.
--
-- Anyone removed from the party through this tab is remembered (saved with
-- the game in PersistentVars). When that character is resurrected - by any
-- means - they're put straight back into the party through the game's own
-- recruitment routine, PROC_GLO_PartyMembers_Add (_GLO_Shared_PartyMembers.txt).
-- That routine itself has no party-size check; the vanilla limit lives only in
-- PROC_GLO_PartyMembers_CheckAdd, which we deliberately skip, so this works
-- regardless of the party limit (Configurable Party Limit or not).
-- Without this, a revived companion is left as a stray NPC whose only
-- interaction is the "not right now" party-member bark.
------------------------------------------------------------
PersistentVars = PersistentVars or {}

local function RemovedSet()
    PersistentVars.DD_RemovedWhileDead = PersistentVars.DD_RemovedWhileDead or {}
    return PersistentVars.DD_RemovedWhileDead
end

local function MarkRemoved(char)
    RemovedSet()[char] = true
end

local function InParty(char)
    local found = false
    pcall(function()
        local rows = Osi.DB_Players:Get(char)
        found = (type(rows) == "table" and #rows > 0)
    end)
    return found
end

local function RejoinParty(char, attempt)
    attempt = attempt or 1
    if InParty(char) then
        RemovedSet()[char] = nil
        return
    end
    local host = nil
    pcall(function() host = Osi.GetHostCharacter() end)
    if not host then return end

    local ok, err = pcall(function() Osi.PROC_GLO_PartyMembers_Add(char, host) end)
    if not ok then
        print(MOD_PREFIX .. " Dead Party Members: re-adding " .. tostring(char) .. " failed - " .. tostring(err))
    end

    Ext.Timer.WaitFor(1000, function()
        if InParty(char) then
            RemovedSet()[char] = nil
            -- Bring them to the party if they were revived far away (e.g. in camp).
            local dist = 0
            pcall(function() dist = Osi.GetDistanceTo(char, host) or 0 end)
            if dist > 40 then
                pcall(function() Osi.TeleportTo(char, host, "", 1, 1, 1) end)
            end
            print(MOD_PREFIX .. " Dead Party Members: " .. GetCharacterName(char) .. " rejoined the party after being revived")
            SendDeadListTo(nil)
        elseif attempt < 3 then
            RejoinParty(char, attempt + 1)
        else
            print(MOD_PREFIX .. " Dead Party Members: could not re-add " .. GetCharacterName(char) .. " to the party")
        end
    end)
end

Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(char)
    if RemovedSet()[char] then
        -- Let resurrection cleanup (RTD_Improved, stale-downed fix) settle first.
        Ext.Timer.WaitFor(1500, function() RejoinParty(char, 1) end)
    end
end)

-- Shared helper: remove a dead character from the party on the spot,
-- leaving the body exactly where it is. Used directly by LEAVE_CHANNEL for
-- everyone, and by CAMP_CHANNEL as well when the target is a custom player
-- Avatar (see file header - both buttons converge to this for Avatars).
local function RemoveFromPartyInPlace(char)
    local isAvatar = false
    pcall(function()
        local rows = Osi.DB_Avatars:Get(char)
        isAvatar = (type(rows) == "table" and #rows > 0)
    end)

    local ok, err
    if isAvatar then
        -- Confirmed call shape from GLO_Jergal.txt's own Avatar dismiss
        -- branch: PROC_GLO_PartyMembers_Remove(_Char,_Dismisser,0).
        local dismisser = nil
        pcall(function() dismisser = Osi.GetHostCharacter() end)
        ok, err = pcall(function() Osi.PROC_GLO_PartyMembers_Remove(char, dismisser, 0) end)
    else
        -- Confirmed call shape used generically for origin companions
        -- elsewhere in the game's own scripts (e.g. Lae'zel's scripted
        -- removal): PROC_GLO_PartyMembers_Remove(character, 1).
        ok, err = pcall(function() Osi.PROC_GLO_PartyMembers_Remove(char, 1) end)
    end
    if not ok then
        print(MOD_PREFIX .. " Dead Party Members: failed to remove " .. tostring(char) .. " from party - " .. tostring(err))
    end

    return isAvatar
end

-- "Send to Camp": replicates Withers' own dismiss behaviour for origin
-- companions/hirelings. For a custom player Avatar (Tav/Durge), this
-- converges to the same plain party removal as "Leave Body, Remove" - see
-- file header for why.
Ext.RegisterNetListener(CAMP_CHANNEL, function(_, payload, _)
    local char = payload
    if type(char) ~= "string" or char == "" then return end

    local isAvatar = false
    pcall(function()
        local rows = Osi.DB_Avatars:Get(char)
        isAvatar = (type(rows) == "table" and #rows > 0)
    end)

    MarkRemoved(char)

    if isAvatar then
        RemoveFromPartyInPlace(char)
        SendDeadListTo(nil)
        return
    end

    local ok, err = pcall(function() Osi.PROC_GLO_Jergal_DismissCharacter(char) end)
    if not ok then
        print(MOD_PREFIX .. " Dead Party Members: failed to send " .. tostring(char) .. " to camp - " .. tostring(err))
    end

    SendDeadListTo(nil)
end)

-- "Leave Body, Remove": drop them from the party where they lie.
Ext.RegisterNetListener(LEAVE_CHANNEL, function(_, payload, _)
    local char = payload
    if type(char) ~= "string" or char == "" then return end

    MarkRemoved(char)
    RemoveFromPartyInPlace(char)

    SendDeadListTo(nil)
end)

Ext.Events.SessionLoaded:Subscribe(function()
    SendDeadListTo(nil)
end)
