-- DD_DeathBlocksRaiseDead.lua (SERVER)
-- Long-rest escalator for dead bodies (NPCs included),
-- with scan EVERY long rest to catch dead bodies that bypass Died().

Ext.Utils.Print("[DD DeathBlocksRaiseDead] Loaded (scan every long rest)")

local TIERS = {
    "DD_DEATH_BLOCKS_RAISE_DEAD",
    "DD_DEATH_BLOCKS_RAISE_DEAD_1",
    "DD_DEATH_BLOCKS_RAISE_DEAD_2",
    "DD_DEATH_BLOCKS_RAISE_DEAD_3",
    "DD_DEATH_BLOCKS_RAISE_DEAD_4",
}

local DURATION = -1
local FORCE = 1

-- Track dead characters to process on long rest
-- key = character GUID string, value = true
local trackedDead = {}

local function SafeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function CharExists(uuid)
    return uuid ~= nil and uuid ~= "" and Osi.CharacterExists(uuid) == 1
end

local function IsDead(uuid)
    return Osi.IsDead(uuid) == 1
end

local function GetCurrentTierIndex(uuid)
    for i = #TIERS, 1, -1 do
        if Osi.HasStatus(uuid, TIERS[i]) == 1 then
            return i
        end
    end
    return 0
end

local function RemoveAllTiers(uuid)
    for i = 1, #TIERS do
        if Osi.HasStatus(uuid, TIERS[i]) == 1 then
            Osi.RemoveStatus(uuid, TIERS[i])
        end
    end
end

local function ApplyTier(uuid, tierIndex)
    if tierIndex < 1 then return end
    if tierIndex > #TIERS then tierIndex = #TIERS end

    RemoveAllTiers(uuid)
    Osi.ApplyStatus(uuid, TIERS[tierIndex], DURATION, FORCE)

    Ext.Utils.Print(string.format(
        "[DD DeathBlocksRaiseDead] Applied tier %d (%s) to %s",
        tierIndex, TIERS[tierIndex], uuid
    ))
end

local function AdvanceTierIfStillDead(uuid)
    if not CharExists(uuid) then
        trackedDead[uuid] = nil
        return
    end

    if not IsDead(uuid) then
        -- Revived: clean up and stop tracking
        RemoveAllTiers(uuid)
        trackedDead[uuid] = nil
        return
    end

    local cur = GetCurrentTierIndex(uuid)
    if cur >= #TIERS then
        return -- already max tier
    end

    ApplyTier(uuid, cur + 1)
end

------------------------------------------------------------
-- Scan dead characters (runs EVERY long rest)
------------------------------------------------------------

local function ExtractGuidFromEntity(entity)
    local u = nil

    if entity and entity.Uuid then
        if type(entity.Uuid) == "table" and entity.Uuid.EntityUuid then
            u = entity.Uuid.EntityUuid
        elseif type(entity.Uuid) == "string" then
            u = entity.Uuid
        end
    end

    if not u and entity and entity.UUID then
        u = entity.UUID
    end

    if u then
        u = tostring(u)
        if u ~= "" then
            return u
        end
    end

    return nil
end

local function ScanAndTrackAllDeadCharacters()
    -- If entity enumeration isn't available in this SE build, just skip (no crash).
    local entities = SafeCall(function()
        return Ext.Entity.GetAllEntitiesWithComponent("Character")
    end)

    if not entities then
        -- Keep this quiet-ish; it's normal on some setups
        -- Ext.Utils.Print("[DD DeathBlocksRaiseDead] Scan skipped: entity enumeration not available")
        return
    end

    local added = 0
    for _, ent in pairs(entities) do
        local guid = ExtractGuidFromEntity(ent)
        if guid and not trackedDead[guid] and CharExists(guid) and IsDead(guid) then
            trackedDead[guid] = true
            added = added + 1
        end
    end

    if added > 0 then
        Ext.Utils.Print(string.format(
            "[DD DeathBlocksRaiseDead] Scan added %d new dead characters to tracking",
            added
        ))
    end
end

------------------------------------------------------------
-- Events
------------------------------------------------------------

-- Track all deaths (NPCs included)
Ext.Osiris.RegisterListener("Died", 1, "after", function(character)
    if not character or character == "" then return end
    if CharExists(character) and IsDead(character) then
        trackedDead[character] = true
        -- Ext.Utils.Print(string.format("[DD DeathBlocksRaiseDead] Tracking dead: %s", character))
    end
end)

-- On long rest finished:
-- 1) scan entire world for dead characters (catches pre-existing + bypass deaths)
-- 2) advance tiers for anyone still dead
Ext.Osiris.RegisterListener("LongRestFinished", 0, "after", function()
    ScanAndTrackAllDeadCharacters()

    local keys = {}
    for uuid, _ in pairs(trackedDead) do
        keys[#keys+1] = uuid
    end

    for i = 1, #keys do
        AdvanceTierIfStillDead(keys[i])
    end
end)
