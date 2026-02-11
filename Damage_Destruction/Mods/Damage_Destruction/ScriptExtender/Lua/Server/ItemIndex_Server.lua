-- Damage_Destruction: server-side item index builder and broadcaster
--
-- On some versions of BG3 Script Extender the client API cannot
-- enumerate armour/weapon stats or templates reliably.  To ensure
-- every client sees the same list of items when configuring damage
-- immunity, we build the index on the server and broadcast it out to
-- all players at session load.  Clients listen for the message and
-- cache the result locally.  This mirrors the pattern used by
-- EasyCheat and Attunement.

local channel = ModuleUUID .. "_ItemIndex" -- e.g. "Damage_Destruction_ItemIndex"

-- List of mod IDs considered vanilla.  Anything else will be
-- categorised as "modded" when populating the index.  These values
-- mirror those in EasyCheat/ItemManager.lua.
local vanillaModIds = {
    "ed539163-bb70-431b-96a7-f5b2eda5376b", -- Shared
    "b176a0ac-d79f-ed9d-5a87-5c2c80874e10", -- DiceSet_02
    "e842840a-2449-588c-b0c4-22122cfce31b", -- DiceSet_01
    "e0a4d990-7b9b-8fa9-d7c6-04017c6cf5b1", -- DiceSet_03
    "ee4989eb-aab8-968f-8674-812ea2f4bfd7", -- DiceSet_06
    "630daa32-70f8-3da5-41b9-154fe8410236", -- MainUI
    "ee5a55ff-eb38-0b27-c5b0-f358dc306d34", -- ModBrowser
    "3d0c5ff8-c95d-c907-ff3e-34b204f1c630", -- SharedDev
    "991c9c7a-fb80-40cb-8f0d-b92d4e80e9b1", -- Gustav
    "28ac9ce2-2aba-8cda-b3b5-6e922f71b6b8", -- GustavDev
}
local vanillaModSet = {}
for _, id in ipairs(vanillaModIds) do
    vanillaModSet[id] = true
end

-- Build a table mapping mod ID to a boolean indicating whether it is
-- considered vanilla.  If a stat’s ModId is empty or absent it is
-- treated as vanilla.
local function IsVanilla(modId)
    if not modId or modId == "" then return true end
    return vanillaModSet[modId] == true
end

-- Build the item index by enumerating all Armour and Weapon stats on
-- the server.  For each stat we fetch the root template to get
-- display names and icons.  Items whose slot is Underwear or any
-- Vanity slot are skipped.  Each entry in the resulting list
-- contains StatName, DisplayName, Icon and Source ("vanilla" or
-- "mod").
local function BuildItemIndex()
    local index = {}
    -- Helper to process a single stat entry.  This localised
    -- function captures the index table for closure.
    local function ProcessStat(statName)
        local stat = Ext.Stats.Get(statName)
        if stat then
            local rtGuid = stat.RootTemplate
            if rtGuid and rtGuid ~= "" and rtGuid ~= "00000000-0000-0000-0000-000000000000" then
                local ok, rt = pcall(Ext.Template.GetRootTemplate, rtGuid)
                if ok and rt and rt.TemplateType == "item" then
                    -- Determine slot; skip underwear and vanity items.
                        -- Safely retrieve slot; some stats may not define it.
                        local slot = ""
                        local okSlot, resSlot = pcall(function() return stat.Slot end)
                        if okSlot and resSlot then slot = resSlot else slot = "" end
                        if slot ~= "Underwear" and not string.find(slot, "Vanity") then
                            -- Safely retrieve ModifierList; skip if not weapon/armor
                            local modifier = ""
                            local okMod, resMod = pcall(function() return stat.ModifierList end)
                            if okMod and resMod then modifier = resMod else modifier = "" end
                            if modifier == "Weapon" or modifier == "Armor" then
                            -- Determine display name: prefer the template
                            -- DisplayName translated text; fall back to
                            -- stat.DisplayName or stat.Name via safe
                            -- access; finally use statName.
                            local display = ""
                            -- Template display name may be nested
                            if rt.DisplayName and rt.DisplayName.Handle then
                                local handle = rt.DisplayName.Handle
                                local h
                                if type(handle) == "table" and handle.Handle then
                                    h = handle.Handle
                                else
                                    h = handle
                                end
                                local ok2, res = pcall(Ext.Loca.GetTranslatedString, h)
                                if ok2 and type(res) == "string" then
                                    display = res
                                end
                            end
                            if display == "" then
                                -- Try to safely access stat.DisplayName and
                                -- stat.Name.  stats::Object may not define
                                -- these properties, so we use pcall.
                                local sd
                                local okSd, resSd = pcall(function() return stat.DisplayName end)
                                if okSd then sd = resSd end
                                if sd and type(sd) == "string" and sd ~= "" then
                                    display = sd
                                else
                                    local sname
                                    local okSn, resSn = pcall(function() return stat.Name end)
                                    if okSn then sname = resSn end
                                    if sname and type(sname) == "string" and sname ~= "" then
                                        display = sname
                                    else
                                        display = statName
                                    end
                                end
                            end
                                -- Determine icon
                                local icon = rt.Icon or "Item_Unknown"
                                -- Safely retrieve mod ID for determining source
                                local modId = ""
                                local okModId, resModId = pcall(function() return stat.ModId end)
                                if okModId and resModId then modId = resModId else modId = "" end
                                -- Determine source
                                local source = IsVanilla(modId) and "vanilla" or "mod"
                                index[#index + 1] = {
                                    StatName = statName,
                                    DisplayName = display,
                                    Icon = icon,
                                    Source = source,
                                }
                            end
                        end
                end
            end
        end
    end
    -- Armour stats
    for _, sName in pairs(Ext.Stats.GetStats("Armor") or {}) do
        ProcessStat(sName)
    end
    -- Weapon stats
    for _, sName in pairs(Ext.Stats.GetStats("Weapon") or {}) do
        ProcessStat(sName)
    end
    -- Sort index by display name for deterministic order
    table.sort(index, function(a, b)
        local an = a.DisplayName or a.StatName or ""
        local bn = b.DisplayName or b.StatName or ""
        return an < bn
    end)
    Mods.Damage_Destruction = Mods.Damage_Destruction or {}
    Mods.Damage_Destruction.ItemIndex = index
    return index
end

-- Broadcast the current item index to all connected clients.
local function BroadcastItemIndex()
    local idx = Mods.Damage_Destruction and Mods.Damage_Destruction.ItemIndex
    if not idx then
        idx = BuildItemIndex()
    end
    -- Use chunked messaging if available to avoid payload size limits
    if ChunkedNet and ChunkedNet.SendTableToAll then
        ChunkedNet.SendTableToAll(channel, idx)
    else
        local json = Ext.Json.Stringify(idx)
        -- Fallback to a direct broadcast (risking the 1MB limit)
        Ext.Net.BroadcastMessage(channel, json)
    end
end

-- Send the index to a single user in response to a request.  The
-- request channel is derived by appending "_REQ" to our base
-- channel.  When a client posts an empty string to this channel we
-- respond by sending them the full index.
Ext.RegisterNetListener(channel .. "_REQ", function(_, _, user)
    local idx = Mods.Damage_Destruction and Mods.Damage_Destruction.ItemIndex
    if not idx then
        idx = BuildItemIndex()
    end
    -- Use chunked messaging if available
    if ChunkedNet and ChunkedNet.SendTableToUser then
        ChunkedNet.SendTableToUser(user, channel, idx)
    else
        local json = Ext.Json.Stringify(idx)
        Ext.ServerNet.PostMessageToUser(user, channel, json)
    end
end)

-- On session load (and after a reset), build the index and broadcast it
-- to all clients.  This ensures every player sees the same list when
-- opening the Immune Items tab.
Ext.Events.SessionLoaded:Subscribe(function()
    BuildItemIndex()
    BroadcastItemIndex()
end)
Ext.Events.ResetCompleted:Subscribe(function()
    BuildItemIndex()
    BroadcastItemIndex()
end)