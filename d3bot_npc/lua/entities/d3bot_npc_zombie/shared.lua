AddCSLuaFile()

-- Slotless Zombie Survival NextBot Entity (D3bot NPC)
-- Executes D3bot navigation & AI decisions without consuming server player slots.
-- Exposes JetBoom ZS compatibility accessors for TargetID, Scoreboard, Killfeed, and Deployables.

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "D3bot Zombie NPC"
ENT.Author = "D3bot NPC (Derivative of AzBot/D3bot)"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.AutomaticFrameAdvance = true

ENT.IsD3botNPC = true

function ENT:SetupDataTables()
	self:NetworkVar("String", 0, "NPCClassName")
	self:NetworkVar("String", 1, "NPCName")
	self:NetworkVar("Bool", 0, "NPCCrouching")
	self:NetworkVar("Bool", 1, "NPCLiving")
	self:NetworkVar("Bool", 2, "NPCAggroAlpha")
	self:NetworkVar("Bool", 3, "NPCCrow")
	self:NetworkVar("Int", 0, "NPCBotID")
	self:NetworkVar("Int", 1, "NPCFrags")
	self:NetworkVar("Int", 2, "NPCDeaths")
	self:NetworkVar("Int", 3, "NPCTeam")
	self:NetworkVar("Float", 0, "NextPounceTime")
	self:NetworkVar("Float", 1, "NextRangedTime")
end

function ENT:GetClassConfig()
	local cls = self:GetNPCClassName()
	if cls == "" then
		cls = self.PendingZombieClass or "Zombie"
	end
	local cached = self.m_ClassConfig
	if cached and cached.Name == cls then
		return cached
	end
	cached = D3botNPC.GetClassConfig(cls)
	self.m_ClassConfig = cached
	return cached
end

function ENT:GetNPCDisplayName()
	local n = self:GetNPCName()
	if n and n ~= "" then
		return n
	end
	if self.PendingBotName and self.PendingBotName ~= "" then
		return self.PendingBotName
	end
	local cfg = self:GetClassConfig()
	return (cfg and cfg.Name) or "Zombie"
end

-- JetBoom Zombie Survival Entity & Player Compatibility Surface
function ENT:Team()
	local t = self:GetNPCTeam()
	if t and t > 0 then return t end
	return TEAM_UNDEAD or 3
end

function ENT:Alive()
	return self:GetNPCLiving() and self:Health() > 0
end

function ENT:IsZombie()
	return self:Team() == (TEAM_UNDEAD or 3)
end

function ENT:IsValidZombie()
	return IsValid(self) and self:IsZombie()
end

function ENT:IsValidLivingZombie()
	return IsValid(self) and self:IsZombie() and self:Alive()
end

function ENT:IsHuman()
	return false
end

function ENT:IsValidHuman()
	return false
end

function ENT:IsValidLivingHuman()
	return false
end

function ENT:IsValidPlayer()
	return false
end

function ENT:IsCrow()
	if self:GetNPCCrow() then return true end
	local cfg = self:GetClassConfig()
	return (cfg and cfg.IsCrow == true) or false
end

function ENT:IsHeadcrab()
	local cfg = self:GetClassConfig()
	return (cfg and cfg.IsCrab == true) or false
end

function ENT:IsBoss()
	local cfg = self:GetClassConfig()
	return (cfg and cfg.Boss == true) or false
end

function ENT:GetMaxZombieHealth()
	return math.max(self:GetMaxHealth() or 1, 1)
end

function ENT:GetZombieClass()
	local cfg = self:GetClassConfig()
	return (cfg and cfg.ZSClassIndex) or 1
end

function ENT:GetZombieClassTable()
	local cfg = self:GetClassConfig()
	if GAMEMODE and GAMEMODE.ZombieClasses and cfg and cfg.Name and GAMEMODE.ZombieClasses[cfg.Name] then
		return GAMEMODE.ZombieClasses[cfg.Name]
	end
	return cfg
end

function ENT:GetObserverMode()
	return OBS_MODE_NONE
end

function ENT:Name()
	return self:GetNPCDisplayName()
end

function ENT:Nick()
	return self:GetNPCDisplayName()
end

function ENT:ClippedName()
	return self:GetNPCDisplayName()
end

function ENT:Frags()
	return self:GetNPCFrags() or 0
end

function ENT:Deaths()
	return self:GetNPCDeaths() or 0
end

function ENT:Ping()
	return 0
end

function ENT:GetZSRemortLevel()
	return 0
end

function ENT:GetZSLevel()
	return 1
end

function ENT:IsSpectator()
	return self:Team() == (TEAM_SPECTATOR or 1002)
end

function ENT:Crouching()
	return self:GetNPCCrouching()
end

function ENT:GetHull()
	local cfg = self:GetClassConfig()
	local scale = self:GetModelScale() or 1
	local hull = (cfg and cfg.Hull) or { Vector(-16, -16, 0), Vector(16, 16, 72) }
	return hull[1] * scale, hull[2] * scale
end

function ENT:GetHullDuck()
	local cfg = self:GetClassConfig()
	local scale = self:GetModelScale() or 1
	local hullDuck = (cfg and cfg.HullDuck) or { Vector(-16, -16, 0), Vector(16, 16, 36) }
	return hullDuck[1] * scale, hullDuck[2] * scale
end

function ENT:GetViewOffset()
	local cfg = self:GetClassConfig()
	return (cfg and cfg.ViewOffset) or Vector(0, 0, 64)
end

function ENT:GetViewOffsetDucked()
	local cfg = self:GetClassConfig()
	return (cfg and cfg.ViewOffsetDucked) or Vector(0, 0, 28)
end

function ENT:GetShootPos()
	local offset = self:Crouching() and self:GetViewOffsetDucked() or self:GetViewOffset()
	return self:GetPos() + offset * (self:GetModelScale() or 1)
end

function ENT:EyePos()
	return self:GetShootPos()
end

function ENT:EyeAngles()
	return self.m_EyeAngles or self:GetAngles()
end

function ENT:SyncAngles()
	local ang = self:EyeAngles()
	return Angle(0, ang.y, 0)
end

function ENT:SetEyeAngles(ang)
	self.m_EyeAngles = ang
end

function ENT:GetAimVector()
	return self:EyeAngles():Forward()
end

function ENT:GetLegDamage()
	if not self.m_LegDamageEnd then return 0 end
	return math.max(0, self.m_LegDamageEnd - CurTime())
end

function ENT:RawCapLegDamage(t)
	self.m_LegDamageEnd = CurTime() + math.min(t, (GAMEMODE and GAMEMODE.MaxLegDamage) or 3)
end

function ENT:AddLegDamage(amt)
	local cur = self:GetLegDamage()
	self:RawCapLegDamage(cur + (amt or 0))
end

function ENT:AddLegDamageExt(amt)
	self:AddLegDamage(amt)
end

function ENT:GetMeleeSpeedMul()
	return 1
end

function ENT:GetMaxSpeed()
	local cfg = self:GetClassConfig()
	local base = (cfg and cfg.RunSpeed) or 175
	local maxLeg = (GAMEMODE and GAMEMODE.MaxLegDamage) or 3
	local legFrac = math.Clamp(self:GetLegDamage() / math.max(maxLeg, 1), 0, 1)
	local mul = 1 - 0.5 * legFrac
	if self:Crouching() then
		mul = mul * ((cfg and cfg.CrouchedWalkSpeed) or 0.55)
	end
	return base * mul
end

function ENT:WasHitInHead()
	return self.m_LastHitGroup == HITGROUP_HEAD
end

function ENT:GetStatus()
	return nil
end

function ENT:GetDTBool()
	return false
end

function ENT:GetPoisonDamage()
	return 0
end

function ENT:GetBleedDamage()
	return 0
end

function ENT:GetPhantomHealth()
	return 0
end

function ENT:IsPlaying()
	return self:Alive() and self:Team() ~= (TEAM_SPECTATOR or 1002)
end

function ENT:BarricadeGhosting()
	return false
end

function ENT:IsSkillActive()
	return false
end

function ENT:HasTrinket()
	return false
end

function ENT:Armor()
	return 0
end

function ENT:MaxArmor()
	return 0
end

function ENT:FlashlightIsOn()
	return false
end

function ENT:InVehicle()
	return false
end

function ENT:GetRagdollEntity()
	return NULL
end

function ENT:HasGodMode()
	return false
end

function ENT:CallZombieFunction0() end
function ENT:CallZombieFunction1() end
function ENT:CallZombieFunction2() end
function ENT:CallZombieFunction3() end
function ENT:CallZombieFunction4() end
function ENT:CallZombieFunction5() end

function ENT:ShouldNotCollide(ent)
	if not IsValid(ent) then return false end
	if self:IsCrow() and (ent:IsPlayer() or ent.IsD3botNPC) then
		return true
	end
	if D3botNPC and D3botNPC.ConVars and D3botNPC.ConVars.NoCollideZombies and D3botNPC.ConVars.NoCollideZombies:GetBool() then
		if ent.IsD3botNPC then return true end
		if ent:IsPlayer() and ent:Team() == TEAM_UNDEAD then return true end
	end
	return false
end

-- Engine hook required by SetCustomCollisionCheck(true): ENT:ShouldNotCollide is not invoked automatically by Source NextBots.
local noCollideCV = nil
hook.Add("ShouldCollide", "D3botNPC.ZombieCollisionCheck", function(ent1, ent2)
	if not IsValid(ent1) or not IsValid(ent2) then return end
	local npc1 = ent1.IsD3botNPC
	local npc2 = ent2.IsD3botNPC
	if not npc1 and not npc2 then return end

	if npc1 and npc2 then
		if noCollideCV == nil then
			noCollideCV = D3botNPC and D3botNPC.ConVars and D3botNPC.ConVars.NoCollideZombies
		end
		if not noCollideCV or noCollideCV:GetBool() then
			return false
		end
		return
	end

	local npc = npc1 and ent1 or ent2
	local other = npc1 and ent2 or ent1
	if not IsValid(other) then return end

	if other:IsPlayer() then
		if npc.GetNPCCrow and npc:GetNPCCrow() then
			return false
		end
		if other:Team() == (TEAM_UNDEAD or 3) then
			if noCollideCV == nil then
				noCollideCV = D3botNPC and D3botNPC.ConVars and D3botNPC.ConVars.NoCollideZombies
			end
			if not noCollideCV or noCollideCV:GetBool() then
				return false
			end
		end
	end
end)
