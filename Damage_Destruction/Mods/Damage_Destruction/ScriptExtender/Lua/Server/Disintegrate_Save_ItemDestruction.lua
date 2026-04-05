-- Disintegrate_Save_ItemDestruction.lua
-- When a target succeeds on a saving throw against Disintegrate (or its
-- upcast variants), our stats inject a hidden marker status.  This listener
-- responds by destroying one random equipped item on that target.

---@diagnostic disable: lowercase-global, undefined-global

local MARKER_STATUS = "DD_DISINTEGRATE_SAVE_ITEM_BREAK"
local VFX_DESTROY = "9862815f-d9e4-4d1d-a004-9d2c68f996cb"
local EQUIP_SLOTS = {
    "Melee Main Weapon", "Melee Offhand Weapon", "Ranged Main Weapon", "Ranged Offhand Weapon",
    "Helmet", "Breast", "Cloak", "Boots", "Gloves", "Amulet", "Ring", "Ring2", "Underwear"
}

local function DPrint(msg)
    pcall(function()
        Ext.Utils.Print("[Damage_Destruction:DisintegrateSave] " .. tostring(msg))
    end)
end

local function CollectEquippedItems(charGuid)
    local items = {}
    local seen = {}
    for _, slot in ipairs(EQUIP_SLOTS) do
        local item = Osi.GetEquippedItem(charGuid, slot)
        if item and item ~= "" and not seen[item] then
            seen[item] = true
            local immune = false
            if DestroyOnDeathConfig and type(DestroyOnDeathConfig.IsItemImmune) == "function" then
                local ok, res = pcall(DestroyOnDeathConfig.IsItemImmune, item)
                immune = ok and res == true
            end
            if not immune then
                items[#items+1] = item
            end
        end
    end
    return items
end

local function DestroyOneRandomEquippedItem(charGuid)
    if not charGuid or Osi.IsCharacter(charGuid) ~= 1 then return false end
    local items = CollectEquippedItems(charGuid)
    if #items == 0 then
        DPrint("No eligible equipped items found on " .. tostring(charGuid))
        return false
    end

    local idx = Ext.Utils.Random(1, #items)
    local item = items[idx]
    pcall(function() Osi.PlayEffect(charGuid, VFX_DESTROY, "", 1.0) end)
    Osi.Unequip(charGuid, item)
    Osi.RequestDelete(item)
    DPrint(("Destroyed random equipped item %s on %s after Disintegrate save"):format(tostring(item), tostring(charGuid)))
    return true
end

Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(target, status, causee, _)
    if status ~= MARKER_STATUS then return end
    DestroyOneRandomEquippedItem(target)
    pcall(function() Osi.RemoveStatus(target, MARKER_STATUS) end)
end)

DPrint("Loaded")
