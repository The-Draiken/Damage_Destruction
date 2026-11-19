
-- CFG_FALLBACK_INIT: if shared config failed to load for any reason, create safe defaults
if DestroyOnDeathConfig == nil then
    DestroyOnDeathConfig = {
        Enabled = false,
        AffectScope = "party",
        StackingEnabled = false,
        IgnoreLegendaries = true,
        IgnoreAdamantine = true,
        DestroyAshBodyItems = false,
        DisintegrateSaveBreaksItem = false,
        ElementalPermadeathMode = "none",
        ElementalPermadeathOverkillThreshold = 10,
        DamageRules = {
            Acid={mode="none", step=0, chunking=false, chunkThreshold=30}, Fire={mode="none", step=0, chunking=false, chunkThreshold=30}, Cold={mode="none", step=0, chunking=false, chunkThreshold=30}, Lightning={mode="none", step=0, chunking=false, chunkThreshold=30},
            Radiant={mode="none", step=0, chunking=false, chunkThreshold=30}, Necrotic={mode="none", step=0, chunking=false, chunkThreshold=30},
            Bludgeoning={mode="none", step=0, chunking=false, chunkThreshold=30}, Force={mode="none", step=0, chunking=false, chunkThreshold=30}, Thunder={mode="none", step=0, chunking=false, chunkThreshold=30},
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
local ELEMENTAL_PERMADEATH_TYPES = {
    Fire = true,
    Acid = true,
    Lightning = true,
    Cold = true,
    Radiant = true,
    Necrotic = true,
}

local function _DD_ClearDamageContext(charGuid)
    if charGuid == nil or charGuid == "" then
        return
    end
    LastHit[charGuid] = nil
    PendingHPBefore[charGuid] = nil
end

-- Forward declarations for helpers used by early listeners/functions.
-- Without these, early calls resolve to globals and crash before the later local
-- function definitions are reached.
local DPrint
local NormalizeDamageType

-- === Overkill_Exploder status support ===
-- A hidden status that will be applied to most characters on load/spawn and removed under
-- certain lethal damage conditions. When removed, it triggers Overkill_Explode via its
-- OnRemoveFunctors (defined in the stats).  Characters or tags listed in the
-- exclusion tables below will not receive this status.

--[[
To add exclusions, add the GUID or tag of the character/race to the appropriate table.
Example:
    OVERKILL_EXPLODER_EXCLUDED_CHARACTERS["<GUID>"] = true
    OVERKILL_EXPLODER_EXCLUDED_TAGS["ELF"] = true
]]
OVERKILL_EXPLODER_EXCLUDED_CHARACTERS = OVERKILL_EXPLODER_EXCLUDED_CHARACTERS or {}
OVERKILL_EXPLODER_EXCLUDED_TAGS       = OVERKILL_EXPLODER_EXCLUDED_TAGS or {}

-- Ensures the Overkill_Exploder status is applied to the given character, unless
-- the character is excluded by GUID or tag. Uses a permanent duration (-1) so
-- the status persists until explicitly removed.  The optional `src` argument
-- is for debugging and is unused otherwise.
local function _DD_EnsureOverkillExploder(char, src)
    -- Only apply to valid characters
    if Osi.IsCharacter(char) ~= 1 then return end
    -- Do not apply during character creation/resurrection if not yet in the world
    -- Exclude manually configured characters
    if OVERKILL_EXPLODER_EXCLUDED_CHARACTERS[char] then
        return
    end
    -- Exclude characters with any excluded tag
    for tag,_ in pairs(OVERKILL_EXPLODER_EXCLUDED_TAGS) do
        if Osi.IsTagged(char, tag) == 1 then
            return
        end
    end
    -- Apply if not already present
    local ok, has = pcall(function() return Osi.HasActiveStatus(char, "Overkill_Exploder") end)
    if ok and has == 1 then
        return
    end
    -- Duration -1.0 denotes permanent in Baldur's Gate 3
    pcall(function()
        Osi.ApplyStatus(char, "Overkill_Exploder", -1.0, 1)
        if DEBUG then DPrint(("Applied Overkill_Exploder to %s via %s"):format(tostring(char), tostring(src))) end
    end)
end

-- Removes Overkill_Exploder from the defender under specific lethal damage conditions.
-- If a character is killed by Bludgeoning, Force or Thunder damage and the
-- overkill damage exceeds three times the configured OverkillStep, remove
-- the Overkill_Exploder status.  If the damage cause comes from the spell
-- Target_Multiattack_Dragon_Skeletal, always remove the status regardless
-- of damage or overkill.  If the damage cause corresponds to one of the
-- Disintegrate projectiles (Projectile_Disintegrate, and numbered variants),
-- never remove the status, even though it is Force damage.
--
-- Removes the hidden Overkill_Exploder status when "chunking" conditions are met.
--
-- In the base mod, Overkill_Exploder was removed whenever Bludgeoning, Force or
-- Thunder damage exceeded three times the global overkill step.  This created
-- situations where any sufficiently large damage instance — even if it combined
-- multiple damage types — could prematurely strip the status.  To provide
-- per‑damage‑type control and avoid unintended explosions, this function now
-- consults DestroyOnDeathConfig.DamageRules to determine whether chunking is
-- enabled and what overkill step to use for each damage type.
--
-- When a character is dealt lethal damage, the function calculates the
-- overkill (damage beyond remaining HP).  If chunking is enabled for the
-- normalized damage type, and the overkill is at least three times that
-- type's configured overkill step, Overkill_Exploder is removed.  Chunking
-- defaults to false, so most damage types will never trigger this removal
-- unless explicitly configured.
local function _DD_TryRemoveOverkillExploder(defender, damageType, damageAmount, hpBefore, damageCause)
    if Osi.IsCharacter(defender) ~= 1 then return end

    local causeStr = tostring(damageCause or "")
    if causeStr:find("Target_Multiattack_Dragon_Skeletal") then
        local ok, has = pcall(function() return Osi.HasActiveStatus(defender, "Overkill_Exploder") end)
        if ok and has == 1 then
            if DEBUG then DPrint(("Overkill_Exploder: Removing due to Target_Multiattack_Dragon_Skeletal on %s"):format(tostring(defender))) end
            pcall(function() Osi.RemoveStatus(defender, "Overkill_Exploder") end)
        end
        return
    end
    if causeStr:find("Projectile_Disintegrate_9") or
       causeStr:find("Projectile_Disintegrate_8") or
       causeStr:find("Projectile_Disintegrate_7") or
       causeStr:find("Projectile_Disintegrate") then
        if DEBUG then DPrint(("Overkill_Exploder: Not removed due to disintegrate projectile on %s"):format(tostring(defender))) end
        return
    end

    local dmgType = NormalizeDamageType(damageType)
    local cfg = DestroyOnDeathConfig or {}
    local rules = cfg.DamageRules or {}
    local rule = rules[dmgType] or rules[dmgType:lower()] or rules[dmgType:upper()] or {}

    local chunking = (rule.chunking == true)
    local threshold = tonumber(rule.chunkThreshold) or 0
    local dmg = tonumber(damageAmount) or 0
    local hpB = tonumber(hpBefore) or 0
    local lethal = (hpB <= 0 and dmg > 0) or (hpB > 0 and dmg >= hpB)

    if not chunking then
        if DEBUG then DPrint(("Overkill_Exploder: not removed on %s because chunking is disabled for %s"):format(tostring(defender), tostring(dmgType))) end
        return
    end
    if threshold <= 0 then
        if DEBUG then DPrint(("Overkill_Exploder: not removed on %s because chunk threshold is invalid for %s (threshold=%s)"):format(tostring(defender), tostring(dmgType), tostring(threshold))) end
        return
    end
    if not lethal then
        if DEBUG then DPrint(("Overkill_Exploder: not removed on %s because hit was not lethal (type=%s amount=%s hpBefore=%s threshold=%s)"):format(tostring(defender), tostring(dmgType), tostring(dmg), tostring(hpB), tostring(threshold))) end
        return
    end
    if dmg < threshold then
        if DEBUG then DPrint(("Overkill_Exploder: not removed on %s because lethal %s damage %s is below chunk threshold %s"):format(tostring(defender), tostring(dmgType), tostring(dmg), tostring(threshold))) end
        return
    end

    -- Party members can be intercepted by the Downed system before a true death.
    -- For them, only remove Overkill_Exploder after Died actually fires.
    local isPartyLike = false
    if Osi.IsPlayer(defender) == 1 then
        isPartyLike = true
    else
        local okParty, inParty = pcall(function()
            if Osi.IsPartyMember then return Osi.IsPartyMember(defender) == 1 end
            if Osi.IsInParty then return Osi.IsInParty(defender) == 1 end
            if Osi.CharacterIsInParty then return Osi.CharacterIsInParty(defender) == 1 end
            return false
        end)
        isPartyLike = okParty and inParty or false
    end

    if isPartyLike then
        if DEBUG then DPrint(("Overkill_Exploder: party target %s met chunk threshold for %s, waiting for actual Died before removal"):format(tostring(defender), tostring(dmgType))) end
        return
    end

    local ok, has = pcall(function() return Osi.HasActiveStatus(defender, "Overkill_Exploder") end)
    if ok and has ~= 1 then
        pcall(function() Osi.ApplyStatus(defender, "Overkill_Exploder", -1.0, 1) end)
    end

    if DEBUG then DPrint(("Overkill_Exploder: removing on %s due to lethal %s damage amount=%s threshold=%s"):format(tostring(defender), tostring(dmgType), tostring(dmg), tostring(threshold))) end
    pcall(function() Osi.RemoveStatus(defender, "Overkill_Exploder") end)
end

-- Verbose per-hit tracing. This used to be hardcoded to `true`, which meant every
-- AttackedBy/Died event in the game (not just this mod's own party) built and wrote
-- a formatted debug line to the Script Extender log. That's the single biggest
-- performance cost this mod was imposing on busy combat, and because Osiris runs
-- every mod's listeners for an event synchronously, it also delayed every other
-- Script Extender mod hooked to the same events. Leave this false for normal play;
-- flip it to true only when you're actively debugging.
local DEBUG = false
DPrint = function(msg)
    if DEBUG then Ext.Utils.Print("[Damage_Destruction] " .. msg) end
end

local function RecordDestroyedItem(charGuid, item, damageType, cause)
    if DD and DD.DestructionLog and type(DD.DestructionLog.Record) == "function" then
        pcall(DD.DestructionLog.Record, charGuid, item, damageType, cause or "Death")
    end
end


-- === Exploding Death (pre-death) support ===
-- Some builds differ in AttackedBy signature; we register multiple arities below and funnel into one handler.
local function _DD_NormalizeDmgType(dt)
    if dt == nil then return "" end
    local s = tostring(dt)
    s = s:gsub("^DamageType%.", "")
    s = s:gsub("^DAMAGE_", "")
    return string.lower(s)
end

local function _DD_IsExplodeType(dt)
    dt = _DD_NormalizeDmgType(dt)
    return dt == "bludgeoning" or dt == "force" or dt == "thunder"
end

local function _DD_TryApplyExplodingDeath(defender, damageType, damageAmount, hpBefore, damageCause)
    if Osi.IsCharacter(defender) ~= 1 then return end
    local dmgType = NormalizeDamageType(damageType)
    local cfg = DestroyOnDeathConfig or {}
    local rules = cfg.DamageRules or {}
    local rule = rules[dmgType] or rules[dmgType:lower()] or rules[dmgType:upper()] or {}

    if rule.chunking == true then
        return
    end

    local step = tonumber(rule.step) or 10
    local dmg = tonumber(damageAmount) or 0
    local hpB = tonumber(hpBefore) or 0
    local lethal = (hpB <= 0 and dmg > 0) or (hpB > 0 and dmg >= hpB)
    local overkill = lethal and math.max(0, dmg - hpB) or 0
    if lethal and _DD_IsExplodeType(damageType) and step > 0 and overkill >= (step * 3) then
        if DEBUG then DPrint(("Exploding_Death: pre-death apply on %s (type=%s amount=%s hpBefore=%s overkill=%s step=%s cause=%s)")
            :format(tostring(defender), tostring(damageType), tostring(dmg), tostring(hpB), tostring(overkill), tostring(step), tostring(damageCause))) end
        Osi.ApplyStatus(defender, "Exploding_Death", 0.2, 1)
    end
end

local function _DD_ShouldRemoveExploderOnActualDeath(char)
    local hit = LastHit[char]
    if not hit then return false, nil, nil, nil end

    local dmgType = NormalizeDamageType(hit.damageType)
    local cfg = DestroyOnDeathConfig or {}
    local rules = cfg.DamageRules or {}
    local rule = rules[dmgType] or rules[dmgType:lower()] or rules[dmgType:upper()] or {}
    local chunking = (rule.chunking == true)
    local threshold = tonumber(rule.chunkThreshold) or 0
    local dmg = tonumber(hit.amount) or 0

    if not chunking or threshold <= 0 then
        return false, dmgType, dmg, threshold
    end
    if dmg < threshold then
        return false, dmgType, dmg, threshold
    end
    return true, dmgType, dmg, threshold
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

NormalizeDamageType = function(dmgType)
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
    if not DestroyOnDeathConfig then return false end

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

-- Returns { {item=guid, slot=slotName}, ... }.
local function CollectEquippedItems(charGuid, damageType)
    if type(damageType) == "string" and damageType ~= "" then
        local helper = DD and DD.EquipmentFailure and DD.EquipmentFailure.BuildDestructibleEquippedItems
        if type(helper) == "function" then
            local ok, filtered = pcall(helper, charGuid, damageType)
            if ok and type(filtered) == "table" then
                return filtered
            end
            if DEBUG then DPrint(("CollectEquippedItems: damage filter failed for %s; destroying nothing for safety"):format(tostring(damageType))) end
            return {}
        end
        if DEBUG then DPrint(("CollectEquippedItems: damage filter unavailable for %s; destroying nothing for safety"):format(tostring(damageType))) end
        return {}
    end

    local items = {}
    local seen = {}
    for _, slot in ipairs(EQUIP_SLOTS) do
        local item = Osi.GetEquippedItem(charGuid, slot)
        if item and item ~= "" and not seen[item] then
            seen[item] = true
            if not DestroyOnDeathConfig.IsItemImmune(item) then
                table.insert(items, { item = item, slot = slot })
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

-- Tells ImmersiveNudity_SE_Patch a destruction-worthy death happened even
-- though no item was destroyed, so a character who burned wearing nothing
-- is still stripped of their baked visual clothing. The patch only strips
-- slots with no real item equipped. Safe if the mod isn't installed.
local function NotifyNudityPatchNoItems(charGuid)
    if IMNSEP and IMNSEP.OnDestructionTriggered then
        pcall(IMNSEP.OnDestructionTriggered, charGuid)
    end
end

local function DestroyEquippedItems(charGuid, countToDestroy, damageType)
    local items = CollectEquippedItems(charGuid, damageType)
    local total = #items
    if DEBUG then DPrint(("DestroyEquippedItems: destructible=%d count=%d damageType=%s"):format(total, countToDestroy, tostring(damageType))) end
    if countToDestroy == 0 then return end
    if total == 0 then
        NotifyNudityPatchNoItems(charGuid)
        return
    end

    pcall(function() Osi.PlayEffect(charGuid, VFX_DESTROY, "", 1.0) end)

    if countToDestroy < 0 or countToDestroy >= total then
        for _, entry in ipairs(items) do
            RecordDestroyedItem(charGuid, entry.item, damageType, "Death")
            Osi.Unequip(charGuid, entry.item)
            Osi.RequestDelete(entry.item)
            NotifyNudityPatch(charGuid, entry.slot)
        end
        return
    end

    for _=1, math.min(countToDestroy, total) do
        if #items == 0 then break end
        local idx = Ext.Utils.Random(1, #items)
        local entry = items[idx]
        RecordDestroyedItem(charGuid, entry.item, damageType, "Death")
        Osi.Unequip(charGuid, entry.item)
        Osi.RequestDelete(entry.item)
        NotifyNudityPatch(charGuid, entry.slot)
        table.remove(items, idx)
    end
end

--
-- DestroyBreastItem
--
-- Specialized item destruction for slashing damage overkill.  When a character
-- is killed by slashing damage and the overkill thresholds are met, we only
-- want to destroy the item equipped in the Breast slot instead of picking a
-- random item.  This helper checks the Breast slot, verifies the item is not
-- immune to destruction, plays the destruction visual effect, unequips it,
-- and deletes it.  If nothing is equipped in that slot, or the item is
-- immune, nothing happens.
--
-- @param charGuid (guid) The character whose breast slot item should be destroyed.
local function DestroyBreastItem(charGuid, damageType)
    -- Validate input and ensure we have a character.
    if not charGuid or Osi.IsCharacter(charGuid) ~= 1 then return end
    -- Fetch whatever is currently equipped in the Breast slot.  The slot name
    -- "Breast" corresponds to chest armor in Baldur's Gate 3.
    local item = Osi.GetEquippedItem(charGuid, "Breast")
    if not item or item == "" then
        return
    end
    -- Respect immunity rules (e.g. legendaries/adamantine/custom immune list).
    if DestroyOnDeathConfig and type(DestroyOnDeathConfig.IsItemImmune) == "function" then
        if DestroyOnDeathConfig.IsItemImmune(item) then
            return
        end
    end
    if type(damageType) == "string" and damageType ~= "" then
        local helper = DD and DD.EquipmentFailure and DD.EquipmentFailure.CanDestroyItemWithDamage
        if type(helper) == "function" then
            local ok, canDestroy = pcall(helper, charGuid, item, "Breast", damageType)
            if not ok or canDestroy ~= true then
                return
            end
        else
            return
        end
    end
    -- Play the same destruction VFX used for random destruction.
    pcall(function()
        Osi.PlayEffect(charGuid, VFX_DESTROY, "", 1.0)
    end)
    -- Unequip and permanently remove the item.
    RecordDestroyedItem(charGuid, item, damageType, "Death")
    Osi.Unequip(charGuid, item)
    Osi.RequestDelete(item)
    NotifyNudityPatch(charGuid, "Breast")
end

local function ComputeItemsToDestroy(charGuid)
    -- Determine how many items (if any) should be destroyed when this character dies.
    -- This function has been tightened up to avoid unintended destruction.  It now
    -- requires a valid hit record with positive overkill and honours per‑type
    -- thresholds for both "all" and "random" modes.  A non‑positive step is
    -- treated as disabling destruction for that damage type.
    if not DestroyOnDeathConfig or not DestroyOnDeathConfig.Enabled then return 0 end
    local hit = LastHit[charGuid]
    -- No hit information?  Do not destroy anything.
    if not hit then return 0 end

    -- Normalise the damage type and extract overkill.  Default to zero if the
    -- values are missing or malformed.
    local dmgType = NormalizeDamageType(hit.damageType)
    local overkill = tonumber(hit.overkill) or 0
    if overkill <= 0 then
        -- If there was no overkill, there is no justification for item destruction.
        return 0
    end

    local cfg = DestroyOnDeathConfig or {}
    local rules = cfg.DamageRules or {}
    -- Lookup the per‑type rule; attempt multiple casings for robustness
    local rule = rules[dmgType] or rules[dmgType:lower()] or rules[dmgType:upper()] or {}
    local mode = tostring(rule.mode or "none"):lower()
    -- Determine the per‑type overkill step used for random destruction tiers.
    local step = tonumber(rule.step)
    if step == nil then step = 0 end
    local stackingEnabled = rule.stacking
    if stackingEnabled == nil then stackingEnabled = cfg.StackingEnabled end

    if DEBUG then DPrint(("ComputeItemsToDestroy: raw=%s norm=%s mode=%s overkill=%s step=%s stacking=%s")
        :format(tostring(hit.damageType), tostring(dmgType), tostring(mode), tostring(overkill), tostring(step), tostring(stackingEnabled))) end

    -- Mode "none": explicitly disable item destruction for this damage type.
    if mode == "none" then return 0 end

    -- Mode "all": destroy all equipped items only when overkill meets the step threshold.
    -- If no step is set (<= 0), treat it as disabling destruction.  This prevents
    -- unexpected full destruction when the configuration is mis‑specified.
    if mode == "all" then
        if step > 0 and overkill >= step then
            return -1
        end
        return 0
    end

    -- Only handle random mode here; any other value falls back to no destruction.
    if mode ~= "random" then
        return 0
    end

    -- A non‑positive step disables random destruction entirely.  Historically this
    -- returned one item, but that caused unintended destruction when users
    -- configured step=0 to disable the feature.  Now it returns zero items.
    if step <= 0 then
        return 0
    end
    -- If the overkill does not meet the first step, destroy nothing.
    if overkill < step then
        return 0
    end
    -- The first tier destroys one item; additional tiers add one more item
    -- for each full step of overkill beyond the initial threshold when stacking
    -- is enabled.
    local tiers = 1
    if stackingEnabled then
        tiers = tiers + math.floor(math.max(0, overkill - step) / step)
    end
    return math.max(1, tiers)
end

local function _DD_GetElementalPermadeathDecision(hit)
    if type(hit) ~= "table" then
        return false, "missing_hit", nil, 0, 0, "none", 0
    end

    local dmgType = NormalizeDamageType(hit.damageType)
    local amount = tonumber(hit.amount) or 0
    local overkill = tonumber(hit.overkill) or 0
    local cfg = DestroyOnDeathConfig or {}
    local mode = tostring(cfg.ElementalPermadeathMode or "death"):lower()
    local threshold = tonumber(cfg.ElementalPermadeathOverkillThreshold) or 10
    if threshold < 1 then threshold = 1 end

    if not ELEMENTAL_PERMADEATH_TYPES[dmgType] then
        return false, "damage_type", dmgType, amount, overkill, mode, threshold
    end

    if amount <= 0 then
        return false, "non_positive_damage", dmgType, amount, overkill, mode, threshold
    end

    if mode == "none" then
        return false, "mode_none", dmgType, amount, overkill, mode, threshold
    end

    if mode == "death" then
        return true, "mode_death", dmgType, amount, overkill, mode, threshold
    end

    if mode == "overkill" then
        if overkill >= threshold then
            return true, "mode_overkill", dmgType, amount, overkill, mode, threshold
        end
        return false, "overkill_below_threshold", dmgType, amount, overkill, mode, threshold
    end

    return false, "unknown_mode", dmgType, amount, overkill, mode, threshold
end

Ext.Osiris.RegisterListener("AttackedBy", 7, "before", function(defender, attackerOwner, attacker, _, _, _, _)
    if Osi.IsCharacter(defender) == 1 then
        PendingHPBefore[defender] = Osi.GetHitpoints(defender) or 0
        LastHit[defender] = LastHit[defender] or {}
        LastHit[defender].attackerOwner = attackerOwner
        LastHit[defender].attacker = attacker
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
    LastHit[defender] = { damageType=damageType, amount=damageAmount or 0, overkill=overkill, cause=damageCause, attackerOwner=(LastHit[defender] and LastHit[defender].attackerOwner), attacker=(LastHit[defender] and LastHit[defender].attacker) }

    -- Remove Overkill_Exploder if lethal conditions are met.  This will trigger
    -- the explosion functors on removal.  Always removes on the
    -- Target_Multiattack_Dragon_Skeletal spell, never removes on Disintegrate projectiles.
    _DD_TryRemoveOverkillExploder(defender, damageType, damageAmount, hpBefore, damageCause)
    -- Legacy support: still attempt to apply Exploding_Death status for backward
    -- compatibility with older mods that might rely on the status itself.
    _DD_TryApplyExplodingDeath(defender, damageType, damageAmount, hpBefore, damageCause)
    if DEBUG then DPrint(("AttackedBy: def=%s dmgType=%s amount=%s cause=%s hpBefore=%s overkill=%s")
        :format(tostring(defender), tostring(damageType), tostring(damageAmount), tostring(damageCause), tostring(hpBefore), tostring(overkill))) end
end)

Ext.Osiris.RegisterListener("Died", 1, "after", function(char)
    if DEBUG then DPrint("Died: " .. tostring(char)) end
    if DEBUG then DPrint(("CFGDBG Scope=%s BludgeoningStep=%s BludgeoningChunking=%s BludgeoningChunkThreshold=%s ForceStep=%s ForceChunking=%s ForceChunkThreshold=%s ThunderStep=%s ThunderChunking=%s ThunderChunkThreshold=%s")
        :format(
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.AffectScope),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Bludgeoning and DestroyOnDeathConfig.DamageRules.Bludgeoning.step),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Bludgeoning and DestroyOnDeathConfig.DamageRules.Bludgeoning.chunking),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Bludgeoning and DestroyOnDeathConfig.DamageRules.Bludgeoning.chunkThreshold),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Force and DestroyOnDeathConfig.DamageRules.Force.step),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Force and DestroyOnDeathConfig.DamageRules.Force.chunking),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Force and DestroyOnDeathConfig.DamageRules.Force.chunkThreshold),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Thunder and DestroyOnDeathConfig.DamageRules.Thunder.step),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Thunder and DestroyOnDeathConfig.DamageRules.Thunder.chunking),
            tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.DamageRules and DestroyOnDeathConfig.DamageRules.Thunder and DestroyOnDeathConfig.DamageRules.Thunder.chunkThreshold)
        )) end
    if DEBUG then DPrint("SCOPE=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.AffectScope) .. " IsPlayer=" .. tostring(Osi.IsPlayer(char)) .. " IsCharacter=" .. tostring(Osi.IsCharacter(char))) end
    if not IsAffectedCharacter(char) then
        if DEBUG then DPrint("Died: not in scope") end
        _DD_ClearDamageContext(char)
        return
    end
    local removeExploder, chunkType, chunkAmount, chunkThreshold = _DD_ShouldRemoveExploderOnActualDeath(char)
    if removeExploder then
        if DEBUG then DPrint(("Overkill_Exploder: actual-death removal on %s type=%s amount=%s threshold=%s"):format(tostring(char), tostring(chunkType), tostring(chunkAmount), tostring(chunkThreshold))) end
        pcall(function() Osi.RemoveStatus(char, "Overkill_Exploder") end)
    end

    -- Apply our Raise Dead block status if the last hit that killed this character
    -- was one of the destructive elemental types. We reuse the LastHit table from
    -- Damage_Destruction to determine the damage type that dealt the final blow.
    local hit = LastHit[char]
    if hit then
        local shouldApply, reason, dmgType, amount, overkill, mode, threshold = _DD_GetElementalPermadeathDecision(hit)
        if shouldApply then
            Osi.ApplyStatus(char, "DD_DEATH_BLOCKS_RAISE_DEAD_4", -1, 1)
            pcall(function() Osi.RemoveStatus(char, "DEAD_ONE_MINUTE") end)
            pcall(function() Osi.RemoveStatus(char, "DEAD_TECHNICAL") end)
            pcall(function() Osi.RemoveStatus(char, "DEAD_COMBAT_BLOCK") end)
            if DEBUG then DPrint(("Elemental permadeath applied: char=%s type=%s amount=%s overkill=%s mode=%s threshold=%s")
                :format(tostring(char), tostring(dmgType), tostring(amount), tostring(overkill), tostring(mode), tostring(threshold))) end
        else
            if DEBUG then DPrint(("Elemental permadeath skipped: char=%s reason=%s type=%s amount=%s overkill=%s mode=%s threshold=%s")
                :format(tostring(char), tostring(reason), tostring(dmgType), tostring(amount), tostring(overkill), tostring(mode), tostring(threshold))) end
        end
    end
    -- Continue with item destruction logic
    local count = ComputeItemsToDestroy(char)
    if count == 0 then
        _DD_ClearDamageContext(char)
        return
    end
    -- For slashing damage overkill in random mode, only destroy the Breast slot rather
    -- than selecting a random equipped item.  This ensures that slashing death
    -- always targets chest armor when it meets the configured overkill step.  If the
    -- mode for slashing is not "random", fall back to the default behavior.
    do
        local hitInfo = LastHit[char]
        if hitInfo then
            local dmgType = NormalizeDamageType(hitInfo.damageType)
            if dmgType == "Slashing" then
                -- Consult the configured rule for slashing to ensure we only intercept
                -- random destruction.  The rules table may contain entries keyed by
                -- various casings; try multiple forms for robustness.
                local cfg = DestroyOnDeathConfig or {}
                local rules = cfg.DamageRules or {}
                -- Use explicit string.lower/upper to avoid relying on string methods on raw strings
                local lowerKey = (type(dmgType) == "string") and string.lower(dmgType) or dmgType
                local upperKey = (type(dmgType) == "string") and string.upper(dmgType) or dmgType
                local rule = rules[dmgType] or rules[lowerKey] or rules[upperKey] or {}
                local mode = rule.mode or "none"
                if mode == "random" then
                    -- Only destroy the Breast slot item once when the random logic
                    -- would have destroyed at least one item.  Additional tiers are
                    -- ignored for slashing: the Breast item is the sole target.
                    DestroyBreastItem(char, dmgType)
                    _DD_ClearDamageContext(char)
                    return
                end
            end
        end
    end
    local deathDamageType = nil
    if LastHit[char] then
        deathDamageType = NormalizeDamageType(LastHit[char].damageType)
    end
    DestroyEquippedItems(char, count, deathDamageType)

    -- Clear the hit record for this character now that item destruction (if any)
    -- has been resolved.  Without this, stale hit data could incorrectly cause
    -- destruction on subsequent deaths triggered by other means (e.g. scripted
    -- deaths without an AttackedBy event).  Clearing here ensures that
    -- ComputeItemsToDestroy returns zero until a fresh hit record is recorded.
    _DD_ClearDamageContext(char)
end)

-- === Overkill_Exploder application events ===
-- Apply the Overkill_Exploder status to characters on load/spawn/party/resurrection events.
pcall(function()
    Ext.Osiris.RegisterListener("CharacterLoadedInPreset", 1, "after", function(char)
        _DD_EnsureOverkillExploder(char, "CharacterLoadedInPreset")
    end)
    Ext.Osiris.RegisterListener("CharacterMadePlayer", 1, "after", function(char)
        _DD_EnsureOverkillExploder(char, "CharacterMadePlayer")
    end)
    -- CharacterJoinedParty: (Character, Party) signature
    Ext.Osiris.RegisterListener("CharacterJoinedParty", 2, "after", function(char, party)
        _DD_EnsureOverkillExploder(char, "CharacterJoinedParty")
    end)
    Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(char)
        _DD_ClearDamageContext(char)
        _DD_EnsureOverkillExploder(char, "Resurrected")
    end)
    -- Dynamically created characters (summons, spawns)
    Ext.Osiris.RegisterListener("CharacterCreated", 1, "after", function(char)
        _DD_EnsureOverkillExploder(char, "CharacterCreated")
    end)
    -- LevelGameplayReady fires on level load and save load; ensure party members have the status.
    Ext.Osiris.RegisterListener("LevelGameplayReady", 0, "after", function()
        -- Iterate over all current characters in the region and apply the status.
        local chars = Osi.GetRegionCharacters(nil) or {}
        for i=1,#chars do
            local c = chars[i]
            _DD_EnsureOverkillExploder(c, "LevelGameplayReady")
        end
    end)
end)


-- === AttackedBy signature compatibility ===
-- Some game/script extender versions provide different param counts.
-- We register additional listeners and reuse the same PendingHPBefore/handler logic.
local function _DD_AttackedByBefore(defender, attackerOwner, attacker)
    if Osi.IsCharacter(defender) == 1 then
        PendingHPBefore[defender] = Osi.GetHitpoints(defender) or 0
        LastHit[defender] = LastHit[defender] or {}
        LastHit[defender].attackerOwner = attackerOwner
        LastHit[defender].attacker = attacker
    end
end

local function _DD_AttackedByAfter(defender, damageType, damageAmount, damageCause)
    if Osi.IsCharacter(defender) ~= 1 then return end
    local hpBefore = PendingHPBefore[defender]
    PendingHPBefore[defender] = nil
    if hpBefore == nil then
        -- Fallback: compute hit points before damage using the after‑attack hit points plus damage
        local hpAfter = Osi.GetHitpoints(defender) or 0
        hpBefore = (tonumber(hpAfter) or 0) + (tonumber(damageAmount) or 0)
    end
    -- Always try to apply exploding death when hpBefore is now defined
    if hpBefore ~= nil then
        -- Remove Overkill_Exploder if necessary, then attempt to apply Exploding_Death for compatibility
        _DD_TryRemoveOverkillExploder(defender, damageType, damageAmount, hpBefore, damageCause)
        _DD_TryApplyExplodingDeath(defender, damageType, damageAmount, hpBefore, damageCause)
    end
end

pcall(function()
    Ext.Osiris.RegisterListener("AttackedBy", 8, "before", function(defender, a,b,c,d,e,f,g) _DD_AttackedByBefore(defender, a, b) end)
    Ext.Osiris.RegisterListener("AttackedBy", 8, "after", function(defender, a,b,damageType, damageAmount, damageCause, f,g) _DD_AttackedByAfter(defender, damageType, damageAmount, damageCause) end)
end)

pcall(function()
    Ext.Osiris.RegisterListener("AttackedBy", 9, "before", function(defender, a,b,c,d,e,f,g,h) _DD_AttackedByBefore(defender, a, b) end)
    Ext.Osiris.RegisterListener("AttackedBy", 9, "after", function(defender, a,b,damageType, damageAmount, damageCause, f,g,h) _DD_AttackedByAfter(defender, damageType, damageAmount, damageCause) end)
end)
