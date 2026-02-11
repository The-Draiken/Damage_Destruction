-- ResurrectionPenalty.lua (SERVER)
-- Tiered resurrection penalty with Withers exemption and cleansing

Ext.Utils.Print("[DD ResurrectionPenalty] Loaded (Withers fixed, tier-backed)")

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local SPELLS = {
    ["Teleportation_TrueResurrection_Scroll"] = true,
    ["Teleportation_Resurrection"] = true,
}

-- Tier statuses in ascending order (EXACT IDs)
local PENALTY_TIERS = {
    "DD_RESURRECTION_PENALTY",
    "DD_RESURRECTION_PENALTY_2",
    "DD_RESURRECTION_PENALTY_3",
    "DD_RESURRECTION_PENALTY_4",
    "DD_RESURRECTION_PENALTY_5",
    "DD_RESURRECTION_PENALTY_6",
    "DD_RESURRECTION_PENALTY_7",
    "DD_RESURRECTION_PENALTY_8",
}

-- Effectively permanent
local PENALTY_DURATION = 999999

-- Character var storing the current tier
local VAR_TIER = "DD_ResPenaltyTier"

------------------------------------------------------------
-- SAFE CALL
------------------------------------------------------------
local function SafeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return res end
    return nil
end

local function IsTrackedSpell(spell)
    return SPELLS[spell] == true
end

------------------------------------------------------------
-- WITHERS DETECTION (LOCKED)
------------------------------------------------------------
local function IsWithers(charGuid)
    if not charGuid or charGuid == "" then
        return false
    end

    -- Withers dynamic instances always use this prefix
    if string.find(charGuid, "S_GLO_JergalAvatar_", 1, true) == 1 then
        return true
    end

    return false
end

------------------------------------------------------------
-- STATUS HELPERS
------------------------------------------------------------
local function RemoveAllTiers(charGuid)
    for _, status in ipairs(PENALTY_TIERS) do
        SafeCall(Osi.RemoveStatus, charGuid, status)
    end
end

local function ApplyTier(charGuid, tierIndex, sourceGuid)
    local status = PENALTY_TIERS[tierIndex]
    if not status then return end

    SafeCall(
        Osi.ApplyStatus,
        charGuid,
        status,
        PENALTY_DURATION,
        1,
        sourceGuid or charGuid
    )

    Ext.Utils.Print(string.format(
        "[DD ResurrectionPenalty] Applied tier %d (%s) to %s (source=%s)",
        tierIndex,
        status,
        tostring(charGuid),
        tostring(sourceGuid or charGuid)
    ))
end

------------------------------------------------------------
-- VAR-BACKED TIER LOGIC
------------------------------------------------------------
local function GetTier(charGuid)
    local v = SafeCall(Osi.GetVarInteger, charGuid, VAR_TIER)
    if type(v) ~= "number" then
        return 0
    end
    return v
end

local function SetTier(charGuid, value)
    SafeCall(Osi.SetVarInteger, charGuid, VAR_TIER, value)
end

local function ClearPenalty(charGuid)
    if not charGuid or charGuid == "" then return end

    RemoveAllTiers(charGuid)
    SetTier(charGuid, 0)

    Ext.Utils.Print(string.format(
        "[DD ResurrectionPenalty] Cleared all penalties from %s",
        tostring(charGuid)
    ))
end

local function IncrementAndApply(charGuid, sourceGuid)
    if not charGuid or charGuid == "" then return end

    local current = GetTier(charGuid)
    local nextTier = current + 1
    if nextTier > #PENALTY_TIERS then
        nextTier = #PENALTY_TIERS
    end

    SetTier(charGuid, nextTier)

    RemoveAllTiers(charGuid)
    ApplyTier(charGuid, nextTier, sourceGuid)
end

------------------------------------------------------------
-- LISTENERS (AFTER)
------------------------------------------------------------

-- CASTER HANDLING
Ext.Osiris.RegisterListener("UsingSpell", 5, "after",
function(caster, spell, spellType, spellElement, storyActionID)
    if not IsTrackedSpell(spell) then
        return
    end

    if IsWithers(caster) then
        Ext.Utils.Print("[DD ResurrectionPenalty] Withers cast detected: caster exempt")
        return
    end

    IncrementAndApply(caster, caster)
end)

-- TARGET HANDLING
Ext.Osiris.RegisterListener("UsingSpellOnTarget", 6, "after",
function(caster, target, spell, spellType, spellElement, storyActionID)
    if not IsTrackedSpell(spell) then
        return
    end

    if IsWithers(caster) then
        Ext.Utils.Print(string.format(
            "[DD ResurrectionPenalty] Withers resurrected target=%s : cleansing penalties",
            tostring(target)
        ))
        ClearPenalty(target)
        return
    end

    IncrementAndApply(target, caster)
end)

-- OPTIONAL fallback for odd teleport variants
-- ENABLE ONLY if you confirm a resurrection fires without UsingSpellOnTarget
--Ext.Osiris.RegisterListener("UsingSpellAtPosition", 8, "after",
--function(caster, x, y, z, spell, spellType, spellElement, storyActionID)
--    if not IsTrackedSpell(spell) then return end
--    if IsWithers(caster) then return end
--    IncrementAndApply(caster, caster)
--end)
