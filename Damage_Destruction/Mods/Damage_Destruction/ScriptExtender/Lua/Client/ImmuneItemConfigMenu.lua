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
    -- We don't need to rebuild the list here because `PushToServer()`
    -- calls `BuildClientList()` when serialising `immuneSet`.  If
    -- further logic is required it can be added here without
    -- modifying the MCM callbacks.
    PushToServer()
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

local function BuildClientList()
    local out = {}
    for statName, active in pairs(immuneSet) do
        if active == true and type(statName) == "string" and statName ~= "" then
            out[#out+1] = statName
        end
    end
    table.sort(out)
    return out
end

local function SyncFromServer(list)
    immuneSet = {}
    if type(list) == "table" then
        for _, v in ipairs(list) do
            if type(v) == "string" and v ~= "" then
                immuneSet[v] = true
            end
        end
    end
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
    -- Build the index only once.  We scan all root templates for items
    -- whose stats correspond to Armor or Weapon types.  This mirrors
    -- Attunement's logic and avoids relying on Ext.Stats.GetStats(),
    -- which may not return values on some builds.  Even if ItemIndex
    -- exists, we always rebuild the lookup table below to remain
    -- consistent.
    if ItemIndex == nil then
        ItemIndex = {}
        -- Use the same logic as Attunement's populateTemplateTable() to
        -- gather all item templates.  Iterate over every root template
        -- and collect entries whose ModifierList is "Weapon" or "Armor"
        -- and which are not underwear or vanity slots.  In addition
        -- to the template display name, we fallback to stat name or
        -- internal name when a display name is unavailable.
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
                                    -- Determine display name:
                                    -- Use the template DisplayName handle if possible, otherwise
                                    -- fallback to the stat DisplayName or Name, and finally the
                                    -- statName itself.
                                    local disp = ""
                                    -- Some builds use nested DisplayName.Handle handles.
                                    disp = TemplateDisplayName(rt)
                                    if disp == "" then
                                        -- Use stat DisplayName if available.
                                        local sd = StatField(stat, "DisplayName")
                                        if sd and type(sd) == "string" and sd ~= "" then
                                            disp = sd
                                        else
                                            -- Fall back to stat name
                                            disp = SafeString(StatField(stat, "Name") or statName)
                                        end
                                    end
                                    -- Ensure we have some display string
                                    if disp == "" then disp = statName end
                                    local icon = SafeString(rt.Icon or "Item_Unknown")
                                    local modId = SafeString(StatField(stat, "ModId"))
                                    local source = IsVanillaModId(modId) and "vanilla" or "mod"
                                    ItemIndex[#ItemIndex+1] = {
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

-- ============================================================
-- UI
-- ============================================================
local uiSearch = ""
local sourceFilter = 0 -- 0=Both, 1=Vanilla, 2=Modded

if Mods and Mods.BG3MCM and Mods.BG3MCM.IMGUIAPI then
    Mods.BG3MCM.IMGUIAPI:InsertModMenuTab(ModuleUUID, "Immune Items", function(tab)

        EnsureItemIndex()

        -- We'll build the search results dynamically using a helper
        -- function defined later in this scope, so no forward
        -- declarations are needed here.

        tab:AddText("Add items that should be immune to destruction (StatName-based).")
        tab:AddSeparator()

        -- Use a single table for the SizeHint instead of a nested table.  A
        -- nested table causes the window height to collapse to zero and
        -- makes its children invisible on some BG3SE builds.  See
        -- https://github.com/Norbyte/bg3se/issues/358 for details.
        -- Give child windows a fixed positive width so that they occupy space.  A
        -- width of 0 causes the window to collapse on some builds, hiding
        -- its contents.
        local controls = tab:AddChildWindow("dd_immune_controls", {600, 70})
        controls.NoScrollbar = true

        controls:AddText("Search")
        UISameLine()
        local search = controls:AddInputText("")
        search.IDContext = "DD_ImmuneSearch"
        search.SameLine = true
        search.SizeHint = {260, 36}
        -- Provide a hint so users know they can search by item name or stat
        search.Hint = "Search by item name or stat"
        -- search.OnChange will be assigned later once RefreshResults is defined

        controls:AddText("Vanilla/Modded")
        local optBoth = controls:AddRadioButton("Both", true)
        optBoth.IDContext = "dd_src_both"
        optBoth.SameLine = true
        local optVan = controls:AddRadioButton("Vanilla", false)
        optVan.IDContext = "dd_src_van"
        optVan.SameLine = true
        local optMod = controls:AddRadioButton("Modded", false)
        optMod.IDContext = "dd_src_mod"

        tab:AddSeparator()

        -- Containers for search results and current immune items.  We build
        -- tables inside these containers on each refresh rather than
        -- prebuilding child windows for every row.  Tables natively support
        -- scrolling and row backgrounds.
        local resultsContainer = tab:AddChildWindow("dd_search_results_container", {600, 420})
        local currentContainer = tab:AddChildWindow("dd_immune_current_container", {600, 220})

        -- Helper to determine the current source filter from the radio
        -- buttons.  When neither Vanilla nor Modded is selected, both
        -- types are shown.
        local function GetSourceFilter()
            if optVan.Active then return "vanilla" end
            if optMod.Active then return "mod" end
            return "both"
        end

        -- Forward declaration for the result refresh function.  This
        -- allows RenderCurrent() to call RefreshResults() even though
        -- the full implementation appears later in this file.
        local RefreshResults

        -- Render the list of currently immune items.  Each entry
        -- displays the icon and display name, along with a small
        -- remove button to unassign immunity.  Rebuilding this list on
        -- every change is cheap because there are typically only a
        -- handful of entries.
        local function RenderCurrent()
            -- Clear and rebuild the list of current immune items using a table.
            UIClearChildren(currentContainer)
            currentContainer:AddText("Current immune items:")
            local list = BuildClientList()
            if #list == 0 then
                currentContainer:AddText("(None)")
                return
            end
            local curTable = currentContainer:AddTable("dd_immune_items_table", 2)
            curTable.RowBg = true
            curTable.ScrollY = true
            curTable.SizingFixedFit = true
            curTable.NoHostExtendX = true
            curTable.Borders = true
            for _, statName in ipairs(list) do
                local entry = ItemIndexByStatName and ItemIndexByStatName[statName] or nil
                local row = curTable:AddRow()
                -- Column 1: icon and display name
                local c1 = row:AddCell()
                if entry and IsSafeIcon(entry.Icon) then
                    c1:AddImage(entry.Icon, {24, 24})
                    UISameLine()
                end
                local disp = statName
                if entry and entry.DisplayName and entry.DisplayName ~= "" then
                    disp = entry.DisplayName .. " (" .. statName .. ")"
                end
                c1:AddText(disp)
                -- Column 2: remove button
                local c2 = row:AddCell()
                local remBtn = c2:AddButton("x")
                remBtn.OnClick = function()
                    immuneStatsClient[statName] = nil
                    PushClientListToServer()
                    RenderCurrent()
                    RefreshResults()
                end
            end
        end

        -- Build and display the current search results based on the
        -- search text and source filter.  This function completely
        -- rebuilds the contents of resultsList each time it is called.
        RefreshResults = function()
            -- Clear the results container and rebuild a table of matches
            UIClearChildren(resultsContainer)
            local ft = string.lower(search.Text or "")
            local sf = GetSourceFilter()
            local matches = {}
            for _, entry in ipairs(ItemIndex) do
                if sf == "both" or entry.Source == sf then
                    local ok = true
                    if ft ~= "" then
                        local dn = string.lower(entry.DisplayName or "")
                        local sn = string.lower(entry.StatName or "")
                        ok = (string.find(dn, ft, 1, true) ~= nil) or (string.find(sn, ft, 1, true) ~= nil)
                    end
                    if ok then
                        matches[#matches+1] = entry
                    elseif ft == "" and #matches < 100 then
                        matches[#matches+1] = entry
                    end
                    if ft == "" and #matches >= 100 then break end
                end
            end
            if #matches == 0 then
                resultsContainer:AddText("No matches found. Type to search.")
                return
            end
            local displayed = 0
            local resTable = resultsContainer:AddTable("dd_search_results_table", 3)
            resTable.RowBg = true
            resTable.ScrollY = true
            resTable.SizingFixedFit = true
            resTable.NoHostExtendX = true
            resTable.Borders = true
            for _, entry in ipairs(matches) do
                displayed = displayed + 1
                if displayed > 600 then
                    local msgRow = resTable:AddRow()
                    local msgCell = msgRow:AddCell()
                    msgCell:AddText("(Results capped; refine search for more.)")
                    -- fill remaining cells to keep row structure
                    for i = 2, 3 do msgRow:AddCell():AddText("") end
                    break
                end
                local row = resTable:AddRow()
                -- Column 1: icon and name
                local c1 = row:AddCell()
                if IsSafeIcon(entry.Icon) then
                    c1:AddImage(entry.Icon, {24, 24})
                    UISameLine()
                end
                c1:AddText(string.format("%s (%s)", entry.DisplayName, entry.StatName))
                -- Column 2: source label
                local c2 = row:AddCell()
                c2:AddText(entry.Source)
                -- Column 3: add/remove button
                local c3 = row:AddCell()
                local btn = c3:AddButton("+")
                if immuneStatsClient[entry.StatName] == true then
                    btn.Label = "x"
                else
                    btn.Label = "+"
                end
                btn.OnClick = function()
                    local already = immuneStatsClient[entry.StatName] == true
                    if already then
                        immuneStatsClient[entry.StatName] = nil
                    else
                        immuneStatsClient[entry.StatName] = true
                    end
                    PushClientListToServer()
                    RenderCurrent()
                    btn.Label = (immuneStatsClient[entry.StatName] and "x") or "+"
                end
            end
        end

        -- Attach search and radio button callbacks to trigger a refresh
        -- whenever the user interacts with the controls.
        search.OnChange = function(_)
            RefreshResults()
        end
        optBoth.OnChange = function(_)
            optBoth.Active = true
            optVan.Active  = false
            optMod.Active  = false
            RefreshResults()
        end
        optVan.OnChange = function(_)
            optBoth.Active = false
            optVan.Active  = true
            optMod.Active  = false
            RefreshResults()
        end
        optMod.OnChange = function(_)
            optBoth.Active = false
            optVan.Active  = false
            optMod.Active  = true
            RefreshResults()
        end

        -- Initial population of both lists
        RenderCurrent()
        RefreshResults()

    end)
end
