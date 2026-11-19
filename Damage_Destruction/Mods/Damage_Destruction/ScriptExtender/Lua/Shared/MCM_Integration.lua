-- MCM_Integration.lua
--
-- This module wires the Damage_Destruction configuration into the BG3 Mod
-- Configuration Menu (MCM).  Without this integration, settings changed via
-- the in‑game MCM UI have no effect on the mod’s behaviour.  The code below
-- synchronises our internal configuration with MCM both on session load and
-- whenever a setting is saved or reset from the MCM UI.  It also supports
-- legacy MCM versions that signal changes via net messages.

-- Guard against missing globals or running outside of Script Extender.  Only
-- proceed if both DestroyOnDeathConfig and the MCM API are available.
if not (DestroyOnDeathConfig and MCM and type(MCM.Get) == "function") then
    return
end

-- A list of all setting IDs defined in MCM_blueprint.json for this mod.  When
-- synchronising settings, each ID is queried via MCM.Get() and the result is
-- applied to DestroyOnDeathConfig via UpdateFromMCM().  Keeping this list
-- centralised makes it easy to add new settings in the future without
-- sprinkling hard‑coded IDs throughout the code.
local ALL_SETTING_IDS = {
    -- Core toggles
    "enabled",
    "affect_scope",
    "stacking_enabled",
    "ignore_legendaries",
    "ignore_adamantine",
    "destroy_ash_body_items",
    "disintegrate_save_breaks_item",
    "elemental_permadeath_mode",
    "elemental_permadeath_overkill_threshold",
    "empty_slots_initiative_enabled",
    "equipment_failure_on_hit_chance",
    "equipment_failure_on_crit_chance",
    "equipment_failure_downed_chance",
    "equipment_failure_dexterity_dc",
    "equipment_failure_condition_roll_advantage",
    -- Per‑damage‑type modes (what happens on lethal damage)
    "damage_mode__Acid",
    "damage_mode__Fire",
    "damage_mode__Cold",
    "damage_mode__lightning",
    "damage_mode__Radiant",
    "damage_mode__Necrotic",
    "damage_mode__Bludgeoning",
    "damage_mode__Force",
    "damage_mode__Thunder",
    "damage_mode__Piercing",
    "damage_mode__Slashing",
    "damage_mode__Poison",
    "damage_mode__Psychic",
    -- Per‑damage‑type overkill step (extra damage threshold per tier)
    "damage_step__Acid",
    "damage_step__Fire",
    "damage_step__Cold",
    "damage_step__lightning",
    "damage_step__Radiant",
    "damage_step__Necrotic",
    "damage_step__Bludgeoning",
    "damage_step__Force",
    "damage_step__Thunder",
    "damage_step__Piercing",
    "damage_step__Slashing",
    "damage_step__Poison",
    "damage_step__Psychic",
    -- Chunking/corpse explosion flags and thresholds
    "damage_chunking__Bludgeoning",
    "damage_chunk_threshold__Bludgeoning",
    "damage_chunking__Force",
    "damage_chunk_threshold__Force",
    "damage_chunking__Thunder",
    "damage_chunk_threshold__Thunder",
    -- Custom immunity list (comma/whitespace separated StatNames)
    "immune_stat_list",
}

-- Helper: parse a comma/whitespace separated string of stat names into a list.
-- MCM stores text fields as raw strings; this function splits on commas or
-- whitespace and returns a list of non‑empty tokens.  The result can be
-- passed directly to DestroyOnDeathConfig.SetImmuneList().
-- Parse a comma or whitespace separated string of StatNames into a list.
--
-- Prior to this revision, `ParseImmuneList` only accepted tokens
-- containing letters, digits and underscores.  However, many BG3 item
-- StatNames include hyphens, plus signs or other punctuation (for
-- example "MAG_Sword+1" or "UNIQUE-Armour"), so the old pattern
-- inadvertently discarded those entries.  As a result, when players
-- added such items to the immunity list via the MCM text field or via
-- the Immune Items tab (which mirrors its selections into this
-- field), they silently disappeared on reload because parsing
-- rejected them.  To fix this, we now treat any non‑whitespace token
-- as a valid StatName.  Commas are normalised to spaces before
-- splitting, and leading/trailing whitespace is trimmed.  Duplicate
-- tokens are preserved; `SetImmuneList` will deduplicate as needed.
local function ParseImmuneList(str)
    local entries = {}
    if type(str) == "string" and str ~= "" then
        -- Replace commas with spaces so we can split on whitespace
        str = str:gsub(",", " ")
        -- Iterate over sequences of non‑space characters (tokens)
        for token in string.gmatch(str, "%S+") do
            local cleaned = token
            -- Trim any surrounding whitespace (should already be none)
            cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned
            if cleaned ~= "" then
                table.insert(entries, cleaned)
            end
        end
    end
    return entries
end

-- Apply all persisted settings from MCM into our configuration.  This is
-- typically called once per session after MCM initialises, but can also be
-- reused to reset the entire config to the current MCM values.
local function SyncAllSettingsFromMCM()
    -- We'll accumulate the immunity list separately to avoid clearing
    -- existing immunities when the MCM value is blank.  See below.
    local mcmImmuneString = nil
    -- First, apply all simple settings (non-immunity) directly.  For the
    -- immunity list we handle it specially after iterating.
    for _, settingId in ipairs(ALL_SETTING_IDS) do
        local ok, value = pcall(function() return MCM.Get(settingId, ModuleUUID) end)
        if not ok then value = nil end
        if value ~= nil then
            if settingId == "immune_stat_list" then
                mcmImmuneString = value
            else
                if DestroyOnDeathConfig.UpdateFromMCM then
                    DestroyOnDeathConfig.UpdateFromMCM(settingId, value)
                end
            end
        end
    end
    -- Handle the immunity list: if the MCM string is non-empty (i.e. it
    -- contains at least one token), then parse it and update the config.
    -- Otherwise, if the MCM value is empty or nil but the config already
    -- contains immunities (loaded from the global file), we copy those
    -- immunities back into MCM to ensure the two stay in sync.  This
    -- prevents MCM from clearing the list on session load when it has
    -- never been set by the user.
    do
        local parsed = {}
        if type(mcmImmuneString) == "string" and mcmImmuneString ~= "" then
            parsed = ParseImmuneList(mcmImmuneString)
        end
        local hasParsed = parsed and #parsed > 0
        if hasParsed then
            if DestroyOnDeathConfig.SetImmuneList then
                DestroyOnDeathConfig.SetImmuneList(parsed)
            end
        else
            -- No entries parsed from MCM.  Check if the config has
            -- existing immunities (ImmuneStatNames not empty); if so,
            -- write them back into MCM.  Build a sorted list for
            -- determinism.
            if DestroyOnDeathConfig and DestroyOnDeathConfig.BuildImmuneList then
                local okList, existing = pcall(DestroyOnDeathConfig.BuildImmuneList)
                if okList and type(existing) == "table" and #existing > 0 then
                    -- Convert list into a space-separated string
                    local parts = {}
                    for _, v in ipairs(existing) do
                        if type(v) == "string" and v ~= "" then
                            parts[#parts+1] = v
                        end
                    end
                    local joined = table.concat(parts, " ")
                    if joined ~= "" and MCM and type(MCM.Set) == "function" then
                        -- Use pcall to guard against errors when MCM.Set is not available
                        pcall(function()
                            MCM.Set("immune_stat_list", joined, ModuleUUID)
                        end)
                    end
                end
            end
        end
    end
    -- Persist the updated configuration so it is stored in the user domain.
    if DestroyOnDeathConfig.SaveToGlobal then
        DestroyOnDeathConfig.SaveToGlobal()
    end
    if DD and DD.EmptySlotsInitiative and type(DD.EmptySlotsInitiative.RefreshAll) == "function" then
        DD.EmptySlotsInitiative.RefreshAll()
    end
end

-- Apply a single setting change from MCM.  This is used when the user
-- modifies a value from the MCM UI.  The payload table contains
-- `modUUID`, `settingId`, `value` and (optionally) `oldValue`.  We only
-- act on updates belonging to this mod.
local function ApplySingleSetting(payload)
    if not payload then return end
    -- Support both modUUID and modGUID keys for backwards compatibility.
    local modUUID = payload.modUUID or payload.modGUID
    if modUUID ~= ModuleUUID then return end
    local settingId = payload.settingId
    if not settingId then return end
    local value = payload.value
    if settingId == "immune_stat_list" then
        local entries = ParseImmuneList(value)
        if DestroyOnDeathConfig.SetImmuneList then
            DestroyOnDeathConfig.SetImmuneList(entries)
        end
        -- When the immunity list is updated via the MCM, broadcast the new
        -- list to all connected clients so that their UIs refresh.
        -- We only broadcast from the server context where Ext.Net is
        -- available.  Clients will ignore this because Ext.Net is nil in
        -- their environment.
        do
            local okList, list = pcall(function()
                if DestroyOnDeathConfig and DestroyOnDeathConfig.BuildImmuneList then
                    return DestroyOnDeathConfig.BuildImmuneList()
                end
                return nil
            end)
            if okList and type(list) == "table" and Ext and Ext.Net and type(Ext.Net.BroadcastMessage) == "function" then
                local IMMUNE_UPD = ModuleUUID .. "_ImmuneStats_Update"
                local okJson, json = pcall(Ext.Json.Stringify, list)
                if okJson and type(json) == "string" then
                    -- Broadcast the updated immunity list.  Clients listening
                    -- on IMMUNE_UPD will call SyncFromServer() and update
                    -- their local immuneSet.  Use pcall to guard against
                    -- errors if the network API is unavailable.
                    pcall(function()
                        Ext.Net.BroadcastMessage(IMMUNE_UPD, json)
                    end)
                end
            end
        end
    else
        if DestroyOnDeathConfig.UpdateFromMCM then
            DestroyOnDeathConfig.UpdateFromMCM(settingId, value)
        end
    end
    if DestroyOnDeathConfig.SaveToGlobal then
        DestroyOnDeathConfig.SaveToGlobal()
    end
    if DD and DD.EmptySlotsInitiative and type(DD.EmptySlotsInitiative.RefreshAll) == "function" then
        DD.EmptySlotsInitiative.RefreshAll()
    end
end

-- === Event subscriptions ===

-- Synchronise all settings once the session has loaded.  This ensures that
-- DestroyOnDeathConfig reflects the player’s persistent MCM values every
-- time the game (re)loads a session.  We subscribe on SessionLoaded to
-- guarantee that the MCM global is initialised and that ChunkedNet hooks
-- have been installed.
Ext.Events.SessionLoaded:Subscribe(function()
    SyncAllSettingsFromMCM()
end)

-- Subscribe to MCM events using Script Extender’s ModEvents API (v1.11+).  If
-- available, these events fire whenever a setting is saved or reset via the
-- MCM UI.  We process only events destined for our mod and apply the
-- updated value through ApplySingleSetting().
if Ext and Ext.ModEvents and Ext.ModEvents.BG3MCM then
    local mcmEvents = Ext.ModEvents.BG3MCM
    -- Setting saved: update the changed setting.
    if mcmEvents["MCM_Setting_Saved"] then
        mcmEvents["MCM_Setting_Saved"]:Subscribe(function(payload)
            ApplySingleSetting(payload)
        end)
    end
    -- Setting reset: treat as saved and re‑query the default value via MCM.Get.
    if mcmEvents["MCM_Setting_Reset"] then
        mcmEvents["MCM_Setting_Reset"]:Subscribe(function(payload)
            if not payload then return end
            local modUUID = payload.modUUID or payload.modGUID
            if modUUID ~= ModuleUUID then return end
            local settingId = payload.settingId
            if not settingId then return end
            -- Use MCM.Get to fetch the current value (which will be the default
            -- after a reset) rather than payload.defaultValue, to avoid issues
            -- where MCM may normalise values differently.
            local ok, value = pcall(function() return MCM.Get(settingId, ModuleUUID) end)
            if ok then
                ApplySingleSetting({ modUUID = ModuleUUID, settingId = settingId, value = value })
            end
        end)
    end
end

-- Fallback for MCM <= 1.10, which uses net messages instead of ModEvents.  In
-- these versions, MCM sends a JSON payload on the net channel
-- `MCM_Saved_Setting` whenever a setting is saved.  The payload contains
-- fields `modGUID`, `settingId` and `value`.  We parse the payload and
-- delegate to ApplySingleSetting() accordingly.  This fallback ensures
-- backwards compatibility without requiring users to update MCM.
Ext.RegisterNetListener("MCM_Saved_Setting", function(call, payload)
    local ok, data = pcall(function()
        return Ext.Json.Parse(payload or "{}")
    end)
    if not ok or type(data) ~= "table" then
        return
    end
    -- Normalise payload keys to match the ApplySingleSetting signature.  In
    -- legacy versions, `modGUID` is used instead of `modUUID`.
    if data.modGUID and not data.modUUID then
        data.modUUID = data.modGUID
    end
    ApplySingleSetting(data)
end)
