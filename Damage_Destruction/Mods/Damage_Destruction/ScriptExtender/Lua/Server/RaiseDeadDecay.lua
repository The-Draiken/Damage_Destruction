-- RaiseDeadDecay.lua
-- Long-rest corpse decay ladder for Raise Dead eligibility.
-- Party members: reliable. NPCs: best effort (loaded only).

local LADDER = {
    "DD_DEATH_BLOCKS_RAISE_DEAD",
    "DD_DEATH_BLOCKS_RAISE_DEAD_1",
    "DD_DEATH_BLOCKS_RAISE_DEAD_2",
    "DD_DEATH_BLOCKS_RAISE_DEAD_3",
    "DD_DEATH_BLOCKS_RAISE_DEAD_4",
}

local function HasAnyStatus(uuid)
    for _, s in ipairs(LADDER) do
        if Osi.HasActiveStatus(uuid, s) == 1 then
            return true
        end
    end
    return false
end

local function Advance(uuid)
    -- terminal
    if Osi.HasActiveStatus(uuid, "DD_DEATH_BLOCKS_RAISE_DEAD_4") == 1 then
        return
    end

    -- If already on ladder, move up exactly one step
    for i = 1, #LADDER do
        local cur = LADDER[i]
        if Osi.HasActiveStatus(uuid, cur) == 1 then
            Osi.RemoveStatus(uuid, cur)
            local nxt = LADDER[i + 1]
            if nxt then
                Osi.ApplyStatus(uuid, nxt, -1, 1) -- duration=-1 permanent
            end
            return
        end
    end

    -- No ladder status yet -> apply _0 on first long rest
    Osi.ApplyStatus(uuid, LADDER[1], -1, 1)
end

local function ProcessParty()
    -- DB_Players returns tuples; first value is the character UUID
    local rows = Osi.DB_Players:Get(nil)
    for _, r in ipairs(rows) do
        local char = r[1]
        if char and Osi.IsDead(char) == 1 then
            Advance(char)
        end
    end
end

local function ProcessNPCsBestEffort()
    -- Best effort: only loaded entities with Health component
    local ok, ents = pcall(Ext.Entity.GetAllEntitiesWithComponent, "Health")
    if not ok or not ents then return end

    for _, e in pairs(ents) do
        local uuid = e and e.Uuid
        if uuid
            and Osi.IsPlayer(uuid) == 0
            and Osi.IsDead(uuid) == 1
        then
            -- Optional: only start tracking NPCs once they already have any ladder status
            -- If you want to also start NPC decay automatically, remove this guard.
            if HasAnyStatus(uuid) then
                Advance(uuid)
            end
        end
    end
end

local function OnLongRest()
    ProcessParty()
    ProcessNPCsBestEffort()
end

-- Prefer SE event if available
if Ext.Events and Ext.Events.LongRestFinished then
    Ext.Events.LongRestFinished:Subscribe(function(_)
        OnLongRest()
    end)
else
    -- Fallback: Osiris listener (if your SE build supports it)
    Ext.Osiris.RegisterListener("LongRestFinished", 0, "after", function()
        OnLongRest()
    end)
end
