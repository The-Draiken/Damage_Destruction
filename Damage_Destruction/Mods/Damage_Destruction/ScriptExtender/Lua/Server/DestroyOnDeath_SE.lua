
-- CFG_FALLBACK_INIT: if shared config failed to load for any reason, create safe defaults
if DestroyOnDeathConfig == nil then
    DestroyOnDeathConfig = {
        Enabled = true,
        AffectScope = "all",
        OverkillStep = 10,
        StackingEnabled = true,
        IgnoreLegendaries = true,
        IgnoreAdamantine = true,
        ConditionalRequiresOverkill = false,
        DamageRules = {
            Acid={mode="all"}, Fire={mode="all"}, Cold={mode="all"}, Lightning={mode="all"},
            Radiant={mode="all"}, Necrotic={mode="all"},
            Bludgeoning={mode="random"}, Force={mode="random"}, Thunder={mode="random"},
        },
        _ImmuneStats = {},
        IsItemImmune = function(_) return false end
    }
end
if DestroyOnDeathConfig.EnsureDefaults then
    DestroyOnDeathConfig.EnsureDefaults()
end

---@diagnostic disable: lowercase-global, undefined-global

local LastHit = {}
local PendingHPBefore = {}

local DEBUG = true
local function DPrint(msg)
    if DEBUG then Ext.Utils.Print("[Damage_Destruction] " .. msg) end
end

local conditionalTypes = { Bludgeoning=true, Force=true, Thunder=true }

local EQUIP_SLOTS = {
  -- Armor/jewelry
  "Helmet","Amulet","Breast","Cloak","Belt","Gloves","Leggings","Boots",
  "Ring","Ring2",

  -- Weapons (Osiris uses both generic slots and melee/ranged-specific slot names)
  "Weapon","Shield",
  "Melee Main Weapon","Melee Offhand Weapon",
  "Ranged Main Weapon","Ranged Offhand Weapon",

  -- Clothing / camp
  "CampClothing","CampShoes","Underwear",

  -- Misc slots (may exist depending on version/mods)
  "Instrument","Torch","Arrow"
}

local VFX_DESTROY = "VFX_Cinematic_RolanProjection_Appear_01_d5eb43de-4fce-dba6-7bc4-1aac43d5d5e1"

local function NormalizeDamageType(dmgType)
    if type(dmgType) ~= "string" then return "" end
    local s = dmgType:gsub("^DAMAGE_", "")
    local u = s:upper()
    if u:find("FIRE", 1, true) then return "Fire" end
    if u:find("NECRO", 1, true) then return "Necrotic" end
    if u:find("RADIANT", 1, true) then return "Radiant" end
    if u:find("LIGHTNING", 1, true) or u:find("ELECTRIC", 1, true) then return "Lightning" end
    if u:find("COLD", 1, true) or u:find("ICE", 1, true) then return "Cold" end
    if u:find("ACID", 1, true) then return "Acid" end
    if u:find("BLUDGE", 1, true) then return "Bludgeoning" end
    if u:find("THUNDER", 1, true) then return "Thunder" end
    if u:find("FORCE", 1, true) then return "Force" end
    return s
end


local function IsAffectedCharacter(charGuid)
    -- Died can fire for non-characters in some situations; keep the check but log it
    local isChar = (Osi.IsCharacter(charGuid) == 1)
    if not isChar then
        return false
    end
    if not DestroyOnDeathConfig then return true end

    -- Normalize scope defensively (if anything other than exact "party", treat as all)
    local scope = tostring(DestroyOnDeathConfig.AffectScope or "party"):lower()
    if scope ~= "party" then
        return true
    end

    -- party scope:
    if Osi.IsPlayer(charGuid) == 1 then
        return true
    end

    local ok, inParty = pcall(function()
        if Osi.IsPartyMember then return Osi.IsPartyMember(charGuid) == 1 end
        if Osi.IsInParty then return Osi.IsInParty(charGuid) == 1 end
        if Osi.CharacterIsInParty then return Osi.CharacterIsInParty(charGuid) == 1 end
        return false
    end)
    if ok and inParty then
        return true
    end

    -- fallback: DB_Players if available
    local ok2, res2 = pcall(function()
        if Osi.DB_Players then
            for _, row in pairs(Osi.DB_Players:Get(nil)) do
                if row[1] == charGuid then
                    return true
                end
            end
        end
        return false
    end)

    return ok2 and res2 or false
end

local function CollectEquippedItems(charGuid)
    local items = {}
    local seen = {}
    for _, slot in ipairs(EQUIP_SLOTS) do
        local item = Osi.GetEquippedItem(charGuid, slot)
        if item and item ~= "" and not seen[item] then
            seen[item] = true
            if not DestroyOnDeathConfig.IsItemImmune(item) then
                table.insert(items, item)
            end
        end
    end
    return items
end

local function DestroyEquippedItems(charGuid, countToDestroy)
    local items = CollectEquippedItems(charGuid)
    local total = #items
    DPrint(("DestroyEquippedItems: equipped=%d count=%d"):format(total, countToDestroy))
    if total == 0 or countToDestroy == 0 then return end

    pcall(function() Osi.PlayEffect(charGuid, VFX_DESTROY, "", 1.0) end)

    if countToDestroy < 0 or countToDestroy >= total then
        for _, item in ipairs(items) do
            Osi.Unequip(charGuid, item)
            Osi.RequestDelete(item)
        end
        return
    end

    for _=1, math.min(countToDestroy, total) do
        if #items == 0 then break end
        local idx = Ext.Utils.Random(1, #items)
        local guid = items[idx]
        Osi.Unequip(charGuid, guid)
        Osi.RequestDelete(guid)
        table.remove(items, idx)
    end
end

local function ComputeItemsToDestroy(charGuid)
    if not DestroyOnDeathConfig or not DestroyOnDeathConfig.Enabled then return 0 end
    local hit = LastHit[charGuid]
    if not hit then return 0 end

    local dmgType = NormalizeDamageType(hit.damageType)
    local overkill = hit.overkill or 0

    local step = DestroyOnDeathConfig.OverkillStep or 0
    local rules = DestroyOnDeathConfig.DamageRules or {}
    local rule = rules[dmgType] or { mode="none" }
    local mode = rule.mode or "none"

    DPrint(("ComputeItemsToDestroy: raw=%s norm=%s mode=%s overkill=%s step=%s requireOverkill=%s")
      :format(tostring(hit.damageType), tostring(dmgType), tostring(mode), overkill, step, tostring(DestroyOnDeathConfig.ConditionalRequiresOverkill)))

    if mode == "none" then return 0 end

    if not conditionalTypes[dmgType] then
        if mode == "all" then return -1 end
        if mode == "random" then return 1 end
        return 0
    end
    if (DestroyOnDeathConfig.ConditionalRequiresOverkill == true) and step > 0 and overkill < step then return 0 end
    if mode == "all" then return -1 end

    local tiers = 1
    if DestroyOnDeathConfig.StackingEnabled and step > 0 then
        if DestroyOnDeathConfig.ConditionalRequiresOverkill == true then
            -- First tier requires meeting the threshold; additional tiers per extra step beyond it
            tiers = tiers + math.floor(math.max(0, overkill - step) / step)
        else
            -- Always at least 1 tier on kill; additional tiers per full step of overkill
            tiers = tiers + math.floor(math.max(0, overkill) / step)
        end
    end
    return math.max(1, tiers)
end

Ext.Osiris.RegisterListener("AttackedBy", 7, "before", function(defender, _, _, _, _, _, _)
    if Osi.IsCharacter(defender) == 1 then
        PendingHPBefore[defender] = Osi.GetHitpoints(defender) or 0
    end
end)

Ext.Osiris.RegisterListener("AttackedBy", 7, "after", function(defender, _, _, damageType, damageAmount, damageCause, _)
    if Osi.IsCharacter(defender) ~= 1 then return end
    local hpBefore = PendingHPBefore[defender]
    PendingHPBefore[defender] = nil
    if hpBefore == nil then
        local hpAfter = Osi.GetHitpoints(defender) or 0
        hpBefore = hpAfter + (damageAmount or 0)
    end
    local overkill = 0
    if damageAmount and hpBefore then
        overkill = math.max(0, (damageAmount or 0) - (hpBefore or 0))
    end
    LastHit[defender] = { damageType=damageType, amount=damageAmount or 0, overkill=overkill, cause=damageCause }
    DPrint(("AttackedBy: def=%s dmgType=%s amount=%s cause=%s hpBefore=%s overkill=%s")
        :format(tostring(defender), tostring(damageType), tostring(damageAmount), tostring(damageCause), tostring(hpBefore), tostring(overkill)))
end)

Ext.Osiris.RegisterListener("Died", 1, "after", function(char)
    DPrint("Died: " .. tostring(char))
    DPrint("CFGDBG Scope=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.AffectScope) .. " RequireOverkill=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.ConditionalRequiresOverkill) .. " Step=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.OverkillStep) .. " ForceMode=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Force and DestroyOnDeathConfig.DamageRules.Force.mode))
    DPrint("SCOPE=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.AffectScope) .. " IsPlayer=" .. tostring(Osi.IsPlayer(char)) .. " IsCharacter=" .. tostring(Osi.IsCharacter(char)))
    if not IsAffectedCharacter(char) then
        DPrint("Died: not in scope")
        return
    end
    -- Apply our Raise Dead block status if the last hit that killed this character
    -- was one of the destructive elemental types. We reuse the LastHit table from
    -- Damage_Destruction to determine the damage type that dealt the final blow.
    local hit = LastHit[char]
    if hit then
        local dmgType = NormalizeDamageType(hit.damageType)
        -- If the normalized damage type is one of our destructive elements
        -- then permanently block Raise Dead by applying the terminal status.
        if dmgType == "Fire" or dmgType == "Acid" or dmgType == "Lightning" or dmgType == "Cold" or dmgType == "Radiant" or dmgType == "Necrotic" then
            -- Only apply if not already applied; using ApplyStatus will stack if we don't remove duplicates,
            -- but since this status is non-stackable and uses a unique StackId, it will not duplicate.
            Osi.ApplyStatus(char, "DD_DEATH_BLOCKS_RAISE_DEAD_4", -1, 1)
        end
    end
    -- Continue with item destruction logic
    local count = ComputeItemsToDestroy(char)
    if count == 0 then return end
    DestroyEquippedItems(char, count)
end)
