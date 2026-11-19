-- Empty slot initiative support for Damage Destruction.
--
-- Copies the Empty Slots Humanoid approach, but gates the passive behind this
-- mod's MCM setting and adds armor, helmet, and cloak empty-slot bonuses.

---@diagnostic disable: undefined-global

local PASSIVE = "DD_EmptySlotsInitiative"
local HUMANOID_TAG = "HUMANOID_7fbed0d4-cabc-4a9d-804e-12ca6088a0a8"

DD = DD or {}
DD.EmptySlotsInitiative = DD.EmptySlotsInitiative or {}

local function IsEnabled()
    if DestroyOnDeathConfig and DestroyOnDeathConfig.EnsureDefaults then
        DestroyOnDeathConfig.EnsureDefaults()
    end
    return DestroyOnDeathConfig and DestroyOnDeathConfig.EmptySlotsInitiativeEnabled == true
end

local function IsCharacter(character)
    if not character or character == "" then return false end
    local ok, result = pcall(function()
        return Osi.IsCharacter(character) == 1
    end)
    return ok and result == true
end

local function IsPlayer(character)
    local ok, result = pcall(function()
        return Osi.IsPlayer(character) == 1
    end)
    return ok and result == true
end

local function IsHumanoid(character)
    local ok, result = pcall(function()
        return Osi.IsTagged(character, HUMANOID_TAG) == 1
    end)
    return ok and result == true
end

local function ShouldHavePassive(character)
    if not IsEnabled() then return false end
    if not IsCharacter(character) then return false end
    return IsPlayer(character) or IsHumanoid(character)
end

local function HasPassive(character)
    local ok, result = pcall(function()
        return Osi.HasPassive(character, PASSIVE) == 1
    end)
    return ok and result == true
end

function DD.EmptySlotsInitiative.RefreshCharacter(character)
    if not IsCharacter(character) then return end

    local shouldHave = ShouldHavePassive(character)
    local hasPassive = HasPassive(character)

    if shouldHave and not hasPassive then
        pcall(function()
            Osi.AddPassive(character, PASSIVE)
        end)
    elseif not shouldHave and hasPassive then
        pcall(function()
            Osi.RemovePassive(character, PASSIVE)
        end)
    end
end

function DD.EmptySlotsInitiative.RefreshAll()
    local ok, characters = pcall(function()
        return Osi.GetRegionCharacters(nil)
    end)
    if not ok or type(characters) ~= "table" then return end

    for _, character in pairs(characters) do
        DD.EmptySlotsInitiative.RefreshCharacter(character)
    end
end

Ext.Events.SessionLoaded:Subscribe(function()
    DD.EmptySlotsInitiative.RefreshAll()
end)

pcall(function()
    Ext.Osiris.RegisterListener("LevelGameplayReady", 0, "after", function()
        DD.EmptySlotsInitiative.RefreshAll()
    end)

    Ext.Osiris.RegisterListener("CharacterLoadedInPreset", 1, "after", function(character)
        DD.EmptySlotsInitiative.RefreshCharacter(character)
    end)

    Ext.Osiris.RegisterListener("CharacterCreated", 1, "after", function(character)
        DD.EmptySlotsInitiative.RefreshCharacter(character)
    end)

    Ext.Osiris.RegisterListener("CharacterMadePlayer", 1, "after", function(character)
        DD.EmptySlotsInitiative.RefreshCharacter(character)
    end)

    Ext.Osiris.RegisterListener("CharacterJoinedParty", 2, "after", function(character, _)
        DD.EmptySlotsInitiative.RefreshCharacter(character)
    end)

    Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(character, _)
        DD.EmptySlotsInitiative.RefreshCharacter(character)
    end)
end)
