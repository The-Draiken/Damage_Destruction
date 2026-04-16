Ext.Require("Shared/DD_Globals.lua")
Ext.Require("Shared/Config_DestroyOnDeath.lua")
-- Pull in MCM integration logic.  This must be required after the config
-- module so that DestroyOnDeathConfig is defined and ModuleUUID is
-- available.  The integration will subscribe to session load and MCM events
-- to synchronise settings.
Ext.Require("Shared/MCM_Integration.lua")
Ext.Require("Server/DestroyOnDeath_Main.lua")
Ext.Require("Server/DestroyOnDeath_SE.lua")
Ext.Require("Server/Disintegrate_Save_ItemDestruction.lua")
Ext.Require("Server/DeathBlock_PetrifyDisintegrate.lua")
Ext.Require("Server/DD_RecentDeath_All.lua")
Ext.Require("Server/RTD_Improved.lua")
Ext.Require("Server/WithersPriceFix.lua")
Ext.Require("Server/WithersPrice.lua")
Ext.Require("Server/ResurrectionPenalty.lua")
Ext.Require("Server/DD_DeathBlocksRaiseDead.lua")
-- Load the server-side item index broadcaster.  This must be
-- required after the core destruction scripts so that the ModuleUUID
-- is defined.
Ext.Require("Server/ItemIndex_Server.lua")

-- Load the server-side handler for the immune items configuration.  This
-- script listens for client requests to fetch or update the list of
-- immune stat names and synchronises them via the shared config.  It
-- must be loaded after Config_DestroyOnDeath and DestroyOnDeathConfig
-- are initialised so that BuildImmuneList and SetImmuneList are
-- available.
Ext.Require("Server/ImmuneList_Server.lua")
