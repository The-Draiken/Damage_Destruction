-- Damage_Destruction: client-side item index receiver
--
-- This module listens for the server-broadcast item index message,
-- parses it and stores the resulting table on the Mods.Damage_Destruction
-- namespace.  When opening the Immune Items tab the UI will pull
-- from this cache instead of attempting to enumerate items on the
-- client.  We register for chunked transfers if available; otherwise
-- fall back to a simple net listener.  Clients also request the
-- index on session load to handle cases where they connect after
-- the initial broadcast.

local channel = ModuleUUID .. "_ItemIndex" -- must match server

-- Handle a complete JSON payload (either a direct message or the
-- assembled chunks) by parsing and storing it.  Any errors are
-- caught so as not to crash the net listener.
local function OnItemIndexReceived(payload)
    if not payload then return end
    local ok, data = pcall(function()
        if type(payload) == "string" then
            return Ext.Json.Parse(payload)
        end
        return payload -- already a table when using ChunkedNet
    end)
    if ok and type(data) == "table" then
        Mods.Damage_Destruction = Mods.Damage_Destruction or {}
        Mods.Damage_Destruction.ItemIndex = data
    end
end

-- Register listeners once per session.  We subscribe on SessionLoaded
-- to ensure MCM has initialised ChunkedNet.Client before we call
-- RegisterNetListeners().
Ext.Events.SessionLoaded:Subscribe(function()
    -- Ensure the ChunkedNet client has hooks installed
    if ChunkedNet and ChunkedNet.Client and ChunkedNet.Client.RegisterNetListeners then
        ChunkedNet.Client.RegisterNetListeners()
        -- Register our handler for the item index channel
        ChunkedNet.Client.RegisterHandler(channel, function(jsonStr)
            -- jsonStr is a JSON string when using ChunkedNet
            OnItemIndexReceived(jsonStr)
        end)
    end
    -- Fallback net listener for non-chunked messages
    Ext.RegisterNetListener(channel, function(_, payload, _)
        OnItemIndexReceived(payload)
    end)
    -- Always request the index from the server.  Even if the server
    -- broadcasts automatically on load, this handles late joiners.
    Ext.Net.PostMessageToServer(channel .. "_REQ", "")
end)