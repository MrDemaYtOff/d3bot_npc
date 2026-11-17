include("shared.lua")

-- Client-side rendering for D3bot Zombie NPC (e.g. Wraith translucency)

function ENT:Initialize()
	self:SetCustomCollisionCheck(true)
end

function ENT:Draw()
	local clsName = self:GetNPCClassName()
	local cfg = self.m_ClientClassCfg
	if not cfg or self.m_ClientClassName ~= clsName then
		cfg = self:GetClassConfig()
		self.m_ClientClassCfg = cfg
		self.m_ClientClassName = clsName
	end

	if cfg and cfg.RenderMode and cfg.RenderMode ~= RENDERMODE_NORMAL then
		local alpha = self:GetNPCAggroAlpha() and (cfg.AttackAlpha or 140) or (cfg.Alpha or 55)
		local col = self:GetColor()
		render.SetBlend(alpha / 255)
		render.SetColorModulation(col.r / 255, col.g / 255, col.b / 255)
		self:DrawModel()
		render.SetColorModulation(1, 1, 1)
		render.SetBlend(1)
		return
	end

	self:DrawModel()
end

function ENT:DrawTranslucent()
	self:Draw()
end
