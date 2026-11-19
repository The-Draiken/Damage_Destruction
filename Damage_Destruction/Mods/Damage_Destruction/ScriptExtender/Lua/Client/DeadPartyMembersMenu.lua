-- DeadPartyMembersMenu.lua
--
-- "Dead Party Members" MCM tab (Damage_Destruction only). Lists party
-- members who are dead but still in the active party - which Damage
-- Destruction's permadeath statuses can otherwise leave stuck indefinitely,
-- before the player has a way to raise them or before Withers is available
-- in camp - and lets the player resolve each one manually, the same way
-- talking to Withers would:
--
--   * Send to Camp          - teleports the body to their camp spot and
--                              removes them from the party (mirrors
--                              Withers' own dismiss behaviour).
--   * Leave Body, Remove    - removes them from the party on the spot;
--                              the corpse stays exactly where it died.
--
-- UI structure follows the existing "Immune Items" tab
-- (ImmuneItemConfigMenu.lua) in this same mod: a tab inserted via
-- Mods.BG3MCM.IMGUIAPI:InsertModMenuTab, talking to the server over
-- Ext.Net.PostMessageToServer / Ext.RegisterNetListener, since the actual
-- party-state checks and actions have to happen server-side.

local REQ_CHANNEL   = ModuleUUID .. "_DeadPartyMembers_Request"
local LIST_CHANNEL  = ModuleUUID .. "_DeadPartyMembers_List"
local CAMP_CHANNEL  = ModuleUUID .. "_DeadPartyMembers_SendToCamp"
local LEAVE_CHANNEL = ModuleUUID .. "_DeadPartyMembers_LeaveBody"

-- Client-side cache of the last list received from the server.
local deadMembers = {}

-- UI elements, created once the tab is built. May still be nil if a list
-- update arrives before the player has ever opened the tab - DisplayEntries
-- guards against that and just leaves the cache updated for next time.
local resultsTable = nil
local emptyText = nil

local function RequestList()
    Ext.Net.PostMessageToServer(REQ_CHANNEL, "")
end

local function ClearResults()
    if not resultsTable then return end
    -- Remove every row except the header (index 1).
    for i = #resultsTable.Children, 2, -1 do
        resultsTable:RemoveChild(resultsTable.Children[i])
    end
end

local function DisplayEntries()
    if not resultsTable then return end
    ClearResults()

    if #deadMembers == 0 then
        resultsTable.Visible = false
        if emptyText then emptyText.Visible = true end
        return
    end

    resultsTable.Visible = true
    if emptyText then emptyText.Visible = false end

    for _, entry in ipairs(deadMembers) do
        local row = resultsTable:AddRow()

        local nameCell = row:AddCell()
        nameCell:AddText(entry.Name or entry.UUID or "Unknown")

        local campCell = row:AddCell()
        local campBtn = campCell:AddButton("Send to Camp")
        campBtn.OnClick = function()
            Ext.Net.PostMessageToServer(CAMP_CHANNEL, entry.UUID)
        end

        local leaveCell = row:AddCell()
        local leaveBtn = leaveCell:AddButton("Leave Body, Remove")
        leaveBtn.OnClick = function()
            Ext.Net.PostMessageToServer(LEAVE_CHANNEL, entry.UUID)
        end
    end
end

Ext.RegisterNetListener(LIST_CHANNEL, function(_, payload)
    local ok, list = pcall(Ext.Json.Parse, payload or "[]")
    if ok and type(list) == "table" then
        deadMembers = list
    else
        deadMembers = {}
    end
    DisplayEntries()
end)

Ext.Events.SessionLoaded:Subscribe(function()
    RequestList()
end)

if Mods and Mods.BG3MCM and Mods.BG3MCM.IMGUIAPI then
    Mods.BG3MCM.IMGUIAPI:InsertModMenuTab(ModuleUUID, "Dead Party Members", function(tabHeader)
        tabHeader:AddText(
            "Party members who are dead but still in your party. Damage " ..
            "Destruction's permadeath statuses can leave someone stuck like " ..
            "this before you have a way to raise them, or before Withers is " ..
            "available in camp. Use one of the options below to resolve it " ..
            "manually - same as talking to Withers would."
        )

        local refreshBtn = tabHeader:AddButton("Refresh")
        refreshBtn.OnClick = function()
            RequestList()
        end

        emptyText = tabHeader:AddText("No dead party members right now.")

        resultsTable = tabHeader:AddTable("DeadPartyMembersTable", 3)
        resultsTable.RowBg = true
        resultsTable:AddColumn("Name", "WidthStretch")
        resultsTable:AddColumn("Send to Camp")
        resultsTable:AddColumn("Leave Body, Remove")

        local headerRow = resultsTable:AddRow()
        headerRow.Headers = true
        headerRow:AddCell():AddText("Name")
        headerRow:AddCell():AddText("Send to Camp")
        headerRow:AddCell():AddText("Leave Body, Remove")

        DisplayEntries()
        RequestList()
    end)
end
