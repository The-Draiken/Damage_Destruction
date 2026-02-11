-- DeathBlock_PetrifyDisintegrate.lua (final: disintegrate works + petrify->shatter works)
-- Goal:
--   Apply DD_DEATH_BLOCKS_RAISE_DEAD_Hidden ONLY for "ash-body" deaths:
--     A) Death caused by Projectile_Disintegrate (windowed)
--     B) Death that happens right after petrification is removed (shatter into ash)
--        (This is reliable even when StatusApplied didn't fire or petrify happened long before.)
--
-- Notes:
--   - We DO NOT apply Hidden while the target is merely PETRIFIED (alive).
--   - We DO NOT remove Hidden on basilisk oil / greater restoration here.
--     (Resurrection removes the block via your spell edits / Teleported hook.)
--
-- Drop into: ScriptExtender/Lua/Server/DeathBlock_PetrifyDisintegrate.lua
-- Ensure it is required from BootstrapServer.lua (or your main server lua)

local MOD_PREFIX = "[DD]"
local HIDDEN_BLOCK = "DD_DEATH_BLOCKS_RAISE_DEAD_Hidden"

local DISINTEGRATE_SPELL = "Projectile_Disintegrate"

-- Tracks (uuid -> true) if we saw a petrify-like status applied during runtime (helpful, but not relied on)
local PetrifiedMark = {}

-- Tracks (uuid -> expiresMs) if we saw disintegrate targeting; if death occurs within window -> ash-death
local PendingDisintegrate = {}

-- Tracks (uuid -> expiresMs) if we saw petrify-like status removed; if death occurs soon after -> ash-death
-- This is the key fix for "petrified then killed" (PETRIFIED often clears before Died).
local RecentPetrifyRemoved = {}

local function NowMs()
    return Ext.Utils.MonotonicTime()
end

local function ExtractUUID(obj)
    if not obj then return nil end
    local s = tostring(obj)
    return s:match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
end

local function GetUUIDSafe(obj)
    local u = ExtractUUID(obj)
    if u and u ~= "" then return u end
    local ok, v = pcall(function() return Osi.GetUUID(obj) end)
    if ok and v and v ~= "" then return v end
    return nil
end


-- Destroy every equipped item on the target (used for ash-body deaths).
local function DestroyAllEquippedItems(target)
    if not target or target == "" then return end

    local destroyed = 0

    -- Preferred: GetEquippedItems if available in this environment
    local okList, equippedList = pcall(function() return Osi.GetEquippedItems(target) end)
    if okList and equippedList then
        for _, item in pairs(equippedList) do
            if item and item ~= "" and item ~= "NULL_00000000-0000-0000-0000-000000000000" then
                local okDestroy = pcall(function() Osi.DestroyItem(item, 1) end)
                if not okDestroy then
                    pcall(function() Osi.RequestDelete(item) end)
                end
                destroyed = destroyed + 1
            end
        end
        Ext.Utils.Print(string.format("%s HiddenDeath: destroyed %d equipped items on %s", MOD_PREFIX, destroyed, tostring(target)))
        return
    end

    -- Fallback: iterate common equipment slots
    local slots = {
        "Helmet","Cloak","Breast","Gloves","Boots",
        "Amulet","Ring","Ring2",
        "Melee Main Weapon","Melee Offhand Weapon",
        "Ranged Main Weapon","Ranged Offhand Weapon",
        "Shield","Instrument",
        "Underwear","Camp Clothing","Camp Shoes"
    }

    for _, slot in ipairs(slots) do
        local item = nil
        pcall(function() item = Osi.GetEquippedItem(target, slot) end)
        if item and item ~= "" and item ~= "NULL_00000000-0000-0000-0000-000000000000" then
            local okDestroy = pcall(function() Osi.DestroyItem(item, 1) end)
            if not okDestroy then
                pcall(function() Osi.RequestDelete(item) end)
            end
            destroyed = destroyed + 1
        end
    end

    Ext.Utils.Print(string.format("%s HiddenDeath: destroyed %d equipped items on %s", MOD_PREFIX, destroyed, tostring(target)))
end

local function ApplyHidden(target, reason)
    if not target or target == "" then return end

    local has = 0
    pcall(function() has = Osi.HasActiveStatus(target, HIDDEN_BLOCK) end)
    if has == 1 then
        Ext.Utils.Print(string.format("%s ApplyHidden skipped (already has): %s (%s)", MOD_PREFIX, tostring(target), tostring(reason)))
        return
    end

    -- NEW: ash-body deaths destroy all equipped items when the hidden block is applied
    DestroyAllEquippedItems(target)

    Ext.Utils.Print(string.format("%s APPLY %s -> %s (%s)", MOD_PREFIX, HIDDEN_BLOCK, tostring(target), tostring(reason)))
    pcall(function()
        Osi.ApplyStatus(target, HIDDEN_BLOCK, -1, 1, target)
    end)
end

local function IsPetrifyLikeStatus(status)
    local st = tostring(status or "")
    -- Covers PETRIFIED + Flesh to Stone and any variants containing PETRIF
    return st:find("PETRIF") ~= nil or st:find("FLESH_TO_STONE") ~= nil
end

Ext.Utils.Print(MOD_PREFIX .. " DeathBlock_PetrifyDisintegrate.lua LOADED (server)")

-- =========================================================
-- PETRIFY tracking (best-effort)
-- =========================================================
Ext.Osiris.RegisterListener("StatusApplied", 4, "after", function(target, status, instigator, storyActionID)
    if not target or target == "" then return end
    if not IsPetrifyLikeStatus(status) then return end

    local uuid = GetUUIDSafe(target)
    Ext.Utils.Print(string.format("%s PetrifyMark SET: target=%s status=%s uuid=%s", MOD_PREFIX, tostring(target), tostring(status), tostring(uuid)))
    if uuid then
        PetrifiedMark[uuid] = true
    end
end)

-- This is the RELIABLE signal for "petrified then shattered":
-- BG3 removes petrify right before (or as part of) converting to ash, then death happens.
Ext.Osiris.RegisterListener("StatusRemoved", 4, "after", function(target, status, instigator, storyActionID)
    if not target or target == "" then return end
    if not IsPetrifyLikeStatus(status) then return end

    local uuid = GetUUIDSafe(target)
    Ext.Utils.Print(string.format("%s Petrify REMOVED: status=%s target=%s uuid=%s (arming death flag)",
        MOD_PREFIX, tostring(status), tostring(target), tostring(uuid)
    ))
    if uuid then
        -- Arm a short window: if death follows soon, treat as “ash death”.
        -- 2500ms is conservative; if your setup is slower, bump to 4000.
        RecentPetrifyRemoved[uuid] = NowMs() + 2500

        -- Also clear the long-lived mark after a delay if no death occurs (cure case).
        Ext.Timer.WaitFor(3000, function()
            -- If they didn't die in the window, clean up.
            local exp = RecentPetrifyRemoved[uuid]
            if exp and exp <= NowMs() then
                RecentPetrifyRemoved[uuid] = nil
            end
            PetrifiedMark[uuid] = nil
        end)
    end
end)

-- =========================================================
-- DISINTEGRATE tracking (death-only window)
-- =========================================================
Ext.Osiris.RegisterListener("UsingSpellOnTarget", 6, "after",
function(caster, target, spell, spellType, spellElement, storyActionID)
    if tostring(spell) ~= DISINTEGRATE_SPELL then return end
    if not target or target == "" then return end

    local uuid = GetUUIDSafe(target)
    Ext.Utils.Print(string.format("%s Disintegrate MARK: target=%s uuid=%s", MOD_PREFIX, tostring(target), tostring(uuid)))
    if uuid then
        -- 8s window to be safe around delayed death resolution
        PendingDisintegrate[uuid] = NowMs() + 8000
    end
end)

-- Backup logging (helps confirm spell fires even if OnTarget is weird in some setups)
Ext.Osiris.RegisterListener("UsingSpell", 5, "after",
function(caster, spell, spellType, spellElement, storyActionID)
    if tostring(spell) == DISINTEGRATE_SPELL then
        Ext.Utils.Print(string.format("%s Disintegrate CAST (UsingSpell): caster=%s", MOD_PREFIX, tostring(caster)))
    end
end)

-- =========================================================
-- DEATH handling (arity-safe)
-- =========================================================
local function OnDied(deadChar, killer, extra)
    Ext.Utils.Print(string.format("%s DIED handler fired: dead=%s killer=%s extra=%s",
        MOD_PREFIX, tostring(deadChar), tostring(killer), tostring(extra)
    ))

    if not deadChar or deadChar == "" then return end
    local uuid = GetUUIDSafe(deadChar)

    Ext.Utils.Print(string.format("%s DIED uuid=%s", MOD_PREFIX, tostring(uuid)))
    if not uuid then return end

    -- A) Petrified -> shattered into ash
    local petrifyExp = RecentPetrifyRemoved[uuid]
    if petrifyExp and petrifyExp > NowMs() then
        RecentPetrifyRemoved[uuid] = nil
        PetrifiedMark[uuid] = nil
        ApplyHidden(deadChar, "Ash death: petrify removed just before death")
        return
    end

    -- Fallback (if we happened to catch StatusApplied but not StatusRemoved for some reason)
    if PetrifiedMark[uuid] then
        PetrifiedMark[uuid] = nil
        ApplyHidden(deadChar, "Ash death: died after petrify mark (fallback)")
        return
    end

    -- B) Disintegrate -> death in window
    local disExp = PendingDisintegrate[uuid]
    Ext.Utils.Print(string.format("%s DIED disintegrate expires=%s now=%s",
        MOD_PREFIX, tostring(disExp), tostring(NowMs())
    ))
    if disExp and disExp > NowMs() then
        PendingDisintegrate[uuid] = nil
        ApplyHidden(deadChar, "Ash death: died from disintegrate window")
        return
    end
end

-- Register Died with multiple arities because BG3SE setups differ
Ext.Osiris.RegisterListener("Died", 1, "after", function(deadChar)
    OnDied(deadChar, nil, "arity1")
end)

Ext.Osiris.RegisterListener("Died", 2, "after", function(deadChar, killer)
    OnDied(deadChar, killer, "arity2")
end)

Ext.Osiris.RegisterListener("Died", 3, "after", function(deadChar, killer, storyActionID)
    OnDied(deadChar, killer, storyActionID)
end)
