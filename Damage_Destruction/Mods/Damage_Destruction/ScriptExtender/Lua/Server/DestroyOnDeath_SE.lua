
-- CFG_FALLBACK_INIT: if shared config failed to load for any reason, create safe defaults
if DestroyOnDeathConfig == nil then
    DestroyOnDeathConfig = {
        Enabled = true,
        AffectScope = "all",
        StackingEnabled = true,
        IgnoreLegendaries = true,
        IgnoreAdamantine = true,
        DamageRules = {
            Acid={mode="all", step=10}, Fire={mode="all", step=10}, Cold={mode="all", step=10}, Lightning={mode="all", step=10},
            Radiant={mode="all", step=10}, Necrotic={mode="all", step=10},
            Bludgeoning={mode="random", step=10, chunking=false, chunkThreshold=30}, Force={mode="random", step=10, chunking=false, chunkThreshold=30}, Thunder={mode="random", step=10, chunking=false, chunkThreshold=30},
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
        DPrint(("Applied Overkill_Exploder to %s via %s"):format(tostring(char), tostring(src)))
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
            DPrint(("Overkill_Exploder: Removing due to Target_Multiattack_Dragon_Skeletal on %s"):format(tostring(defender)))
            pcall(function() Osi.RemoveStatus(defender, "Overkill_Exploder") end)
        end
        return
    end
    if causeStr:find("Projectile_Disintegrate_9") or
       causeStr:find("Projectile_Disintegrate_8") or
       causeStr:find("Projectile_Disintegrate_7") or
       causeStr:find("Projectile_Disintegrate") then
        DPrint(("Overkill_Exploder: Not removed due to disintegrate projectile on %s"):format(tostring(defender)))
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
        DPrint(("Overkill_Exploder: not removed on %s because chunking is disabled for %s"):format(tostring(defender), tostring(dmgType)))
        return
    end
    if threshold <= 0 then
        DPrint(("Overkill_Exploder: not removed on %s because chunk threshold is invalid for %s (threshold=%s)"):format(tostring(defender), tostring(dmgType), tostring(threshold)))
        return
    end
    if not lethal then
        DPrint(("Overkill_Exploder: not removed on %s because hit was not lethal (type=%s amount=%s hpBefore=%s threshold=%s)"):format(tostring(defender), tostring(dmgType), tostring(dmg), tostring(hpB), tostring(threshold)))
        return
    end
    if dmg < threshold then
        DPrint(("Overkill_Exploder: not removed on %s because lethal %s damage %s is below chunk threshold %s"):format(tostring(defender), tostring(dmgType), tostring(dmg), tostring(threshold)))
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
        DPrint(("Overkill_Exploder: party target %s met chunk threshold for %s, waiting for actual Died before removal"):format(tostring(defender), tostring(dmgType)))
        return
    end

    local ok, has = pcall(function() return Osi.HasActiveStatus(defender, "Overkill_Exploder") end)
    if ok and has ~= 1 then
        pcall(function() Osi.ApplyStatus(defender, "Overkill_Exploder", -1.0, 1) end)
    end

    DPrint(("Overkill_Exploder: removing on %s due to lethal %s damage amount=%s threshold=%s"):format(tostring(defender), tostring(dmgType), tostring(dmg), tostring(threshold)))
    pcall(function() Osi.RemoveStatus(defender, "Overkill_Exploder") end)
end

local DEBUG = true
DPrint = function(msg)
    if DEBUG then Ext.Utils.Print("[Damage_Destruction] " .. msg) end
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
        DPrint(("Exploding_Death: pre-death apply on %s (type=%s amount=%s hpBefore=%s overkill=%s step=%s cause=%s)")
            :format(tostring(defender), tostring(damageType), tostring(dmg), tostring(hpB), tostring(overkill), tostring(step), tostring(damageCause)))
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
local function DestroyBreastItem(charGuid)
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
    -- Play the same destruction VFX used for random destruction.
    pcall(function()
        Osi.PlayEffect(charGuid, VFX_DESTROY, "", 1.0)
    end)
    -- Unequip and permanently remove the item.
    Osi.Unequip(charGuid, item)
    Osi.RequestDelete(item)
end

local function ComputeItemsToDestroy(charGuid)
    if not DestroyOnDeathConfig or not DestroyOnDeathConfig.Enabled then return 0 end
    local hit = LastHit[charGuid]
    if not hit then return 0 end

    local dmgType = NormalizeDamageType(hit.damageType)
    local overkill = hit.overkill or 0
    local cfg = DestroyOnDeathConfig or {}
    local rules = cfg.DamageRules or {}
    -- Lookup the per‑type rule; attempt multiple casings for robustness
    local rule = rules[dmgType] or rules[dmgType:lower()] or rules[dmgType:upper()] or {}
    local mode = rule.mode or "none"
    -- Determine the per-type overkill step used for random destruction tiers.
    local step = tonumber(rule.step) or 0
    local stackingEnabled = rule.stacking
    if stackingEnabled == nil then stackingEnabled = cfg.StackingEnabled end

    DPrint(("ComputeItemsToDestroy: raw=%s norm=%s mode=%s overkill=%s step=%s stacking=%s")
      :format(tostring(hit.damageType), tostring(dmgType), tostring(mode), tostring(overkill), tostring(step), tostring(stackingEnabled)))

    -- Modes: none -> destroy nothing; all -> destroy all; random -> compute tiers
    if mode == "none" then return 0 end
    if mode == "all" then return -1 end

    -- For "random" mode, if step is zero or negative, just destroy one item
    if mode ~= "random" then return 0 end

    if step <= 0 then
        return 1
    end
    -- Random destruction now always keys off full overkill steps for that damage type.
    -- The first item requires meeting the first configured step, and each additional
    -- full step adds one more random item when stacking is enabled.
    if overkill < step then
        return 0
    end

    local tiers = 1
    if stackingEnabled then
        tiers = tiers + math.floor(math.max(0, overkill - step) / step)
    end
    return math.max(1, tiers)
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
    DPrint(("AttackedBy: def=%s dmgType=%s amount=%s cause=%s hpBefore=%s overkill=%s")
        :format(tostring(defender), tostring(damageType), tostring(damageAmount), tostring(damageCause), tostring(hpBefore), tostring(overkill)))
end)

Ext.Osiris.RegisterListener("Died", 1, "after", function(char)
    DPrint("Died: " .. tostring(char))
    DPrint(("CFGDBG Scope=%s BludgeoningStep=%s BludgeoningChunking=%s BludgeoningChunkThreshold=%s ForceStep=%s ForceChunking=%s ForceChunkThreshold=%s ThunderStep=%s ThunderChunking=%s ThunderChunkThreshold=%s")
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
        ))
    DPrint("SCOPE=" .. tostring(DestroyOnDeathConfig and DestroyOnDeathConfig.AffectScope) .. " IsPlayer=" .. tostring(Osi.IsPlayer(char)) .. " IsCharacter=" .. tostring(Osi.IsCharacter(char)))
    if not IsAffectedCharacter(char) then
        DPrint("Died: not in scope")
        return
    end
    local removeExploder, chunkType, chunkAmount, chunkThreshold = _DD_ShouldRemoveExploderOnActualDeath(char)
    if removeExploder then
        DPrint(("Overkill_Exploder: actual-death removal on %s type=%s amount=%s threshold=%s"):format(tostring(char), tostring(chunkType), tostring(chunkAmount), tostring(chunkThreshold)))
        pcall(function() Osi.RemoveStatus(char, "Overkill_Exploder") end)
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
                    DestroyBreastItem(char)
                    return
                end
            end
        end
    end
    DestroyEquippedItems(char, count)
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

