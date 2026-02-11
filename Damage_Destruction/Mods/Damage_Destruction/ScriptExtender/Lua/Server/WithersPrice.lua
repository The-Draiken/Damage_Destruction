local PRICE = 8500

local DIALOGS = {
    "CAMP_Jergal_7f4acd9b-15c0-81fe-9409-623634ec3ed3", -- main camp Withers res dialog
    "SCE_Jergal_Debrief_40bfba6f-d321-0d1e-1d14-5092544d96ea", -- act2 debrief version
}

local function ApplyWithersPrice()
    for _, dialog in ipairs(DIALOGS) do
        -- This PROC exists in your story and rewrites DB_DialogMoneyTransfer
		Ext.Utils.Print(string.format("[WithersPrice] Setting res price to %d", PRICE))
        Osi.PROC_GLO_Jergal_SetResurrectionPrice(PRICE, dialog)
    end
end

-- Fires for existing saves too
Ext.Events.SessionLoaded:Subscribe(function(_)
    -- Run a bit later to avoid “too early” cases
    Ext.Timer.WaitFor(1000, function()
        ApplyWithersPrice()
    end)

    -- Extra safety: apply again after a short delay (some setups seed later)
    Ext.Timer.WaitFor(4000, function()
        ApplyWithersPrice()
    end)
end)

-- Optional: also apply when gameplay starts in a level (covers weird load orders)
Ext.Events.LevelGameplayStarted:Subscribe(function(_)
    Ext.Timer.WaitFor(500, function()
        ApplyWithersPrice()
    end)
end)
