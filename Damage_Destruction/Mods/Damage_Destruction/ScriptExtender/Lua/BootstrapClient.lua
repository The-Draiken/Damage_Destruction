Ext.Require("Shared/DD_Globals.lua")
Ext.Require("Shared/Config_DestroyOnDeath.lua")
-- Bring in MCM integration on the client too.  Even though the bulk of
-- configuration logic is server‑side, syncing the config on the client
-- allows other client components (such as UI helpers) to reference the
-- current settings.  The integration will no‑op if MCM is unavailable.
Ext.Require("Shared/MCM_Integration.lua")
Ext.Require("Client/ImmuneItemConfigMenu.lua")
-- Load client-side item index receiver before the UI menu so that
-- Mods.Damage_Destruction.ItemIndex is populated when the menu is
-- constructed.  This will register net listeners for the server
-- broadcast and request the index on session load.
Ext.Require("Client/ItemIndex_Client.lua")
