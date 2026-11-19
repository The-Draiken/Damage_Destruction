-- Disintegrate_Save_ItemDestruction.lua
-- When a target succeeds on a saving throw against Disintegrate (or its
-- upcast variants), our stats inject a hidden marker status. Whether this
-- breaks one equipped item is controlled by config/MCM.

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

local function RecordDestroyedItem(charGuid, item)
    if DD and DD.DestructionLog and type(DD.DestructionLog.Record) == "function" then
        pcall(DD.DestructionLog.Record, charGuid, item, "Force", "DisintegrateSave")
    end
end

local function ShouldBreakItemOnDisintegrateSave()
    if not DestroyOnDeathConfig then
        return false
    end

    return DestroyOnDeathConfig.Enabled == true
        and DestroyOnDeathConfig.DisintegrateSaveBreaksItem == true
end

-- Returns { {item=guid, slot=slotName}, ... }.
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
                items[#items+1] = { item = item, slot = slot }
            end
        end
    end
    return items
end

-- Direct call into ImmersiveNudity_SE_Patch, when it's loaded, so it can
-- instantly strip the corresponding baked visual slot. Safe to call
-- whether or not that mod is installed.
local function NotifyNudityPatch(charGuid, slot)
    if IMNSEP and IMNSEP.OnItemDestroyed then
        pcall(IMNSEP.OnItemDestroyed, charGuid, slot)
    end
end

local function DestroyOneRandomEquippedItem(charGuid)
    if not charGuid or Osi.IsCharacter(charGuid) ~= 1 then return false end
    local items = CollectEquippedItems(charGuid)
    if #items == 0 then
        DPrint("No eligible equipped items found on " .. tostring(charGuid))
        return false
    end

    local idx = Ext.Utils.Random(1, #items)
    local entry = items[idx]
    pcall(function() Osi.PlayEffect(charGuid, VFX_DESTROY, "", 1.0) end)
    RecordDestroyedItem(charGuid, entry.item)
    Osi.Unequip(charGuid, entry.item)
    Osi.RequestDelete(entry.item)
    NotifyNudityPatch(charGuid, entry.slot)
    DPrint(("Destroyed random equipped item %s on %s after Disintegrate save"):format(tostring(entry.item), tostring(charGuid)))
    return true
end

Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(target, status, causee, _)
    if status ~= MARKER_STATUS then return end
    if ShouldBreakItemOnDisintegrateSave() then
        DestroyOneRandomEquippedItem(target)
    else
        DPrint(("Ignoring %s on %s because the config toggle is disabled"):format(tostring(MARKER_STATUS), tostring(target)))
    end
    pcall(function() Osi.RemoveStatus(target, MARKER_STATUS) end)
end)

DPrint("Loaded")
