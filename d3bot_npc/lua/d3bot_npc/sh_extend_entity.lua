AddCSLuaFile()

-- Ported from D3bot sh_extend_entity.lua
local meta = FindMetaTable("Entity")

---Returns whether this entity is a barricade (nailed physics prop/door or ZS barricade object).
---@return boolean
function meta:D3bot_IsBarricade()
	if self.IsNailed and self:IsNailed() then return true end
	return self.IsBarricadeObject or false
end
