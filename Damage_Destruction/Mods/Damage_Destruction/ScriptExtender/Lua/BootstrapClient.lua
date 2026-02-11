Ext.Require("Shared/DD_Globals.lua")
Ext.Require("Shared/Config_DestroyOnDeath.lua")
Ext.Require("Client/ImmuneItemConfigMenu.lua")
-- Load client-side item index receiver before the UI menu so that
-- Mods.Damage_Destruction.ItemIndex is populated when the menu is
-- constructed.  This will register net listeners for the server
-- broadcast and request the index on session load.
Ext.Require("Client/ItemIndex_Client.lua")
