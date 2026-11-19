-- AvatarSwitchMenu.lua
--
-- "Avatar Switching" MCM tab (Damage_Destruction only). Only meaningful
-- while the custom player character (Tav/Durge) is dead: lets the player
-- promote one alive origin companion in the party to Avatar (controllable
-- party leader) status, and later hand it straight back to Tav once
-- revived - which instantly strips it from whichever companion held it.
--
-- See DD_AvatarSwitch.lua's header for the full risk/confidence notes on
-- how this is implemented and why. Short version: the "revive Tav, make
-- Tav the Avatar again" direction uses real vanilla dismiss/restore code.
-- The "promote a companion" direction does not have a clean vanilla
-- equivalent and is built the most solid way currently known to be
-- possible - watch for issues.
--
-- UI structure follows the existing "Immune Items" / "Dead Party Members"
-- tabs in this same mod.

local REQ_CHANNEL     = ModuleUUID .. "_AvatarSwitch_Request"
local STATE_CHANNEL   = ModuleUUID .. "_AvatarSwitch_State"
local PROMOTE_CHANNEL = ModuleUUID .. "_AvatarSwitch_Promote"
local RESTORE_CHANNEL = ModuleUUID .. "_AvatarSwitch_RestoreTav"

-- Client-side cache of the last state received from the server.
local currentState = {}

-- UI elements, created once the tab is built.
local statusText = nil
local candidatesTable = nil
local candidatesEmptyText = nil
local restoreBtn = nil

local function RequestState()
    Ext.Net.PostMessageToServer(REQ_CHANNEL, "")
end

local function ClearCandidateRows()
    if not candidatesTable then return end
    for i = #candidatesTable.Children, 2, -1 do
        candidatesTable:RemoveChild(candidatesTable.Children[i])
    end
end

local function DisplayState()
    if not statusText then return end

    local state = currentState or {}

    if state.TavDead then
        statusText.Label = "Tav is dead. You may promote one of the living companions below to Avatar " ..
            "status, making them your controlled party leader until Tav is revived and takes it back."
    elseif state.CurrentAvatarIsTav == false and state.CurrentAvatarName then
        statusText.Label = "Tav is alive. " .. tostring(state.CurrentAvatarName) ..
            " is currently holding Avatar status - use the button below to hand it back to Tav."
    else
        statusText.Label = "Tav is alive and is the current Avatar. This tab activates automatically if Tav dies."
    end

    if candidatesTable then
        ClearCandidateRows()
        local candidates = state.Candidates or {}
        if #candidates == 0 then
            candidatesTable.Visible = false
            if candidatesEmptyText then
                candidatesEmptyText.Visible = state.TavDead == true
                candidatesEmptyText.Label = state.TavDead
                    and "No living companions available to promote right now."
                    or ""
            end
        else
            candidatesTable.Visible = true
            if candidatesEmptyText then candidatesEmptyText.Visible = false end
            for _, entry in ipairs(candidates) do
                local row = candidatesTable:AddRow()
                local nameCell = row:AddCell()
                nameCell:AddText(entry.Name or entry.UUID or "Unknown")

                local actionCell = row:AddCell()
                local btn = actionCell:AddButton("Make Avatar")
                btn.OnClick = function()
                    Ext.Net.PostMessageToServer(PROMOTE_CHANNEL, entry.UUID)
                end
            end
        end
    end

    if restoreBtn then
        local showRestore = (state.TavAlive == true) and (state.CurrentAvatarIsTav == false) and (state.CurrentAvatarName ~= nil)
        restoreBtn.Visible = showRestore
    end
end

Ext.RegisterNetListener(STATE_CHANNEL, function(_, payload)
    local ok, state = pcall(Ext.Json.Parse, payload or "{}")
    if ok and type(state) == "table" then
        currentState = state
    else
        currentState = {}
    end
    DisplayState()
end)

Ext.Events.SessionLoaded:Subscribe(function()
    RequestState()
end)

if Mods and Mods.BG3MCM and Mods.BG3MCM.IMGUIAPI then
    Mods.BG3MCM.IMGUIAPI:InsertModMenuTab(ModuleUUID, "Avatar Switching", function(tabHeader)
        tabHeader:AddText(
            "Only relevant while your custom character (Tav/Durge) is dead. Promote a living " ..
            "companion to Avatar status to keep playing with full control until Tav is revived " ..
            "and you hand control back. There is never more than one Avatar at a time. This is a " ..
            "delicate, engine-level swap - if you notice odd behaviour (a companion who won't " ..
            "dismiss, dialogue oddities), please report it."
        )

        local refreshBtn = tabHeader:AddButton("Refresh")
        refreshBtn.OnClick = function()
            RequestState()
        end

        statusText = tabHeader:AddText("")

        restoreBtn = tabHeader:AddButton("Make Tav the Avatar Again")
        restoreBtn.Visible = false
        restoreBtn.OnClick = function()
            Ext.Net.PostMessageToServer(RESTORE_CHANNEL, "")
        end

        candidatesEmptyText = tabHeader:AddText("")
        candidatesEmptyText.Visible = false

        candidatesTable = tabHeader:AddTable("AvatarSwitchTable", 2)
        candidatesTable.RowBg = true
        candidatesTable:AddColumn("Companion", "WidthStretch")
        candidatesTable:AddColumn("Action")

        local headerRow = candidatesTable:AddRow()
        headerRow.Headers = true
        headerRow:AddCell():AddText("Companion")
        headerRow:AddCell():AddText("Action")

        DisplayState()
        RequestState()
    end)
end
