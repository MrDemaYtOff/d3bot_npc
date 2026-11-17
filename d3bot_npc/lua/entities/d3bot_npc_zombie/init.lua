AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- Server-side NextBot execution layer for D3bot NPC
-- Translates D3bot AI/navigation intents into NextBot locomotion, jumping, crouching,
-- wall climbing, trajectory pouncing, flying intermission Crows, doors/barricades, and ZS projectiles.

local function pickRandomSound(tbl)
	if not istable(tbl) or #tbl == 0 then return nil end
	return tbl[math.random(1, #tbl)]
end

local function computeNonZeroDamageForce(dirVec, fromPos, toPos, forwardVec, scale)
	local fx, fy, fz = 0, 0, 0
	if dirVec then
		fx, fy, fz = dirVec.x, dirVec.y, dirVec.z
	end
	local lenSqr = fx * fx + fy * fy + fz * fz
	if lenSqr < 0.001 and fromPos and toPos then
		fx = toPos.x - fromPos.x
		fy = toPos.y - fromPos.y
		fz = toPos.z - fromPos.z
		lenSqr = fx * fx + fy * fy + fz * fz
	end
	if lenSqr < 0.001 and forwardVec then
		fx, fy, fz = forwardVec.x, forwardVec.y, forwardVec.z
		lenSqr = fx * fx + fy * fy + fz * fz
	end
	if lenSqr < 0.001 then
		fx, fy, fz = 0, 0, 1
		lenSqr = 1
	end
	local invLen = 1 / math.sqrt(lenSqr)
	local s = math.max(tonumber(scale) or 200, 100)
	return Vector(fx * invLen * s, fy * invLen * s, fz * invLen * s)
end

local scratchMeleeMin, scratchMeleeMax = Vector(-4, -4, -4), Vector(4, 4, 4)
local scratchPounceMin, scratchPounceMax = Vector(-12, -12, -12), Vector(12, 12, 12)
local scratchStartVec, scratchEndVec = Vector(), Vector()
local activeFilterNpc = nil

local function npcNonAllyFilter(ent)
	if ent == activeFilterNpc or ent.IsD3botNPC then return false end
	if ent:IsPlayer() and ent:Team() == (TEAM_UNDEAD or 3) then return false end
	return true
end

local standUpTrData = {
	start = scratchStartVec,
	endpos = scratchEndVec,
	filter = npcNonAllyFilter,
	mask = MASK_NPCSOLID
}

local meleeTrData = {
	start = scratchStartVec,
	endpos = scratchEndVec,
	mins = scratchMeleeMin,
	maxs = scratchMeleeMax,
	filter = npcNonAllyFilter,
	mask = MASK_SHOT
}

local pounceTrData = {
	start = scratchStartVec,
	endpos = scratchEndVec,
	mins = scratchPounceMin,
	maxs = scratchPounceMax,
	filter = npcNonAllyFilter,
	mask = MASK_SHOT
}

function ENT:EmitClassSound(category, level, pitchOffset)
	local cfg = self:GetClassConfig()
	local snd = cfg and cfg.Sounds and pickRandomSound(cfg.Sounds[category])
	if not snd then return end
	local basePitch = math.Clamp(math.Round((cfg.VoicePitch or 0.7) * 140) + (pitchOffset or 0), 50, 160)
	self:EmitSound(snd, level or 75, math.random(basePitch - 6, basePitch + 6), 0.9, CHAN_VOICE)
end

local COL_OPAQUE_WHITE = Color(255, 255, 255, 255)
local SAFE_FALLBACK_ACTS = {
	ACT_HL2MP_RUN_ZOMBIE,
	ACT_HL2MP_WALK_ZOMBIE_01,
	ACT_HL2MP_IDLE_ZOMBIE,
	ACT_RUN,
	ACT_WALK,
	ACT_IDLE
}

function ENT:PlaySafeActivity(act, fallbackSeqName)
	if self:GetActivity() == act and act ~= ACT_INVALID then
		return
	end
	local seq = (act and act ~= ACT_INVALID) and self:SelectWeightedSequence(act) or -1
	if seq and seq >= 0 then
		self:StartActivity(act)
		return
	end
	if fallbackSeqName then
		local fbSeq = self:LookupSequence(fallbackSeqName)
		if fbSeq and fbSeq >= 0 then
			self:ResetSequence(fbSeq)
			return
		end
	end
	for i = 1, #SAFE_FALLBACK_ACTS do
		local fbAct = SAFE_FALLBACK_ACTS[i]
		if fbAct and fbAct ~= act then
			local fbSeq = self:SelectWeightedSequence(fbAct)
			if fbSeq and fbSeq >= 0 then
				self:StartActivity(fbAct)
				return
			end
		end
	end
	if act and act ~= ACT_INVALID then
		self:StartActivity(act)
	end
end

function ENT:ApplyZombieClass(classNameOrQuery)
	local resolved = D3botNPC.ResolveClassName(classNameOrQuery) or "Zombie"
	local cfg = D3botNPC.GetClassConfig(resolved)

	self:SetNPCClassName(cfg.Name)
	self:SetNPCCrow(cfg.IsCrow == true)
	self.PendingZombieClass = cfg.Name
	self.m_ClassConfig = cfg
	if not cfg.IsCrow then
		self.m_NonCrowClass = cfg.Name
	end

	local mdl = cfg.Model
	if not util.IsValidModel(mdl) then
		mdl = cfg.FallbackModel or "models/player/zombie_classic.mdl"
	end
	self:SetModel(mdl)
	local scale = cfg.ModelScale or 1
	self:SetModelScale(scale, 0)

	self:SetMaxHealth(cfg.Health or 225)
	self:SetHealth(cfg.Health or 225)
	self:SetBloodColor(cfg.BloodColor or BLOOD_COLOR_RED)

	if cfg.RenderMode and cfg.RenderMode ~= RENDERMODE_NORMAL then
		self:SetRenderMode(cfg.RenderMode)
		self:SetColor(Color(255, 255, 255, cfg.Alpha or 55))
		self:DrawShadow(false)
	else
		self:SetRenderMode(RENDERMODE_NORMAL)
		self:SetColor(COL_OPAQUE_WHITE)
		self:DrawShadow(true)
	end

	if cfg.IsCrow then
		self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
	else
		self:SetCollisionGroup(COLLISION_GROUP_NPC)
	end
	self:CollisionRulesChanged()

	local hullMin, hullMax = self:GetHull()
	local duckMin, duckMax = self:GetHullDuck()
	self.m_CachedHullMin = hullMin
	self.m_CachedHullMax = hullMax
	self.m_CachedHullDuckMin = duckMin
	self.m_CachedHullDuckMax = duckMax
	self:SetCollisionBounds(hullMin, hullMax)

	if self.loco then
		self.loco:SetDesiredSpeed(cfg.RunSpeed or 175)
		self.loco:SetAcceleration(math.max(550, (cfg.RunSpeed or 175) * 4.8))
		self.loco:SetDeceleration(math.max(650, (cfg.RunSpeed or 175) * 5.8))
		self.loco:SetStepHeight(cfg.StepSize or 18)
		-- Physical jump height must equal what D3bot's pathfinder assumes (mem.JumpHeight, see D3bot_InitializeOrReset),
		-- otherwise the bot attempts/overshoots ledges the navmesh never intended. Same formula D3bot uses for players.
		local gravZ = (physenv and physenv.GetGravity and physenv.GetGravity().z) or -600
		if math.abs(gravZ) < 1 then gravZ = -600 end
		local jumpH = D3botNPC.CalculateJumpHeight and D3botNPC.CalculateJumpHeight(cfg.JumpPower or 200, gravZ, false) or 0
		if not jumpH or jumpH < 20 then jumpH = ((cfg.JumpPower or 200) ^ 2) / (2 * math.abs(gravZ)) end
		self.loco:SetJumpHeight(jumpH)
		self.loco:SetDeathDropHeight(cfg.NoFallDamage and 1800 or 450)
	end

	local slot = self.D3bot_RosterSlot
	if slot then
		slot.ZombieClass = cfg.Name
		slot.IsCrow = cfg.IsCrow == true
		if not cfg.IsCrow then
			slot.DeathClass = cfg.Name
		end
		if D3botNPC.Roster and D3botNPC.Roster.ScheduleSync then
			D3botNPC.Roster.ScheduleSync()
		end
	end

	D3botNPC.AI.InitializeOrReset(self)
end

function ENT:MorphToCrow()
	if self:IsCrow() then return end
	local slot = self.D3bot_RosterSlot
	local cfg = self:GetClassConfig()
	local curClass = (cfg and not cfg.IsCrow and cfg.Name) or self.m_NonCrowClass or (slot and slot.DeathClass) or "Zombie"
	if slot and curClass ~= "Crow" then
		slot.DeathClass = curClass
	end
	self.m_NonCrowClass = curClass
	self:ApplyZombieClass("Crow")
	self:SetNPCCrouching(false)
	-- Launch briefly upward so crows lift off dramatically on wave end
	if self.loco and self:IsOnGround() then
		self.loco:Jump()
	end
end

function ENT:RestoreFromCrow(overrideClassName)
	if not self:IsCrow() and not overrideClassName then return end
	local targetClass = overrideClassName
		or (self.D3bot_RosterSlot and self.D3bot_RosterSlot.ForcedClass)
		or (self.D3bot_RosterSlot and self.D3bot_RosterSlot.DeathClass)
		or self.m_NonCrowClass
		or "Zombie"

	local cfg = D3botNPC.GetClassConfig(targetClass)
	if not cfg or cfg.IsCrow then
		cfg = D3botNPC.Population and D3botNPC.Population.SelectSpawnClass() or D3botNPC.GetClassConfig("Zombie")
	end

	local spawnPos, spawnAng = D3botNPC.ZS.SelectZombieSpawnPos(cfg)
	if spawnPos then
		self:SetPos(spawnPos)
		if spawnAng then
			self:SetAngles(spawnAng)
		end
	end

	self:SetNPCCrouching(false)
	self:ApplyZombieClass(cfg.Name)
	if D3botNPC.AI then
		local errHandler = ErrorNoHaltWithStack or ErrorNoHalt
		xpcall(function()
			D3botNPC.AI.RerollTarget(self)
			D3botNPC.AI.UpdatePathImmediate(self)
		end, errHandler)
	end
end

function ENT:Initialize()
	self:SetNPCLiving(true)
	self:SetNPCCrouching(false)
	self:SetNPCAggroAlpha(false)
	self:SetNPCCrow(false)
	self:SetNPCTeam(TEAM_UNDEAD or 3)
	self:SetNextPounceTime(0)
	self:SetNextRangedTime(0)

	self:SetHealth(225)
	self:SetMaxHealth(225)
	self:SetSolid(SOLID_BBOX)
	self:SetCollisionGroup(COLLISION_GROUP_NPC)
	self:SetCustomCollisionCheck(true)
	self:CollisionRulesChanged()
	self:SetLagCompensated(true)

	self.DamagedBy = {}
	self.m_EyeAngles = self:GetAngles()
	self.m_NextAttackTime = 0
	self.m_NextIdleSound = CurTime() + math.Rand(3, 8)
	self.m_NextPosStore = CurTime() + 0.5
	self.m_CurrentActivity = ACT_INVALID
	self.m_LegDamageEnd = nil

	self:ApplyZombieClass(self.PendingZombieClass or "Zombie")

	if self.PendingRosterSlot and D3botNPC.Roster and D3botNPC.Roster.BindEntity then
		D3botNPC.Roster.BindEntity(self.PendingRosterSlot, self)
	elseif self.PendingBotName then
		self:SetNPCName(self.PendingBotName)
	end

	D3botNPC.RegisterNPC(self)
end

function ENT:OnRemove()
	D3botNPC.UnregisterNPC(self)
	if self.D3bot_Deinitialize then
		self:D3bot_Deinitialize()
	elseif D3botNPC.AI and D3botNPC.AI.Deinitialize then
		D3botNPC.AI.Deinitialize(self)
	end
	if not self.m_DeadProcessed and not self.m_RosterRemoved and D3botNPC.Roster and D3botNPC.Roster.UnbindEntityOnDeath then
		D3botNPC.Roster.UnbindEntityOnDeath(self)
	end
end

function ENT:CanStandUp()
	local standMin = self.m_CachedHullMin
	local standMax = self.m_CachedHullMax
	if not standMin then
		standMin, standMax = self:GetHull()
		self.m_CachedHullMin, self.m_CachedHullMax = standMin, standMax
	end
	local p = self:GetPos()
	scratchStartVec:SetUnpacked(p.x, p.y, p.z)
	scratchEndVec:SetUnpacked(p.x, p.y, p.z + 2)
	standUpTrData.mins = standMin
	standUpTrData.maxs = standMax
	activeFilterNpc = self
	local tr = util.TraceHull(standUpTrData)
	activeFilterNpc = nil
	return not tr.Hit
end

function ENT:UpdateCrouchState(wantDuck)
	local cfg = self:GetClassConfig()
	if cfg.CantDuck then wantDuck = false end

	local isCrouching = self:GetNPCCrouching()
	if wantDuck and not isCrouching then
		self:SetNPCCrouching(true)
		if not self.m_CachedHullDuckMin then
			self.m_CachedHullDuckMin, self.m_CachedHullDuckMax = self:GetHullDuck()
		end
		self:SetCollisionBounds(self.m_CachedHullDuckMin, self.m_CachedHullDuckMax)
	elseif not wantDuck and isCrouching then
		if self:CanStandUp() then
			self:SetNPCCrouching(false)
			if not self.m_CachedHullMin then
				self.m_CachedHullMin, self.m_CachedHullMax = self:GetHull()
			end
			self:SetCollisionBounds(self.m_CachedHullMin, self.m_CachedHullMax)
		end
	end
end

function ENT:TryOpenOrBreakDoor(ent)
	if not IsValid(ent) then return false end
	local cls = ent:GetClass()
	if cls ~= "prop_door_rotating" and cls ~= "func_door" and cls ~= "func_door_rotating" and cls ~= "func_button" then
		return false
	end
	if self:IsCrow() then return false end
	if ent.IsNailed and ent:IsNailed() then return false end

	-- Try opening unlocked door cleanly once per cooldown
	local isLocked = tobool(D3botNPC.GetInternalVar(ent, "m_bLocked"))
	if (not ent.D3botNPC_NextDoorUse or ent.D3botNPC_NextDoorUse < CurTime()) and not isLocked then
		ent.D3botNPC_NextDoorUse = CurTime() + 1.4
		if cls == "func_button" then
			ent:Fire("Press", "", 0, self, self)
		else
			ent:Fire("Open", "", 0, self, self)
		end
		return true
	end
	return false
end

function ENT:DoMeleeImpact(preferredTarget)
	if not IsValid(self) or not self:Alive() or self:IsCrow() then return end

	local cfg = self:GetClassConfig()
	local origin = self:GetShootPos()
	local aimDir = self:GetAimVector()
	local reach = math.max(cfg.AttackRange or 48, 48) + 12
	local dmgAmount = math.max(cfg.Damage or 35, 0)
	local dmgType = cfg.DamageType or DMG_SLASH
	local mSize = cfg.MeleeSize or 4.5

	scratchStartVec:SetUnpacked(origin.x, origin.y, origin.z)
	scratchEndVec:SetUnpacked(origin.x + aimDir.x * reach, origin.y + aimDir.y * reach, origin.z + aimDir.z * reach)
	scratchMeleeMin:SetUnpacked(-mSize, -mSize, -mSize)
	scratchMeleeMax:SetUnpacked(mSize, mSize, mSize)
	activeFilterNpc = self
	local tr = util.TraceHull(meleeTrData)
	activeFilterNpc = nil

	local hitEnt = tr.Entity
	local nearestFallbackPt = nil
	if (not IsValid(hitEnt) or tr.HitWorld) and IsValid(preferredTarget) then
		nearestFallbackPt = preferredTarget.NearestPoint and preferredTarget:NearestPoint(origin) or preferredTarget:WorldSpaceCenter()
		if origin:DistToSqr(nearestFallbackPt) <= (reach + 16) ^ 2 then
			local dx = nearestFallbackPt.x - origin.x
			local dy = nearestFallbackPt.y - origin.y
			local dz = nearestFallbackPt.z - origin.z
			local dLen = math.sqrt(dx * dx + dy * dy + dz * dz)
			local tReach = math.min(reach + 16, dLen + 8)
			if dLen > 0.01 then
				scratchStartVec:SetUnpacked(origin.x, origin.y, origin.z)
				scratchEndVec:SetUnpacked(origin.x + (dx / dLen) * tReach, origin.y + (dy / dLen) * tReach, origin.z + (dz / dLen) * tReach)
				activeFilterNpc = self
				local directTr = util.TraceHull(meleeTrData)
				activeFilterNpc = nil
				if IsValid(directTr.Entity) and (directTr.Entity == preferredTarget or D3botNPC.IsBarricadeEntity(directTr.Entity)) then
					tr = directTr
					hitEnt = directTr.Entity
				elseif not directTr.HitWorld then
					hitEnt = preferredTarget
				end
			else
				hitEnt = preferredTarget
			end
		end
	end

	if IsValid(hitEnt) or tr.HitWorld then
		if IsValid(hitEnt) then
			self:EmitClassSound("Hit", 75)

			local ct = CurTime()
			local cls = hitEnt:GetClass()
			local dmgPos = (tr.HitPos and tr.HitPos ~= vector_origin) and tr.HitPos or (nearestFallbackPt or hitEnt:WorldSpaceCenter())
			local forceVec = computeNonZeroDamageForce(aimDir, origin, dmgPos, self:GetForward(), math.max(dmgAmount, 1) * 220 * (cfg.MeleeForceScale or 1))

			local dmginfo = DamageInfo()
			dmginfo:SetDamage(dmgAmount)
			dmginfo:SetAttacker(self)
			dmginfo:SetInflictor(self)
			dmginfo:SetDamageType(dmgType)
			dmginfo:SetDamagePosition(dmgPos)
			dmginfo:SetDamageForce(forceVec)

			local sigilBeforeHp = nil
			local sigilWasCorrupted = false
			if cls == "prop_obj_sigil" then
				sigilBeforeHp = hitEnt.GetSigilHealth and tonumber(hitEnt:GetSigilHealth()) or nil
				sigilWasCorrupted = (hitEnt.GetSigilCorrupted and hitEnt:GetSigilCorrupted()) or (hitEnt.IsSigilCorrupted and hitEnt:IsSigilCorrupted()) or false
			end

			-- Handle nailed ZS barricades cleanly
			if hitEnt.IsNailed and hitEnt:IsNailed() and hitEnt.DamageNails then
				hitEnt:DamageNails(self, self, dmgAmount, dmginfo)
				self.D3bot_LastDamage = ct
			elseif hitEnt.TakeDamageInfo then
				hitEnt:TakeDamageInfo(dmginfo)
				if cls == "prop_obj_sigil" and not sigilWasCorrupted and dmgAmount > 0 then
					local sigilNowCorrupted = (hitEnt.GetSigilCorrupted and hitEnt:GetSigilCorrupted()) or (hitEnt.IsSigilCorrupted and hitEnt:IsSigilCorrupted()) or false
					local sigilAfterHp = hitEnt.GetSigilHealth and tonumber(hitEnt:GetSigilHealth()) or sigilBeforeHp
					if not sigilNowCorrupted and sigilBeforeHp and sigilAfterHp and sigilAfterHp >= sigilBeforeHp
						and D3botNPC.ZS and D3botNPC.ZS.ApplySigilDamage then
						D3botNPC.ZS.ApplySigilDamage(hitEnt, self, dmgAmount, dmginfo)
					end
					self.D3bot_LastDamage = ct
				end
			end

			if D3botNPC.IsBarricadeEntity(hitEnt) and self.D3bot_Mem then
				self.D3bot_Mem.BarricadeAttackEntity = hitEnt
				self.D3bot_Mem.BarricadeAttackPos = dmgPos
				self.D3bot_LastDamage = ct
			end

			if hitEnt:IsPlayer() and hitEnt:Team() == TEAM_HUMAN then
				self.D3bot_LastDamage = ct
				if cfg.OnMeleeHitHuman then
					pcall(cfg.OnMeleeHitHuman, self, hitEnt, dmgAmount, tr, cfg)
				end
				if cfg.UsePoisonDamage and hitEnt.AddPoisonDamage then
					hitEnt:AddPoisonDamage(dmgAmount * 0.25, self)
				end
			elseif cls == "prop_arsenalcrate" or string.StartWith(cls, "prop_gunturret") or string.StartWith(cls, "prop_zapper") or string.StartWith(cls, "prop_manhack") or cls == "func_breakable" or cls == "func_breakable_surf" then
				self.D3bot_LastDamage = ct
			end

			if cls == "prop_door_rotating" or cls == "func_door_rotating" then
				self.D3bot_LastDamage = ct
				hitEnt:EmitSound("physics/wood/wood_box_break" .. math.random(1, 2) .. ".wav", 75)
			end
		else
			self:EmitClassSound("Miss", 72)
		end
	else
		self:EmitClassSound("Miss", 72)
	end
end

function ENT:TryMeleeAttack(preferredTarget)
	if self:IsCrow() then return false end
	local ct = CurTime()
	if ct < (self.m_NextAttackTime or 0) then return false end

	if IsValid(preferredTarget) and self:TryOpenOrBreakDoor(preferredTarget) then
		-- Also proceed with swing if nailed/locked
		local isLocked = tobool(D3botNPC.GetInternalVar(preferredTarget, "m_bLocked"))
		if not (preferredTarget.IsNailed and preferredTarget:IsNailed()) and not isLocked then
			self.m_NextAttackTime = ct + 0.5
			return true
		end
	end

	local cfg = self:GetClassConfig()
	self.m_NextAttackTime = ct + (cfg.AttackCooldown or 1.2)
	self:SetNPCAggroAlpha(true)
	timer.Simple(0.6, function()
		if IsValid(self) then
			self:SetNPCAggroAlpha(false)
		end
	end)

	self:EmitClassSound("Attack", 78)

	local gesture = cfg.Animations and cfg.Animations.AttackGesture or ACT_GMOD_GESTURE_RANGE_ZOMBIE
	if gesture then
		self:RestartGesture(gesture)
	end

	local windup = math.Clamp(cfg.AttackDelay or 0.45, 0.05, 1.0)
	timer.Simple(windup, function()
		if IsValid(self) and self:Alive() then
			self:DoMeleeImpact(preferredTarget)
		end
	end)

	return true
end

function ENT:TryRangedAttack(target)
	if self:IsCrow() then return false end
	local ct = CurTime()
	if ct < self:GetNextRangedTime() then return false end

	local cfg = self:GetClassConfig()
	local r = cfg.RangedAttack
	if not r or not r.Projectile or not IsValid(target) then return false end

	self:SetNextRangedTime(ct + (r.Cooldown or 4.5))
	self:EmitSound(r.CastSound or "npc/fast_zombie/leap1.wav", 78)

	local gesture = cfg.Animations and (cfg.Animations.RangedGesture or cfg.Animations.AttackGesture)
	if gesture then
		self:RestartGesture(gesture)
	end

	timer.Simple(r.Windup or 0.65, function()
		if not IsValid(self) or not self:Alive() or not IsValid(target) then return end

		local startPos = self:GetShootPos()
		local targetPos = target:IsPlayer() and LerpVector(0.65, target:GetPos(), target:EyePos()) or target:WorldSpaceCenter()
		local baseAng = (targetPos - startPos):Angle()

		local sx = r.SpreadScaleX or r.SpreadScale or 6
		local sy = r.SpreadScaleY or r.SpreadScale or 4

		for _, offset in ipairs(r.Spread or { { 0, 0 } }) do
			local ent = ents.Create(r.Projectile)
			if IsValid(ent) then
				local ang = Angle(baseAng.p + (offset[2] or 0) * sy - 4, baseAng.y + (offset[1] or 0) * sx, 0)
				ent:SetPos(startPos + ang:Forward() * 14)
				ent:SetAngles(ang)
				ent:SetOwner(self)
				ent.Team = function() return TEAM_UNDEAD end
				ent:Spawn()
				local phys = ent:GetPhysicsObject()
				if IsValid(phys) then
					phys:Wake()
					phys:SetVelocityInstantaneous(ang:Forward() * (r.Speed or 500) + Vector(0, 0, 60))
				end
			end
		end
	end)

	return true
end

function ENT:ExecutePounce(pounceInfo)
	if not pounceInfo or self:IsCrow() then return end
	local cfg = self:GetClassConfig()

	if pounceInfo.triggerNow then
		self:SetNextPounceTime(CurTime() + (cfg.PounceDelay or 1.25))
		self:EmitClassSound("PounceStart", 78)

		local gesture = cfg.Animations and (cfg.Animations.LeapStart or cfg.Animations.AttackGesture)
		if gesture then
			self:RestartGesture(gesture)
		end

		local startDelay = cfg.PounceStartDelay or 0.45
		local launchAngle = pounceInfo.aimAngle
		self:SetEyeAngles(launchAngle)

		timer.Simple(startDelay, function()
			if not IsValid(self) or not self:Alive() then return end
			self:EmitClassSound("Pounce", 82)
			local maxLeg = (GAMEMODE and GAMEMODE.MaxLegDamage) or 3
			local legFrac = math.Clamp(self:GetLegDamage() / math.max(maxLeg, 1), 0, 1)
			local speed = (1 - 0.5 * legFrac) * (cfg.PounceVelocity or 600)
			local vel = launchAngle:Forward() * speed
			if vel.z < 140 then vel.z = math.max(vel.z, 190) end
			self.loco:Jump()
			self.loco:SetVelocity(vel)
			self.m_ActivePounceUntil = CurTime() + 1.35
			self.m_NextPounceHitCheck = CurTime() + 0.08
		end)
	end
end

function ENT:CheckMidAirPounceImpact()
	if self:IsCrow() then
		self.m_ActivePounceUntil = nil
		return
	end
	local ct = CurTime()
	if not self.m_ActivePounceUntil or ct > self.m_ActivePounceUntil then return end
	if ct < (self.m_NextPounceHitCheck or 0) then return end
	self.m_NextPounceHitCheck = ct + 0.06

	local cfg = self:GetClassConfig()
	local reach = cfg.PounceReach or 24
	local size = cfg.PounceSize or 12
	local origin = self:WorldSpaceCenter()
	local dir = self:GetAimVector()

	scratchStartVec:SetUnpacked(origin.x, origin.y, origin.z)
	scratchEndVec:SetUnpacked(origin.x + dir.x * reach, origin.y + dir.y * reach, origin.z + dir.z * reach)
	scratchPounceMin:SetUnpacked(-size, -size, -size)
	scratchPounceMax:SetUnpacked(size, size, size)
	activeFilterNpc = self
	local tr = util.TraceHull(pounceTrData)
	activeFilterNpc = nil

	if tr.Hit and IsValid(tr.Entity) then
		self.m_ActivePounceUntil = nil
		local ent = tr.Entity
		local dmg = cfg.PounceDamage or 16
		if ent:IsPlayer() then
			dmg = dmg * (cfg.PounceDamageVsPlayerMul or 1)
		end

		local dmginfo = DamageInfo()
		dmginfo:SetDamage(dmg)
		dmginfo:SetAttacker(self)
		dmginfo:SetInflictor(self)
		dmginfo:SetDamageType(DMG_SLASH)
		dmginfo:SetDamagePosition(tr.HitPos)
		dmginfo:SetDamageForce(computeNonZeroDamageForce(dir, origin, tr.HitPos, self:GetForward(), math.max(dmg, 1) * 200))

		local entCls = ent:GetClass()
		local sigilBeforeHp = (entCls == "prop_obj_sigil" and ent.GetSigilHealth) and tonumber(ent:GetSigilHealth()) or nil
		local sigilWasCorrupted = (entCls == "prop_obj_sigil") and ((ent.GetSigilCorrupted and ent:GetSigilCorrupted()) or (ent.IsSigilCorrupted and ent:IsSigilCorrupted()) or false) or false

		if ent.IsNailed and ent:IsNailed() and ent.DamageNails then
			ent:DamageNails(self, self, dmg, dmginfo)
			self.D3bot_LastDamage = ct
		elseif ent.TakeDamageInfo then
			ent:TakeDamageInfo(dmginfo)
			if entCls == "prop_obj_sigil" and not sigilWasCorrupted and dmg > 0 then
				local corrupted = (ent.GetSigilCorrupted and ent:GetSigilCorrupted()) or (ent.IsSigilCorrupted and ent:IsSigilCorrupted()) or false
				local sigilAfterHp = ent.GetSigilHealth and tonumber(ent:GetSigilHealth()) or sigilBeforeHp
				if not corrupted and sigilBeforeHp and sigilAfterHp and sigilAfterHp >= sigilBeforeHp
					and D3botNPC.ZS and D3botNPC.ZS.ApplySigilDamage then
					D3botNPC.ZS.ApplySigilDamage(ent, self, dmg, dmginfo)
				end
				self.D3bot_LastDamage = ct
			end
		end

		if D3botNPC.IsBarricadeEntity(ent) and self.D3bot_Mem then
			self.D3bot_Mem.BarricadeAttackEntity = ent
			self.D3bot_Mem.BarricadeAttackPos = tr.HitPos
			self.D3bot_LastDamage = ct
		end

		if ent:IsPlayer() and ent:Team() == TEAM_HUMAN then
			self.D3bot_LastDamage = ct
		end
		self:EmitClassSound("Hit", 75)
	end
end

function ENT:IsClimbing()
	return (self.m_IsClimbingUntil or 0) > CurTime()
end

function ENT:GetClimbSurfaceTrace()
	local myPos = self:GetPos()
	local fwd = self:GetForward()
	scratchStartVec:SetUnpacked(myPos.x, myPos.y, myPos.z + 24)
	scratchEndVec:SetUnpacked(myPos.x + fwd.x * 38, myPos.y + fwd.y * 38, myPos.z + 24)
	return util.TraceLine({
		start = scratchStartVec,
		endpos = scratchEndVec,
		filter = self,
		mask = MASK_SOLID_BRUSHONLY
	})
end

function ENT:Kill()
	if not IsValid(self) or self.m_DeadProcessed then return end
	self.m_SilentRecycle = true
	local pos = self:WorldSpaceCenter()
	local dmg = DamageInfo()
	dmg:SetDamage(math.max(self:Health(), self:GetMaxHealth(), 1000) + 100)
	dmg:SetAttacker(self)
	dmg:SetInflictor(self)
	dmg:SetDamageType(DMG_GENERIC)
	dmg:SetDamagePosition(pos)
	dmg:SetDamageForce(Vector(0, 0, -250))
	self:TakeDamageInfo(dmg)
	if IsValid(self) and not self.m_DeadProcessed then
		self:OnKilled(dmg)
	end
end

function ENT:ExecuteClimb(targetPos)
	if not targetPos then return end
	local cfg = self:GetClassConfig()
	local myPos = self:GetPos()
	local dir2D = Vector(targetPos.x - myPos.x, targetPos.y - myPos.y, 0)
	if dir2D:LengthSqr() > 4 then
		dir2D:Normalize()
	else
		dir2D = self:GetForward()
	end

	if self:IsOnGround() and self.loco then
		self.loco:Jump()
	end

	local dz = targetPos.z - myPos.z
	local upSpeed = (dz > 18) and (cfg.ClimbSpeed or 220) or ((dz < -18) and -40 or 90)
	local fwdSpeed = (dz > 28) and 115 or 175
	local climbVel = dir2D * fwdSpeed + Vector(0, 0, upSpeed)
	if self.loco then
		self.loco:SetVelocity(climbVel)
	end
	self.m_IsClimbingUntil = CurTime() + 0.18
end

function ENT:ExecuteCrowFlight(movePos, shouldFlap)
	local cfg = self:GetClassConfig()
	local flySpeed = cfg.FlyingSpeed or 340
	local myPos = self:GetPos()
	local dir = (movePos - myPos)
	local len = dir:Length()
	if len > 2 then
		dir = dir / len
	else
		dir = self:GetForward()
	end

	if shouldFlap and self:IsOnGround() then
		self.loco:Jump()
	end

	if not self:IsOnGround() then
		local curVel = self.loco:GetVelocity()
		local targetZ = math.Clamp((movePos.z - myPos.z) * 1.4, -140, 200)
		local targetVel = Vector(dir.x * flySpeed, dir.y * flySpeed, targetZ)
		local blended = LerpVector(0.18, curVel, targetVel)
		self.loco:SetVelocity(blended)
	end
end

function ENT:BodyUpdate()
	local cfg = self:GetClassConfig()
	local anims = cfg.Animations or {}
	local vel = self.loco and self.loco:GetVelocity() or self:GetVelocity()
	local speed = vel:Length2D()
	local ct = CurTime()

	local targetAct = anims.Idle or ACT_HL2MP_IDLE_ZOMBIE
	local fallbackSeq = anims.SeqIdle

	if cfg.IsCrow then
		if not self:IsOnGround() then
			targetAct = anims.Fly or ACT_FLY
			fallbackSeq = anims.SeqFly or "Fly01"
		elseif speed > 10 then
			targetAct = anims.Run or ACT_RUN
			fallbackSeq = anims.SeqRun or "Run"
		else
			targetAct = anims.Idle or ACT_IDLE
			fallbackSeq = anims.SeqIdle or "Idle01"
		end
	elseif self.m_IsClimbingUntil and ct < self.m_IsClimbingUntil and anims.Climb then
		targetAct = anims.Climb
	elseif not self:IsOnGround() then
		if self.m_ActivePounceUntil and ct < self.m_ActivePounceUntil and anims.Leaping then
			targetAct = anims.Leaping
		else
			targetAct = anims.Jump or anims.Idle or ACT_HL2MP_JUMP_ZOMBIE
		end
	elseif self:Crouching() then
		if speed > 15 then
			targetAct = anims.CrouchWalk or anims.Walk or targetAct
		else
			targetAct = anims.CrouchIdle or anims.Idle or targetAct
		end
	elseif speed > 15 then
		targetAct = (speed > (cfg.WalkSpeed or 110)) and (anims.Run or anims.Walk or targetAct) or (anims.Walk or anims.Run or targetAct)
	end

	self:PlaySafeActivity(targetAct, fallbackSeq)

	-- Drive 2D move & aim pose parameters cleanly for humanoid zombie models
	local maxSpd = math.max(self:GetMaxSpeed(), 1)
	local fwd = self:GetForward():Dot(vel) / maxSpd
	local right = self:GetRight():Dot(vel) / maxSpd
	self:SetPoseParameter("move_x", math.Clamp(fwd, -1, 1))
	self:SetPoseParameter("move_y", math.Clamp(right, -1, 1))

	local eyeAng = self:EyeAngles()
	local entAng = self:GetAngles()
	local pitch = math.NormalizeAngle(eyeAng.p)
	local yawDiff = math.NormalizeAngle(eyeAng.y - entAng.y)
	self:SetPoseParameter("aim_pitch", math.Clamp(pitch, -65, 65))
	self:SetPoseParameter("aim_yaw", math.Clamp(yawDiff, -60, 60))

	self:FrameAdvance()
end

function ENT:OnStuck()
	if D3botNPC and D3botNPC.AI and D3botNPC.AI.NotifyNextBotStuck then
		D3botNPC.AI.NotifyNextBotStuck(self)
	end
	if self.loco and self.loco.ClearStuck then
		self.loco:ClearStuck()
	end
end

function ENT:OnUnStuck()
	if self.D3bot_Mem then
		self.D3bot_Mem.NextBotStuckFlag = false
	end
end

function ENT:OnLandOnGround(ent)
	if self.D3bot_Mem then
		if self.D3bot_Mem.pouncing then
			self.D3bot_Mem.pouncing = false
			self.D3bot_Mem.pounceFlightTime = nil
		end
		if self.D3bot_UpdatePathProgress then
			self:D3bot_UpdatePathProgress()
		end
	end
	self.m_ActivePounceUntil = nil
	self.m_PounceSeqStarted = false
end

function ENT:RunBehaviour()
	local faceVec = self.m_FaceVec or Vector()
	local moveVec = self.m_MoveVec or Vector()
	local destVec = self.m_DestVec or Vector()
	self.m_FaceVec = faceVec
	self.m_MoveVec = moveVec
	self.m_DestVec = destVec

	while IsValid(self) and self:Alive() do
		local ct = CurTime()

		if ct >= (self.m_NextIdleSound or 0) then
			self.m_NextIdleSound = ct + math.Rand(5, 11)
			self:EmitClassSound("Idle", 68)
		end

		self:CheckMidAirPounceImpact()

		local cmd = self.D3bot_Cmd
		local mem = self.D3bot_Mem
		local cfg = self:GetClassConfig()

		if cmd then
			local viewAng = cmd.ViewAngles or self:EyeAngles()
			self:SetEyeAngles(viewAng)

			local buttons = cmd.Buttons or 0
			local wantDuck = bit.band(buttons, IN_DUCK) ~= 0
			local wantJump = bit.band(buttons, IN_JUMP) ~= 0
			local wantAttack = bit.band(buttons, IN_ATTACK) ~= 0
			local wantAttack2 = bit.band(buttons, IN_ATTACK2) ~= 0
			local wantUse = bit.band(buttons, IN_USE) ~= 0

			self:UpdateCrouchState(wantDuck)

			local myPos = self:GetPos()
			local fwdMove = cmd.ForwardMove or 0
			local sideMove = cmd.SideMove or 0

			-- Reconstruct desired world velocity from D3bot CUserCmd view yaw + ForwardMove/SideMove
			moveVec:SetUnpacked(fwdMove, -sideMove, 0)
			moveVec:Rotate(Angle(0, viewAng.y, 0))
			local desiredSpeed = math.min(moveVec:Length2D(), self:GetMaxSpeed())

			-- Face target/look direction
			local fwdDir = viewAng:Forward()
			if IsValid(mem and mem.TgtOrNil) and wantAttack then
				local atkPt = mem.TgtOrNil.NearestPoint and mem.TgtOrNil:NearestPoint(myPos) or mem.TgtOrNil:WorldSpaceCenter()
				faceVec:SetUnpacked(atkPt.x, atkPt.y, myPos.z)
			else
				faceVec:SetUnpacked(myPos.x + fwdDir.x * 128, myPos.y + fwdDir.y * 128, myPos.z)
			end
			self.loco:FaceTowards(faceVec)

			local isPounceWinding = false
			if cfg.CanPounce and not self:IsCrow() then
				local pounceNow = (mem and mem.pouncing) or (cfg.IsCrab and mem and mem.PounceActive)
				if pounceNow then
					if not self.m_PounceSeqStarted and self:IsOnGround() and ct >= self:GetNextPounceTime() then
						self.m_PounceSeqStarted = true
						self.m_PounceWindupEnd = ct + (cfg.PounceStartDelay or 0.5)
						self:ExecutePounce({ triggerNow = true, aimAngle = viewAng })
					end
					if self.m_PounceWindupEnd and ct < self.m_PounceWindupEnd then
						isPounceWinding = true
					end
				else
					self.m_PounceSeqStarted = false
				end
			end

			if isPounceWinding then
				self.loco:SetDesiredSpeed(0)
			elseif moveVec:Length2DSqr() > 1 then
				destVec:SetUnpacked(myPos.x + moveVec.x, myPos.y + moveVec.y, myPos.z)
				self.loco:SetDesiredSpeed(desiredSpeed)
				self.loco:Approach(destVec, 1)
			else
				self.loco:SetDesiredSpeed(0)
			end

			if self:IsCrow() then
				local crowDest = (moveVec:Length2DSqr() > 1) and destVec or (myPos + fwdDir * 160 + Vector(0, 0, 48))
				self:ExecuteCrowFlight(crowDest, wantJump)
			elseif wantJump and self:IsOnGround() then
				self.loco:Jump()
			end

			-- Wall climbing for Fast Zombie / Lacerator / Classic Zombie / Bonemesh
			local climbHandled = false
			if cfg.CanClimb and wantAttack2 and not self:IsCrow() then
				local climbTr = self:GetClimbSurfaceTrace()
				if climbTr and climbTr.Hit then
					local nextPos = (mem and mem.NextNodeOrNil and (mem.NextNodeOrNil.Pos or (IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetCenter()))) or (myPos + fwdDir * 48 + Vector(0, 0, 72))
					self:ExecuteClimb(nextPos)
					climbHandled = true
				end
			end

			if not self:IsCrow() then
				if wantUse then
					scratchStartVec:SetUnpacked(myPos.x, myPos.y, myPos.z + 36)
					scratchEndVec:SetUnpacked(myPos.x + fwdDir.x * 58, myPos.y + fwdDir.y * 58, myPos.z + 36)
					local useTr = util.TraceLine({
						start = scratchStartVec,
						endpos = scratchEndVec,
						filter = self,
						mask = MASK_SOLID
					})
					if IsValid(useTr.Entity) then
						self:TryOpenOrBreakDoor(useTr.Entity)
					end
				end

				if wantAttack2 and not climbHandled and cfg.RangedAttack and IsValid(mem and mem.TgtOrNil) then
					local tgtDistSqr = mem.TgtOrNil:GetPos():DistToSqr(myPos)
					local minR = (cfg.RangedAttack.MinRange or 140) ^ 2
					local maxR = (cfg.RangedAttack.MaxRange or 750) ^ 2
					if tgtDistSqr >= minR and tgtDistSqr <= maxR and self:D3bot_CanSeeTarget(nil, mem.TgtOrNil) then
						self:TryRangedAttack(mem.TgtOrNil)
					end
				end

				if wantAttack and not (cfg.IsCrab and (mem and (mem.pouncing or mem.PounceActive))) then
					local preferred = (mem and IsValid(mem.BarricadeAttackEntity) and mem.BarricadeAttackEntity) or (mem and mem.TgtOrNil)
					self:TryMeleeAttack(preferred)
				end
			end
		end

		coroutine.yield()
	end
end

function ENT:OnTraceAttack(dmginfo, dir, trace)
	self.m_LastHitGroup = trace and trace.HitGroup or HITGROUP_GENERIC
	local cfg = self:GetClassConfig()

	if self.m_LastHitGroup == HITGROUP_HEAD and not cfg.NoHeadbox then
		local inf = dmginfo:GetInflictor()
		local hsMul = (IsValid(inf) and inf.HeadshotMulti) or 2
		dmginfo:ScaleDamage(hsMul)
	elseif not cfg.IsCrow and (self.m_LastHitGroup == HITGROUP_LEFTLEG or self.m_LastHitGroup == HITGROUP_RIGHTLEG) then
		dmginfo:ScaleDamage(0.5)
		self:AddLegDamage(1.5)
	end
end

function ENT:OnInjured(dmginfo)
	if not IsValid(self) or not self:Alive() then return end

	local ct = CurTime()
	if ct >= (self.m_NextPainSound or 0) then
		self.m_NextPainSound = ct + 0.55
		self:EmitClassSound("Pain", 75)
	end
end

function ENT:OnKilled(dmginfo)
	if self.m_DeadProcessed then return end
	self.m_DeadProcessed = true
	self:SetNPCLiving(false)
	D3botNPC.UnregisterNPC(self)

	if D3botNPC.Roster and D3botNPC.Roster.UnbindEntityOnDeath then
		D3botNPC.Roster.UnbindEntityOnDeath(self)
	end

	-- Silent stuck/admin recycle: clean respawn without fake death sound, scoreboard death, or ragdoll
	if self.m_SilentRecycle then
		if self.D3bot_Deinitialize then self:D3bot_Deinitialize() end
		hook.Run("D3botNPC_OnZombieKilled", self, nil, nil, dmginfo, nil, false)
		SafeRemoveEntity(self)
		return
	end

	self:EmitClassSound("Death", 78)
	D3botNPC.ZS.OnNPCZombieKilled(self, dmginfo)
	if self.D3bot_Deinitialize then self:D3bot_Deinitialize() end

	-- Bloated Zombie poison death splash (matches authentic ZS Bloated behavior safely)
	local cfg = self:GetClassConfig()
	if cfg and cfg.UsePoisonDamage and not self:IsCrow() and not (GAMEMODE and GAMEMODE.RoundEnded) then
		local splashOrigin = self:WorldSpaceCenter()
		local splashRadius = 110
		local edSplash = EffectData()
		edSplash:SetOrigin(splashOrigin)
		edSplash:SetNormal(Vector(0, 0, 1))
		util.Effect("BloodImpact", edSplash, true, true)
		self:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(1, 4) .. ".wav", 75)

		for _, ply in ipairs(player.GetAll()) do
			if IsValid(ply) and ply:Alive() and ply:Team() == (TEAM_HUMAN or 4) then
				local tgtPt = ply:WorldSpaceCenter()
				local dist = splashOrigin:Distance(tgtPt)
				if dist <= splashRadius then
					scratchStartVec:SetUnpacked(splashOrigin.x, splashOrigin.y, splashOrigin.z)
					scratchEndVec:SetUnpacked(tgtPt.x, tgtPt.y, tgtPt.z)
					local visTr = util.TraceLine({
						start = scratchStartVec,
						endpos = scratchEndVec,
						mask = MASK_SOLID_BRUSHONLY
					})
					if not visTr.Hit then
						local frac = 1 - (dist / splashRadius) * 0.5
						if ply.AddPoisonDamage then
							ply:AddPoisonDamage(math.Round(18 * frac), self)
						else
							local poisonDmg = DamageInfo()
							poisonDmg:SetDamage(math.Round(14 * frac))
							poisonDmg:SetAttacker(self)
							poisonDmg:SetInflictor(self)
							poisonDmg:SetDamageType(DMG_POISON)
							poisonDmg:SetDamagePosition(tgtPt)
							poisonDmg:SetDamageForce(computeNonZeroDamageForce(tgtPt - splashOrigin, splashOrigin, tgtPt, Vector(0, 0, 1), 180))
							ply:TakeDamageInfo(poisonDmg)
						end
					end
				end
			end
		end
	end

	local gib = dmginfo and dmginfo:IsDamageType(DMG_ALWAYSGIB)
	local ragLife = D3botNPC.ConVars.RagdollLifetime and D3botNPC.ConVars.RagdollLifetime:GetFloat() or 8

	if self:IsCrow() then
		ragLife = math.min(ragLife, 3)
	end

	if not gib and ragLife > 0 then
		local rag = ents.Create("prop_ragdoll")
		if IsValid(rag) then
			rag:SetModel(self:GetModel())
			rag:SetPos(self:GetPos())
			rag:SetAngles(self:GetAngles())
			rag:SetSkin(self:GetSkin() or 0)
			rag:SetModelScale(self:GetModelScale() or 1, 0)
			rag:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
			rag:Spawn()

			local force = dmginfo and dmginfo:GetDamageForce() or vector_origin
			for i = 0, rag:GetPhysicsObjectCount() - 1 do
				local phys = rag:GetPhysicsObjectNum(i)
				if IsValid(phys) then
					phys:ApplyForceCenter(force * 0.15)
				end
			end

			SafeRemoveEntityDelayed(rag, ragLife)
		end
	elseif gib then
		local ed = EffectData()
		ed:SetOrigin(self:WorldSpaceCenter())
		ed:SetNormal(Vector(0, 0, 1))
		util.Effect("BloodImpact", ed, true, true)
	end

	SafeRemoveEntity(self)
end

if D3botNPC and D3botNPC.ApplyNPCMethods then
	D3botNPC.ApplyNPCMethods(ENT)
end
