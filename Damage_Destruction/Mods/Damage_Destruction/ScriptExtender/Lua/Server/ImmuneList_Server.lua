-- ImmuneList_Server.lua
--
-- Server‑side handling for the Immune Items configuration in the Damage
-- Destruction mod.  This script listens for client requests to fetch
-- the current immunity list and updates coming from the client when
-- players toggle items in the UI.  When a client submits a new list
-- of immune StatNames the server updates the shared configuration,
-- persists the changes to the global config and broadcasts the
-- updated list back to all connected clients.  This ensures that
-- every player sees the same immunity list and that the server
-- respects the player’s choices when determining whether items
-- should be destroyed on death.

-- Compute the network channels using the module UUID.  These
-- definitions must match the constants used in the client UI.  The
-- suffixes correspond to: requesting the list, setting the list and
-- sending updates.
local IMMUNE_REQ = ModuleUUID .. "_ImmuneStats_Request"
local IMMUNE_SET = ModuleUUID .. "_ImmuneStats_Set"
local IMMUNE_UPD = ModuleUUID .. "_ImmuneStats_Update"

-- Helper: build the list of immune StatNames and return it as a
-- sorted array.  This delegates to the shared config API provided
-- by Config_DestroyOnDeath.lua.  If that API is missing or fails we
-- fall back to an empty list to avoid crashing.
local function GetImmuneList()
    if DestroyOnDeathConfig and DestroyOnDeathConfig.BuildImmuneList then
        local ok, list = pcall(DestroyOnDeathConfig.BuildImmuneList)
        if ok and type(list) == "table" then
            return list
        end
    end
    return {}
end

-- Send the current immune list to a single user.  We accept both a
-- user handle (string) and nil; when user is nil the message is
-- broadcast to all players.  The payload is a JSON array of stat
-- names.
local function SendImmuneList(user)
    local list = GetImmuneList()
    local json = Ext.Json.Stringify(list)
    if user == nil then
        Ext.Net.BroadcastMessage(IMMUNE_UPD, json)
    else
        Ext.ServerNet.PostMessageToUser(user, IMMUNE_UPD, json)
    end
end

-- Broadcast the current immunity list to all connected clients.  This
-- is called after changes are applied so every UI refreshes.
local function BroadcastImmuneList()
    SendImmuneList(nil)
end

-- Handle requests from clients to fetch the current immunity list.  On
-- receiving IMMUNE_REQ we simply send the list back to the user who
-- requested it.  This keeps the wire payload small since clients
-- individually request the list on session load.
Ext.RegisterNetListener(IMMUNE_REQ, function(_, _, user)
    if user ~= nil then
        SendImmuneList(user)
    end
end)

-- Handle updates from clients.  The payload is expected to be a JSON
-- array of stat names representing the items that should be immune.
-- We parse the payload, update the shared config via SetImmuneList,
-- save the changes to the global config and broadcast the updated
-- list to all clients.  Any malformed payload is ignored to avoid
-- corrupting the configuration.  A nil or empty list will clear the
-- immunity list.
Ext.RegisterNetListener(IMMUNE_SET, function(_, payload, _)
    local ok, list = pcall(function()
        return Ext.Json.Parse(payload or "[]")
    end)
    if not ok or type(list) ~= "table" then
        return
    end
    -- Coerce the list into an array of strings.  We ignore empty
    -- entries and non‑string values to ensure a clean config.
    local entries = {}
    for _, v in ipairs(list) do
        if type(v) == "string" and v ~= "" then
            table.insert(entries, v)
        end
    end
    -- Update the shared config.  SetImmuneList replaces the existing
    -- immunity table with the provided entries.  If the API is
    -- missing we do nothing.
    if DestroyOnDeathConfig and DestroyOnDeathConfig.SetImmuneList then
        local okSet = pcall(DestroyOnDeathConfig.SetImmuneList, entries)
        -- Persist to the global JSON file for profile‑wide storage.
        if okSet and DestroyOnDeathConfig.SaveToGlobal then
            pcall(DestroyOnDeathConfig.SaveToGlobal)
        end
    end
    -- Synchronise the MCM text field with the updated list.  Without
    -- this, the MCM integration will overwrite the immunity list on
    -- session load because it retains its own stale value.  Convert
    -- the array of stat names into a space‑separated string.  We
    -- perform this on the server so that clients who are not
    -- controlling the UI still see the correct string in their MCM
    -- menus when opening the settings.
    if MCM and type(MCM.Set) == "function" then
        local parts = {}
        for _, v in ipairs(entries) do
            if type(v) == "string" and v ~= "" then
                parts[#parts+1] = v
            end
        end
        local joined = table.concat(parts, " ")
        pcall(function()
            MCM.Set("immune_stat_list", joined, ModuleUUID)
        end)
    end
    -- Notify all clients of the updated list so their UIs stay in
    -- sync.
    BroadcastImmuneList()
end)

-- When the session loads or resets, broadcast the current immunity
-- list to all players.  Clients also request the list individually
-- via IMMUNE_REQ, but broadcasting here ensures that late joiners
-- receive an up‑to‑date list even if they never send a request.
Ext.Events.SessionLoaded:Subscribe(function()
    BroadcastImmuneList()
end)
Ext.Events.ResetCompleted:Subscribe(function()
    BroadcastImmuneList()
end)