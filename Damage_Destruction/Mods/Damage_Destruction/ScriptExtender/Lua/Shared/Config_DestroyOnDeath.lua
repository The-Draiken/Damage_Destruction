-- Shared config/state for Damage_Destruction (global, profile-wide persistence via BG3SE user storage)
DestroyOnDeathConfig = DestroyOnDeathConfig or {}
local CFG = DestroyOnDeathConfig

local GLOBAL_FILE = "Damage_Destruction/GlobalConfig.json"

local function ReadGlobal()
    if not (Ext and Ext.IO and Ext.IO.LoadFile) then return nil end
    local ok, content = pcall(Ext.IO.LoadFile, GLOBAL_FILE, "user")
    if not ok or not content or content == "" then return nil end
    local ok2, obj = pcall(Ext.Json.Parse, content)
    if ok2 and type(obj) == "table" then return obj end
    return nil
end

local function WriteGlobal(tbl)
    if not (Ext and Ext.IO and Ext.IO.SaveFile) then return false end
    local ok, content = pcall(Ext.Json.Stringify, tbl or {})
    if not ok or not content then return false end
    -- Save in user domain so it persists globally across saves
    local ok2 = pcall(Ext.IO.SaveFile, GLOBAL_FILE, content, "user")
    if not ok2 then
        -- Fallback if this BG3SE build doesn't accept the domain arg
        ok2 = pcall(Ext.IO.SaveFile, GLOBAL_FILE, content)
    end
    return ok2 == true
end

local function Snapshot()
    return {
        Enabled = CFG.Enabled,
        AffectScope = CFG.AffectScope,
        OverkillStep = CFG.OverkillStep,
        ConditionalRequiresOverkill = CFG.ConditionalRequiresOverkill,
        StackingEnabled = CFG.StackingEnabled,
        IgnoreLegendaries = CFG.IgnoreLegendaries,
        IgnoreAdamantine = CFG.IgnoreAdamantine,
        DamageRules = CFG.DamageRules,
        ImmuneStatNames = CFG.ImmuneStatNames,
        ImmuneTemplateIds = CFG.ImmuneTemplateIds,
    }
end

local function Apply(t)
    if type(t) ~= "table" then return end
    if type(t.Enabled) == "boolean" then CFG.Enabled = t.Enabled end
    if type(t.AffectScope) == "string" then CFG.AffectScope = t.AffectScope end
    if type(t.OverkillStep) == "number" then CFG.OverkillStep = t.OverkillStep end
    if type(t.ConditionalRequiresOverkill) == "boolean" then CFG.ConditionalRequiresOverkill = t.ConditionalRequiresOverkill end
    if type(t.StackingEnabled) == "boolean" then CFG.StackingEnabled = t.StackingEnabled end
    if type(t.IgnoreLegendaries) == "boolean" then CFG.IgnoreLegendaries = t.IgnoreLegendaries end
    if type(t.IgnoreAdamantine) == "boolean" then CFG.IgnoreAdamantine = t.IgnoreAdamantine end
    if type(t.DamageRules) == "table" then CFG.DamageRules = t.DamageRules end
    if type(t.ImmuneStatNames) == "table" then CFG.ImmuneStatNames = t.ImmuneStatNames end
    if type(t.ImmuneTemplateIds) == "table" then CFG.ImmuneTemplateIds = t.ImmuneTemplateIds end
end

function CFG.LoadFromGlobal()
    local t = ReadGlobal()
    if t then Apply(t) end
end

function CFG.SaveToGlobal()
    local ok = WriteGlobal(Snapshot())
    if Ext and Ext.Utils and Ext.Utils.Print then
        Ext.Utils.Print(string.format("[Damage_Destruction][GLOBAL] SaveFile ok=%s", tostring(ok)))
    end
end

function CFG.EnsureDefaults()
    if CFG.Enabled == nil then CFG.Enabled = true end
    if CFG.AffectScope == nil then CFG.AffectScope = "all" end
    if CFG.OverkillStep == nil then CFG.OverkillStep = 10 end
    if CFG.ConditionalRequiresOverkill == nil then CFG.ConditionalRequiresOverkill = false end
    if CFG.StackingEnabled == nil then CFG.StackingEnabled = true end
    if CFG.IgnoreLegendaries == nil then CFG.IgnoreLegendaries = true end
    if CFG.IgnoreAdamantine == nil then CFG.IgnoreAdamantine = true end

    CFG.DamageRules = CFG.DamageRules or {
        Acid        = { mode = "all" },
        Fire        = { mode = "all" },
        Cold        = { mode = "all" },
        Lightning   = { mode = "all" },
        Radiant     = { mode = "all" },
        Necrotic    = { mode = "all" },

        Force       = { mode = "random" },
        Bludgeoning = { mode = "random" },
        Thunder     = { mode = "random" },
        Piercing    = { mode = "random" },
        Slashing    = { mode = "random" },
        Poison      = { mode = "random" },
        Psychic     = { mode = "random" },
    }

    CFG.ImmuneStatNames = CFG.ImmuneStatNames or {}
    CFG.ImmuneTemplateIds = CFG.ImmuneTemplateIds or {}
end

-- Update from MCM setting ids
function CFG.UpdateFromMCM(settingId, value)
    if settingId == "enabled" then
        CFG.Enabled = (value == true)
    elseif settingId == "affect_scope" then
        CFG.AffectScope = tostring(value)
    elseif settingId == "overkill_threshold" then
        local n = tonumber(value)
        if n ~= nil then CFG.OverkillStep = n end
    elseif settingId == "conditional_requires_overkill" then
        CFG.ConditionalRequiresOverkill = (value == true)
    elseif settingId == "stacking_enabled" then
        CFG.StackingEnabled = (value == true)
    elseif settingId == "ignore_legendaries" then
        CFG.IgnoreLegendaries = (value == true)
    elseif settingId == "ignore_adamantine" then
        CFG.IgnoreAdamantine = (value == true)
    elseif type(settingId) == "string" and (settingId:sub(1,11) == "dmg_mode__" or settingId:sub(1,13) == "damage_mode__") then
        local dmg = (settingId:sub(1,13) == "damage_mode__") and settingId:sub(14) or settingId:sub(12)
        CFG.DamageRules = CFG.DamageRules or {}
        CFG.DamageRules[dmg] = CFG.DamageRules[dmg] or {}
        CFG.DamageRules[dmg].mode = tostring(value)
    end
end

-- Immunity list API used by client menu + server
function CFG.SetImmuneList(entries)
    CFG.ImmuneStatNames = {}
    if type(entries) ~= "table" then return end
    for _,v in ipairs(entries) do
        if type(v) == "string" and v ~= "" then
            CFG.ImmuneStatNames[v] = true
        end
    end
end

function CFG.BuildImmuneList()
    local out = {}
    if CFG.ImmuneStatNames then
        for k,_ in pairs(CFG.ImmuneStatNames) do table.insert(out, k) end
    end
    table.sort(out)
    return out
end

-- Stat/id helpers
local function GetItemStatName(itemGuid)
    if Ext and Ext.Entity and Ext.Entity.Get then
        local e = Ext.Entity.Get(itemGuid)
        if e and e.Data and e.Data.StatsId and e.Data.StatsId ~= "" then
            return e.Data.StatsId
        end
    end
    return nil
end

local function IsLegendary(itemGuid)
    local stat = GetItemStatName(itemGuid)
    if type(stat) == "string" then
        return stat:upper():find("LEGENDARY", 1, true) ~= nil
    end
    if Osi and Osi.GetRarity then
        local ok, rarity = pcall(Osi.GetRarity, itemGuid)
        if ok and type(rarity) == "number" then return rarity >= 6 end
    end
    return false
end

local function IsAdamantine(itemGuid)
    local stat = GetItemStatName(itemGuid)
    if type(stat) == "string" then
        return stat:upper():find("ADAMANTINE", 1, true) ~= nil
    end
    return false
end

function CFG.IsItemImmune(itemGuid)
    if itemGuid == nil then return true end
    if CFG.IgnoreLegendaries == true and IsLegendary(itemGuid) then return true end
    if CFG.IgnoreAdamantine == true and IsAdamantine(itemGuid) then return true end
    local stat = GetItemStatName(itemGuid)
    if type(stat) == "string" and CFG.ImmuneStatNames and CFG.ImmuneStatNames[stat] then
        return true
    end
    return false
end

-- Load + fill blanks
CFG.LoadFromGlobal()
CFG.EnsureDefaults()


function WriteGlobal(data)
    local payload = Ext.Json.Stringify(data)
    local ok = false
    if Ext and Ext.IO and Ext.IO.SaveFile then
        ok = pcall(Ext.IO.SaveFile, GLOBAL_FILE, payload, "user")
        if not ok then
            ok = pcall(Ext.IO.SaveFile, GLOBAL_FILE, payload)
        end
    end
    if Ext and Ext.Utils and Ext.Utils.Print then
        Ext.Utils.Print(string.format("[Damage_Destruction][GLOBAL] SaveFile ok=%s file=%s", tostring(ok), tostring(GLOBAL_FILE)))
    end
    return ok
end


if Ext and Ext.Utils and Ext.Utils.Print then
  Ext.Utils.Print(string.format("[Damage_Destruction][GLOBAL] File=%s (domain=user)", tostring(GLOBAL_FILE)))
end
