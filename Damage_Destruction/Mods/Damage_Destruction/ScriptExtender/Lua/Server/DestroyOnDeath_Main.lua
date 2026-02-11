local ModuleUUID = _G.ModuleUUID or ModuleUUID or "87ec711e-73b5-1812-7f6a-4a92b9be0190"

local function PrintLoaded(tag)
    if Ext and Ext.Utils and Ext.Utils.Print and DestroyOnDeathConfig then
        Ext.Utils.Print(string.format("[Damage_Destruction][GLOBAL] %s Enabled=%s RequireOverkill=%s Step=%s Scope=%s",
            tag,
            tostring(DestroyOnDeathConfig.Enabled),
            tostring(DestroyOnDeathConfig.ConditionalRequiresOverkill),
            tostring(DestroyOnDeathConfig.OverkillStep),
            tostring(DestroyOnDeathConfig.AffectScope)))
    end
end

Ext.Events.SessionLoaded:Subscribe(function(_)
    if DestroyOnDeathConfig and DestroyOnDeathConfig.LoadFromGlobal then
        DestroyOnDeathConfig.LoadFromGlobal()
    end
    if DestroyOnDeathConfig and DestroyOnDeathConfig.EnsureDefaults then
        DestroyOnDeathConfig.EnsureDefaults()
    end
    PrintLoaded("Loaded")
end)

if Ext.ModEvents and Ext.ModEvents.BG3MCM and Ext.ModEvents.BG3MCM.MCM_Setting_Saved then
    Ext.ModEvents.BG3MCM.MCM_Setting_Saved:Subscribe(function(payload)
        if not payload or payload.modUUID ~= ModuleUUID then
            return
        end
        if DestroyOnDeathConfig and DestroyOnDeathConfig.UpdateFromMCM then
            DestroyOnDeathConfig.UpdateFromMCM(payload.settingId, payload.value)
            if DestroyOnDeathConfig.SaveToGlobal then DestroyOnDeathConfig.SaveToGlobal() end
                        PrintLoaded("Saved")
        end
    end)
end
