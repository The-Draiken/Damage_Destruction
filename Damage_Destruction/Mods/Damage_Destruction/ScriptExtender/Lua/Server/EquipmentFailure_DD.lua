-- Combat equipment failure for Damage Destruction.
--
-- This is intentionally separate from DestroyOnDeath_SE.lua. Death-overkill
-- destruction remains governed by DamageRules, while this module only handles
-- the MCM-controlled on-hit, on-crit, and downed equipment failure chances.

---@diagnostic disable: undefined-global

if DestroyOnDeathConfig and DestroyOnDeathConfig.EnsureDefaults then
    DestroyOnDeathConfig.EnsureDefaults()
end

local LastEquipmentFailureHit = {}
local RecentPositiveAcidDamageUntil = {}

local ACID_STATUS_DAMAGE_WINDOW_MS = 6000

local VFX_DESTROY = "VFX_Cinematic_RolanProjection_Appear_01_d5eb43de-4fce-dba6-7bc4-1aac43d5d5e1"

local EQUIP_SLOTS = {
    "Helmet", "Amulet", "Breast", "Cloak", "Belt", "Gloves", "Leggings", "Boots",
    "Ring", "Ring2",
    "Weapon", "Shield",
    "Melee Main Weapon", "Melee Offhand Weapon",
    "Ranged Main Weapon", "Ranged Offhand Weapon",
    "CampClothing", "CampShoes", "Underwear",
    "Instrument", "Torch", "Arrow"
}

local WEAPON_SLOTS = {
    "Weapon",
    "Melee Main Weapon",
    "Melee Offhand Weapon",
    "Ranged Main Weapon",
    "Ranged Offhand Weapon"
}

local function Set(values)
    local out = {}
    for _, value in ipairs(values) do
        out[value] = true
    end
    return out
end

local ALLOWED_DAMAGE = {
    LightArmor = Set({ "Acid", "Fire", "Necrotic", "Radiant", "Lightning", "Slashing" }),
    MediumArmor = Set({ "Acid", "Radiant", "Thunder", "Bludgeoning", "Necrotic" }),
    HeavyArmor = Set({ "Bludgeoning", "Thunder", "Acid", "Force", "Necrotic", "Radiant" }),
    NonArmor = Set({ "Acid", "Fire", "Necrotic", "Radiant", "Lightning", "Slashing", "Bludgeoning", "Thunder" }),
    Cloak = Set({ "Fire", "Acid", "Thunder", "Radiant", "Necrotic", "Lightning" }),
    Jewelry = Set({ "Acid", "Necrotic", "Force", "Radiant", "Thunder", "Slashing", "Bludgeoning" }),
    Shield = Set({ "Acid", "Radiant", "Thunder", "Bludgeoning", "Necrotic" }),
    SimpleWeapon = Set({ "Fire", "Acid", "Radiant", "Thunder", "Force", "Slashing", "Bludgeoning", "Necrotic" }),
    MartialWeapon = Set({ "Bludgeoning", "Thunder", "Acid", "Force", "Necrotic", "Radiant" }),
}

local FIRE_WEAK_SHIELDS = Set({
    -- Common weak, wooden, scrap, organic, or damaged shields.
    "WPN_HUM_Shield_Broken_A",
    "WPN_Kuotoa_Shield_A_0",
    "WPN_Drow_Shield_A_0",
    "WPN_Wood_Woad_Shield",
    "WPN_HUM_Shield_D_0_Rusty_A",
    "WPN_GOB_Shield_D_0_NOT_APPROVED",
    "WPN_GOB_Shield_A_0_NOT_APPROVED",
    "WPN_GOB_Shield_E_0_NOT_APPROVED",
    "WPN_HUM_Shield_D_0",
    "WPN_GOB_Shield_C_0_NOT_APPROVED",
    "WPN_HUM_Shield_A_0",
    "WPN_HUM_Toy_Shield_A",
    "WPN_HUM_Shield_C_0",
    "WPN_HUM_Shield_B_0",
    "WPN_Duergar_Shield_B_0",

    -- Named shields the player asked to make vulnerable to fire.
    "UNI_Gob_Priest_Shield",
    "GOB_Priest_Shield",
    "MAG_Druid_Ironvine_Shield",
    "UNI_TWN_WPN_HUM_ShieldOfWatcher_D_1",
    "MAG_WoodWoad_Nature_Shield",
    "WPN_Drow_Shield_A_0_Absolute",
    "WPN_HUM_Shield_B_1",
    "MAG_Justiciar_Shield",
    "MAG_PHB_Sentinel_Shield",
    "MAG_MissileProtection_Shield",
    "MAG_Steadfast_Shield",
})

local PHYSICAL_WEAPON_DAMAGE = {
    Bludgeoning = true,
    Piercing = true,
    Slashing = true,
}

local WEAPON_SLOT_SET = Set(WEAPON_SLOTS)

local SIMPLE_WEAPON_PROFICIENCIES = {
    "SimpleWeapons",
    "Daggers",
    "Handaxes",
    "LightHammers",
    "Sickles",
    "Clubs",
    "Javelins",
    "Maces",
    "Quarterstaves",
    "Spears",
    "Greatclubs",
    "LightCrossbows",
    "Shortbows",
}

local MARTIAL_WEAPON_PROFICIENCIES = {
    "MartialWeapons",
    "Scimitars",
    "Shortswords",
    "Flails",
    "Morningstars",
    "Rapiers",
    "WarPicks",
    "Battleaxes",
    "Longswords",
    "Tridents",
    "Warhammers",
    "Glaives",
    "Greataxes",
    "Greatswords",
    "Halberds",
    "Mauls",
    "Pikes",
    "HandCrossbows",
    "HeavyCrossbows",
    "Longbows",
}

local SIMPLE_WEAPON_STAT_PATTERNS = {
    "DAGGER",
    "HANDAXE",
    "HAND_AXE",
    "AXE_HAND",
    "LIGHTHAMMER",
    "LIGHT_HAMMER",
    "HAMMER_LIGHT",
    "SICKLE",
    "CLUB",
    "JAVELIN",
    "MACE",
    "QUARTERSTAFF",
    "QUARTER_STAFF",
    "SPEAR",
    "GREATCLUB",
    "GREAT_CLUB",
    "CLUB_GREAT",
    "LIGHTCROSSBOW",
    "LIGHT_CROSSBOW",
    "CROSSBOW_LIGHT",
    "SHORTBOW",
    "SHORT_BOW",
    "BOW_SHORT",
}

local MARTIAL_WEAPON_STAT_PATTERNS = {
    "SCIMITAR",
    "SHORTSWORD",
    "SHORT_SWORD",
    "SWORD_SHORT",
    "FLAIL",
    "MORNINGSTAR",
    "MORNING_STAR",
    "RAPIER",
    "WARPICK",
    "WAR_PICK",
    "PICK_WAR",
    "BATTLEAXE",
    "BATTLE_AXE",
    "AXE_BATTLE",
    "LONGSWORD",
    "LONG_SWORD",
    "SWORD_LONG",
    "TRIDENT",
    "WARHAMMER",
    "WAR_HAMMER",
    "HAMMER_WAR",
    "GLAIVE",
    "GREATAXE",
    "GREAT_AXE",
    "AXE_GREAT",
    "GREATSWORD",
    "GREAT_SWORD",
    "SWORD_GREAT",
    "HALBERD",
    "MAUL",
    "PIKE",
    "HANDCROSSBOW",
    "HAND_CROSSBOW",
    "CROSSBOW_HAND",
    "HEAVYCROSSBOW",
    "HEAVY_CROSSBOW",
    "CROSSBOW_HEAVY",
    "LONGBOW",
    "LONG_BOW",
    "BOW_LONG",
}

local FIRE_WEAK_MARTIAL_RANGED_PROFICIENCIES = {
    "Longbows",
    "HeavyCrossbows",
    "HandCrossbows",
}

local FIRE_WEAK_MARTIAL_RANGED_PATTERNS = {
    "LONGBOW",
    "LONG_BOW",
    "BOW_LONG",
    "BOWLONG",
    "HEAVYCROSSBOW",
    "HEAVY_CROSSBOW",
    "CROSSBOW_HEAVY",
    "CROSSBOWHEAVY",
    "HANDCROSSBOW",
    "HAND_CROSSBOW",
    "CROSSBOW_HAND",
    "CROSSBOWHAND",
}

local function RandomInt(minValue, maxValue)
    if Ext and Ext.Utils and type(Ext.Utils.Random) == "function" then
        local ok, value = pcall(Ext.Utils.Random, minValue, maxValue)
        if ok and type(value) == "number" then
            return value
        end
    end
    return math.random(minValue, maxValue)
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

local function NowMs()
    if Ext and Ext.Utils and type(Ext.Utils.MonotonicTime) == "function" then
        local ok, now = pcall(Ext.Utils.MonotonicTime)
        if ok and type(now) == "number" then
            return now
        end
    end
    if os and os.clock then
        local ok, now = pcall(os.clock)
        if ok and type(now) == "number" then
            return now * 1000
        end
    end
    return nil
end

local function MarkRecentPositiveAcidDamage(character, damageType)
    if NormalizeDamageType(damageType) ~= "Acid" then return end

    local now = NowMs()
    if now then
        RecentPositiveAcidDamageUntil[character] = now + ACID_STATUS_DAMAGE_WINDOW_MS
    else
        RecentPositiveAcidDamageUntil[character] = true
    end
end

local function HasRecentPositiveAcidDamage(character)
    local expiresAt = RecentPositiveAcidDamageUntil[character]
    if expiresAt == true then
        return true
    end
    if type(expiresAt) ~= "number" then
        return false
    end

    local now = NowMs()
    if not now then
        return false
    end

    if expiresAt > now then
        return true
    end

    RecentPositiveAcidDamageUntil[character] = nil
    return false
end

local function IsCharacter(guid)
    if not guid or guid == "" then return false end
    local ok, result = pcall(function()
        return Osi.IsCharacter(guid) == 1
    end)
    return ok and result == true
end

local function IsAffectedCharacter(charGuid)
    if not IsCharacter(charGuid) then return false end
    if not DestroyOnDeathConfig or DestroyOnDeathConfig.Enabled ~= true then return false end

    local scope = tostring(DestroyOnDeathConfig.AffectScope or "party"):lower()
    if scope ~= "party" then
        return true
    end

    local okPlayer, isPlayer = pcall(function()
        return Osi.IsPlayer(charGuid) == 1
    end)
    if okPlayer and isPlayer then
        return true
    end

    local okParty, inParty = pcall(function()
        if Osi.IsPartyMember then return Osi.IsPartyMember(charGuid) == 1 end
        if Osi.IsInParty then return Osi.IsInParty(charGuid) == 1 end
        if Osi.CharacterIsInParty then return Osi.CharacterIsInParty(charGuid) == 1 end
        return false
    end)
    return okParty and inParty == true
end

local function IsInCombat(character)
    local ok, result = pcall(function()
        return Osi.IsInCombat(character) == 1
    end)
    return ok and result == true
end

local function GetEquipmentFailureConfig()
    local cfg = (DestroyOnDeathConfig and DestroyOnDeathConfig.EquipmentFailure) or {}
    return {
        OnHitChance = tonumber(cfg.OnHitChance) or 0,
        OnCritChance = tonumber(cfg.OnCritChance) or 0,
        DownedChance = tonumber(cfg.DownedChance) or 0,
        DexterityDC = tonumber(cfg.DexterityDC) or 10,
        ConditionRollAdvantage = cfg.ConditionRollAdvantage ~= false,
    }
end

local function GetEquippedItem(character, slot)
    local ok, item = pcall(function()
        return Osi.GetEquippedItem(character, slot)
    end)
    if ok and item and item ~= "" then
        return item
    end
    return nil
end

local function HasProficiency(item, proficiency)
    local ok, result = pcall(function()
        return Osi.IsEquipmentWithProficiency(item, proficiency) == 1
    end)
    return ok and result == true
end

local function HasAnyProficiency(item, proficiencies)
    for _, proficiency in ipairs(proficiencies) do
        if HasProficiency(item, proficiency) then
            return true
        end
    end
    return false
end

local function IsItemImmune(item)
    if not item or item == "" then return true end
    if DestroyOnDeathConfig and type(DestroyOnDeathConfig.IsItemImmune) == "function" then
        local ok, immune = pcall(DestroyOnDeathConfig.IsItemImmune, item)
        if ok then
            return immune == true
        end
    end
    return false
end

local GetItemStatName

local function ClassifyItem(item, slot)
    if slot == "Cloak" then
        return "Cloak"
    end
    if slot == "Amulet" or slot == "Ring" or slot == "Ring2" then
        return "Jewelry"
    end
    if slot == "Shield" then
        return "Shield"
    end
    if WEAPON_SLOT_SET[slot] == true then
        if HasAnyProficiency(item, SIMPLE_WEAPON_PROFICIENCIES) then
            return "SimpleWeapon"
        end
        if HasAnyProficiency(item, MARTIAL_WEAPON_PROFICIENCIES) then
            return "MartialWeapon"
        end
    end
    if HasProficiency(item, "HeavyArmor") then
        return "HeavyArmor"
    end
    if HasProficiency(item, "MediumArmor") then
        return "MediumArmor"
    end
    if HasProficiency(item, "LightArmor") then
        return "LightArmor"
    end
    if WEAPON_SLOT_SET[slot] == true then
        local statName = GetItemStatName(item)
        if type(statName) == "string" then
            local upper = statName:upper()
            for _, pattern in ipairs(SIMPLE_WEAPON_STAT_PATTERNS) do
                if upper:find(pattern, 1, true) then
                    return "SimpleWeapon"
                end
            end
            for _, pattern in ipairs(MARTIAL_WEAPON_STAT_PATTERNS) do
                if upper:find(pattern, 1, true) then
                    return "MartialWeapon"
                end
            end
        end
        return "UnknownWeapon"
    end
    return "NonArmor"
end

GetItemStatName = function(item)
    if Ext and Ext.Entity and type(Ext.Entity.Get) == "function" then
        local ok, entity = pcall(Ext.Entity.Get, item)
        if ok and entity and entity.Data and entity.Data.StatsId and entity.Data.StatsId ~= "" then
            return entity.Data.StatsId
        end
    end
    return nil
end

local function ReadNumberPath(root, path)
    local node = root
    for _, key in ipairs(path) do
        if node == nil then return nil end
        local ok, value = pcall(function()
            return node[key]
        end)
        if not ok then return nil end
        node = value
    end
    local n = tonumber(node)
    if n and n > 0 then
        return n
    end
    return nil
end

local function GetItemWeight(item)
    if Ext and Ext.Entity and type(Ext.Entity.Get) == "function" then
        local ok, entity = pcall(Ext.Entity.Get, item)
        if ok and entity then
            local paths = {
                { "Weight", "Weight" },
                { "Weight", "Value" },
                { "Value", "Weight" },
                { "Data", "Weight" },
                { "Stats", "Weight" },
            }
            for _, path in ipairs(paths) do
                local n = ReadNumberPath(entity, path)
                if n then return n end
            end
        end
    end

    local statName = GetItemStatName(item)
    if statName and Ext and Ext.Stats and type(Ext.Stats.Get) == "function" then
        local ok, stat = pcall(Ext.Stats.Get, statName)
        if ok and stat then
            local n = ReadNumberPath(stat, { "Weight" })
            if n then return n end
        end
    end

    return 1
end

local function WeightToSelectionChance(item)
    local itemWeight = GetItemWeight(item)
    if itemWeight < 0.1 then
        itemWeight = 0.1
    end
    local selectionWeight = math.floor(100 / itemWeight)
    if selectionWeight < 1 then selectionWeight = 1 end
    if selectionWeight > 250 then selectionWeight = 250 end
    return selectionWeight
end

local function HasEquippedWeapon(character)
    if not IsCharacter(character) then return false end
    for _, slot in ipairs(WEAPON_SLOTS) do
        if GetEquippedItem(character, slot) then
            return true
        end
    end
    return false
end

local function IsWeaponAttack(hit)
    if type(hit) ~= "table" then return false end
    local cause = tostring(hit.damageCause or ""):upper()
    if cause == "ATTACK" or cause == "OFFHAND" then
        return true
    end
    if cause:find("WEAPON", 1, true) or cause:find("MELEE", 1, true) or cause:find("RANGED", 1, true) then
        return true
    end
    local damageType = NormalizeDamageType(hit.damageType)
    if not PHYSICAL_WEAPON_DAMAGE[damageType] then
        return false
    end
    return HasEquippedWeapon(hit.attacker) or HasEquippedWeapon(hit.attackerOwner)
end

local function ClampDC(dc)
    local clampedDC = tonumber(dc) or 10
    if clampedDC < 1 then clampedDC = 1 end
    if clampedDC > 30 then clampedDC = 30 end
    return clampedDC
end

local function GetAbilityScore(character, ability)
    if Osi and type(Osi.GetAbility) == "function" then
        local ok, value = pcall(Osi.GetAbility, character, ability)
        if ok and tonumber(value) then
            return tonumber(value)
        end
    end
    return 10
end

local function AbilityModifier(score)
    return math.floor(((tonumber(score) or 10) - 10) / 2)
end

local function RollD20(useAdvantage)
    local roll = RandomInt(1, 20)
    if useAdvantage == true then
        local secondRoll = RandomInt(1, 20)
        if secondRoll > roll then
            roll = secondRoll
        end
    end
    return roll
end

local function PassesDexterityRoll(character, dc)
    local clampedDC = ClampDC(dc)
    local score = GetAbilityScore(character, "Dexterity")
    local modifier = math.floor((score - 10) / 2)
    local roll = RandomInt(1, 20)
    return (roll + modifier) >= clampedDC
end

local function PassesConditionEquipmentRoll(character, dc, useAdvantage)
    local clampedDC = ClampDC(dc)
    local dexterity = GetAbilityScore(character, "Dexterity")
    return (RollD20(useAdvantage) + AbilityModifier(dexterity)) >= clampedDC
end

local function IsDamageAllowed(itemClass, damageType)
    local allowed = ALLOWED_DAMAGE[itemClass]
    return allowed ~= nil and allowed[damageType] == true
end

local function IsFireWeakShield(item)
    local statName = GetItemStatName(item)
    return type(statName) == "string" and FIRE_WEAK_SHIELDS[statName] == true
end

local function IsFireWeakMartialRangedWeapon(item)
    if HasAnyProficiency(item, FIRE_WEAK_MARTIAL_RANGED_PROFICIENCIES) then
        return true
    end

    local statName = GetItemStatName(item)
    if type(statName) ~= "string" then
        return false
    end

    local upper = statName:upper()
    for _, pattern in ipairs(FIRE_WEAK_MARTIAL_RANGED_PATTERNS) do
        if upper:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local DestroyCandidate

local function BuildWeightedEquippedItems(character, hit)
    local candidates = {}
    local seen = {}
    local weaponAttack = IsWeaponAttack(hit)

    for _, slot in ipairs(EQUIP_SLOTS) do
        local item = GetEquippedItem(character, slot)
        if item and not seen[item] then
            seen[item] = true
            local selectionWeight = WeightToSelectionChance(item)
            if weaponAttack and slot == "Breast" then
                selectionWeight = selectionWeight * 4
            end
            table.insert(candidates, {
                item = item,
                slot = slot,
                weight = selectionWeight,
            })
        end
    end

    return candidates
end

local function CanDestroySelectedItem(character, candidate, hit)
    if not candidate or not candidate.item then return false end

    local damageType = NormalizeDamageType(hit and hit.damageType)
    if damageType == "" then return false end

    if IsItemImmune(candidate.item) then
        return false
    end

    if (candidate.slot == "Ring" or candidate.slot == "Ring2") and GetEquippedItem(character, "Gloves") ~= nil then
        return false
    end

    local itemClass = ClassifyItem(candidate.item, candidate.slot)
    if itemClass == "Shield" and damageType == "Fire" and IsFireWeakShield(candidate.item) then
        return true
    end
    if itemClass == "MartialWeapon" and damageType == "Fire" and IsFireWeakMartialRangedWeapon(candidate.item) then
        return true
    end

    return IsDamageAllowed(itemClass, damageType)
end

DD = DD or {}
DD.EquipmentFailure = DD.EquipmentFailure or {}

function DD.EquipmentFailure.CanDestroyItemWithDamage(character, item, slot, damageType)
    return CanDestroySelectedItem(character, { item = item, slot = slot }, { damageType = damageType, damageCause = "DamageDestruction" })
end

-- Returns { {item=guid, slot=slotName}, ... } -- the slot travels alongside
-- the item guid (rather than a flat item-guid list) so callers that go on
-- to actually destroy the item, like DestroyOnDeath_SE.lua, can tell
-- ImmersiveNudity_SE_Patch which slot was hit without having to re-derive
-- it after the fact.
function DD.EquipmentFailure.BuildDestructibleEquippedItems(character, damageType)
    local hit = { damageType = damageType, damageCause = "DamageDestruction" }
    local candidates = BuildWeightedEquippedItems(character, hit)
    local items = {}

    for _, candidate in ipairs(candidates) do
        if CanDestroySelectedItem(character, candidate, hit) then
            table.insert(items, { item = candidate.item, slot = candidate.slot })
        end
    end

    return items
end

local function ProcessAllEquippedItemsForDamage(character, damageType)
    if not IsAffectedCharacter(character) then return false end

    local hit = { damageType = damageType, damageCause = "StatusCondition" }
    local candidates = BuildWeightedEquippedItems(character, hit)
    local destroyedAny = false
    local cfg = GetEquipmentFailureConfig()

    for _, candidate in ipairs(candidates) do
        if not PassesConditionEquipmentRoll(character, cfg.DexterityDC, cfg.ConditionRollAdvantage) then
            if CanDestroySelectedItem(character, candidate, hit) then
                destroyedAny = DestroyCandidate(character, candidate, hit) or destroyedAny
            end
        end
    end

    return destroyedAny
end

local function HasStatus(character, status)
    local ok, result = pcall(function()
        return Osi.HasActiveStatus(character, status) == 1
    end)
    return ok and result == true
end

local function IsStatus(status, expected)
    return type(status) == "string" and status:upper() == expected
end

local function RecordDestroyedItem(character, item, hit)
    if DD and DD.DestructionLog and type(DD.DestructionLog.Record) == "function" then
        pcall(DD.DestructionLog.Record, character, item, hit and hit.damageType, hit and hit.damageCause or "EquipmentFailure")
    end
end

local function SelectWeightedCandidate(candidates)
    local totalWeight = 0
    for _, candidate in ipairs(candidates) do
        totalWeight = totalWeight + (tonumber(candidate.weight) or 0)
    end
    if totalWeight <= 0 then return nil end

    local roll = RandomInt(1, totalWeight)
    local running = 0
    for _, candidate in ipairs(candidates) do
        running = running + (tonumber(candidate.weight) or 0)
        if roll <= running then
            return candidate
        end
    end

    return candidates[#candidates]
end

DestroyCandidate = function(character, candidate, hit)
    if not candidate or not candidate.item then return false end
    RecordDestroyedItem(character, candidate.item, hit)
    pcall(function()
        Osi.PlayEffect(character, VFX_DESTROY, "", 1.0)
    end)
    pcall(function()
        Osi.Unequip(character, candidate.item)
    end)
    pcall(function()
        Osi.RequestDelete(candidate.item)
    end)
    -- Direct call into ImmersiveNudity_SE_Patch, when it's loaded, so it can
    -- instantly strip the corresponding baked visual slot without needing
    -- to watch every Equipped/Unequipped event in the game itself. Safe to
    -- call whether or not that mod is installed.
    if IMNSEP and IMNSEP.OnItemDestroyed then
        pcall(IMNSEP.OnItemDestroyed, character, candidate.slot)
    end
    return true
end

local function AttemptEquipmentFailure(character, chancePercent, hit)
    if not IsAffectedCharacter(character) then return false end
    if not IsInCombat(character) then return false end

    local chance = tonumber(chancePercent) or 0
    if chance <= 0 then return false end
    if chance > 100 then chance = 100 end

    if RandomInt(1, 100) > chance then
        return false
    end

    local cfg = GetEquipmentFailureConfig()
    if PassesDexterityRoll(character, cfg.DexterityDC) then
        return false
    end

    local candidates = BuildWeightedEquippedItems(character, hit)
    local candidate = SelectWeightedCandidate(candidates)
    if not candidate then
        return false
    end
    if not CanDestroySelectedItem(character, candidate, hit) then
        return false
    end

    return DestroyCandidate(character, candidate, hit)
end

local function StoreLastHit(defender, attackerOwner, attacker, damageType, damageAmount, damageCause)
    if not IsCharacter(defender) then return end
    local amount = tonumber(damageAmount) or 0
    if amount <= 0 then
        LastEquipmentFailureHit[defender] = nil
        return nil
    end

    MarkRecentPositiveAcidDamage(defender, damageType)

    LastEquipmentFailureHit[defender] = {
        attackerOwner = attackerOwner,
        attacker = attacker,
        damageType = damageType,
        damageAmount = amount,
        damageCause = damageCause,
    }
    return LastEquipmentFailureHit[defender]
end

local function IsMatchingCriticalHit(character, attackOwner, attacker, hit)
    if type(hit) ~= "table" then return false end
    if character == nil then return false end
    if attackOwner == nil and attacker == nil then return true end
    return hit.attackerOwner == attackOwner
        or hit.attacker == attacker
        or hit.attackerOwner == attacker
        or hit.attacker == attackOwner
end

local function HandleAttackedBy(defender, attackerOwner, attacker, damageType, damageAmount, damageCause)
    -- AttackedBy fires for every hit landed by anyone on anyone, anywhere in the game
    -- (monsters hitting monsters included), not just hits against party-scope targets.
    -- Checking scope first, before StoreLastHit/GetEquipmentFailureConfig allocate
    -- anything, lets the vast majority of hits during a big fight bail out immediately
    -- instead of doing bookkeeping work whose result will never be used.
    if not IsAffectedCharacter(defender) then return end
    local hit = StoreLastHit(defender, attackerOwner, attacker, damageType, damageAmount, damageCause)
    if type(hit) ~= "table" then return end
    local cfg = GetEquipmentFailureConfig()
    AttemptEquipmentFailure(defender, cfg.OnHitChance, hit)
end

local function HandleCriticalHit(defender, attackOwner, attacker)
    if not IsAffectedCharacter(defender) then return end
    local hit = LastEquipmentFailureHit[defender]
    if not IsMatchingCriticalHit(defender, attackOwner, attacker, hit) then
        return
    end
    local cfg = GetEquipmentFailureConfig()
    AttemptEquipmentFailure(defender, cfg.OnCritChance, hit)
end

local function HandleDownedChanged(character, isDowned)
    if tonumber(isDowned) ~= 1 then return end
    if not IsAffectedCharacter(character) then return end

    local hit = LastEquipmentFailureHit[character]
    if type(hit) ~= "table" then return end

    local cfg = GetEquipmentFailureConfig()
    AttemptEquipmentFailure(character, cfg.DownedChance, hit)
end

Ext.Osiris.RegisterListener("AttackedBy", 7, "after", function(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, _)
    HandleAttackedBy(defender, attackerOwner, attacker, damageType, damageAmount, damageCause)
end)

pcall(function()
    Ext.Osiris.RegisterListener("AttackedBy", 8, "after", function(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, _, _)
        HandleAttackedBy(defender, attackerOwner, attacker, damageType, damageAmount, damageCause)
    end)
end)

pcall(function()
    Ext.Osiris.RegisterListener("AttackedBy", 9, "after", function(defender, attackerOwner, attacker, damageType, damageAmount, damageCause, _, _, _)
        HandleAttackedBy(defender, attackerOwner, attacker, damageType, damageAmount, damageCause)
    end)
end)

Ext.Osiris.RegisterListener("CriticalHitBy", 4, "after", function(defender, attackOwner, attacker, _)
    HandleCriticalHit(defender, attackOwner, attacker)
end)

Ext.Osiris.RegisterListener("DownedChanged", 2, "before", function(character, isDowned)
    HandleDownedChanged(character, isDowned)
end)

Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(character, status, _, _)
    if IsStatus(status, "ACID") then
        if HasRecentPositiveAcidDamage(character) then
            ProcessAllEquippedItemsForDamage(character, "Acid")
        elseif Ext and Ext.Timer and type(Ext.Timer.WaitFor) == "function" then
            Ext.Timer.WaitFor(100, function()
                if HasRecentPositiveAcidDamage(character) then
                    ProcessAllEquippedItemsForDamage(character, "Acid")
                end
            end)
        end
    end
end)

Ext.Osiris.RegisterListener("TurnEnded", 1, "before", function(character)
    if HasStatus(character, "BURNING") then
        ProcessAllEquippedItemsForDamage(character, "Fire")
    end
end)

pcall(function()
    Ext.Osiris.RegisterListener("Died", 1, "after", function(character)
        LastEquipmentFailureHit[character] = nil
        RecentPositiveAcidDamageUntil[character] = nil
    end)
    Ext.Osiris.RegisterListener("Resurrected", 1, "after", function(character)
        LastEquipmentFailureHit[character] = nil
        RecentPositiveAcidDamageUntil[character] = nil
    end)
end)
