-- Mods/YourMod/ScriptExtender/Lua/Server/WithersPriceFix.lua

Ext.Osiris.RegisterListener("SessionLoaded", 0, "after", function()
    local campDialog = "CAMP_Jergal_7f4acd9b-15c0-81fe-9409-623634ec3ed3"
    local sceDialog  = "SCE_Jergal_Debrief_40bfba6f-d321-0d1e-1d14-5092544d96ea"
    local price = 8500

    -- Force the actual gold check values used by dialog
    Osi.PROC_GLO_Jergal_SetResurrectionPrice(price, campDialog)
    Osi.PROC_GLO_Jergal_SetResurrectionPrice(price, sceDialog)

    -- Optional: also seed the DB row (usually not required if the PROC is enough)
    -- Osi.DB_GLO_Jergal_ResurrectionDialogues(campDialog, price)
    -- Osi.DB_GLO_Jergal_ResurrectionDialogues(sceDialog, price)
end)
