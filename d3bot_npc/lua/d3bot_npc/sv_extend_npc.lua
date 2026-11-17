-- Faithful port of D3bot sv_extend_player.lua adapted to slotless base_nextbot NPCs (d3bot_npc_zombie)
-- Preserves D3bot target positioning, velocity-lead aim, pounce trajectory checking, LOS caching,
-- offshoot angles, barricade detection, class rerolling, navmesh path progression, and stuck detection,
-- while inheriting d3bot_npc's fast A* pathfinder and bad-sigil-node main-component snapping.

local lib = D3botNPC

lib.NPCMethods = lib.NPCMethods or {}
local meta = lib.NPCMethods

local scratchSeenStart = Vector()
local scratchSeenEnd = Vector()
local seeTrFilterNpc = nil

local function canSeeTargetFilter(ent)
	if not IsValid(ent) then return false end
	if ent == seeTrFilterNpc or ent.IsD3botNPC then return false end
	if ent:IsPlayer() then return false end
	return true
end

local function adjustNodeCongestion(mem, newNode)
	if not mem or newNode == mem.LastCongestionNode then return end
	if mem.LastCongestionNode and lib.NodeCongestion then
		local prevCount = lib.NodeCongestion[mem.LastCongestionNode] or 0
		if prevCount <= 1 then
			lib.NodeCongestion[mem.LastCongestionNode] = nil
		else
			lib.NodeCongestion[mem.LastCongestionNode] = prevCount - 1
		end
	end
	if newNode and lib.NodeCongestion then
		lib.NodeCongestion[newNode] = (lib.NodeCongestion[newNode] or 0) + 1
	end
	mem.LastCongestionNode = newNode
end

local function adjustLinkCongestion(mem, newLink)
	if not mem or newLink == mem.LastCongestionLink then return end
	if mem.LastCongestionLink and lib.LinkCongestion then
		local prevCount = lib.LinkCongestion[mem.LastCongestionLink] or 0
		if prevCount <= 1 then
			lib.LinkCongestion[mem.LastCongestionLink] = nil
		else
			lib.LinkCongestion[mem.LastCongestionLink] = prevCount - 1
		end
	end
	if newLink and lib.LinkCongestion then
		lib.LinkCongestion[newLink] = (lib.LinkCongestion[newLink] or 0) + 1
	end
	mem.LastCongestionLink = newLink
end

local function syncLinkFromNodes(mem)
	if not mem then return end
	if not mem.NodeOrNil or not mem.NextNodeOrNil then
		adjustLinkCongestion(mem, nil)
		return
	end
	if lib.UsingSourceNav then
		if IsValid(mem.NodeOrNil) and IsValid(mem.NextNodeOrNil) and mem.NodeOrNil.D3botNPC_SharesLink then
			adjustLinkCongestion(mem, mem.NodeOrNil:D3botNPC_SharesLink(mem.NextNodeOrNil))
		else
			adjustLinkCongestion(mem, nil)
		end
	else
		local link = mem.NodeOrNil.LinkByLinkedNode and mem.NodeOrNil.LinkByLinkedNode[mem.NextNodeOrNil] or nil
		adjustLinkCongestion(mem, link)
	end
end

local function createFakeCmd()
	return {
		ViewAngles = Angle(0, 0, 0),
		ForwardMove = 0,
		SideMove = 0,
		UpMove = 0,
		Buttons = 0,
		ClearButtons = function(self) self.Buttons = 0 end,
		ClearMovement = function(self)
			self.ForwardMove = 0
			self.SideMove = 0
			self.UpMove = 0
		end,
		SetButtons = function(self, b) self.Buttons = b or 0 end,
		GetButtons = function(self) return self.Buttons or 0 end,
		SetViewAngles = function(self, ang) self.ViewAngles = ang or angle_zero end,
		GetViewAngles = function(self) return self.ViewAngles or angle_zero end,
		SetForwardMove = function(self, v) self.ForwardMove = v or 0 end,
		GetForwardMove = function(self) return self.ForwardMove or 0 end,
		SetSideMove = function(self, v) self.SideMove = v or 0 end,
		GetSideMove = function(self) return self.SideMove or 0 end,
		SetUpMove = function(self, v) self.UpMove = v or 0 end,
		GetUpMove = function(self) return self.UpMove or 0 end
	}
end

---Get attack position for the target entity.
function meta:D3bot_GetAttackPosOrNil(fraction, target)
	local mem = self.D3bot_Mem
	local tgt = target or (mem and mem.TgtOrNil)
	if not tgt or not IsValid(tgt) then return end
	return tgt:IsPlayer() and LerpVector(fraction or 0.75, tgt:GetPos(), tgt:EyePos()) or tgt:WorldSpaceCenter()
end

---Linear extrapolated attack position for the target entity in the future.
function meta:D3bot_GetAttackPosOrNilFuture(fraction, t)
	local mem = self.D3bot_Mem
	local tgt = mem and mem.TgtOrNil
	if not tgt or not IsValid(tgt) then return end
	return tgt:IsPlayer() and (LerpVector(fraction or 0.75, tgt:GetPos(), tgt:EyePos()) + tgt:GetVelocity() * (t or 0)) or tgt:WorldSpaceCenter()
end

---Linear extrapolated attack position in the future using physics velocity when available.
function meta:D3bot_GetAttackPosOrNilFuturePlatforms(fraction, t)
	local mem = self.D3bot_Mem
	local tgt = mem and mem.TgtOrNil
	if not tgt or not IsValid(tgt) then return end
	if not tgt:IsPlayer() then
		return tgt:WorldSpaceCenter()
	end
	local phys = tgt.GetPhysicsObject and tgt:GetPhysicsObject() or nil
	local vel = IsValid(phys) and phys:GetVelocity() or tgt:GetVelocity()
	return LerpVector(fraction or 0.75, tgt:GetPos(), tgt:EyePos()) + vel * (t or 0)
end

function meta:D3bot_IsLookingAt(targetPos, conditionCos)
	return self:GetAimVector():Dot((targetPos - self:EyePos()):GetNormalized()) > (conditionCos or 0.95)
end

function meta:D3bot_CanPounceToPos(pos)
	if not pos then return end

	local weapon = self.GetActiveWeapon and self:GetActiveWeapon() or nil
	if not weapon or not weapon.PounceVelocity then
		return
	end

	local maxLeg = (GAMEMODE and GAMEMODE.MaxLegDamage) or 3
	local legFrac = math.Clamp((self.GetLegDamage and self:GetLegDamage() or 0) / math.max(maxLeg, 1), 0, 1)
	local initVel = (1 - 0.5 * legFrac) * (weapon.PounceVelocity or 400)

	local selfPos = self:GetPos()
	local trajectories = lib.GetTrajectories(initVel, selfPos, pos, 8)
	local resultTrajectories = {}
	for _, trajectory in ipairs(trajectories) do
		local lastPoint = nil
		local hit = false
		for _, point in ipairs(trajectory.points) do
			if lastPoint then
				local tr = util.TraceEntity({
					start = point,
					endpos = lastPoint,
					mask = CONTENTS_SOLID + CONTENTS_GRATE + CONTENTS_MOVEABLE + CONTENTS_PLAYERCLIP
				}, self)
				if tr.Hit and pos:DistToSqr(tr.HitPos) > 16 * 16 then
					hit = true
					break
				end
			end
			lastPoint = point
		end
		if not hit then
			table.insert(resultTrajectories, trajectory)
		end
	end
	if #resultTrajectories == 0 then resultTrajectories = nil end
	return resultTrajectories
end

function meta:D3bot_CanSeeTargetCached(fraction, target)
	local mem = self.D3bot_Mem
	if not mem then return end
	local ct = CurTime()
	if not mem.CanSeeTargetCache or mem.CanSeeTargetCache.ValidUntil < ct then
		mem.CanSeeTargetCache = {
			ValidUntil = ct + 0.9 + math.random() * 0.2,
			Result = self:D3bot_CanSeeTarget(fraction, target)
		}
	end
	return mem.CanSeeTargetCache.Result
end

function meta:D3bot_CanSeeTarget(fraction, target)
	local attackPos = self:D3bot_GetAttackPosOrNil(fraction, target)
	if not attackPos then return false end
	local mem = self.D3bot_Mem
	if mem and mem.TgtNodeOrNil and mem.NodeOrNil ~= mem.TgtNodeOrNil then
		if lib.UsingSourceNav then
			local md = mem.TgtNodeOrNil.D3botNPC_GetMetaData and mem.TgtNodeOrNil:D3botNPC_GetMetaData()
			if md and md.Params and md.Params.See == "Disabled" then return false end
		elseif mem.TgtNodeOrNil.Params and mem.TgtNodeOrNil.Params.See == "Disabled" then
			return false
		end
	end
	local tr = lib.BotSeeTr
	local eye = self:EyePos()
	scratchSeenStart:SetUnpacked(eye.x, eye.y, eye.z)
	scratchSeenEnd:SetUnpacked(attackPos.x, attackPos.y, attackPos.z)
	tr.start = scratchSeenStart
	tr.endpos = scratchSeenEnd
	seeTrFilterNpc = self
	tr.filter = canSeeTargetFilter
	local res = util.TraceHull(tr)
	seeTrFilterNpc = nil
	return not res.Hit
end

function meta:D3bot_AngsRotateTo(angle, lerpFactor)
	local mem = self.D3bot_Mem
	if not mem or not angle then return end
	mem.Angs = LerpAngle(lerpFactor or 0.2, mem.Angs or angle_zero, angle)
end

function meta:D3bot_GetOffshoot(offshootFactor)
	local mem = self.D3bot_Mem
	if not mem then return angle_zero end
	local factor = offshootFactor or 1
	if factor == 1 then return mem.AngsOffshoot or angle_zero end
	if factor == 0 then return angle_zero end
	return (mem.AngsOffshoot or angle_zero) * factor
end

local barricadeTraceData = {
	mask = MASK_SOLID,
	collisiongroup = COLLISION_GROUP_DEBRIS_TRIGGER,
	ignoreworld = true
}

function meta:D3bot_FindBarricadeEntity(samples)
	barricadeTraceData.filter = self
	local weapon = self.GetActiveWeapon and self:GetActiveWeapon() or {}
	local start = self:GetShootPos()
	barricadeTraceData.start = start
	local dir = self:GetAimVector()
	local reach = math.max((weapon and weapon.MeleeReach) or 48, 30)

	for _ = 1, (samples or 1) do
		barricadeTraceData.endpos = start + (dir + VectorRand(-1, 1)):GetNormalized() * reach
		local tr = util.TraceLine(barricadeTraceData)
		local trEntity = tr.Entity
		if tr.Hit and IsValid(trEntity) and trEntity.D3bot_IsBarricade and trEntity:D3bot_IsBarricade() then
			return trEntity, tr.HitPos
		end
	end

	return nil, nil
end

function meta:D3bot_RerollClass(classes)
	if not lib.GetWaveActive or not lib.GetWaveActive() then return end
	if not GAMEMODE then return end
	if GAMEMODE.ZombieEscape or GAMEMODE.PantsMode
		or (GAMEMODE.IsClassicMode and GAMEMODE:IsClassicMode())
		or (GAMEMODE.IsBabyMode and GAMEMODE:IsBabyMode()) then
		return
	end
	if self.D3bot_RosterSlot and self.D3bot_RosterSlot.ForcedClass then return end

	local wave = lib.GetCurrentWave()
	local eligible = {}
	for _, className in ipairs(classes or {}) do
		local zc = GAMEMODE.ZombieClasses and GAMEMODE.ZombieClasses[className]
		local unlocked = false
		if zc then
			unlocked = (not zc.Locked) and (zc.Unlocked or ((zc.Wave or 0) <= wave))
		elseif lib.IsNPCClassUnlocked then
			unlocked = lib.IsNPCClassUnlocked(className)
		end
		if unlocked and lib.GetClassConfig then
			local cfg = lib.GetClassConfig(className)
			if cfg and not cfg.IsCrow and not cfg.Boss then
				table.insert(eligible, cfg.Name)
			end
		end
	end

	local chosenName = (#eligible > 0) and eligible[math.random(1, #eligible)] or nil
	if not chosenName and lib.Population and lib.Population.SelectSpawnClass then
		local fallbackCfg = lib.Population.SelectSpawnClass()
		chosenName = fallbackCfg and fallbackCfg.Name or "Zombie"
	end
	if chosenName and self.D3bot_RosterSlot then
		self.D3bot_RosterSlot.DeathClass = chosenName
	end
	self.m_NonCrowClass = chosenName or self.m_NonCrowClass
end

function meta:D3bot_ResetTgt()
	local mem = self.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = nil, nil, nil
	mem.PosTgtOrNil, mem.PosTgtProximity = nil, nil
	mem.NodeTgtOrNil = nil
	mem.NodeOrNil = nil
	mem.NextNodeOrNil = nil
	mem.RemainingNodes = {}
	mem.ObjectiveType = nil
	adjustNodeCongestion(mem, nil)
	adjustLinkCongestion(mem, nil)
end

function meta:D3bot_SetTgtOrNil(target, dontAttack, proximity)
	local mem = self.D3bot_Mem
	if not mem then return end
	if mem.TgtOrNil ~= target then
		mem.CanSeeTargetCache = nil
	end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = target, dontAttack, proximity
	mem.PosTgtOrNil, mem.PosTgtProximity = nil, nil
	mem.NodeTgtOrNil = nil
	if IsValid(target) then
		if target:IsPlayer() then
			mem.ObjectiveType = "human"
		elseif target:GetClass() == "prop_obj_sigil" then
			mem.ObjectiveType = "sigil"
		else
			mem.ObjectiveType = "deployable"
		end
	else
		mem.ObjectiveType = nil
	end
end

function meta:D3bot_SetPosTgtOrNil(targetPos, proximity)
	local mem = self.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = nil, nil, nil
	mem.PosTgtOrNil, mem.PosTgtProximity = targetPos, proximity
	mem.NodeTgtOrNil = nil
	mem.ObjectiveType = targetPos and "pos" or nil
end

function meta:D3bot_SetNodeTgtOrNil(targetNode)
	local mem = self.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = nil, nil, nil
	mem.PosTgtOrNil, mem.PosTgtProximity = nil, nil
	mem.NodeTgtOrNil = targetNode
	mem.ObjectiveType = targetNode and "node" or nil
end

function meta:D3bot_InitializeOrReset()
	self.D3bot_Mem = self.D3bot_Mem or {}
	local mem = self.D3bot_Mem

	adjustNodeCongestion(mem, nil)
	adjustLinkCongestion(mem, nil)

	local considerPathLethality = math.random(1, lib.BotConsideringDeathCostAntichance or 3) == 1

	mem.TgtOrNil = nil
	mem.PosTgtOrNil = nil
	mem.NodeTgtOrNil = nil
	mem.TgtNodeOrNil = nil
	mem.NodeOrNil = nil
	mem.NextNodeOrNil = nil
	mem.RemainingNodes = {}
	mem.ConsidersPathLethality = considerPathLethality
	mem.Angs = Angle(0, self:GetAngles().y, 0)
	mem.AngsOffshoot = angle_zero
	mem.CanSeeTargetCache = nil

	mem.DontAttackTgt = nil
	mem.TgtProximity = nil
	mem.PosTgtProximity = nil
	mem.NextCheckStuck = nil
	mem.MajorStuckCounter = nil
	mem.AntiStuckCounter = nil
	mem.AntiStuckTime = nil
	mem.BarricadeAttackEntity = nil
	mem.BarricadeAttackPos = nil
	mem.BlockMovementUntil = nil
	mem.BlockedOnNode = nil
	mem.pouncing = false
	mem.pouncingTimer = nil
	mem.pouncingStartTime = nil
	mem.pounceFlightTime = nil
	mem.PounceActive = nil
	mem.NextPounce = nil
	mem.NextThrowPoisonTime = nil
	mem.nextCheckTarget = nil
	mem.nextUpdateOffshoot = nil
	mem.nextUpdatePath = nil
	mem.nextUpdateSurroundingPlayers = nil
	mem.UnreachableTargets = nil
	mem.ObjectiveType = nil
	mem.StuckStateName = "OK"
	mem.StuckTier = 0
	mem.PathRecalcCount = mem.PathRecalcCount or 0
	mem.RecoveryAttempts = 0

	mem.IsCrab = false
	mem.Height = 72
	mem.CrouchHeight = 36
	mem.JumpHeight = 30
	mem.JumpCrouchHeight = 68
	mem.CrouchJumpHeight = 70
	mem.IsOnLadder = false

	self.D3bot_Cmd = self.D3bot_Cmd or createFakeCmd()

	local function computeStats()
		if not IsValid(self) or not self.D3bot_Mem then return end
		local m = self.D3bot_Mem
		local weapon = self.GetActiveWeapon and self:GetActiveWeapon() or nil
		m.IsCrab = (weapon and (weapon.HitRecovery or weapon.SpitWindUp)) and true or false

		local myClass = self.GetClassConfig and self:GetClassConfig() or (self.GetZombieClassTable and self:GetZombieClassTable()) or {}
		local scale = (self.GetModelScale and self:GetModelScale()) or 1
		m.Height = (myClass.Hull and myClass.Hull[2].z or 72) * scale
		m.CrouchHeight = (myClass.HullDuck and myClass.HullDuck[2].z or 36) * scale

		local gravZ = -600
		if physenv and physenv.GetGravity then
			local gz = physenv.GetGravity().z
			if math.abs(gz) > 1 then gravZ = gz end
		end
		local entGrav = (self.GetGravity and self:GetGravity() ~= 0) and self:GetGravity() or 1
		local g = gravZ * entGrav

		local jp = myClass.JumpPower or DEFAULT_JUMP_POWER or 200
		m.JumpHeight = lib.CalculateJumpHeight(jp, g, false)
		m.JumpCrouchHeight = lib.CalculateJumpHeight(jp, g, false) + (m.Height - m.CrouchHeight)
		m.CrouchJumpHeight = lib.CalculateJumpHeight(jp, g, true) + (m.Height - m.CrouchHeight)
	end

	computeStats()
	timer.Simple(0, computeStats)
end

function meta:D3bot_Deinitialize()
	if self.D3bot_Mem then
		adjustNodeCongestion(self.D3bot_Mem, nil)
		adjustLinkCongestion(self.D3bot_Mem, nil)
	end
	self.D3bot_Mem = nil
end

function meta:D3bot_UpdateAngsOffshoot(angOffshoot)
	local mem = self.D3bot_Mem
	if not mem then return end
	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil

	if lib.UsingSourceNav then
		local nParams = nodeOrNil and IsValid(nodeOrNil) and nodeOrNil.D3botNPC_GetMetaData and nodeOrNil:D3botNPC_GetMetaData().Params
		local nnParams = nextNodeOrNil and IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_GetMetaData and nextNodeOrNil:D3botNPC_GetMetaData().Params
		local link = (nodeOrNil and nextNodeOrNil and nextNodeOrNil.D3botNPC_SharesLink) and nextNodeOrNil:D3botNPC_SharesLink(nodeOrNil) or nil
		local lParams = link and link.GetMetaData and link:GetMetaData().Params
		if (nParams and nParams.Aim == "Straight") or (nnParams and nnParams.AimTo == "Straight") or (lParams and lParams.CrabPouncing == "Needed") then
			mem.AngsOffshoot = angle_zero
			return
		end
	else
		local link = (nodeOrNil and nextNodeOrNil and nextNodeOrNil.LinkByLinkedNode) and nextNodeOrNil.LinkByLinkedNode[nodeOrNil] or nil
		if (nodeOrNil and nodeOrNil.Params and nodeOrNil.Params.Aim == "Straight")
			or (nextNodeOrNil and nextNodeOrNil.Params and nextNodeOrNil.Params.AimTo == "Straight")
			or (link and link.Params and link.Params.CrabPouncing == "Needed") then
			mem.AngsOffshoot = angle_zero
			return
		end
	end

	local spread = angOffshoot or 45
	mem.AngsOffshoot = Angle(math.random(-spread, spread), math.random(-spread, spread), 0)
end

function meta:D3bot_SetPath(path, noReset)
	if not path then return end
	if not noReset then self:D3bot_ResetTgt() end
	local mem = self.D3bot_Mem
	if not mem then return end
	if mem.NextNodeOrNil and mem.NextNodeOrNil == path[1] then
		table.insert(path, 1, mem.NodeOrNil)
	end
	mem.NodeOrNil = table.remove(path, 1)
	mem.NextNodeOrNil = table.remove(path, 1)
	mem.RemainingNodes = path
	adjustNodeCongestion(mem, mem.NodeOrNil)
	syncLinkFromNodes(mem)
end

function meta:D3bot_UpdatePath(pathCostFunction, heuristicCostFunction)
	local mem = self.D3bot_Mem
	if not mem then return end
	if not IsValid(mem.TgtOrNil) and not mem.PosTgtOrNil and not mem.NodeTgtOrNil then return end

	local abilities = {
		Walk = true,
		Jump = mem.CrouchJumpHeight or 70,
		Height = mem.CrouchHeight or 36,
		Crab = mem.IsCrab,
		NoFallDamage = (self.GetClassConfig and self:GetClassConfig().NoFallDamage) or false
	}
	local weapon = self.GetActiveWeapon and self:GetActiveWeapon() or nil
	if weapon then
		if weapon.PounceVelocity then abilities.Pounce = true end
		if weapon.GetClimbing then abilities.Climb = true end
	end

	if lib.UsingSourceNav then
		if not navmesh or not navmesh.GetNearestNavArea then return end
		local area = navmesh.GetNearestNavArea(self:GetPos())
		mem.TgtNodeOrNil = mem.NodeTgtOrNil or navmesh.GetNearestNavArea(IsValid(mem.TgtOrNil) and mem.TgtOrNil:GetPos() or mem.PosTgtOrNil)
		if not IsValid(area) or not IsValid(mem.TgtNodeOrNil) then return end
		local path = lib.GetBestValveMeshPathOrNil(area, mem.TgtNodeOrNil, pathCostFunction, heuristicCostFunction, abilities)
		if not path then
			if not mem.PathRerollGuard then
				mem.PathRerollGuard = true
				local handler = lib.FindHandler and lib.FindHandler(self:GetZombieClass(), self:Team(), self)
				if handler and handler.RerollTarget then handler.RerollTarget(self) end
				mem.PathRerollGuard = nil
			end
			return
		end
		mem.PathRecalcCount = (mem.PathRecalcCount or 0) + 1
		self:D3bot_SetPath(path, true)
		return
	end

	local mapNavMesh = lib.MapNavMesh
	if not mapNavMesh then return end

	local myPos = self:GetPos()
	local tgtPos = IsValid(mem.TgtOrNil) and mem.TgtOrNil:GetPos() or mem.PosTgtOrNil
	local wave = lib.GetCurrentWave()

	-- Use D3botNPC's component/directed-reachable snapping to avoid isolated or "bad sigil nodes"
	local tgtNode = mem.NodeTgtOrNil
	if not tgtNode and tgtPos then
		if mapNavMesh.GetBestNodeNear then
			tgtNode = mapNavMesh:GetBestNodeNear(tgtPos, {
				wave = wave,
				requireLinked = true,
				requireDirectedReachable = true,
				preferredComponentId = mapNavMesh.MainComponentId,
				checkLOS = true
			})
		elseif mapNavMesh.GetNearestNodeOrNil then
			tgtNode = mapNavMesh:GetNearestNodeOrNil(tgtPos)
		end
	end
	mem.TgtNodeOrNil = tgtNode

	local node
	if mapNavMesh.GetBestNodeNear then
		node = mapNavMesh:GetBestNodeNear(myPos, {
			wave = wave,
			requireLinked = true,
			preferredComponentId = (tgtNode and tgtNode.RuntimeComponentId) or mapNavMesh.MainComponentId,
			checkLOS = true
		})
	elseif mapNavMesh.GetNearestNodeOrNil then
		node = mapNavMesh:GetNearestNodeOrNil(myPos)
	end

	if not node or not mem.TgtNodeOrNil then return end

	local path = lib.GetBestMeshPathOrNil(node, mem.TgtNodeOrNil, pathCostFunction, heuristicCostFunction, abilities)

	-- If initial nearest target node was off-component / one-way unreachable, try one reachable alternate nearby
	if not path and tgtPos and mapNavMesh.GetBestNodeNear then
		local altTgt = mapNavMesh:GetBestNodeNear(tgtPos, {
			wave = wave,
			requireLinked = true,
			requireDirectedReachable = true,
			preferredComponentId = mapNavMesh.MainComponentId,
			excludeNodes = { [mem.TgtNodeOrNil] = true },
			checkLOS = false
		})
		if altTgt and altTgt ~= mem.TgtNodeOrNil then
			path = lib.GetBestMeshPathOrNil(node, altTgt, pathCostFunction, heuristicCostFunction, abilities)
			if path then
				mem.TgtNodeOrNil = altTgt
			end
		end
	end

	if not path then
		if not mem.PathRerollGuard then
			mem.PathRerollGuard = true
			if IsValid(mem.TgtOrNil) then
				mem.UnreachableTargets = mem.UnreachableTargets or {}
				mem.UnreachableTargets[mem.TgtOrNil] = CurTime() + 6
			end
			local handler = lib.FindHandler and lib.FindHandler(self:GetZombieClass(), self:Team(), self)
			if handler and handler.RerollTarget then handler.RerollTarget(self) end
			mem.PathRerollGuard = nil
		end
		return
	end

	mem.PathRecalcCount = (mem.PathRecalcCount or 0) + 1
	self:D3bot_SetPath(path, true)
end

function meta:D3bot_UpdatePathProgress()
	local mem = self.D3bot_Mem
	if not mem then return end
	local myPos = self:GetPos()
	local progressed = false
	if lib.UsingSourceNav then
		while mem.NextNodeOrNil do
			if navmesh and navmesh.GetNavArea and mem.NextNodeOrNil == navmesh.GetNavArea(myPos, 100) then
				mem.NodeOrNil = mem.NextNodeOrNil
				mem.NextNodeOrNil = table.remove(mem.RemainingNodes, 1)
				progressed = true
			else
				break
			end
		end
	else
		while mem.NextNodeOrNil do
			if mem.NextNodeOrNil.GetContains and mem.NextNodeOrNil:GetContains(myPos, 100) then
				mem.NodeOrNil = mem.NextNodeOrNil
				mem.NextNodeOrNil = table.remove(mem.RemainingNodes, 1)
				progressed = true
			else
				break
			end
		end
	end
	if progressed then
		adjustNodeCongestion(mem, mem.NodeOrNil)
		syncLinkFromNodes(mem)
	end
end

function meta:D3bot_StorePos()
	self.D3bot_PosList = self.D3bot_PosList or {}
	local posList = self.D3bot_PosList
	table.insert(posList, 1, self:GetPos())
	while #posList > 30 do
		table.remove(posList)
	end
end

function meta:D3bot_CheckStuck()
	local mem = self.D3bot_Mem
	if not mem then return false, false end
	local ct = CurTime()
	if not mem.NextCheckStuck or mem.NextCheckStuck < ct then
		mem.NextCheckStuck = ct + 0.9 + math.random() * 0.2
	else
		return false, false
	end

	local posList = self.D3bot_PosList
	if not posList then return false, false end

	local pos_1, pos_2, pos_10 = posList[1], posList[2], posList[10]

	local minorStuck = pos_1 and pos_2 and pos_1:DistToSqr(pos_2) < 1 * 1
	local preMajorStuck = pos_1 and pos_10 and pos_1:DistToSqr(pos_10) < 300 * 300
	local majorStuck = false

	if preMajorStuck and (not self.D3bot_LastDamage or self.D3bot_LastDamage < ct - 5) then
		mem.MajorStuckCounter = (mem.MajorStuckCounter or 0) + 1
		mem.StuckTier = (mem.MajorStuckCounter > 8) and 2 or 1
		mem.StuckStateName = (mem.StuckTier >= 2) and "CRITICAL_TRAP" or "MICRO_STALL"
		if mem.MajorStuckCounter > 15 then
			majorStuck, mem.MajorStuckCounter = true, nil
		end
	else
		mem.MajorStuckCounter = nil
		mem.StuckTier = 0
		mem.StuckStateName = "OK"
	end

	return minorStuck, majorStuck
end

function lib.ApplyNPCMethods(targetTable)
	if not istable(targetTable) then return end
	for k, fn in pairs(lib.NPCMethods) do
		if isfunction(fn) then
			targetTable[k] = fn
		end
	end
end

local storedEnt = scripted_ents and scripted_ents.GetStored and scripted_ents.GetStored(lib.NPCEntityClass or "d3bot_npc_zombie")
if storedEnt and storedEnt.t then
	lib.ApplyNPCMethods(storedEnt.t)
end
