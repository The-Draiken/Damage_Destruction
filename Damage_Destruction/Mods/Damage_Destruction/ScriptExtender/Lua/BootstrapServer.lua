Ext.Require("Shared/DD_Globals.lua")
Ext.Require("Shared/Config_DestroyOnDeath.lua")
Ext.Require("Server/DestroyOnDeath_Main.lua")
Ext.Require("Server/DestroyOnDeath_SE.lua")
Ext.Require("Server/DeathBlock_PetrifyDisintegrate.lua")
Ext.Require("Server/DD_RecentDeath_All.lua")
Ext.Require("Server/RTD_Improved.lua")
Ext.Require("Server/WithersPriceFix.lua")
Ext.Require("Server/WithersPrice.lua")
Ext.Require("Server/ResurrectionPenalty.lua")
Ext.Require("Server/RaiseDeadDecay.lua")
-- Load the server-side item index broadcaster.  This must be
-- required after the core destruction scripts so that the ModuleUUID
-- is defined.
Ext.Require("Server/ItemIndex_Server.lua")
