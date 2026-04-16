local function IsSafeIcon(icon)
    if icon == nil then return false end
    if type(icon) ~= "string" then return false end
    if icon == "" then return false end
    if string.match(icon, "^%d+_Head_") then return false end
    return true
end

-- Damage_Destruction: Immune Items tab (icons + search)
-- StatName-based immunity list stored in Script Extender user config (GlobalConfig.json)
--
-- Notes:
--  * Some BG3SE builds do NOT expose stats::Object::DisplayName, so we only index Armor/Weapon stats.
--  * Extui ChildWindow does NOT have :ClearChildren(); use UIClearChildren(child).


-- UI global compatibility (different BG3MCM/SE builds expose either ImGui or Imgui)
local UI = _G.Imgui or _G.ImGui or Imgui or ImGui
local function UISameLine()
    if UI and UI.SameLine then return UI.SameLine() end
end
local function UIClearChildren(win)
    if UI and UI.ClearChildren then
        return UI.ClearChildren(win)
    end
    -- Fallback: no-op (won't crash)
end

local IMMUNE_REQ = ModuleUUID .. "_ImmuneStats_Request"
local IMMUNE_SET = ModuleUUID .. "_ImmuneStats_Set"
local IMMUNE_UPD = ModuleUUID .. "_ImmuneStats_Update"

-- Forward declarations for functions defined later in the file. Lua
-- closures created earlier in the chunk must capture these locals, so
-- the implementations below assign into these names instead of using
-- `local function ...`, which would create shadowing locals.
local BuildClientList
local SyncFromServer

-- client-side cache of immune StatNames
local immuneSet = {}

--[[
    The UI logic in this file was originally written to reference two
    globals that never existed: `immuneStatsClient` and
    `PushClientListToServer()`.  These identifiers were intended to
    represent the client‑side table of immune stat names and a helper
    function for pushing that list to the server.  Without
    definitions the code crashed at runtime when the Mod Configuration
    Menu attempted to refresh the list of immune items (see stack
    trace in the user’s bug report).  To fix this we explicitly
    initialise `immuneStatsClient` and `PushClientListToServer()` as
    aliases to the existing `immuneSet` table and `PushToServer()`
    function.  By pointing `immuneStatsClient` at `immuneSet` any
    additions or removals made through the UI are reflected in the
    underlying client data structure used by `BuildClientList()`, and
    `PushClientListToServer()` simply forwards to the established
    networking helper `PushToServer()`.  See the top of this file
    where `immuneSet` and `PushToServer()` are defined.
--]]

-- alias used by UI callbacks for the current immune entries.  This
-- references `immuneSet` directly so mutations stay in sync.
local immuneStatsClient = immuneSet

-- forwarder used by the UI to push the client list of immune stats
-- back to the server.  This just delegates to the existing
-- `PushToServer()` function defined above.
local function PushClientListToServer()
    -- Serialize and send the current list of immune stat names to the server.
    -- We intentionally do not update the MCM text field from the client here.
    -- Instead, the server will persist the new list and mirror it back into
    -- MCM via its own integration code.  Updating MCM from the client can
    -- cause race conditions where the MCM event handler overwrites the
    -- immune list before the server has processed the network message.
    local okList, list = pcall(BuildClientList)
    local payload
    if okList and type(list) == "table" then
        payload = Ext.Json.Stringify(list)
    else
        payload = "[]"
    end
    Ext.Net.PostMessageToServer(IMMUNE_SET, payload)
end

-- Vanilla mod IDs (Base + Gustav/Shared etc). Anything else is considered "Modded" for filtering.
local vanillaModIds = {
    "ed539163-bb70-431b-96a7-f5b2eda5376b",
    "1d5e38b2-7cc7-4b72-89d1-63d9aa2f6a5e",
    "630daa32-70f8-3da5-41b9-154fe8410236",
    "ee5a55ff-eb38-0b27-c5b0-f358dc306d34",
    "ee4989eb-aab8-968f-8674-812ea2f4bfd7",
    "e842840a-2449-588c-b0c4-22122cfce31b",
    "e0a4d990-7b9b-8fa9-d7c6-04017c6cf5b1",
    "b176a0ac-d79f-ed9d-5a87-5c2c80874e10",
}
local vanillaModSet = {}
for _, id in ipairs(vanillaModIds) do vanillaModSet[id] = true end

local function IsVanillaModId(modId)
    if not modId or modId == "" then return true end
    return vanillaModSet[modId] == true
end

local function SafeString(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    return tostring(v)
end

local function GetTranslated(handle)
    if not handle then return "" end
    local ok, res = pcall(Ext.Loca.GetTranslatedString, handle)
    if ok and type(res) == "string" then return res end
    return ""
end

local function TemplateDisplayName(rt)
    if not rt then return "" end
    -- RootTemplate DisplayName handle nesting varies by build
    if rt.DisplayName and rt.DisplayName.Handle and rt.DisplayName.Handle.Handle then
        return GetTranslated(rt.DisplayName.Handle.Handle)
    end
    if rt.DisplayName and rt.DisplayName.Handle then
        return GetTranslated(rt.DisplayName.Handle)
    end
    return ""
end

BuildClientList = function()
    local out = {}
    for statName, active in pairs(immuneSet) do
        -- Include any entry whose key exists.  We ignore the stored value
        -- (true/false) because presence alone indicates the user selected
        -- the item as immune.  This mirrors Attunement’s behaviour of
        -- mapping overrides to `false` while treating nil as absent.
        if active == true and type(statName) == "string" and statName ~= "" then
            out[#out+1] = statName
        end
    end
    table.sort(out)
    return out
end

SyncFromServer = function(list)
    -- Instead of reassigning immuneSet to a new table (which would
    -- break references such as immuneStatsClient), clear the existing
    -- table and repopulate it.  This ensures that any aliases remain
    -- valid and UI callbacks continue to mutate the correct table.
    if type(immuneSet) ~= "table" then
        immuneSet = {}
    end
    -- Remove all existing keys
    for k in pairs(immuneSet) do
        immuneSet[k] = nil
    end
    -- Populate with new entries from the server.  Each stat name in the
    -- list marks that item as immune.  To mirror Attunement’s override
    -- pattern, we store `false` as the value (presence is what matters).
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "string" and v ~= "" then
                immuneSet[v] = true
            end
        end
    end
    -- Do not update the MCM text field from the client.  The server
    -- integration is responsible for synchronising the field after
    -- persisting the updated immunity list.  Updating MCM from the
    -- client can conflict with server-side event handling and cause
    -- the immune list to be cleared.  See MCM_Integration.lua for
    -- details.
end

local function PushToServer()
    Ext.Net.PostMessageToServer(IMMUNE_SET, Ext.Json.Stringify(BuildClientList()))
end

Ext.RegisterNetListener(IMMUNE_UPD, function(_, payload, _)
    local ok, data = pcall(Ext.Json.Parse, payload or "[]")
    if ok and type(data) == "table" then
        SyncFromServer(data)
    end
end)

Ext.Events.SessionLoaded:Subscribe(function(_)
    Ext.Net.PostMessageToServer(IMMUNE_REQ, "")
end)

-- ============================================================
-- Item index (Armor + Weapon only)
-- ============================================================
local ItemIndex = nil

-- map stat names to their entry for quick lookup.  This is filled
-- alongside ItemIndex in EnsureItemIndex().
local ItemIndexByStatName = nil

local function StatField(stat, field)
    local ok, val = pcall(function() return stat[field] end)
    if ok then return val end
    return nil
end

local function AddStatsToIndex(index, statsType)
    local stats = Ext.Stats.GetStats(statsType) or {}
    for _, statName in ipairs(stats) do
        local stat = Ext.Stats.Get(statName)
        if stat then
            local rtGuid = StatField(stat, "RootTemplate")
            if rtGuid and rtGuid ~= "" and rtGuid ~= "00000000-0000-0000-0000-000000000000" then
                local ok, rt = pcall(Ext.Template.GetRootTemplate, rtGuid)
                if ok and rt then
                    local disp = TemplateDisplayName(rt)
                    if disp == "" then
                        disp = SafeString(StatField(stat, "DisplayName") or StatField(stat, "Name") or statName)
                    end
                    local icon = SafeString(rt.Icon or "Item_Unknown")
                    local modId = StatField(stat, "ModId")
                    local source = IsVanillaModId(modId) and "vanilla" or "mod"

                    index[#index+1] = {
                        StatName = statName,
                        DisplayName = disp,
                        Icon = icon,
                        Source = source,
                    }
                end
            end
        end
    end
end

local function EnsureItemIndex()
    -- Build the index only once.  On some Script Extender builds the
    -- client cannot enumerate templates or stats reliably, so we
    -- attempt multiple strategies in order: (1) use the server‑sent
    -- index stored in Mods.Damage_Destruction.ItemIndex, enriching it
    -- with additional metadata; (2) enumerate all root templates on
    -- the client; (3) fall back to enumerating weapon/armour stats via
    -- Ext.Stats.GetStats().  If all methods fail we will still
    -- initialise ItemIndex to an empty table so the UI does not crash.
    if ItemIndex == nil then
        -- Attempt to consume the server-provided index.  This is sent
        -- via ItemIndex_Server.lua and stored on the Mods namespace.
        local served = nil
        if Mods and Mods.Damage_Destruction and Mods.Damage_Destruction.ItemIndex then
            served = Mods.Damage_Destruction.ItemIndex
        end
        if served and type(served) == "table" and #served > 0 then
            ItemIndex = {}
            -- Enrich each entry from the server index with
            -- additional information pulled from the stats and templates.
            for _, baseEntry in ipairs(served) do
                local statName = baseEntry.StatName or ""
                if statName ~= "" then
                    local stat = Ext.Stats.Get(statName)
                    -- Determine display name (prefer server value)
                    local disp = baseEntry.DisplayName or ""
                    -- Determine icon (prefer server value)
                    local icon = baseEntry.Icon or "Item_Unknown"
                    -- Determine source (vanilla/mod) from server value
                    local source = baseEntry.Source or "vanilla"
                    -- Extract additional metadata from stat and root template
                    local rarity, slot, passives, statusEquip, boosts = "", "", "", "", ""
                    local modId = ""
                    local modName, modAuthor = "", ""
                    if stat then
                        rarity      = SafeString(StatField(stat, "Rarity"))
                        slot        = SafeString(StatField(stat, "Slot"))
                        passives    = SafeString(StatField(stat, "PassivesOnEquip"))
                        statusEquip = SafeString(StatField(stat, "StatusOnEquip"))
                        boosts      = SafeString(StatField(stat, "Boosts") or StatField(stat, "DefaultBoosts"))
                        modId       = SafeString(StatField(stat, "ModId"))
                    end
                    -- Derive human‑readable mod info
                    if modId ~= "" then
                        local okMod, modInfo = pcall(Ext.Mod.GetMod, modId)
                        if okMod and modInfo and modInfo.Info then
                            modName   = SafeString(modInfo.Info.Name)
                            modAuthor = SafeString(modInfo.Info.Author)
                        end
                    end
                    -- If display name is still empty, attempt to pull
                    -- from stat or fallback to statName
                    if disp == "" then
                        if stat then
                            local sd = StatField(stat, "DisplayName")
                            if sd and type(sd) == "string" and sd ~= "" then
                                disp = sd
                            else
                                local sname = StatField(stat, "Name")
                                if sname and type(sname) == "string" and sname ~= "" then
                                    disp = sname
                                else
                                    disp = statName
                                end
                            end
                        else
                            disp = statName
                        end
                    end
                    -- Attempt to get template icon if server icon is
                    -- unknown.  This may fail quietly.
                    if icon == "Item_Unknown" then
                        local rtGuid = stat and StatField(stat, "RootTemplate") or nil
                        if rtGuid and rtGuid ~= "" and rtGuid ~= "00000000-0000-0000-0000-000000000000" then
                            local okRt, rt = pcall(Ext.Template.GetRootTemplate, rtGuid)
                            if okRt and rt then
                                if rt.Icon and type(rt.Icon) == "string" and rt.Icon ~= "" then
                                    icon = rt.Icon
                                end
                                -- Also try to pull a translation for display name
                                local d = TemplateDisplayName(rt)
                                if d and d ~= "" then
                                    disp = d
                                end
                            end
                        end
                    end
                    -- Filter out underwear and vanity items; rely on slot
                    if slot ~= "Underwear" and (slot == "" or not string.find(slot, "Vanity")) then
                        ItemIndex[#ItemIndex+1] = {
                            StatName        = statName,
                            DisplayName     = disp,
                            Icon            = icon,
                            Source          = source,
                            Rarity          = rarity,
                            Slot            = slot,
                            PassivesOnEquip = passives,
                            StatusOnEquip   = statusEquip,
                            Boosts          = boosts,
                            ModId           = modId,
                            ModName         = modName,
                            ModAuthor       = modAuthor,
                        }
                    end
                end
            end
        else
            -- If no server index is available, attempt to enumerate
            -- templates on the client as before.  This logic mirrors
            -- Attunement and may fail on some builds but is a useful
            -- fallback when the server hasn't sent the index yet.
            ItemIndex = {}
            local ok, templates = pcall(Ext.ClientTemplate.GetAllRootTemplates)
            if ok and type(templates) == "table" then
                for _, rt in pairs(templates) do
                    if rt and rt.TemplateType == "item" then
                        local statName = SafeString(rt.Stats)
                        if statName ~= "" then
                            local stat = Ext.Stats.Get(statName)
                            if stat ~= nil then
                                local modifierList = SafeString(StatField(stat, "ModifierList"))
                                if modifierList == "Weapon" or modifierList == "Armor" then
                                    local slot = SafeString(StatField(stat, "Slot"))
                                    if slot ~= "Underwear" and not string.find(slot, "Vanity") then
                                        local disp = TemplateDisplayName(rt)
                                        if disp == "" then
                                            local sd = StatField(stat, "DisplayName")
                                            if sd and type(sd) == "string" and sd ~= "" then
                                                disp = sd
                                            else
                                                disp = SafeString(StatField(stat, "Name") or statName)
                                            end
                                        end
                                        if disp == "" then disp = statName end
                                        local icon = SafeString(rt.Icon or "Item_Unknown")
                                        local modId = SafeString(StatField(stat, "ModId"))
                                        local source = IsVanillaModId(modId) and "vanilla" or "mod"
                                        local rarity      = SafeString(StatField(stat, "Rarity"))
                                        local passives    = SafeString(StatField(stat, "PassivesOnEquip"))
                                        local statusEquip = SafeString(StatField(stat, "StatusOnEquip"))
                                        local boosts      = SafeString(StatField(stat, "Boosts") or StatField(stat, "DefaultBoosts"))
                                        local modName, modAuthor = "", ""
                                        if modId ~= "" then
                                            local ok2, modInfo = pcall(Ext.Mod.GetMod, modId)
                                            if ok2 and modInfo and modInfo.Info then
                                                modName   = SafeString(modInfo.Info.Name)
                                                modAuthor = SafeString(modInfo.Info.Author)
                                            end
                                        end
                                        ItemIndex[#ItemIndex+1] = {
                                            StatName        = statName,
                                            DisplayName     = disp,
                                            Icon            = icon,
                                            Source          = source,
                                            Rarity          = rarity,
                                            Slot            = slot,
                                            PassivesOnEquip = passives,
                                            StatusOnEquip   = statusEquip,
                                            Boosts          = boosts,
                                            ModId           = modId,
                                            ModName         = modName,
                                            ModAuthor       = modAuthor,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            else
                -- As a last resort, fall back to enumerating stats via
                -- Ext.Stats.GetStats() on the client.  This may
                -- return nil on some builds, but we attempt both
                -- Armour and Weapon types in case one succeeds.  We
                -- gather only basic fields (display name, icon, source)
                -- when template access fails.
                ItemIndex = {}
                local function AddStatsByType(statsType)
                    local stats = Ext.Stats.GetStats(statsType) or {}
                    for _, statName in ipairs(stats) do
                        local stat = Ext.Stats.Get(statName)
                        if stat then
                            local slot = SafeString(StatField(stat, "Slot"))
                            if slot ~= "Underwear" and not string.find(slot, "Vanity") then
                                local modifierList = SafeString(StatField(stat, "ModifierList"))
                                if modifierList == "Weapon" or modifierList == "Armor" then
                                    local disp = SafeString(StatField(stat, "DisplayName") or StatField(stat, "Name") or statName)
                                    if disp == "" then disp = statName end
                                    local modId = SafeString(StatField(stat, "ModId"))
                                    local source = IsVanillaModId(modId) and "vanilla" or "mod"
                                    ItemIndex[#ItemIndex+1] = {
                                        StatName    = statName,
                                        DisplayName = disp,
                                        Icon        = "Item_Unknown",
                                        Source      = source,
                                        Rarity      = SafeString(StatField(stat, "Rarity")),
                                        Slot        = slot,
                                        PassivesOnEquip = SafeString(StatField(stat, "PassivesOnEquip")),
                                        StatusOnEquip   = SafeString(StatField(stat, "StatusOnEquip")),
                                        Boosts          = SafeString(StatField(stat, "Boosts") or StatField(stat, "DefaultBoosts")),
                                        ModId           = modId,
                                        ModName         = "",
                                        ModAuthor       = "",
                                    }
                                end
                            end
                        end
                    end
                end
                AddStatsByType("Armor")
                AddStatsByType("Weapon")
            end
        end
        -- Sort the index alphabetically by display name to ensure
        -- consistent ordering.
        table.sort(ItemIndex, function(a, b)
            local an = a.DisplayName or a.StatName or ""
            local bn = b.DisplayName or b.StatName or ""
            return an < bn
        end)
    end
    -- Always rebuild the fast lookup table keyed by StatName to ensure
    -- entries remain consistent with the index.  Rebuilding this table
    -- on every call is cheap and avoids issues where ItemIndex was
    -- constructed before this table existed.
    ItemIndexByStatName = {}
    for _, entry in ipairs(ItemIndex) do
        if type(entry.StatName) == "string" and entry.StatName ~= "" then
            ItemIndexByStatName[entry.StatName] = entry
        end
    end
end

local function Matches(entry, filterText)
    if not filterText or filterText == "" then return true end
    local ft = string.lower(filterText)
    local dn = string.lower(entry.DisplayName or "")
    local sn = string.lower(entry.StatName or "")
    return (string.find(dn, ft, 1, true) ~= nil) or (string.find(sn, ft, 1, true) ~= nil)
end

--
-- Helper to attach a descriptive tooltip to a search result's icon.
-- The provided image handle must support :Tooltip(), which returns
-- an ExtuiTooltip object.  The entry table should include fields
-- such as DisplayName, StatName, Rarity, Slot, PassivesOnEquip,
-- StatusOnEquip, Boosts, and mod info.  The tooltip will be
-- populated with the item's icon, name and stat name, as well as
-- additional metadata if available.  If mod information is not
-- present the tooltip will indicate whether the item comes from the
-- base game.
--
local function AddItemTooltip(imageObj, entry)
    -- Ensure both parameters are present and the image supports a tooltip
    if not imageObj or not entry or type(entry) ~= "table" or not imageObj.Tooltip then
        return
    end
    local tip = imageObj:Tooltip()
    -- Show a slightly larger icon for clarity
    local iconId = entry.Icon or "Item_Unknown"
    tip:AddImage(iconId, {32, 32})
    -- Item name and stat name
    local nameLine = (entry.DisplayName or entry.StatName or "Unknown") .. " (" .. (entry.StatName or "") .. ")"
    tip:AddText(nameLine)
    -- Rarity and slot
    if entry.Rarity and entry.Rarity ~= "" then
        tip:AddText("Rarity: " .. tostring(entry.Rarity))
    end
    if entry.Slot and entry.Slot ~= "" then
        tip:AddText("Slot: " .. tostring(entry.Slot))
    end
    -- Passives, status and boosts
    if entry.PassivesOnEquip and entry.PassivesOnEquip ~= "" then
        tip:AddText("Passives: " .. tostring(entry.PassivesOnEquip))
    end
    if entry.StatusOnEquip and entry.StatusOnEquip ~= "" then
        tip:AddText("Status On Equip: " .. tostring(entry.StatusOnEquip))
    end
    if entry.Boosts and entry.Boosts ~= "" then
        tip:AddText("Boosts: " .. tostring(entry.Boosts))
    end
    -- Origin information.  Prefer explicit mod info if provided.
    if entry.ModName and entry.ModName ~= "" then
        local author = entry.ModAuthor or ""
        tip:AddText(string.format("From mod '%s' by %s", entry.ModName, author))
    elseif entry.Source == "vanilla" then
        tip:AddText("From base game")
    else
        tip:AddText("From unknown source")
    end
end

-- ============================================================
-- UI
-- ============================================================
local uiSearch = ""
local sourceFilter = 0 -- 0=Both, 1=Vanilla, 2=Modded

if Mods and Mods.BG3MCM and Mods.BG3MCM.IMGUIAPI then
    -- Insert the "Immune Items" tab.  This UI mirrors Attunement's item
    -- configuration menu by providing a search box, a drop‑down to list
    -- items by their originating mod, and a two‑column table where each
    -- item can be toggled as immune via a checkbox.  When an item is
    -- checked it is added to the `immuneStatsClient` table; when
    -- unchecked it is removed.  All changes are immediately pushed to
    -- the server via `PushClientListToServer()`.
    Mods.BG3MCM.IMGUIAPI:InsertModMenuTab(ModuleUUID, "Immune Items", function(tabHeader)
        -- Make sure the item index and lookup table are populated.  This
        -- scans all root templates for Armor and Weapon items and caches
        -- them in `ItemIndex` and `ItemIndexByStatName`.
        EnsureItemIndex()

        -- Build mappings from mod IDs to their display names and from
        -- mod names to their IDs.  We only include mods that actually
        -- contribute items to the index (i.e. entries with a non‑empty
        -- ModId).  Vanilla/base game items have an empty ModId and are
        -- grouped under the "Base Game" label.
        local entriesByModId = {}
        local modIdByName = {}
        for _, entry in ipairs(ItemIndex) do
            local modId = entry.ModId or ""
            local modName = "Base Game"
            if modId ~= "" then
                local ok, modInfo = pcall(Ext.Mod.GetMod, modId)
                if ok and modInfo and modInfo.Info and modInfo.Info.Name then
                    modName = modInfo.Info.Name
                else
                    modName = "Unknown Mod"
                end
            end
            if not entriesByModId[modId] then entriesByModId[modId] = {} end
            modIdByName[modName] = modId
            table.insert(entriesByModId[modId], entry)
        end
        -- Sort each mod group alphabetically by display name to ensure a
        -- consistent order.  Also build a sorted list of mod names for the
        -- combo box.
        local modNames = {}
        for id, list in pairs(entriesByModId) do
            table.sort(list, function(a, b)
                local an = a.DisplayName or a.StatName
                local bn = b.DisplayName or b.StatName
                return an < bn
            end)
            local name = nil
            if id == "" then
                name = "Base Game"
            else
                -- Find the mod name by reverse lookup
                for n, modId in pairs(modIdByName) do
                    if modId == id then name = n; break end
                end
                if not name then name = "Unknown Mod" end
            end
            table.insert(modNames, name)
        end
        table.sort(modNames)

        -- Header instructions
        tabHeader:AddText("Toggle which items are immune to destruction. Search by name or list by mod.")

        -- Search input.  When text is present the mod combo is ignored.
        local searchInput = tabHeader:AddInputText("")
        searchInput.Hint = "Case-insensitive"
        searchInput.AutoSelectAll = true
        searchInput.EscapeClearsAll = true

        -- Combo to list all items by mod.  Selecting a mod clears the
        -- search box and displays all entries from that mod.  The combo
        -- remains empty when no mod filter is applied.
        tabHeader:AddText("List all items by mod - will be cleared if above search is used")
        local getAllForModCombo = tabHeader:AddCombo("")
        getAllForModCombo.WidthFitPreview = true
        getAllForModCombo.Options = modNames

        -- Results table.  It remains hidden until there is either a
        -- search string or a mod selected.
        local resultsTable = tabHeader:AddTable("ImmuneResultsTable", 2)
        resultsTable.Hideable = true
        resultsTable.Visible = false
        resultsTable.ScrollY = true
        resultsTable.RowBg = true
        resultsTable:AddColumn("Item", "WidthStretch")
        resultsTable:AddColumn("Immune")

        -- Create a header row with labels for the two columns.
        local headerRow = resultsTable:AddRow()
        headerRow.Headers = true
        headerRow:AddCell():AddText("Item")
        headerRow:AddCell():AddText("Immune")

        -- Helper to clear result rows but preserve the header.
        local function ClearResults()
            -- Remove all children except the first (the header row)
            for i = #resultsTable.Children, 2, -1 do
                local child = resultsTable.Children[i]
                resultsTable:RemoveChild(child)
            end
        end

        -- Populate the table based on a list of entries.
        local function DisplayEntries(entries)
            ClearResults()
            if not entries or #entries == 0 then
                resultsTable.Visible = false
                return
            end
            resultsTable.Visible = true
            for _, entry in ipairs(entries) do
                local row = resultsTable:AddRow()
                -- Column 1: icon and display name
                local nameCell = row:AddCell()
                if IsSafeIcon(entry.Icon) then
                    local icon = nameCell:AddImage(entry.Icon, { 32, 32 })
                    icon.SameLine = true
                    -- Attach a tooltip describing the item
                    AddItemTooltip(icon, entry)
                end
                local label = string.format("%s (%s)", entry.DisplayName or entry.StatName, entry.StatName or "")
                nameCell:AddText(label).SameLine = true
                -- Column 2: immune checkbox
                local immuneCell = row:AddCell()
                -- Check the checkbox if the stat name is present in the
                -- immunity map.  We ignore the stored boolean value (true/false).
                local checked = immuneStatsClient[entry.StatName] == true
                local checkbox = immuneCell:AddCheckbox("##Immune_" .. tostring(entry.StatName or ""), checked)
                checkbox.OnChange = function()
                    if checkbox.Checked then
                        -- Mark the stat as immune by adding it to the map.  The
                        -- stored value is `false` for consistency with the
                        -- server’s representation (Attunement style).  Using
                        -- `false` rather than `true` avoids confusion when
                        -- serialising to JSON and ensures nil/absence
                        -- differentiates unselected items.
                        immuneStatsClient[entry.StatName] = true
                    else
                        -- Remove the stat name entirely to indicate it is not
                        -- immune.
                        immuneStatsClient[entry.StatName] = nil
                    end
                    PushClientListToServer()
                end
            end
        end

        -- Refresh results based on the current search text and mod filter.
        local function RefreshResults()
            local text = searchInput.Text or ""
            text = string.lower(text)
            if text ~= "" then
                -- When searching by text, clear mod combo and filter all items
                getAllForModCombo.SelectedIndex = -1
                local matches = {}
                for _, entry in ipairs(ItemIndex) do
                    local dn = string.lower(entry.DisplayName or "")
                    local sn = string.lower(entry.StatName or "")
                    if string.find(dn, text, 1, true) or string.find(sn, text, 1, true) then
                        table.insert(matches, entry)
                    end
                end
                DisplayEntries(matches)
            else
                -- If no search, check if a mod is selected
                local idx = getAllForModCombo.SelectedIndex
                if idx and idx >= 0 then
                    -- Selected index is zero‑based in this API, so add 1
                    local modName = getAllForModCombo.Options[idx + 1]
                    local modId = modIdByName[modName]
                    local entries = entriesByModId[modId] or {}
                    DisplayEntries(entries)
                else
                    -- Nothing to show
                    DisplayEntries({})
                end
            end
        end

        -- Bind events
        searchInput.OnChange = function()
            -- Changing the search will always refresh results
            RefreshResults()
        end
        getAllForModCombo.OnChange = function()
            -- Clear the search box when selecting a mod
            searchInput.Text = ""
            RefreshResults()
        end

        -- Initial refresh to populate the table if a default mod is selected
        RefreshResults()
    end)
end
