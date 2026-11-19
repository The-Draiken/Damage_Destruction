-- DD_HalsinGear.lua
--
-- Damage Destruction only, Halsin only. Damage Destruction's permadeath can
-- destroy everything a character is wearing when they die. For Halsin (before
-- he's recruited), this puts his gear back on him when he's revived.
--
-- How it works:
--   * Snapshot: while Halsin is alive, the root template of every equipped
--     item is recorded per slot (on save load, when he enters combat, and in
--     a "before" Died listener, which runs before Damage Destruction's own
--     "after" Died listener destroys anything). Saved in PersistentVars, so it
--     survives saving/loading.
--   * Restore: shortly after he's resurrected, every slot that is now empty
--     gets a fresh copy of the recorded item, which is then equipped. Slots
--     that still hold something are left alone, so nothing is duplicated.
--   * Fallback: if no snapshot exists (e.g. he died before this file was
--     installed), his default Act 1 outfit from the game's own equipment set
--     "EQ_Halsin" (Stats/Generated/Equipment.txt) is used: Druid quarterstaff,
--     his unique leather armour, druid leather boots and his unique gloves.
--     Potions/scrolls/camp clothes from that set are deliberately skipped.
--   * Equipping can fail while he's wildshaped, so it retries for ~1 minute;
--     anything still not equipped stays in his inventory.

local MOD_PREFIX = "[Damage Destruction]"
local HALSIN = "S_GLO_Halsin_7628bc0e-52b8-42a7-856a-13a6fd413323"
local HALSIN_UUID = "7628bc0e-52b8-42a7-856a-13a6fd413323"

local SLOTS = {
    "Helmet", "Amulet", "Breast", "Cloak", "Belt", "Gloves", "Leggings", "Boots",
    "Ring", "Ring2", "Underwear",
    "Melee Main Weapon", "Melee Offhand Weapon",
    "Ranged Main Weapon", "Ranged Offhand Weapon",
}

-- Fallback: slot -> stat name, from the game's EQ_Halsin equipment set.
local FALLBACK_STATS = {
    ["Melee Main Weapon"] = "WPN_Quarterstaff_Druid",
    ["Breast"]            = "UNI_Leather_Halsin",
    ["Boots"]             = "ARM_Boots_Leather_Druid",
    ["Gloves"]            = "UNI_Halsin_Gloves",
}

PersistentVars = PersistentVars or {}

local function IsHalsin(char)
    return type(char) == "string" and char:find(HALSIN_UUID, 1, true) ~= nil
end

local function GetSnapshot()
    local ok, snap = pcall(function() return PersistentVars.DD_HalsinGear end)
    if ok and type(snap) == "table" and next(snap) ~= nil then return snap end
    return nil
end

local function GetEquipped(slot)
    local item = nil
    pcall(function() item = Osi.GetEquippedItem(HALSIN, slot) end)
    if item == "" then item = nil end
    return item
end

local function TakeSnapshot(source)
    local alive = false
    pcall(function() alive = (Osi.IsDead(HALSIN) == 0) end)
    if not alive then return end

    local snap, count = {}, 0
    for _, slot in ipairs(SLOTS) do
        local item = GetEquipped(slot)
        if item then
            local template = nil
            pcall(function() template = Osi.GetTemplate(item) end)
            if type(template) == "string" and template ~= "" then
                snap[slot] = template
                count = count + 1
            end
        end
    end
    -- Never overwrite a good snapshot with an empty (stripped) one.
    if count == 0 then return end
    PersistentVars.DD_HalsinGear = snap
    print(MOD_PREFIX .. " Halsin gear: recorded " .. count .. " equipped item(s) (" .. tostring(source) .. ")")
end

local function FallbackTemplates()
    local list = {}
    for slot, statName in pairs(FALLBACK_STATS) do
        local root = nil
        pcall(function()
            local stat = Ext.Stats.Get(statName)
            root = stat and stat.RootTemplate or nil
        end)
        if type(root) == "string" and root ~= "" then
            list[slot] = root
        else
            print(MOD_PREFIX .. " Halsin gear: no root template found for " .. statName)
        end
    end
    return list
end

local function TryEquipPending(pending, attempt)
    local remaining = {}
    for slot, template in pairs(pending) do
        if not GetEquipped(slot) then
            local item = nil
            pcall(function() item = Osi.GetItemByTemplateInInventory(template, HALSIN) end)
            if item and item ~= "" then
                pcall(function() Osi.Equip(HALSIN, item) end)
            end
            if not GetEquipped(slot) then
                remaining[slot] = template
            end
        end
    end
    if next(remaining) == nil then
        print(MOD_PREFIX .. " Halsin gear: all restored items equipped")
        return
    end
    if attempt < 12 then
        Ext.Timer.WaitFor(5000, function() TryEquipPending(remaining, attempt + 1) end)
    else
        print(MOD_PREFIX .. " Halsin gear: some items could not be equipped and were left in his inventory")
    end
end

local function RestoreGear()
    local source = "snapshot"
    local templates = GetSnapshot()
    if not templates then
        source = "EQ_Halsin fallback"
        templates = FallbackTemplates()
    end

    local pending, created = {}, 0
    for slot, template in pairs(templates) do
        if not GetEquipped(slot) then
            local ok = pcall(function() Osi.TemplateAddTo(template, HALSIN, 1, 0) end)
            if ok then
                pending[slot] = template
                created = created + 1
            end
        end
    end
    print(MOD_PREFIX .. " Halsin gear: recreated " .. created .. " item(s) from " .. source)
    if created > 0 then
        Ext.Timer.WaitFor(500, function() TryEquipPending(pending, 1) end)
    end
end

-- Snapshot triggers.
Ext.Osiris.RegisterListener("LevelGameplayReady", 0, "after", function()
    TakeSnapshot("level ready")
end)

Ext.Osiris.RegisterListener("EnteredCombat", 2, "after", function(object, _)
    if IsHalsin(object) then TakeSnapshot("entered combat") end
end)

-- "before" runs ahead of DestroyOnDeath_SE.lua's "after" Died listener.
Ext.Osiris.RegisterListener("Died", 1, "before", function(char)
    if IsHalsin(char) then
        -- At this point he's technically dying; snapshot regardless of IsDead.
        local snap, count = {}, 0
        for _, slot in ipairs(SLOTS) do
            local item = GetEquipped(slot)
            if item then
                local template = nil
                pcall(function() template = Osi.GetTemplate(item) end)
                if type(template) == "string" and template ~= "" then
                    snap[slot] = template
                    count = count + 1
                end
            end
        end
        if count > 0 then
            PersistentVars.DD_HalsinGear = snap
            print(MOD_PREFIX .. " Halsin gear: recorded " .. count .. " item(s) at death")
        end
    end
end)

-- Restore after revival. Delay lets RTD_Improved's story fix (which can
-- remove his wildshape) run first.
Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(char)
    if IsHalsin(char) then
        Ext.Timer.WaitFor(4500, RestoreGear)
    end
end)
