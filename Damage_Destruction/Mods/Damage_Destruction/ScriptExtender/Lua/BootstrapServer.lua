Ext.Require("Shared/DD_Globals.lua")
Ext.Require("Shared/Config_DestroyOnDeath.lua")
-- Pull in MCM integration logic.  This must be required after the config
-- module so that DestroyOnDeathConfig is defined and ModuleUUID is
-- available.  The integration will subscribe to session load and MCM events
-- to synchronise settings.
Ext.Require("Shared/MCM_Integration.lua")
Ext.Require("Server/EmptySlotsInitiative_DD.lua")
Ext.Require("Server/DestructionLog_DD.lua")
-- NOTE: this used to also require "Server/DestroyOnDeath_Main.lua", a file that no
-- longer exists in this mod (superseded by DestroyOnDeath_SE.lua below). Removed
-- since a missing Ext.Require target just produces a load-time error in the SE log
-- on every session for no benefit.
Ext.Require("Server/EquipmentFailure_DD.lua")
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

-- Load the server-side handler for the "Dead Party Members" MCM tab. Lets
-- the player manually send a dead-but-still-in-party member to camp or
-- remove them from the party (leaving the body), mirroring Withers' own
-- dismiss behaviour without needing to wait for him to become available.
Ext.Require("Server/DD_DeadPartyMembers.lua")

-- Load the server-side handler for the "Avatar Switching" MCM tab. Lets
-- the player promote a living companion to Avatar status while the custom
-- character (Tav) is dead, and hand it back once Tav is revived. See that
-- file's header comment for important risk/confidence notes.
Ext.Require("Server/DD_AvatarSwitch.lua")

-- Halsin only: records his equipped gear while alive and puts it back on
-- him when he's resurrected, since Damage Destruction's permadeath can
-- destroy it. Falls back to his default Act 1 outfit if nothing was recorded.
Ext.Require("Server/DD_HalsinGear.lua")
