-- DD_AvatarSwitch.lua
--
-- Server-side support for the "Avatar Switching" MCM tab. Damage_Destruction
-- only (not used by Raise The Dead).
--
-- Only relevant when the custom player character (Tav/Durge - internally
-- an "Avatar", tagged with the AVATAR_306b9b05-... tag and DB_Avatars) is
-- dead. While that's true, this lets the player promote one of the alive
-- origin companions currently in the party (Shadowheart, Wyll, Astarion,
-- Lae'zel, Karlach, etc.) to Avatar status, making them the controllable
-- party leader instead. If Tav is later revived, the player can hand
-- Avatar status straight back to Tav, which instantly strips it from
-- whichever companion was holding it - there is never more than one
-- Avatar at a time, and a companion can only receive it while Tav is dead.
--
-- IMPORTANT - risk/confidence note (read before touching this file):
-- There is no clean, first-party Osiris path for "promote a companion who
-- has never been an Avatar into becoming one." The vanilla game only has a
-- clean path for the OTHER half - dismissing a dead Avatar and later
-- re-adding that *same* character as Avatar again (PROC_GLO_PartyMembers_
-- MakeNPC's "Avatar Dismissal" branch, which calls the native
-- DismissAvatar() function). That path is real, tested-by-Larian code and
-- is what DismissDeadAvatar() below uses.
--
-- For actually handing Avatar status to a companion who's never held it,
-- the only working approach found (confirmed by reading the actual
-- Osiris source of the Nexus "Toggle Avatar On Party Members" mod, all
-- three of its released versions, which the mod author spent ~1.5 years
-- iterating on) is to set the AVATAR tag and DB_Avatars directly and then
-- do the same native calls the vanilla "re-add a dismissed Avatar" branch
-- does (MakePlayer, PROC_AssignCharacterToPlayer, SetOnStage, clearing
-- BLOCK_RESURRECTION). That author's own documented findings, which this
-- code follows:
--   - Leaving stale DB_ApprovalRating rows pointed at a character after
--     they stop being the Avatar can make the game pick them to voice a
--     companion approval line and crash. CleanupApprovalRatingFor() below
--     deletes those rows every time someone stops being Avatar, mirroring
--     the author's own fix for this exact crash.
--   - The author explicitly found they could NOT get the custom player
--     character (Tav/Durge) itself working as a "toggled back and forth"
--     Avatar without bugs (non-dismissable characters, dialogue issues),
--     and gave up on it. This mod sidesteps that specific failure mode by
--     never trying to make Tav into a plain companion while alive - Tav
--     only ever loses Avatar status by dying, and dead-Avatar dismissal
--     goes through the real vanilla DismissAvatar() path instead of the
--     tag-forcing one.
-- Bottom line: the "promote a companion" direction is built the most
-- solid way currently known to be possible, but it is not backed by a
-- first-party code path the way the rest of this mod's fixes are. Watch
-- for issues (a promoted companion who won't dismiss, approval dialogue
-- weirdness, camp tent/portrait visuals) and report them.

local MOD_PREFIX = "[Damage Destruction]"

local AVATAR_TAG = "AVATAR_306b9b05-1057-4770-aa17-01af21acd650"
local BLOCK_RESURRECTION_TAG = "BLOCK_RESURRECTION_22a75dbb-1588-407e-b559-5aa4e6d4e6a6"

local REQ_CHANNEL     = ModuleUUID .. "_AvatarSwitch_Request"
local STATE_CHANNEL   = ModuleUUID .. "_AvatarSwitch_State"
local PROMOTE_CHANNEL = ModuleUUID .. "_AvatarSwitch_Promote"
local RESTORE_CHANNEL = ModuleUUID .. "_AvatarSwitch_RestoreTav"

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
    if not guid or guid == "" then return "Unknown character" end
    if Ext and Ext.Entity and type(Ext.Entity.Get) == "function" then
        local ok, entity = pcall(Ext.Entity.Get, guid)
        if ok and entity then
            local name = ReadDisplayNameComponent(entity)
            if name then return name end
        end
    end
    return guid
end

local function IsOrigin(char)
    local isOrigin = false
    pcall(function()
        local rows = Osi.DB_Origins:Get(char)
        isOrigin = (type(rows) == "table" and #rows > 0)
    end)
    return isOrigin
end

local function IsAvatar(char)
    local isAvatar = false
    pcall(function()
        local rows = Osi.DB_Avatars:Get(char)
        isAvatar = (type(rows) == "table" and #rows > 0)
    end)
    return isAvatar
end

-- The current Avatar, dead or alive, if any.
local function FindCurrentAvatar()
    local ok, rows = pcall(function() return Osi.DB_Avatars:Get(nil) end)
    if not ok or type(rows) ~= "table" then return nil end
    for _, row in pairs(rows) do
        if type(row) == "table" and row[1] then
            return row[1]
        end
    end
    return nil
end

-- The custom player character (Tav/Durge): whichever current or former
-- party member is not an origin. We look among DB_Players first (covers
-- Tav whether alive or dead-but-still-a-player), falling back to nothing
-- found if Tav has already been fully removed from the party.
local function FindTav()
    local ok, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if not ok or type(rows) ~= "table" then return nil end
    for _, row in pairs(rows) do
        if type(row) == "table" and row[1] then
            local char = row[1]
            if not IsOrigin(char) then
                return char
            end
        end
    end
    return nil
end

-- Alive origin companions currently in the party, not already Avatar.
local function GetPromotableCompanions()
    local list = {}
    local ok, rows = pcall(function() return Osi.DB_Players:Get(nil) end)
    if not ok or type(rows) ~= "table" then return list end
    for _, row in pairs(rows) do
        if type(row) == "table" and row[1] then
            local char = row[1]
            -- Rows come from DB_Players, which IS the active party. (The old
            -- Osi.IsPartyMember(char) call was missing its second argument,
            -- always failed inside pcall, and emptied this list.)
            local isDead = false
            pcall(function() isDead = (Osi.IsDead(char) == 1) end)
            if not isDead and IsOrigin(char) and not IsAvatar(char) then
                table.insert(list, { UUID = char, Name = GetCharacterName(char) })
            end
        end
    end
    table.sort(list, function(a, b) return (a.Name or "") < (b.Name or "") end)
    return list
end

-- Delete stale DB_ApprovalRating rows pointed at a character who just
-- stopped being Avatar. Confirmed necessary (per the Nexus author's own
-- notes) to stop the game from picking a non-Avatar to voice a companion
-- approval line, which can crash.
local function CleanupApprovalRatingFor(char)
    local ok, rows = pcall(function() return Osi.DB_ApprovalRating:Get(nil, char, nil) end)
    if not ok or type(rows) ~= "table" then return end
    for _, row in pairs(rows) do
        if type(row) == "table" and row[1] and row[2] and row[3] ~= nil then
            pcall(function() Osi.DB_ApprovalRating:Delete(row[1], row[2], row[3]) end)
        end
    end
end

-- Dismiss a DEAD Avatar the real way: this is exactly the vanilla
-- "Avatar Dismissal" branch of PROC_GLO_PartyMembers_MakeNPC, which ends
-- up calling the native DismissAvatar() function. Only fires if the
-- character is currently flagged DB_Avatars and the dead-avatar-dismiss
-- conditions (QRY_GLO_AvatarCanBeDismissed) hold, same as they do for
-- Withers' own dismissal dialogue.
local function DismissDeadAvatar(char)
    if not IsAvatar(char) then return end
    local ok, err = pcall(function() Osi.PROC_GLO_PartyMembers_MakeNPC(char) end)
    if not ok then
        print(MOD_PREFIX .. " Avatar Switch: failed to dismiss dead avatar " .. tostring(char) .. " - " .. tostring(err))
    end
    CleanupApprovalRatingFor(char)
end

-- Strip Avatar status from a character who is still ALIVE and remains an
-- ordinary party member (used when handing Avatar status from a promoted
-- companion back to a revived Tav). Deliberately does NOT go through
-- PROC_GLO_PartyMembers_MakeNPC's normal (non-Avatar) branch, since that
-- would eject them from the party entirely - we just want them to stop
-- being the controlled character, not leave.
local function DemoteLivingAvatar(char)
    pcall(function() Osi.ClearTag(char, AVATAR_TAG) end)
    pcall(function() Osi.DB_Avatars:Delete(char) end)
    CleanupApprovalRatingFor(char)
end

-- Grant Avatar status to a character already alive and in the party
-- (either a companion being promoted, or Tav being handed control back).
local function PromoteToAvatar(char)
    local host = nil
    pcall(function() host = Osi.GetHostCharacter() end)

    pcall(function() Osi.SetTag(char, AVATAR_TAG) end)
    pcall(function() Osi.MakePlayer(char, host) end)
    local ok, err = pcall(function() Osi.PROC_AssignCharacterToPlayer(char, host) end)
    if not ok then
        print(MOD_PREFIX .. " Avatar Switch: PROC_AssignCharacterToPlayer failed for " .. tostring(char) .. " - " .. tostring(err))
    end
    pcall(function() Osi.DB_Avatars(char) end)
    pcall(function() Osi.SetOnStage(char, 1) end)
    pcall(function() Osi.ClearTag(char, BLOCK_RESURRECTION_TAG) end)
end

local function BuildState()
    local tav = FindTav()
    local tavDead = false
    if tav then
        pcall(function() tavDead = (Osi.IsDead(tav) == 1) end)
    end

    local currentAvatar = FindCurrentAvatar()
    local currentAvatarName = currentAvatar and GetCharacterName(currentAvatar) or nil
    local currentAvatarIsTav = (tav ~= nil and currentAvatar == tav)

    local state = {
        TavAlive = (tav ~= nil and not tavDead),
        TavDead = tavDead,
        TavName = tav and GetCharacterName(tav) or nil,
        CurrentAvatarName = currentAvatarName,
        CurrentAvatarIsTav = currentAvatarIsTav,
        -- Only offer promotion candidates while Tav is dead.
        Candidates = tavDead and GetPromotableCompanions() or {},
    }
    return state
end

local function SendStateTo(user)
    local state = BuildState()
    local ok, json = pcall(Ext.Json.Stringify, state)
    if not ok then json = "{}" end
    if user then
        if pcall(function() Ext.Net.PostMessageToUser(user, STATE_CHANNEL, json) end) then return end
        if pcall(function() Ext.ServerNet.PostMessageToUser(user, STATE_CHANNEL, json) end) then return end
    end
    pcall(function() Ext.Net.BroadcastMessage(STATE_CHANNEL, json) end)
end

Ext.RegisterNetListener(REQ_CHANNEL, function(_, _, user)
    SendStateTo(user)
end)

-- Promote a chosen companion to Avatar. Only valid while Tav is dead.
Ext.RegisterNetListener(PROMOTE_CHANNEL, function(_, payload, _)
    local companion = payload
    if type(companion) ~= "string" or companion == "" then return end

    local tav = FindTav()
    local tavDead = false
    if tav then
        pcall(function() tavDead = (Osi.IsDead(tav) == 1) end)
    end
    if not tavDead then
        print(MOD_PREFIX .. " Avatar Switch: refused to promote " .. tostring(companion) .. " - Tav is not dead.")
        SendStateTo(nil)
        return
    end

    local isParty, isDead = false, false
    pcall(function()
        local rows = Osi.DB_Players:Get(companion)
        isParty = (type(rows) == "table" and #rows > 0)
    end)
    pcall(function() isDead = (Osi.IsDead(companion) == 1) end)
    if not isParty or isDead or not IsOrigin(companion) or IsAvatar(companion) then
        print(MOD_PREFIX .. " Avatar Switch: refused to promote " .. tostring(companion) .. " - not an eligible living origin companion.")
        SendStateTo(nil)
        return
    end

    -- Make sure there is never more than one Avatar at a time: clear Tav's
    -- Avatar status first (dead-avatar path) before granting it elsewhere.
    if tav then
        DismissDeadAvatar(tav)
    end

    PromoteToAvatar(companion)

    SendStateTo(nil)
end)

-- Hand Avatar status back to a revived Tav, instantly stripping it from
-- whichever companion currently holds it.
Ext.RegisterNetListener(RESTORE_CHANNEL, function(_, _, _)
    local tav = FindTav()
    if not tav then
        print(MOD_PREFIX .. " Avatar Switch: refused to restore Tav - no custom character found in party.")
        SendStateTo(nil)
        return
    end

    local tavDead = false
    pcall(function() tavDead = (Osi.IsDead(tav) == 1) end)
    if tavDead then
        print(MOD_PREFIX .. " Avatar Switch: refused to restore Tav - Tav is still dead.")
        SendStateTo(nil)
        return
    end

    if IsAvatar(tav) then
        -- Tav already holds Avatar status; nothing to do.
        SendStateTo(nil)
        return
    end

    local currentAvatar = FindCurrentAvatar()
    if currentAvatar and currentAvatar ~= tav then
        DemoteLivingAvatar(currentAvatar)
    end

    PromoteToAvatar(tav)

    SendStateTo(nil)
end)

Ext.Events.SessionLoaded:Subscribe(function()
    SendStateTo(nil)
end)
