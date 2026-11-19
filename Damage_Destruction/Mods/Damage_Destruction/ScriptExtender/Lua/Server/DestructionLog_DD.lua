-- Centralized item destruction notifications for Damage Destruction.
-- Uses non-overhead notifications because Osiris does not expose a stable
-- arbitrary custom combat-log-only call.

---@diagnostic disable: undefined-global

DD = DD or {}
DD.DestructionLog = DD.DestructionLog or {}

local NULL_UUID = "NULL_00000000-0000-0000-0000-000000000000"

local function DPrint(message)
    if Ext and Ext.Utils and type(Ext.Utils.Print) == "function" then
        Ext.Utils.Print("[Damage_Destruction:DestructionLog] " .. tostring(message))
    end
end

local function ReadTranslatedHandle(handle)
    if type(handle) == "table" and handle.Handle then
        handle = handle.Handle
    end
    if type(handle) == "table" and handle.Handle then
        handle = handle.Handle
    end
    if type(handle) ~= "string" or handle == "" then
        return nil
    end
    if Ext and Ext.Loca and type(Ext.Loca.GetTranslatedString) == "function" then
        local ok, translated = pcall(Ext.Loca.GetTranslatedString, handle)
        if ok and type(translated) == "string" and translated ~= "" then
            return translated
        end
    end
    return handle
end

local function ReadDisplayNameComponent(entity)
    if not entity or not entity.DisplayName or not entity.DisplayName.Name then
        return nil
    end

    local name = entity.DisplayName.Name
    if type(name) == "string" and name ~= "" then
        return name
    end
    if type(name) == "userdata" or type(name) == "table" then
        local ok, value = pcall(function()
            return name:Get()
        end)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end

    return nil
end

local function GetItemStatName(itemGuid)
    if Ext and Ext.Entity and type(Ext.Entity.Get) == "function" then
        local ok, entity = pcall(Ext.Entity.Get, itemGuid)
        if ok and entity and entity.Data and type(entity.Data.StatsId) == "string" and entity.Data.StatsId ~= "" then
            return entity.Data.StatsId
        end
    end
    return nil
end

local function GetStatDisplayName(statName)
    if type(statName) ~= "string" or statName == "" then
        return nil
    end
    if Ext and Ext.Stats and type(Ext.Stats.Get) == "function" then
        local ok, stat = pcall(Ext.Stats.Get, statName)
        if ok and stat then
            local displayName
            pcall(function()
                displayName = stat.DisplayName
            end)
            local translated = ReadTranslatedHandle(displayName)
            if translated then
                return translated
            end
        end
    end
    return nil
end

local function GetEntityDisplayName(guid, fallback)
    if not guid or guid == "" or guid == NULL_UUID then
        return fallback
    end

    if Ext and Ext.Entity and type(Ext.Entity.Get) == "function" then
        local ok, entity = pcall(Ext.Entity.Get, guid)
        if ok and entity then
            local name = ReadDisplayNameComponent(entity)
            if name then
                return name
            end
        end
    end

    return fallback
end

local function GetCharacterName(character)
    return GetEntityDisplayName(character, "Unknown character")
end

local function GetItemName(item)
    local statName = GetItemStatName(item)
    return GetEntityDisplayName(item, GetStatDisplayName(statName) or statName or "Unknown item")
end

local function NormalizeDamageType(damageType)
    if type(damageType) ~= "string" then return "" end
    local stripped = damageType:gsub("^DAMAGE_", "")
    local upper = stripped:upper()
    if upper:find("FIRE", 1, true) then return "Fire" end
    if upper:find("NECRO", 1, true) then return "Necrotic" end
    if upper:find("RADIANT", 1, true) then return "Radiant" end
    if upper:find("LIGHTNING", 1, true) or upper:find("ELECTRIC", 1, true) then return "Lightning" end
    if upper:find("COLD", 1, true) or upper:find("ICE", 1, true) then return "Cold" end
    if upper:find("ACID", 1, true) then return "Acid" end
    if upper:find("BLUDGE", 1, true) then return "Bludgeoning" end
    if upper:find("THUNDER", 1, true) then return "Thunder" end
    if upper:find("FORCE", 1, true) then return "Force" end
    if upper:find("SLASH", 1, true) then return "Slashing" end
    if upper:find("PIERC", 1, true) then return "Piercing" end
    if upper:find("POISON", 1, true) then return "Poison" end
    if upper:find("PSYCH", 1, true) then return "Psychic" end
    return stripped
end

local function BuildReason(damageType, cause)
    local normalizedDamage = NormalizeDamageType(damageType)
    local causeText = tostring(cause or "")

    if causeText == "AshBody" then
        return "ash-body destruction"
    end
    if causeText == "DisintegrateSave" then
        return "a saved Disintegrate"
    end
    if normalizedDamage ~= "" then
        return normalizedDamage .. " damage"
    end
    if causeText ~= "" then
        return causeText
    end
    return "damage destruction"
end

local function NotifyPlayer(player, message, sent)
    if not player or player == "" or player == NULL_UUID or sent[player] then
        return
    end
    sent[player] = true
    if Osi and type(Osi.ShowNotification) == "function" then
        pcall(Osi.ShowNotification, player, message)
    end
end

local function NotifyAllPlayers(message)
    local sent = {}

    if Osi and Osi.DB_Players and type(Osi.DB_Players.Get) == "function" then
        local ok, rows = pcall(function()
            return Osi.DB_Players:Get(nil)
        end)
        if ok and type(rows) == "table" then
            for _, row in pairs(rows) do
                if type(row) == "table" then
                    NotifyPlayer(row[1], message, sent)
                end
            end
        end
    end

    if Osi and type(Osi.GetHostCharacter) == "function" then
        local ok, host = pcall(Osi.GetHostCharacter)
        if ok then
            NotifyPlayer(host, message, sent)
        end
    end
end

function DD.DestructionLog.Record(character, item, damageType, cause)
    if not item or item == "" or item == NULL_UUID then
        return
    end

    local characterName = GetCharacterName(character)
    local itemName = GetItemName(item)
    local reason = BuildReason(damageType, cause)
    local message = string.format("Damage Destruction: %s's %s was destroyed due to %s.", characterName, itemName, reason)

    DPrint(message)
    NotifyAllPlayers(message)
end
