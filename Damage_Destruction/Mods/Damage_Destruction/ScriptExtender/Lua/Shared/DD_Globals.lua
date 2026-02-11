-- Damage_Destruction shared globals
--
-- Several scripts (client + server) expect `ModuleUUID` to exist as a GLOBAL.
-- If it's missing (or wrong), concatenations like `ModuleUUID .. "_ItemIndex"`
-- will crash and/or BG3MCM events will be ignored.
--
-- IMPORTANT: This must match the ModuleInfo UUID in Mods/Damage_Destruction/meta.lsx

ModuleUUID = ModuleUUID or "87ec711e-73b5-1812-7f6a-4a92b9be0190"

-- Optional helpers
DD = DD or {}
DD.ModuleUUID = ModuleUUID
DD.ModFolder = DD.ModFolder or "Damage_Destruction"
