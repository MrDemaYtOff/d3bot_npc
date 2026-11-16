-- Reusable D3bot AI & Navigation Decision Layer for Slotless NextBot Entities (v3.0.0 Overhaul)
-- Upgrades:
--   * Packed-integer O(1) spatial grid, shared horde caches (humans, target ents, attacker load, target navnodes)
--   * Zero-allocation trace structs, scratch vectors, static trace filters & reusable StepIntent tables
--   * Debounced spatial entity invalidation (coalesces multi-plank barricade breaks)
--   * Multi-sample floor-verified direct chase & doorway-safe waypoint string-pulling
--   * Melee ring surrounding (swarm spread), doorway zipper merging, water swim-up & ladder descent
--   * 4-tier anti-loop recovery with Tier-3 stagnation escalation & silent respawn recycle

local lib = D3botNPC

lib.AI = lib.AI or {}
local AI = lib.AI

AI.BotTgtFixationDistMin = 250
AI.AngOffshoot = 30
AI.CrowAngOffshoot = 40
AI.PounceIntervalCrab = 3.0
AI.PounceIntervalCrabRandom = 4.0

local mathMax = math.max
local mathClamp = math.Clamp
local mathMin = math.min
local mathAbs = math.abs
local mathSqrt = math.sqrt
local mathFloor = math.floor

-- Module-level reusable vectors & trace tables (eliminates per-tick GC churn across 100+ NPCs)
local scratchVecA = Vector()
local scratchVecB = Vector()
local scratchDir = Vector()
local scratchLookPos = Vector()
local scratchCrowOrbit = Vector()

local waistHullMin = Vector(-12, -12, 0)
local waistHullMax = Vector(12, 12, 24)
local shortcutHullMin = Vector(-13, -13, 0)
local shortcutHullMax = Vector(13, 13, 26)
local whiskerHullMin = Vector(-8, -8, -8)
local whiskerHullMax = Vector(8, 8, 8)

local filterSelfNpc = nil
local filterSelfTgt = nil

local function seeTrFilter(ent)
	if ent == filterSelfNpc or ent == filterSelfTgt then return false end
	if ent.IsD3botNPC then return false end
	if ent:IsPlayer() then return false end
	return true
end

local function walkTrFilter(ent)
	if ent == filterSelfNpc or ent == filterSelfTgt or ent.IsD3botNPC then return false end
	if ent:IsPlayer() and ent:Team() == (TEAM_UNDEAD or 3) then return false end
	return true
end

local function whiskerNpcFilter(ent)
	if ent == filterSelfNpc or ent.IsD3botNPC then return false end
	if ent:IsPlayer() and ent:Team() == (TEAM_UNDEAD or 3) then return false end
	return true
end

local sharedSeeTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	mins = lib.BotSeeTr.mins,
	maxs = lib.BotSeeTr.maxs,
	filter = seeTrFilter,
	mask = lib.BotSeeTr.mask
}

local sharedWaistTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	mins = waistHullMin,
	maxs = waistHullMax,
	filter = walkTrFilter,
	mask = MASK_NPCSOLID
}

local sharedFloorTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	filter = walkTrFilter,
	mask = MASK_NPCSOLID
}

local sharedShortcutHullTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	mins = shortcutHullMin,
	maxs = shortcutHullMax,
	filter = whiskerNpcFilter,
	mask = MASK_NPCSOLID
}

local sharedWhiskerTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	mins = whiskerHullMin,
	maxs = whiskerHullMax,
	filter = whiskerNpcFilter,
	mask = MASK_NPCSOLID
}

local sharedBarricadeTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	filter = whiskerNpcFilter,
	mask = MASK_SOLID,
	ignoreworld = true
}

local sharedHiddenTr = {
	start = scratchVecA,
	endpos = scratchVecB,
	mask = MASK_SOLID_BRUSHONLY
}

local function isLivingHuman(ent)
	return IsValid(ent) and ent:IsPlayer() and ent:Team() ~= TEAM_UNDEAD
		and ent:GetObserverMode() == OBS_MODE_NONE
		and not ent:IsFlagSet(FL_NOTARGET)
		and ent:Alive()
end

-- =========================================================================
-- 1. Shared Horde Caches, Spatial Grid & Congestion Tracking (O(1) Crowd Queries)
-- =========================================================================

AI.CachedLivingNPCs = AI.CachedLivingNPCs or {}
AI.NPCSpatialGrid = AI.NPCSpatialGrid or {}
local NPC_GRID_CELL = 128
local nextSpatialRebuild = 0
local nextCongestionRebuild = 0

local cachedLivingHumans = {}
local nextHumansRebuild = 0

local cachedPotentialTargetEnts = {}
local nextTargetEntsRebuild = 0

local cachedAttackerLoad = {}
local nextAttackerLoadRebuild = 0

local cachedTargetNodes = {}
local nextTargetNodePrune = 0

local function npcGridKey(cx, cy)
	return (cx + 32768) * 65536 + (cy + 32768)
end

function AI.GetLivingHumansCached()
	local ct = CurTime()
	if ct >= nextHumansRebuild then
		nextHumansRebuild = ct + 0.20
		local list = {}
		local candidates = TEAM_HUMAN and team.GetPlayers(TEAM_HUMAN) or player.GetAll()
		for i = 1, #candidates do
			local p = candidates[i]
			if isLivingHuman(p) then
				list[#list + 1] = p
			end
		end
		if #list == 0 and TEAM_UNDEAD then
			local allP = player.GetAll()
			for i = 1, #allP do
				local p = allP[i]
				if isLivingHuman(p) then
					list[#list + 1] = p
				end
			end
		end
		cachedLivingHumans = list
	end
	return cachedLivingHumans
end

function AI.GetLivingNPCsCached()
	local ct = CurTime()
	if ct >= nextSpatialRebuild then
		AI.RebuildNPCSpatialGrid()
	end
	return AI.CachedLivingNPCs
end

function AI.RebuildNPCSpatialGrid()
	local ct = CurTime()
	nextSpatialRebuild = ct + 0.10

	local living = {}
	local grid = {}
	for npc, _ in pairs(lib.ActiveNPCs) do
		if not IsValid(npc) then
			lib.ActiveNPCs[npc] = nil
		elseif npc.Alive and npc:Alive() then
			living[#living + 1] = npc
			local pos = npc:GetPos()
			local cx = mathFloor(pos.x / NPC_GRID_CELL)
			local cy = mathFloor(pos.y / NPC_GRID_CELL)
			local k = npcGridKey(cx, cy)
			local bucket = grid[k]
			if not bucket then
				bucket = {}
				grid[k] = bucket
			end
			bucket[#bucket + 1] = npc
		end
	end

	AI.CachedLivingNPCs = living
	AI.NPCSpatialGrid = grid

	-- Update node & link crowd congestion map every 0.20s
	if ct >= nextCongestionRebuild then
		nextCongestionRebuild = ct + 0.20
		local nodeCong = {}
		local linkCong = {}
		local useSource = lib.UsingSourceNav
		for i = 1, #living do
			local npc = living[i]
			local mem = npc.D3bot_Mem
			if mem then
				local curNode = mem.NodeOrNil
				local nextNode = mem.NextNodeOrNil
				if curNode then
					nodeCong[curNode] = (nodeCong[curNode] or 0) + 0.5
				end
				if nextNode then
					nodeCong[nextNode] = (nodeCong[nextNode] or 0) + 1.0
					if not useSource and curNode and curNode.LinkByLinkedNode then
						local link = curNode.LinkByLinkedNode[nextNode]
						if link then
							linkCong[link] = (linkCong[link] or 0) + 1.0
						end
					elseif useSource and IsValid(curNode) and IsValid(nextNode) and curNode.D3botNPC_SharesLink then
						local link = curNode:D3botNPC_SharesLink(nextNode)
						if link then
							linkCong[link] = (linkCong[link] or 0) + 1.0
						end
					end
				end
				-- Count next 2 upcoming waypoints so crowds diverge BEFORE entering a jammed corridor
				local rem = mem.RemainingNodes
				if rem then
					local prev = nextNode
					local lim = mathMin(#rem, 2)
					for j = 1, lim do
						local rn = rem[j]
						if rn then
							local w = (j == 1) and 0.6 or 0.35
							nodeCong[rn] = (nodeCong[rn] or 0) + w
							if not useSource and prev and prev.LinkByLinkedNode then
								local rLink = prev.LinkByLinkedNode[rn]
								if rLink then
									linkCong[rLink] = (linkCong[rLink] or 0) + w
								end
							end
							prev = rn
						end
					end
				end
			end
		end
		lib.NodeCongestion = nodeCong
		lib.LinkCongestion = linkCong
	end
end

function AI.GetTargetNavNode(targetEnt, preferredComp)
	if not IsValid(targetEnt) then return nil end
	local mapNavMesh = lib.MapNavMesh
	if not mapNavMesh or not mapNavMesh.GetBestNodeNear then return nil end

	local ct = CurTime()
	if ct >= nextTargetNodePrune then
		nextTargetNodePrune = ct + 4.0
		for k, v in pairs(cachedTargetNodes) do
			if not IsValid(k) or v.Expires < ct - 2.0 then
				cachedTargetNodes[k] = nil
			end
		end
	end

	local tPos = targetEnt:GetPos()
	local entry = cachedTargetNodes[targetEnt]
	if entry and entry.Expires >= ct and entry.Comp == preferredComp and entry.Pos:DistToSqr(tPos) <= 48 * 48 then
		return entry.Node
	end

	local node = mapNavMesh:GetBestNodeNear(tPos, {
		wave = lib.GetCurrentWave(),
		requireLinked = true,
		preferredComponentId = preferredComp or mapNavMesh.MainComponentId,
		checkLOS = true
	})

	if not entry then
		entry = { Pos = Vector(tPos.x, tPos.y, tPos.z), Node = node, Comp = preferredComp, Expires = ct + 0.25 }
		cachedTargetNodes[targetEnt] = entry
	else
		entry.Pos:SetUnpacked(tPos.x, tPos.y, tPos.z)
		entry.Node = node
		entry.Comp = preferredComp
		entry.Expires = ct + 0.25
	end
	return node
end

-- =========================================================================
-- 2. Adaptive A* Path Budget Queue & Debounced Environment Invalidation
-- =========================================================================

AI.PathQueue = AI.PathQueue or {}
AI.PathQueueSet = AI.PathQueueSet or {}

local lastInvCellTime = {}
local nextInvCellPrune = 0

function AI.QueuePathUpdate(npc, highPriority)
	if not IsValid(npc) or AI.PathQueueSet[npc] then return end
	AI.PathQueueSet[npc] = true
	if highPriority then
		table.insert(AI.PathQueue, 1, npc)
	else
		AI.PathQueue[#AI.PathQueue + 1] = npc
	end
end

hook.Add("Think", lib.HookId .. ".PathBudgetQueue", function()
	local qLen = #AI.PathQueue
	if qLen == 0 then return end

	local baseBudget = lib.ConVars.PathBudget and lib.ConVars.PathBudget:GetInt() or 4
	local budget
	if baseBudget <= 0 then
		budget = qLen
	else
		-- Scale smoothly with horde backlog so 87-120+ NPCs never stall on stale paths
		budget = mathMin(qLen, baseBudget + mathFloor(qLen / 6))
	end

	local processed = 0
	while #AI.PathQueue > 0 and processed < budget do
		local npc = table.remove(AI.PathQueue, 1)
		if npc then
			AI.PathQueueSet[npc] = nil
			if IsValid(npc) and npc.Alive and npc:Alive() then
				AI.UpdatePathImmediate(npc)
				processed = processed + 1
			end
		end
	end
end)

function AI.ResetPathQueue()
	AI.PathQueue = {}
	AI.PathQueueSet = {}
	cachedTargetNodes = {}
end

function AI.InvalidatePathsNear(pos, radius, forceImmediate)
	if not isvector(pos) then return end

	local ct = CurTime()
	if not forceImmediate then
		if ct >= nextInvCellPrune then
			nextInvCellPrune = ct + 5.0
			for k, exp in pairs(lastInvCellTime) do
				if exp < ct - 1.0 then
					lastInvCellTime[k] = nil
				end
			end
		end
		local cellKey = npcGridKey(mathFloor(pos.x / 256), mathFloor(pos.y / 256))
		local prev = lastInvCellTime[cellKey]
		if prev and ct < prev + 0.15 then
			return
		end
		lastInvCellTime[cellKey] = ct
	end

	local rSqr = (radius or 520) ^ 2
	if lib.ResetNodeBlockCache then lib.ResetNodeBlockCache() end
	if lib.ResetPathCache then lib.ResetPathCache() end
	cachedTargetNodes = {}

	local living = AI.GetLivingNPCsCached()
	for i = 1, #living do
		local npc = living[i]
		if IsValid(npc) and npc.D3bot_Mem and npc:GetPos():DistToSqr(pos) <= rSqr then
			npc.D3bot_Mem.ForcePathRefresh = true
			AI.QueuePathUpdate(npc, true)
		end
	end
end

local watchedDynamicClasses = {
	prop_physics = true,
	prop_physics_multiplayer = true,
	prop_door_rotating = true,
	func_door = true,
	func_door_rotating = true,
	func_breakable = true,
	func_physbox = true,
	func_physbox_multiplayer = true
}

hook.Add("EntityRemoved", lib.HookId .. ".DynamicBarricadeInvalidation", function(ent)
	if not IsValid(ent) then return end
	local cls = ent:GetClass()
	local isNailed = ent.IsNailed and ent:IsNailed()
	if not isNailed and not watchedDynamicClasses[cls] then return end
	-- Skip tiny un-nailed prop debris/gibs so shattering crates doesn't wake all hordes unnecessarily
	if not isNailed and (cls == "prop_physics" or cls == "prop_physics_multiplayer") then
		if (ent:BoundingRadius() or 0) < 14 then return end
	end
	AI.InvalidatePathsNear(ent:GetPos(), 550, isNailed)
end)

hook.Add("AcceptInput", lib.HookId .. ".DoorStateInvalidation", function(ent, inputName)
	if not IsValid(ent) then return end
	local cls = ent:GetClass()
	if (cls == "prop_door_rotating" or cls == "func_door" or cls == "func_door_rotating")
		and (inputName == "Open" or inputName == "Close" or inputName == "Toggle" or inputName == "Unlock") then
		AI.InvalidatePathsNear(ent:GetPos(), 480, true)
	end
end)

-- =========================================================================
-- 3. Target Validation & Dispersion Target Scoring (Cached Shared Queries)
-- =========================================================================

function AI.GetPotentialTargetEnts()
	local ct = CurTime()
	if ct >= nextTargetEntsRebuild then
		nextTargetEntsRebuild = ct + 0.65
		local list = {}
		local patterns = lib.PotentialTargetEntClasses
		for i = 1, #patterns do
			local found = ents.FindByClass(patterns[i])
			for j = 1, #found do
				local ent = found[j]
				if IsValid(ent) then
					list[#list + 1] = ent
				end
			end
		end
		cachedPotentialTargetEnts = list
	end
	return cachedPotentialTargetEnts
end

local function getAttackerLoadCached()
	local ct = CurTime()
	if ct >= nextAttackerLoadRebuild then
		nextAttackerLoadRebuild = ct + 0.25
		local load = {}
		local living = AI.GetLivingNPCsCached()
		for i = 1, #living do
			local other = living[i]
			local m = other.D3bot_Mem
			if m and IsValid(m.TgtOrNil) then
				local t = m.TgtOrNil
				load[t] = (load[t] or 0) + 1
			end
		end
		cachedAttackerLoad = load
	end
	return cachedAttackerLoad
end

function AI.CanBeTgt(npc, target)
	if not IsValid(target) or target == npc then return false end
	if target:IsPlayer() then
		if npc.IsCrow and npc:IsCrow() then
			return target:GetObserverMode() == OBS_MODE_NONE
				and not target:IsFlagSet(FL_NOTARGET)
				and target:Alive()
				and target:Team() ~= TEAM_SPECTATOR
		end
		return isLivingHuman(target)
	end
	if npc.IsCrow and npc:IsCrow() then return false end
	local cls = target:GetClass()
	if cls == "prop_obj_sigil" then
		return not (target.GetSigilCorrupted and target:GetSigilCorrupted())
	end
	for _, pattern in ipairs(lib.PotentialTargetEntClasses) do
		local luaPattern = "^" .. string.gsub(pattern, "%*", ".*") .. "$"
		if string.match(cls, luaPattern) then
			if target.GetObjectHealth and target:GetObjectHealth() <= 0 then
				return false
			end
			return true
		end
	end
	return false
end

function AI.InitializeOrReset(npc)
	npc.D3bot_Mem = npc.D3bot_Mem or {}
	local mem = npc.D3bot_Mem
	local cfg = npc:GetClassConfig()

	mem.TgtOrNil = nil
	mem.DontAttackTgt = nil
	mem.TgtProximity = nil
	mem.PosTgtOrNil = nil
	mem.PosTgtProximity = nil
	mem.NodeTgtOrNil = nil
	mem.TgtNodeOrNil = nil
	mem.NodeOrNil = nil
	mem.NextNodeOrNil = nil
	mem.RemainingNodes = {}
	mem.ConsidersPathLethality = (math.random(1, lib.BotConsideringDeathCostAntichance) == 1)
	mem.Angs = npc:GetAngles()
	mem.AngsOffshoot = angle_zero
	mem.CanSeeTargetCache = mem.CanSeeTargetCache or { Target = nil, ValidUntil = 0, Result = false }
	mem.CanSeeTargetCache.ValidUntil = 0
	mem.CanWalkDirectCache = mem.CanWalkDirectCache or { Target = nil, ValidUntil = 0, Result = false }
	mem.CanWalkDirectCache.ValidUntil = 0

	-- Stuck & recovery state
	mem.PosList = {}
	mem.NextPosSample = 0
	mem.NextCheckStuck = 0
	mem.StuckTier = 0
	mem.StuckStateName = "OK"
	mem.RecoveryAttempts = 0
	mem.LastRecoveryAction = nil
	mem.LastRecoveryTime = 0
	mem.LastRepositionTime = 0
	mem.NextBotStuckFlag = false
	mem.FailedLinks = {}
	mem.FailedLinkExpiry = {}
	mem.BadStartNodes = {}
	mem.BadStartExpiry = {}
	mem.UnreachableTargets = {}
	mem.CurrentNextNodeSince = CurTime()
	mem.MinDistToNextNode = math.huge
	mem.AntiStuckCounter = nil
	mem.AntiStuckTime = nil
	mem.BlockMovementUntil = nil
	mem.BlockedOnNode = nil

	-- Local avoidance, waypoint shortcutting & strafing
	mem.StrafeDir = (math.random(1, 2) == 1) and 1 or -1
	mem.StrafeUntil = nil
	mem.NextWhiskerCheck = 0
	mem.NextShortcutCheck = 0
	mem.NextBarricadeProbe = 0
	mem.LastFacesHindrance = false
	mem.WhiskerSteer = mem.WhiskerSteer or Vector()
	mem.WhiskerSteer:SetUnpacked(0, 0, 0)
	mem.WhiskerShouldJump = false
	mem.WhiskerShouldDuck = false
	mem.WhiskerBlockedEnt = nil
	mem.CrowdPushVec = mem.CrowdPushVec or Vector()
	mem.CrowdPushVec:SetUnpacked(0, 0, 0)
	mem.SteeredMoveVec = mem.SteeredMoveVec or Vector()
	mem.LadderCrestDir = mem.LadderCrestDir or Vector()

	-- Reusable StepIntent table (mutated synchronously each step)
	mem.StepIntent = mem.StepIntent or {}

	-- Vertical / pounce
	mem.IsOnLadder = false
	mem.LadderCrestUntil = nil
	mem.ClimbingTarget = nil
	mem.ClimbingSince = nil
	mem.pouncing = false
	mem.pouncingStartTime = nil
	mem.pouncingTimer = nil
	mem.pounceFlightTime = nil
	mem.NextPounceEval = 0
	mem.NextPounce = CurTime() + AI.PounceIntervalCrab + math.random() * AI.PounceIntervalCrabRandom
	mem.IsCrab = cfg.IsCrab or false
	mem.lastNoHindrance = CurTime()
	mem.ForcePathRefresh = false
	mem.PathRecalcCount = 0

	local scale = npc:GetModelScale() or 1
	mem.Height = (cfg.Hull and cfg.Hull[2].z or 72) * scale
	mem.CrouchHeight = (cfg.HullDuck and cfg.HullDuck[2].z or 36) * scale
	mem.HalfHullWidth = (cfg.Hull and mathMax(cfg.Hull[2].x, cfg.Hull[2].y) or 16) * scale

	local grav = 600
	if physenv and physenv.GetGravity then
		local g = mathAbs(physenv.GetGravity().z)
		if g > 1 then grav = g end
	end
	local jumpPow = cfg.JumpPower or 200
	mem.JumpHeight = lib.CalculateJumpHeight(jumpPow, grav, false)
	mem.JumpCrouchHeight = mem.JumpHeight + (mem.Height - mem.CrouchHeight)
	mem.CrouchJumpHeight = lib.CalculateJumpHeight(jumpPow, grav, true) + (mem.Height - mem.CrouchHeight)
end

function AI.ResetTgt(npc)
	local mem = npc.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = nil, nil, nil
	mem.PosTgtOrNil, mem.PosTgtProximity = nil, nil
	mem.NodeTgtOrNil = nil
	mem.TgtNodeOrNil = nil
	mem.NodeOrNil = nil
	mem.NextNodeOrNil = nil
	mem.RemainingNodes = {}
end

function AI.SetTgtOrNil(npc, target, dontAttack, proximity)
	local mem = npc.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = target, dontAttack, proximity
	mem.PosTgtOrNil, mem.PosTgtProximity = nil, nil
	mem.NodeTgtOrNil = nil
end

function AI.SetPosTgtOrNil(npc, targetPos, proximity)
	local mem = npc.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = nil, nil, nil
	mem.PosTgtOrNil, mem.PosTgtProximity = targetPos, proximity
	mem.NodeTgtOrNil = nil
end

function AI.SetNodeTgtOrNil(npc, targetNode)
	local mem = npc.D3bot_Mem
	if not mem then return end
	mem.TgtOrNil, mem.DontAttackTgt, mem.TgtProximity = nil, nil, nil
	mem.PosTgtOrNil, mem.PosTgtProximity = nil, nil
	mem.NodeTgtOrNil = targetNode
end

function AI.GetAttackPosOrNil(npc, fraction, target)
	local mem = npc.D3bot_Mem
	local tgt = target or (mem and mem.TgtOrNil)
	if not IsValid(tgt) then return nil end
	if tgt:IsPlayer() then
		return LerpVector(fraction or 0.75, tgt:GetPos(), tgt:EyePos())
	end
	return tgt:WorldSpaceCenter()
end

function AI.GetAttackPosOrNilFuturePlatforms(npc, fraction, t)
	local mem = npc.D3bot_Mem
	local tgt = mem and mem.TgtOrNil
	if not IsValid(tgt) then return nil end
	if tgt:IsPlayer() then
		local phys = tgt:GetPhysicsObject()
		local vel = IsValid(phys) and phys:GetVelocity() or tgt:GetVelocity()
		return LerpVector(fraction or 0.75, tgt:GetPos(), tgt:EyePos()) + vel * (t or 0)
	end
	return tgt:WorldSpaceCenter()
end

function AI.IsLookingAt(npc, targetPos, conditionCos)
	local eyePos = npc:GetShootPos()
	scratchDir:SetUnpacked(targetPos.x - eyePos.x, targetPos.y - eyePos.y, targetPos.z - eyePos.z)
	if scratchDir:LengthSqr() <= 0.001 then return true end
	scratchDir:Normalize()
	return npc:GetAimVector():Dot(scratchDir) > (conditionCos or 0.92)
end

-- =========================================================================
-- 4. Visibility & Walkable Direct-Chase Validation (Multi-Floor Safe)
-- =========================================================================

function AI.CanSeeTarget(npc, fraction, target)
	local attackPos = AI.GetAttackPosOrNil(npc, fraction, target)
	if not attackPos then return false end

	local mem = npc.D3bot_Mem
	if mem and mem.TgtNodeOrNil and mem.NodeOrNil ~= mem.TgtNodeOrNil then
		local seeParam
		if lib.UsingSourceNav then
			seeParam = IsValid(mem.TgtNodeOrNil) and mem.TgtNodeOrNil:D3botNPC_GetMetaData().Params.See
		elseif istable(mem.TgtNodeOrNil) and mem.TgtNodeOrNil.Params then
			seeParam = mem.TgtNodeOrNil.Params.See
		end
		if seeParam == "Disabled" then
			return false
		end
	end

	local shootPos = npc:GetShootPos()
	scratchVecA:SetUnpacked(shootPos.x, shootPos.y, shootPos.z)
	scratchVecB:SetUnpacked(attackPos.x, attackPos.y, attackPos.z)
	filterSelfNpc = npc
	filterSelfTgt = target
	local tr = util.TraceHull(sharedSeeTr)
	filterSelfNpc = nil
	filterSelfTgt = nil
	return not tr.Hit
end

function AI.CanSeeTargetCached(npc, fraction, target)
	local mem = npc.D3bot_Mem
	if not mem then return false end
	local ct = CurTime()
	local cache = mem.CanSeeTargetCache
	if not cache then
		cache = { Target = nil, ValidUntil = 0, Result = false }
		mem.CanSeeTargetCache = cache
	end
	if cache.Target ~= target or cache.ValidUntil < ct then
		cache.Target = target
		cache.ValidUntil = ct + 0.35 + math.random() * 0.15
		cache.Result = AI.CanSeeTarget(npc, fraction, target)
	end
	return cache.Result
end

-- Verifies whether an NPC can physically walk straight to `target` without falling off a balcony
-- or ramming a wall/railing below an upper-floor player.
function AI.CanWalkDirectlyToTarget(npc, target, canSee, sameNodeAsTarget)
	if not IsValid(target) then return false end
	if sameNodeAsTarget then return canSee end
	if not canSee then return false end

	local npcPos = npc:GetPos()
	local tgtPos = target:GetPos()
	local dz = tgtPos.z - npcPos.z
	local dx = tgtPos.x - npcPos.x
	local dy = tgtPos.y - npcPos.y
	local dist2DSqr = dx * dx + dy * dy

	if dist2DSqr > 220 * 220 then
		return false
	end
	if dz > 54 or dz < -72 then
		return false
	end

	local mem = npc.D3bot_Mem
	local ct = CurTime()
	local cache = mem and mem.CanWalkDirectCache
	if cache and cache.Target == target and cache.ValidUntil >= ct then
		return cache.Result
	end

	local walkable = true
	if dist2DSqr > 64 * 64 then
		filterSelfNpc = npc
		filterSelfTgt = target

		scratchVecA:SetUnpacked(npcPos.x, npcPos.y, npcPos.z + 26)
		scratchVecB:SetUnpacked(tgtPos.x, tgtPos.y, tgtPos.z + 26)
		local waistTr = util.TraceHull(sharedWaistTr)
		if waistTr.Hit then
			local hitEnt = waistTr.Entity
			if not IsValid(hitEnt) or (not lib.IsBarricadeEntity(hitEnt) and hitEnt:GetClass() ~= "prop_door_rotating" and hitEnt:GetClass() ~= "func_door") then
				walkable = false
			end
		end

		if walkable then
			local sampleCount = (dist2DSqr > 130 * 130) and 2 or 1
			for sIdx = 1, sampleCount do
				local frac = (sampleCount == 2) and (sIdx == 1 and 0.34 or 0.67) or 0.5
				local sx = npcPos.x + (tgtPos.x - npcPos.x) * frac
				local sy = npcPos.y + (tgtPos.y - npcPos.y) * frac
				local sz = npcPos.z + (tgtPos.z - npcPos.z) * frac
				scratchVecA:SetUnpacked(sx, sy, sz + 24)
				scratchVecB:SetUnpacked(sx, sy, sz - 82)
				local floorTr = util.TraceLine(sharedFloorTr)
				if not floorTr.Hit then
					walkable = false
					break
				end
			end
		end

		filterSelfNpc = nil
		filterSelfTgt = nil
	end

	if mem then
		if not cache then
			cache = {}
			mem.CanWalkDirectCache = cache
		end
		cache.Target = target
		cache.ValidUntil = ct + 0.30
		cache.Result = walkable
	end
	return walkable
end

-- =========================================================================
-- 5. Aiming, Pouncing & Barricade / Door Probing
-- =========================================================================

function AI.AngsRotateTo(npc, angle, lerpFactor)
	local mem = npc.D3bot_Mem
	if not mem then return end
	mem.Angs = LerpAngle(lerpFactor, mem.Angs or npc:GetAngles(), angle)
end

function AI.UpdateAngsOffshoot(npc, angOffshoot)
	local mem = npc.D3bot_Mem
	if not mem then return end
	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil

	if lib.UsingSourceNav then
		local p1 = nodeOrNil and IsValid(nodeOrNil) and nodeOrNil:D3botNPC_GetMetaData().Params
		local p2 = nextNodeOrNil and IsValid(nextNodeOrNil) and nextNodeOrNil:D3botNPC_GetMetaData().Params
		if (p1 and p1.Aim == "Straight") or (p2 and p2.AimTo == "Straight") then
			mem.AngsOffshoot = angle_zero
			return
		end
	else
		local link = nextNodeOrNil and nodeOrNil and nextNodeOrNil.LinkByLinkedNode and nextNodeOrNil.LinkByLinkedNode[nodeOrNil]
		if (nodeOrNil and nodeOrNil.Params.Aim == "Straight")
			or (nextNodeOrNil and nextNodeOrNil.Params.AimTo == "Straight")
			or (link and link.Params.CrabPouncing == "Needed") then
			mem.AngsOffshoot = angle_zero
			return
		end
	end

	angOffshoot = angOffshoot or AI.AngOffshoot
	mem.AngsOffshoot = Angle(math.random(-angOffshoot, angOffshoot) * 0.35, math.random(-angOffshoot, angOffshoot), 0)
end

function AI.GetOffshoot(npc, offshootFactor)
	local mem = npc.D3bot_Mem
	if not mem or (offshootFactor or 1) == 0 then return angle_zero end
	if (offshootFactor or 1) == 1 then return mem.AngsOffshoot or angle_zero end
	return (mem.AngsOffshoot or angle_zero) * (offshootFactor or 1)
end

function AI.CanPounceToPos(npc, pos)
	if not pos then return nil end
	local cfg = npc:GetClassConfig()
	if not cfg.CanPounce or not cfg.PounceVelocity then return nil end

	local maxLeg = (GAMEMODE and GAMEMODE.MaxLegDamage) or 3
	local legFrac = mathClamp((npc:GetLegDamage() or 0) / mathMax(maxLeg, 1), 0, 1)
	local initVel = (1 - 0.5 * legFrac) * cfg.PounceVelocity

	local selfPos = npc:GetPos()
	local trajectories = lib.GetTrajectories(initVel, selfPos, pos, 8)
	local resultTrajectories = {}
	local mins = npc.m_CachedHullMin or select(1, npc:GetHull())
	local maxs = npc.m_CachedHullMax or select(2, npc:GetHull())
	local trMins = mins * 0.65
	local trMaxs = maxs * 0.65
	local trData = {
		mins = trMins,
		maxs = trMaxs,
		filter = npc,
		mask = CONTENTS_SOLID + CONTENTS_GRATE + CONTENTS_MOVEABLE + CONTENTS_PLAYERCLIP
	}

	for _, trajectory in ipairs(trajectories) do
		local lastPoint = nil
		local hit = false
		for _, point in ipairs(trajectory.points) do
			if lastPoint then
				trData.start = lastPoint
				trData.endpos = point
				local tr = util.TraceHull(trData)
				if tr.Hit and pos:DistToSqr(tr.HitPos) > 24 * 24 then
					hit = true
					break
				end
			end
			lastPoint = point
		end
		if not hit then
			resultTrajectories[#resultTrajectories + 1] = trajectory
		end
	end

	if #resultTrajectories == 0 then return nil end
	return resultTrajectories
end

local barricadeExtraClasses = {
	prop_door_rotating = true,
	func_door = true,
	func_door_rotating = true,
	func_breakable = true,
	func_breakable_surf = true,
	func_physbox = true,
	func_physbox_multiplayer = true,
	prop_physics = true,
	prop_physics_multiplayer = true
}

function AI.FindBarricadeEntity(npc, extraSamples, moveDir)
	local cfg = npc:GetClassConfig()
	local reach = mathMax(cfg.AttackRange or 48, 46) + 20
	local startPos = npc:GetShootPos()
	local centerPos = npc:WorldSpaceCenter()
	local feetPos = npc:GetPos()
	local aimDir = npc:GetAimVector()
	local dir = moveDir or aimDir
	local rightX, rightY = dir.y, -dir.x

	local bestEnt, bestPos = nil, nil
	local bestScore = math.huge

	filterSelfNpc = npc
	local totalProbes = 3 + (extraSamples or 2)
	for pIdx = 1, totalProbes do
		local sx, sy, sz, dx, dy, dz
		if pIdx == 1 then
			sx, sy, sz = startPos.x, startPos.y, startPos.z
			dx, dy, dz = aimDir.x, aimDir.y, aimDir.z
		elseif pIdx == 2 then
			sx, sy, sz = centerPos.x, centerPos.y, centerPos.z
			dx, dy, dz = dir.x, dir.y, dir.z
		elseif pIdx == 3 then
			sx, sy, sz = feetPos.x, feetPos.y, feetPos.z + 22
			dx, dy, dz = dir.x, dir.y, dir.z
		elseif pIdx == 4 then
			sx, sy, sz = startPos.x, startPos.y, startPos.z
			dx, dy, dz = aimDir.x + rightX * 0.35, aimDir.y + rightY * 0.35, aimDir.z
		else
			sx, sy, sz = startPos.x, startPos.y, startPos.z
			dx, dy, dz = aimDir.x - rightX * 0.35, aimDir.y - rightY * 0.35, aimDir.z
		end

		scratchVecA:SetUnpacked(sx, sy, sz)
		scratchVecB:SetUnpacked(sx + dx * reach, sy + dy * reach, sz + dz * reach)
		local tr = util.TraceLine(sharedBarricadeTr)
		local trEnt = tr.Entity
		if tr.Hit and IsValid(trEnt) then
			local isBarricade = lib.IsBarricadeEntity(trEnt)
			local cls = trEnt:GetClass()
			local isDoorOrBreakable = barricadeExtraClasses[cls]
			if isBarricade or isDoorOrBreakable then
				if (cls == "prop_physics" or cls == "prop_physics_multiplayer") and not isBarricade and tr.Fraction > 0.72 then
					trEnt = nil
				end
				if IsValid(trEnt) then
					local hp = trEnt.GetBarricadeHealth and trEnt:GetBarricadeHealth() or trEnt:Health() or 100
					local score = (isBarricade and hp or (hp + 250)) + tr.Fraction * 40
					if score < bestScore then
						bestScore = score
						bestEnt = trEnt
						bestPos = tr.HitPos
					end
				end
			end
		end
	end
	filterSelfNpc = nil

	return bestEnt, bestPos
end

-- Zero-allocation dispersion target selection using cached humans, entities & attacker load
function AI.RerollTarget(npc)
	local isCrow = npc.IsCrow and npc:IsCrow()
	local players = isCrow and lib.RemoveObsDeadTgts(player.GetHumans()) or AI.GetLivingHumansCached()
	if #players == 0 then
		players = lib.RemoveObsDeadTgts(player.GetAll())
	end

	local potEntTargets = isCrow and {} or AI.GetPotentialTargetEnts()
	if #players == 0 and #potEntTargets == 0 then
		AI.ResetTgt(npc)
		return nil
	end

	local mem = npc.D3bot_Mem
	local ct = CurTime()
	local unreachable = mem and mem.UnreachableTargets
	local attackerLoad = getAttackerLoadCached()
	local npcPos = npc:GetPos()

	local best1Tgt, best1Score = nil, math.huge
	local best2Tgt, best2Score = nil, math.huge

	for i = 1, #players do
		local tgt = players[i]
		if IsValid(tgt) then
			local dist = npcPos:Distance(tgt:GetPos())
			local loadPenalty = (attackerLoad[tgt] or 0) * 200
			local healthBonus = mathClamp((tgt:GetMaxHealth() - tgt:Health()) * 2, 0, 120)
			local unreachPenalty = (unreachable and unreachable[tgt] and unreachable[tgt] > ct) and 2200 or 0
			local score = dist + loadPenalty + unreachPenalty - healthBonus + math.random(0, 95)
			if score < best1Score then
				best2Tgt, best2Score = best1Tgt, best1Score
				best1Tgt, best1Score = tgt, score
			elseif score < best2Score then
				best2Tgt, best2Score = tgt, score
			end
		end
	end

	for i = 1, #potEntTargets do
		local tgt = potEntTargets[i]
		if IsValid(tgt) and AI.CanBeTgt(npc, tgt) then
			local dist = npcPos:Distance(tgt:GetPos())
			local loadPenalty = (attackerLoad[tgt] or 0) * 200
			local unreachPenalty = (unreachable and unreachable[tgt] and unreachable[tgt] > ct) and 2200 or 0
			local score = dist + loadPenalty + 140 + unreachPenalty + math.random(0, 95)
			if score < best1Score then
				best2Tgt, best2Score = best1Tgt, best1Score
				best1Tgt, best1Score = tgt, score
			elseif score < best2Score then
				best2Tgt, best2Score = tgt, score
			end
		end
	end

	local chosen = best1Tgt
	if best2Tgt and math.random(1, 2) == 2 then
		chosen = best2Tgt
	end

	if not chosen then
		AI.ResetTgt(npc)
		return nil
	end

	AI.SetTgtOrNil(npc, chosen, false, nil)
	return chosen
end

-- =========================================================================
-- 6. Path Construction, String-Pulling Shortcutter, & Link Failure Tracking
-- =========================================================================

local function setNodeChanged(mem, newNextNode)
	if mem.NextNodeOrNil ~= newNextNode then
		mem.CurrentNextNodeSince = CurTime()
		mem.MinDistToNextNode = math.huge
	end
	mem.NextNodeOrNil = newNextNode
end

function AI.SetPath(npc, path, noReset)
	if not noReset then AI.ResetTgt(npc) end
	local mem = npc.D3bot_Mem
	if not mem or not istable(path) or #path == 0 then return end

	-- Avoid stepping backward if path[1] is where we already stand
	local npcPos = npc:GetPos()
	if #path >= 2 then
		local first = path[1]
		if not lib.UsingSourceNav and istable(first) and first.GetContains and first:GetContains(npcPos, 54, 34) then
			table.remove(path, 1)
		elseif lib.UsingSourceNav and IsValid(first) and first == navmesh.GetNavArea(npcPos, 64) then
			table.remove(path, 1)
		end
	end

	if mem.NextNodeOrNil and mem.NextNodeOrNil == path[1] and mem.NodeOrNil then
		table.insert(path, 1, mem.NodeOrNil)
	end

	mem.NodeOrNil = table.remove(path, 1)
	setNodeChanged(mem, table.remove(path, 1))
	mem.RemainingNodes = path
end

local function pruneExpiredFailures(mem, ct)
	if mem.FailedLinkExpiry then
		for link, exp in pairs(mem.FailedLinkExpiry) do
			if exp <= ct then
				mem.FailedLinkExpiry[link] = nil
				if mem.FailedLinks then mem.FailedLinks[link] = nil end
			end
		end
	end
	if mem.BadStartExpiry then
		for node, exp in pairs(mem.BadStartExpiry) do
			if exp <= ct then
				mem.BadStartExpiry[node] = nil
				if mem.BadStartNodes then mem.BadStartNodes[node] = nil end
			end
		end
	end
	if mem.UnreachableTargets then
		for tgt, exp in pairs(mem.UnreachableTargets) do
			if exp <= ct or not IsValid(tgt) then
				mem.UnreachableTargets[tgt] = nil
			end
		end
	end
end

function AI.MarkLinkFailed(npc, link, duration)
	local mem = npc and npc.D3bot_Mem
	if not mem or not link then return end
	local ct = CurTime()
	mem.FailedLinks = mem.FailedLinks or {}
	mem.FailedLinkExpiry = mem.FailedLinkExpiry or {}
	mem.FailedLinks[link] = (mem.FailedLinks[link] or 0) + 1
	mem.FailedLinkExpiry[link] = ct + (duration or 14)
end

-- String-pulling waypoint shortcut: skips unnecessary zig-zag corner bends when walkable floor & hull are clear
function AI.TryShortcutWaypoint(npc, mem, npcPos)
	if lib.UsingSourceNav or not mem or mem.IsOnLadder or mem.pouncing then return end
	if not npc:IsOnGround() then return end

	local ct = CurTime()
	if ct < (mem.NextShortcutCheck or 0) then return end
	mem.NextShortcutCheck = ct + 0.24

	local rem = mem.RemainingNodes
	local nextN = mem.NextNodeOrNil
	local rem1 = rem and rem[1]
	if not istable(nextN) or not istable(rem1) or not rem1.Pos or not rem1.GetClosestPointOnArea then return end

	-- Only shortcut flat/gentle transitions; never skip ladders, climbs, pounces, drops, crouch vents, or choke doorways
	if nextN.RuntimeNeedsCrouch or rem1.RuntimeNeedsCrouch or nextN.RuntimeEmbedded or rem1.RuntimeEmbedded then return end
	if (nextN.RuntimeBottleneckScore or 0) >= 2 or (rem1.RuntimeBottleneckScore or 0) >= 2 then return end

	local pNext = nextN.Params
	local pRem1 = rem1.Params
	if (pNext and (pNext.Duck or pNext.DuckTo or pNext.Jump or pNext.JumpTo or pNext.Climbing == "Needed"))
		or (pRem1 and (pRem1.Duck or pRem1.DuckTo or pRem1.Jump or pRem1.JumpTo or pRem1.Climbing == "Needed")) then
		return
	end

	local curN = mem.NodeOrNil
	local link1 = curN and curN.LinkByLinkedNode and curN.LinkByLinkedNode[nextN]
	local link2 = nextN.LinkByLinkedNode and nextN.LinkByLinkedNode[rem1]
	if link1 and (link1.RuntimeWorldBlocked or (link1.Params and (link1.Params.Path == "Ladder" or link1.Params.Pouncing == "Needed" or link1.Params.CrabPouncing == "Needed" or link1.Params.Jumping == "Needed"))) then
		return
	end
	if link2 and (link2.RuntimeWorldBlocked or (link2.Params and (link2.Params.Path == "Ladder" or link2.Params.Pouncing == "Needed" or link2.Params.CrabPouncing == "Needed" or link2.Params.Jumping == "Needed"))) then
		return
	end

	local dz1 = mathAbs(nextN.Pos.z - npcPos.z)
	local dz2 = mathAbs(rem1.Pos.z - npcPos.z)
	if dz1 > 20 or dz2 > 22 then return end

	local targetPt = rem1:GetClosestPointOnArea(npcPos)
	local distSqr = npcPos:DistToSqr(targetPt)
	if distSqr > 460 * 460 then return end

	filterSelfNpc = npc
	scratchVecA:SetUnpacked(npcPos.x, npcPos.y, npcPos.z + 28)
	scratchVecB:SetUnpacked(targetPt.x, targetPt.y, targetPt.z + 28)
	local trHull = util.TraceHull(sharedShortcutHullTr)
	local ok = not trHull.Hit
	if ok then
		local samples = (distSqr > 200 * 200) and 2 or 1
		for sIdx = 1, samples do
			local frac = (samples == 2) and (sIdx == 1 and 0.34 or 0.67) or 0.5
			local sx = npcPos.x + (targetPt.x - npcPos.x) * frac
			local sy = npcPos.y + (targetPt.y - npcPos.y) * frac
			local sz = npcPos.z + (targetPt.z - npcPos.z) * frac
			scratchVecA:SetUnpacked(sx, sy, sz + 24)
			scratchVecB:SetUnpacked(sx, sy, sz - 56)
			local trFl = util.TraceLine(sharedFloorTr)
			if not trFl.Hit then
				ok = false
				break
			end
		end
	end
	filterSelfNpc = nil

	if ok then
		mem.NodeOrNil = nextN
		setNodeChanged(mem, table.remove(rem, 1))
	end
end

function AI.UpdatePathImmediate(npc, allowTargetReroll)
	local mem = npc.D3bot_Mem
	if not mem then return end
	if not IsValid(mem.TgtOrNil) and not mem.PosTgtOrNil and not mem.NodeTgtOrNil then return end
	if not lib.HasNavMesh then return end

	if allowTargetReroll == nil then allowTargetReroll = true end

	local ct = CurTime()
	pruneExpiredFailures(mem, ct)

	local cfg = npc:GetClassConfig()
	local abilities = {
		Walk = true,
		Jump = cfg.IsCrow and 320 or mem.CrouchJumpHeight,
		Height = mem.CrouchHeight,
		Crab = cfg.IsCrab,
		Pounce = cfg.CanPounce,
		Climb = cfg.CanClimb,
		NoFallDamage = cfg.NoFallDamage or cfg.IsCrow,
		MaxDrop = cfg.NoFallDamage and 1800 or 450
	}

	local considerDeath = mem.ConsidersPathLethality
	local function pathCostFunction(node, linkedNode, link)
		if not considerDeath then return 0 end
		return lib.GetLinkDeathCost(link)
	end

	local npcPos = npc:GetPos()
	local tgtPos = IsValid(mem.TgtOrNil) and mem.TgtOrNil:GetPos() or mem.PosTgtOrNil

	if lib.UsingSourceNav then
		if not navmesh or not navmesh.IsLoaded() then return end
		local area = navmesh.GetNearestNavArea(npcPos, false, 10000, false, false)
		mem.TgtNodeOrNil = mem.NodeTgtOrNil or (tgtPos and navmesh.GetNearestNavArea(tgtPos, false, 10000, false, false))
		if not IsValid(area) or not IsValid(mem.TgtNodeOrNil) then
			mem.PathUnavailableUntil = ct + 1.5
			return
		end

		local path = lib.GetBestValveMeshPathOrNil(area, mem.TgtNodeOrNil, pathCostFunction, nil, abilities, { failedLinks = mem.FailedLinks })
		if not path then
			if allowTargetReroll then
				if IsValid(mem.TgtOrNil) then
					mem.UnreachableTargets = mem.UnreachableTargets or {}
					mem.UnreachableTargets[mem.TgtOrNil] = ct + 8
				end
				local prevTgt = mem.TgtOrNil
				AI.RerollTarget(npc)
				if mem.TgtOrNil ~= prevTgt then
					AI.UpdatePathImmediate(npc, false)
					return
				end
			end
			mem.PathUnavailableUntil = ct + 1.5
			return
		end
		mem.PathUnavailableUntil = nil
		mem.PathRecalcCount = (mem.PathRecalcCount or 0) + 1
		mem.ForcePathRefresh = false
		AI.SetPath(npc, path, true)
	else
		local mapNavMesh = lib.MapNavMesh
		if not mapNavMesh or not mapNavMesh.GetBestNodeNear then return end

		local wave = lib.GetCurrentWave()
		local tgtNode = (istable(mem.NodeTgtOrNil) and mem.NodeTgtOrNil.Pos) and mem.NodeTgtOrNil or nil
		if not tgtNode then
			if IsValid(mem.TgtOrNil) then
				tgtNode = AI.GetTargetNavNode(mem.TgtOrNil, mapNavMesh.MainComponentId)
			elseif tgtPos then
				tgtNode = mapNavMesh:GetBestNodeNear(tgtPos, {
					wave = wave,
					requireLinked = true,
					preferredComponentId = mapNavMesh.MainComponentId,
					checkLOS = true
				})
			end
		end
		mem.TgtNodeOrNil = tgtNode

		local node = mapNavMesh:GetBestNodeNear(npcPos, {
			wave = wave,
			requireLinked = true,
			preferredComponentId = (tgtNode and tgtNode.RuntimeComponentId) or mapNavMesh.MainComponentId,
			excludeNodes = mem.BadStartNodes,
			checkLOS = true
		})

		if not node or not tgtNode then
			if node and isvector(node.Pos) and npcPos:DistToSqr(node.Pos) > 85 * 85 then
				mem.NodeOrNil = node
				setNodeChanged(mem, node)
				mem.RemainingNodes = {}
			end
			mem.PathUnavailableUntil = ct + 1.5
			return
		end

		local pathOpts = { failedLinks = mem.FailedLinks }
		local path = lib.GetBestMeshPathOrNil(node, tgtNode, pathCostFunction, nil, abilities, pathOpts)

		-- If start node could not reach target (e.g. one-way trap or blocked choke), try alternate nearby entry node
		if not path then
			local exclude = {}
			for k, v in pairs(mem.BadStartNodes or {}) do exclude[k] = v end
			exclude[node] = true
			local altStart = mapNavMesh:GetBestNodeNear(npcPos, {
				wave = wave,
				requireLinked = true,
				preferredComponentId = tgtNode.RuntimeComponentId,
				excludeNodes = exclude,
				checkLOS = false
			})
			if altStart and altStart ~= node then
				path = lib.GetBestMeshPathOrNil(altStart, tgtNode, pathCostFunction, nil, abilities, pathOpts)
				if path then
					node = altStart
				end
			end
		end

		if not path then
			if allowTargetReroll then
				if IsValid(mem.TgtOrNil) then
					mem.UnreachableTargets = mem.UnreachableTargets or {}
					mem.UnreachableTargets[mem.TgtOrNil] = ct + 8
				end
				local prevTgt = mem.TgtOrNil
				AI.RerollTarget(npc)
				if mem.TgtOrNil ~= prevTgt then
					AI.UpdatePathImmediate(npc, false)
					return
				end
			end
			if isvector(node.Pos) and npcPos:DistToSqr(node.Pos) > 85 * 85 then
				mem.NodeOrNil = node
				setNodeChanged(mem, node)
				mem.RemainingNodes = {}
			end
			mem.PathUnavailableUntil = ct + 1.5
			return
		end

		mem.PathUnavailableUntil = nil
		mem.PathRecalcCount = (mem.PathRecalcCount or 0) + 1
		mem.ForcePathRefresh = false
		AI.SetPath(npc, path, true)
	end
end

function AI.UpdatePath(npc, highPriority)
	local mem = npc.D3bot_Mem
	if mem and not mem.NextNodeOrNil and not mem.PathUnavailableUntil then
		AI.UpdatePathImmediate(npc)
	else
		AI.QueuePathUpdate(npc, highPriority)
	end
end

function AI.UpdatePathProgress(npc)
	local mem = npc.D3bot_Mem
	if not mem then return end
	local npcPos = npc:GetPos()
	local wave = lib.GetCurrentWave()

	if lib.UsingSourceNav then
		while mem.NextNodeOrNil and IsValid(mem.NextNodeOrNil) do
			if mem.NextNodeOrNil == navmesh.GetNavArea(npcPos, 64) then
				mem.NodeOrNil = mem.NextNodeOrNil
				setNodeChanged(mem, table.remove(mem.RemainingNodes, 1))
			else
				break
			end
		end
	else
		local vertUp = (mem.IsOnLadder or mem.pouncing or not npc:IsOnGround()) and 88 or 54
		local vertDown = (mem.IsOnLadder or mem.pouncing or not npc:IsOnGround()) and 64 or 34

		-- Advance if reached NextNodeOrNil OR skipped ahead onto RemainingNodes[1]
		while istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.GetContains do
			if mem.NextNodeOrNil:GetContains(npcPos, vertUp, vertDown) then
				mem.NodeOrNil = mem.NextNodeOrNil
				setNodeChanged(mem, table.remove(mem.RemainingNodes, 1))
			elseif mem.RemainingNodes and istable(mem.RemainingNodes[1]) and mem.RemainingNodes[1].GetContains
				and mem.RemainingNodes[1]:GetContains(npcPos, vertUp, vertDown) then
				mem.NodeOrNil = table.remove(mem.RemainingNodes, 1)
				setNodeChanged(mem, table.remove(mem.RemainingNodes, 1))
			else
				-- Dynamic obstruction check: if NextNodeOrNil just became blocked, re-route immediately
				if lib.IsNavMeshNodeBlocked(mem.NextNodeOrNil.Params, mem.NextNodeOrNil.Pos, wave) then
					mem.ForcePathRefresh = true
					AI.QueuePathUpdate(npc, true)
				end
				break
			end
		end

		-- Attempt smooth string-pulling shortcut past redundant corner bends
		AI.TryShortcutWaypoint(npc, mem, npcPos)

		-- Track minimum distance to current waypoint to detect progress stalls
		if istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Pos then
			local pt = mem.NextNodeOrNil.HasArea and mem.NextNodeOrNil:GetClosestPointOnArea(npcPos) or mem.NextNodeOrNil.Pos
			local d = npcPos:Distance(pt)
			if d < (mem.MinDistToNextNode or math.huge) - 10 then
				mem.MinDistToNextNode = d
				mem.CurrentNextNodeSince = CurTime()
			end
		end
	end
end

-- =========================================================================
-- 7. Multi-Tier Stuck Detection & Intelligent Recovery
-- =========================================================================

function AI.StorePos(npc)
	local mem = npc.D3bot_Mem
	if not mem then return end
	local posList = mem.PosList
	table.insert(posList, 1, npc:GetPos())
	while #posList > 14 do
		table.remove(posList)
	end
end

function AI.NotifyNextBotStuck(npc)
	local mem = npc and npc.D3bot_Mem
	if mem then
		mem.NextBotStuckFlag = true
	end
end

local function isPosHiddenFromHumans(pos)
	scratchVecB:SetUnpacked(pos.x, pos.y, pos.z + 48)
	local humans = AI.GetLivingHumansCached()
	for i = 1, #humans do
		local ply = humans[i]
		if IsValid(ply) then
			local eyePos = ply:EyePos()
			if eyePos:DistToSqr(scratchVecB) < 480 * 480 then
				return false
			end
			scratchVecA:SetUnpacked(eyePos.x, eyePos.y, eyePos.z)
			sharedHiddenTr.filter = ply
			local tr = util.TraceLine(sharedHiddenTr)
			sharedHiddenTr.filter = nil
			if not tr.Hit then
				return false
			end
		end
	end
	return true
end

function AI.CheckStuck(npc, expectedSpeed, isAttackingBarricade)
	local mem = npc.D3bot_Mem
	if not mem then return false, false, 0 end

	local ct = CurTime()
	if ct >= (mem.NextPosSample or 0) then
		mem.NextPosSample = ct + 0.35
		AI.StorePos(npc)
	end

	-- Don't treat actively bashing a barricade/human as stuck
	if isAttackingBarricade or (npc.D3bot_LastDamage and npc.D3bot_LastDamage > ct - 3.5) then
		mem.StuckTier = 0
		mem.StuckStateName = "COMBAT"
		mem.RecoveryAttempts = 0
		mem.NextBotStuckFlag = false
		return false, false, 0
	end

	if mem.NextCheckStuck and mem.NextCheckStuck >= ct and not mem.NextBotStuckFlag then
		return (mem.StuckTier or 0) >= 1, (mem.StuckTier or 0) >= 4, mem.StuckTier or 0
	end
	mem.NextCheckStuck = ct + 0.45 + math.random() * 0.1

	local posList = mem.PosList
	local p1 = posList[1]
	local p3 = posList[3]   -- ~1.05s ago
	local p6 = posList[6]   -- ~2.10s ago
	local p10 = posList[10] -- ~3.50s ago
	local p14 = posList[14] -- ~4.90s ago

	local vel = (npc.loco and npc.loco:GetVelocity()) or npc:GetVelocity()
	local vel2D = vel:Length2D()
	local lowSpeed = expectedSpeed > 30 and vel2D < 0.22 * expectedSpeed

	local tier = 0
	if p1 and p3 and p1:DistToSqr(p3) < 14 * 14 and lowSpeed then
		tier = 1 -- Micro-stall
	end
	if (mem.NextBotStuckFlag or (p1 and p6 and p1:DistToSqr(p6) < 26 * 26)) and lowSpeed then
		tier = mathMax(tier, 2) -- Persistent obstacle/edge stall
	end
	local nodeStalled = mem.NextNodeOrNil and mem.CurrentNextNodeSince and (ct - mem.CurrentNextNodeSince) > 4.5
	if (p1 and p10 and p1:DistToSqr(p10) < 42 * 42) or nodeStalled then
		tier = mathMax(tier, 3) -- Route / link failure
	end
	if (mem.RecoveryAttempts or 0) >= 3 and p1 and p14 and p1:DistToSqr(p14) < 64 * 64 then
		tier = 4 -- Critical inescapable trap
	end

	if tier == 0 and not lowSpeed then
		mem.RecoveryAttempts = 0
		mem.StuckStateName = "OK"
	end

	mem.NextBotStuckFlag = false
	mem.StuckTier = tier
	if tier == 1 then mem.StuckStateName = "MICRO_STALL"
	elseif tier == 2 then mem.StuckStateName = "OBSTACLE_STALL"
	elseif tier == 3 then mem.StuckStateName = "ROUTE_FAIL"
	elseif tier >= 4 then mem.StuckStateName = "CRITICAL_TRAP"
	end

	return tier >= 1, tier >= 4, tier
end

-- =========================================================================
-- 8. Local Obstacle Whiskers, Wall-Slide Projection & Spatial Crowd Steering
-- =========================================================================

local function traceWhiskerShared(sx, sy, sz, dx, dy, dist)
	scratchVecA:SetUnpacked(sx, sy, sz)
	scratchVecB:SetUnpacked(sx + dx * dist, sy + dy * dist, sz)
	return util.TraceHull(sharedWhiskerTr)
end

function AI.UpdateWhiskers(npc, moveDir, cfg, distToTargetSqr)
	if not lib.ConVars.WhiskerAvoidance or not lib.ConVars.WhiskerAvoidance:GetBool() then
		return vector_origin, false, false, nil
	end
	local mem = npc.D3bot_Mem
	if not mem then return vector_origin, false, false, nil end

	local steer = mem.WhiskerSteer
	if not steer then
		steer = Vector()
		mem.WhiskerSteer = steer
	end

	local ct = CurTime()
	if ct < (mem.NextWhiskerCheck or 0) then
		return steer, mem.WhiskerShouldJump == true, mem.WhiskerShouldDuck == true, mem.WhiskerBlockedEnt
	end

	-- Adaptive cadence: ~8.5Hz near combat/chokes, ~5.2Hz when >1400u from target
	local baseCadence = (distToTargetSqr and distToTargetSqr > 1400 * 1400) and 0.19 or 0.11
	mem.NextWhiskerCheck = ct + baseCadence + ((npc:EntIndex() % 5) * 0.01)

	local npcPos = npc:GetPos()
	local mx, my = moveDir.x, moveDir.y
	local rx, ry = my, -mx
	local wx, wy, wz = npcPos.x, npcPos.y, npcPos.z + 28
	local reach = 46

	filterSelfNpc = npc

	local trCenter = traceWhiskerShared(wx, wy, wz, mx, my, reach)

	local dlx = mx * 0.84 - rx * 0.54
	local dly = my * 0.84 - ry * 0.54
	local drx = mx * 0.84 + rx * 0.54
	local dry = my * 0.84 + ry * 0.54
	local trLeft = traceWhiskerShared(wx, wy, wz, dlx, dly, reach)
	local trRight = traceWhiskerShared(wx, wy, wz, drx, dry, reach)

	local steerX, steerY = 0, 0
	local wantJump = false
	local wantDuck = false
	local blockedEnt = nil

	if trLeft.Hit and not trRight.Hit then
		local w = (1 - trLeft.Fraction * 0.5) * 48
		steerX, steerY = steerX + rx * w, steerY + ry * w
		mem.StrafeDir = 1
	elseif trRight.Hit and not trLeft.Hit then
		local w = (1 - trRight.Fraction * 0.5) * 48
		steerX, steerY = steerX - rx * w, steerY - ry * w
		mem.StrafeDir = -1
	elseif trLeft.Hit and trRight.Hit then
		if trLeft.Fraction > trRight.Fraction + 0.1 then
			steerX, steerY = steerX - rx * 42, steerY - ry * 42
			mem.StrafeDir = -1
		elseif trRight.Fraction > trLeft.Fraction + 0.1 then
			steerX, steerY = steerX + rx * 42, steerY + ry * 42
			mem.StrafeDir = 1
		end
	end

	if trCenter.Hit then
		local hitEnt = trCenter.Entity
		if IsValid(hitEnt) and (lib.IsBarricadeEntity(hitEnt) or barricadeExtraClasses[hitEnt:GetClass()]) then
			blockedEnt = hitEnt
		else
			-- Check if center hit is a jumpable low obstacle/crate/railing (clear at head height z+58)
			local trHigh = traceWhiskerShared(wx, wy, npcPos.z + 58, mx, my, reach + 6)
			if not trHigh.Hit and cfg.CanJump then
				wantJump = true
			else
				-- Wall-slide deflection along surface normal + wider +-60 deg corner probe
				local hn = trCenter.HitNormal
				local sideDot = hn.x * rx + hn.y * ry
				if mathAbs(sideDot) > 0.18 then
					local slideSign = (sideDot >= 0) and 1 or -1
					local slideStrength = (1 - trCenter.Fraction * 0.4) * 52
					steerX, steerY = steerX + rx * slideSign * slideStrength, steerY + ry * slideSign * slideStrength
					mem.StrafeDir = slideSign
				end

				local wideL = traceWhiskerShared(wx, wy, wz, mx * 0.5 - rx * 0.86, my * 0.5 - ry * 0.86, 54)
				local wideR = traceWhiskerShared(wx, wy, wz, mx * 0.5 + rx * 0.86, my * 0.5 + ry * 0.86, 54)
				if wideL.Fraction > wideR.Fraction + 0.08 then
					steerX, steerY = steerX - rx * 56, steerY - ry * 56
					mem.StrafeDir = -1
				elseif wideR.Fraction > wideL.Fraction + 0.08 then
					steerX, steerY = steerX + rx * 56, steerY + ry * 56
					mem.StrafeDir = 1
				end
			end
		end
	elseif not cfg.CantDuck then
		local trHead = traceWhiskerShared(wx, wy, npcPos.z + 58, mx, my, 42)
		if trHead.Hit and trHead.HitWorld then
			wantDuck = true
		end
	end

	filterSelfNpc = nil

	steer:SetUnpacked(steerX, steerY, 0)
	mem.WhiskerShouldJump = wantJump
	mem.WhiskerShouldDuck = wantDuck
	mem.WhiskerBlockedEnt = blockedEnt
	return steer, wantJump, wantDuck, blockedEnt
end

function AI.ComputeCrowdSteering(npc, moveDir, distToTarget, isNarrow)
	if (not lib.ConVars.SeparationForce or not lib.ConVars.SeparationForce:GetBool())
		and (not lib.ConVars.CrowdAvoidance or not lib.ConVars.CrowdAvoidance:GetBool()) then
		return vector_origin, 1.0
	end
	if not lib.ConVars.NoCollideZombies or not lib.ConVars.NoCollideZombies:GetBool() then
		return vector_origin, 1.0
	end

	AI.GetLivingNPCsCached()
	local grid = AI.NPCSpatialGrid
	if not grid then return vector_origin, 1.0 end

	local mem = npc.D3bot_Mem
	local push = mem and mem.CrowdPushVec
	if not push then
		push = Vector()
		if mem then mem.CrowdPushVec = push end
	end

	local myPos = npc:GetPos()
	local mx, my = moveDir.x, moveDir.y
	local rx, ry = my, -mx
	local cx = mathFloor(myPos.x / NPC_GRID_CELL)
	local cy = mathFloor(myPos.y / NPC_GRID_CELL)

	-- Keep melee hordes fanned out cleanly into a surrounding ring rather than collapsing to one point
	local inMeleeRing = distToTarget <= 78
	local minSep = isNarrow and 24 or (inMeleeRing and 30 or 42)
	local minSepSqr = minSep * minSep
	local pushScale = isNarrow and 18 or (inMeleeRing and 44 or 36)
	local crowdEnabled = lib.ConVars.CrowdAvoidance and lib.ConVars.CrowdAvoidance:GetBool()

	local pushX, pushY = 0, 0
	local count = 0
	local frontBlockedCount = 0

	for dxCell = -1, 1 do
		for dyCell = -1, 1 do
			local bucket = grid[npcGridKey(cx + dxCell, cy + dyCell)]
			if bucket then
				for i = 1, #bucket do
					local other = bucket[i]
					if other ~= npc and IsValid(other) then
						local otherPos = other:GetPos()
						if mathAbs(otherPos.z - myPos.z) <= 56 then
							local odx = myPos.x - otherPos.x
							local ody = myPos.y - otherPos.y
							local dSqr = odx * odx + ody * ody
							if dSqr > 0.05 and dSqr < minSepSqr then
								local d = mathSqrt(dSqr)
								local strength = (minSep - d) / minSep
								local ax = odx / d
								local ay = ody / d
								pushX = pushX + ax * strength * pushScale
								pushY = pushY + ay * strength * pushScale

								if crowdEnabled and distToTarget > 32 then
									local fwdDot = (-ax * mx) + (-ay * my)
									if fwdDot > 0.55 then
										frontBlockedCount = frontBlockedCount + 1
										local sideSign = ((-ax * rx) + (-ay * ry) >= 0) and -1 or 1
										local latWeight = inMeleeRing and 30 or 26
										pushX = pushX + rx * sideSign * strength * latWeight
										pushY = pushY + ry * sideSign * strength * latWeight
									end
								end

								count = count + 1
								if count >= 6 then break end
							end
						end
					end
				end
			end
			if count >= 6 then break end
		end
		if count >= 6 then break end
	end

	local speedMul = 1.0
	if crowdEnabled and frontBlockedCount >= 2 then
		speedMul = isNarrow and 0.78 or 0.88
	end

	push:SetUnpacked(pushX, pushY, 0)
	return push, speedMul
end

-- =========================================================================
-- 9. Target & Path Refresh Tick + Crow + Pounce Evaluators
-- =========================================================================

function AI.ThinkTargetAndPath(npc)
	local mem = npc.D3bot_Mem
	if not mem then return end
	local cfg = npc:GetClassConfig()
	local ct = CurTime()
	local npcPos = npc:GetPos()
	local detectRangeSqr = (cfg.DetectionRange or 1600) ^ 2

	-- Acquire closest visible target within DetectionRange (zero-allocation top-2 scan)
	if not mem.nextUpdateSurroundingPlayers or mem.nextUpdateSurroundingPlayers < ct then
		if not IsValid(mem.TgtOrNil) or mem.TgtOrNil:GetPos():DistToSqr(npcPos) > (AI.BotTgtFixationDistMin ^ 2) then
			mem.nextUpdateSurroundingPlayers = ct + 0.85 + math.random() * 0.25
			local players = cfg.IsCrow and lib.RemoveObsDeadTgts(player.GetHumans()) or AI.GetLivingHumansCached()
			local c1, d1 = nil, math.huge
			local c2, d2 = nil, math.huge
			for i = 1, #players do
				local p = players[i]
				if IsValid(p) then
					local dSqr = npcPos:DistToSqr(p:GetPos())
					if dSqr <= detectRangeSqr then
						if dSqr < d1 then
							c2, d2 = c1, d1
							c1, d1 = p, dSqr
						elseif dSqr < d2 then
							c2, d2 = p, dSqr
						end
					end
				end
			end
			if c1 and AI.CanBeTgt(npc, c1) and AI.CanSeeTarget(npc, nil, c1) then
				AI.SetTgtOrNil(npc, c1, false, nil)
				mem.nextUpdateSurroundingPlayers = ct + 2.8
			elseif c2 and AI.CanBeTgt(npc, c2) and AI.CanSeeTarget(npc, nil, c2) then
				AI.SetTgtOrNil(npc, c2, false, nil)
				mem.nextUpdateSurroundingPlayers = ct + 2.8
			end
		end
	end

	-- Validate target still alive & valid
	if not mem.nextCheckTarget or mem.nextCheckTarget < ct then
		mem.nextCheckTarget = ct + 0.8 + math.random() * 0.2
		if not AI.CanBeTgt(npc, mem.TgtOrNil) or (cfg.IsCrow and math.random(1, 50) == 1) then
			AI.RerollTarget(npc)
			mem.ForcePathRefresh = true
		end
	end

	-- Periodic angular jitter offshoot
	if not mem.nextUpdateOffshoot or mem.nextUpdateOffshoot < ct then
		mem.nextUpdateOffshoot = ct + 0.4 + math.random() * 0.2
		AI.UpdateAngsOffshoot(npc, cfg.IsCrow and AI.CrowAngOffshoot or AI.AngOffshoot)
	end

	-- Smart adaptive path refresh using shared cached target navnodes
	if mem.ForcePathRefresh or not mem.NextNodeOrNil or not mem.nextUpdatePath or mem.nextUpdatePath < ct then
		local baseInterval = (lib.ConVars.PathRecalcInterval and lib.ConVars.PathRecalcInterval:GetFloat()) or 1.1
		local tgtDist = IsValid(mem.TgtOrNil) and npcPos:Distance(mem.TgtOrNil:GetPos()) or 1000
		local distScale = (tgtDist > 900) and 1.7 or ((tgtDist < 420) and 0.75 or 1.0)
		mem.nextUpdatePath = ct + baseInterval * distScale + math.random() * 0.25

		local needSolve = mem.ForcePathRefresh or not mem.NextNodeOrNil
		if not needSolve and IsValid(mem.TgtOrNil) and not lib.UsingSourceNav and lib.MapNavMesh and lib.MapNavMesh.GetBestNodeNear then
			local curTgtNode = AI.GetTargetNavNode(mem.TgtOrNil, lib.MapNavMesh.MainComponentId)
			if curTgtNode ~= mem.TgtNodeOrNil or (mem.RemainingNodes and #mem.RemainingNodes == 0) then
				needSolve = true
			end
		else
			needSolve = true
		end

		if needSolve and not (mem.PathUnavailableUntil and ct < mem.PathUnavailableUntil and not mem.ForcePathRefresh) then
			AI.UpdatePath(npc, mem.ForcePathRefresh == true)
		end
	end
end

function AI.EvaluateCrowStep(npc)
	local mem = npc.D3bot_Mem
	local cfg = npc:GetClassConfig()
	local origin = npc:GetShootPos()
	local npcPos = npc:GetPos()
	local ct = CurTime()

	local moveVec = mem.SteeredMoveVec
	if not moveVec then
		moveVec = Vector()
		mem.SteeredMoveVec = moveVec
	end

	local hasDest = false
	local attackTarget = nil

	if IsValid(mem.TgtOrNil) then
		local dist = npcPos:Distance(mem.TgtOrNil:GetPos())
		if dist < 260 and AI.CanSeeTargetCached(npc, 0.85, mem.TgtOrNil) then
			local angOff = AI.GetOffshoot(npc, 1)
			local angRad = math.rad(ct * 120 + (npc:EntIndex() * 47))
			local ep = mem.TgtOrNil:EyePos()
			scratchCrowOrbit:SetUnpacked(ep.x + math.cos(angRad) * 28, ep.y + math.sin(angRad) * 28, ep.z + 12)
			moveVec:Set(scratchCrowOrbit)
			hasDest = true
			attackTarget = mem.TgtOrNil
			AI.AngsRotateTo(npc, (moveVec - origin):Angle() + angOff * 0.3, 0.25)
		elseif mem.NextNodeOrNil then
			local nPos = (lib.UsingSourceNav and IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetCenter()) or (istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Pos) or nil
			if nPos then
				moveVec:SetUnpacked(nPos.x, nPos.y, nPos.z + 64)
				hasDest = true
				AI.AngsRotateTo(npc, (moveVec - origin):Angle() + AI.GetOffshoot(npc, 1), 0.18)
			end
		else
			local ep = mem.TgtOrNil:EyePos()
			moveVec:SetUnpacked(ep.x, ep.y, ep.z + 28)
			hasDest = true
			AI.AngsRotateTo(npc, (moveVec - origin):Angle() + AI.GetOffshoot(npc, 0.5), 0.2)
		end
	elseif mem.NextNodeOrNil then
		local nPos = (lib.UsingSourceNav and IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetCenter()) or (istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Pos) or nil
		if nPos then
			moveVec:SetUnpacked(nPos.x, nPos.y, nPos.z + 64)
			hasDest = true
			AI.AngsRotateTo(npc, (moveVec - origin):Angle() + AI.GetOffshoot(npc, 1), 0.18)
		end
	end

	local shouldPeck = IsValid(attackTarget) and origin:DistToSqr(attackTarget:EyePos()) <= ((cfg.AttackRange or 36) + 12) ^ 2
	local shouldFlap = hasDest and (not npc:IsOnGround() or math.random(1, 2) == 1)

	local intent = mem.StepIntent or {}
	mem.StepIntent = intent
	intent.hasDestination = hasDest
	intent.movePos = hasDest and moveVec or nil
	intent.desiredSpeed = cfg.FlyingSpeed or cfg.RunSpeed or 260
	intent.aimAngle = mem.Angs or npc:GetAngles()
	intent.shouldAttack = shouldPeck
	intent.shouldRanged = false
	intent.shouldJump = shouldFlap
	intent.shouldDuck = false
	intent.shouldClimb = false
	intent.climbTargetPos = nil
	intent.pounce = nil
	intent.minorStuck = false
	intent.majorStuck = false
	intent.facesHindrance = false
	intent.attackTarget = attackTarget
	return intent
end

function AI.EvaluatePounce(npc)
	local mem = npc.D3bot_Mem
	local cfg = npc:GetClassConfig()
	if not cfg.CanPounce or not cfg.PounceVelocity then return nil end
	if not npc:IsOnGround() and not mem.pouncing then return nil end

	local ct = CurTime()
	if mem.pouncing then
		if mem.pouncingTimer and mem.pouncingTimer < ct and (ct - mem.pouncingTimer > 4.5 or npc:WaterLevel() >= 2 or npc:IsOnGround()) then
			mem.pouncing = false
			mem.pounceFlightTime = nil
			AI.UpdatePathProgress(npc)
			return nil
		end
		return {
			active = true,
			aimAngle = mem.Angs,
			triggerNow = false
		}
	end

	if npc:GetNextPounceTime() > ct then return nil end
	if cfg.IsCrab and mem.NextPounce and mem.NextPounce > ct then return nil end

	-- Throttle expensive trajectory hull traces to 4Hz per pouncing zombie
	if ct < (mem.NextPounceEval or 0) then return nil end
	mem.NextPounceEval = ct + 0.24

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil
	local crab = cfg.IsCrab

	local tempPos = npc:GetPos()
	local tempDist = 0
	local pounceTargetPositions = {}

	if nextNodeOrNil then
		if lib.UsingSourceNav and IsValid(nextNodeOrNil) then
			local cPos = nextNodeOrNil:GetCenter()
			local link = IsValid(nodeOrNil) and nextNodeOrNil:D3botNPC_SharesLink(nodeOrNil)
			local lp = link and link:GetMetaData().Params or {}
			tempDist = tempDist + tempPos:Distance(cPos)
			tempPos = cPos
			pounceTargetPositions[#pounceTargetPositions + 1] = {
				Pos = cPos + Vector(0, 0, 2),
				Dist = tempDist,
				TimeFactor = 1.1,
				ForcePounce = (crab and lp.CrabPouncing == "Needed") or (not crab and lp.Pouncing == "Needed")
			}
		elseif not lib.UsingSourceNav then
			local link = nodeOrNil and nextNodeOrNil.LinkByLinkedNode and nextNodeOrNil.LinkByLinkedNode[nodeOrNil]
			local lp = link and link.Params or {}
			tempDist = tempDist + tempPos:Distance(nextNodeOrNil.Pos)
			tempPos = nextNodeOrNil.Pos
			pounceTargetPositions[#pounceTargetPositions + 1] = {
				Pos = nextNodeOrNil.Pos + Vector(0, 0, 2),
				Dist = tempDist,
				TimeFactor = 1.1,
				ForcePounce = (crab and lp.CrabPouncing == "Needed") or (not crab and lp.Pouncing == "Needed")
			}
		end
	end

	for i, remNode in ipairs(mem.RemainingNodes or {}) do
		local rPos = (lib.UsingSourceNav and IsValid(remNode) and remNode:GetCenter()) or (istable(remNode) and remNode.Pos) or nil
		if rPos then
			tempDist = tempDist + tempPos:Distance(rPos)
			tempPos = rPos
			pounceTargetPositions[#pounceTargetPositions + 1] = { Pos = rPos + Vector(0, 0, 2), Dist = tempDist, TimeFactor = 1.1 }
			if i >= 2 then break end
		end
	end

	local futureAttackPos = AI.GetAttackPosOrNilFuturePlatforms(npc, 0.35, mem.pounceFlightTime or 0)
	if futureAttackPos then
		tempDist = tempDist + npc:GetPos():Distance(futureAttackPos)
		pounceTargetPositions[#pounceTargetPositions + 1] = { Pos = futureAttackPos + Vector(0, 0, 2), Dist = tempDist, TimeFactor = 0.85, HeightDiff = 90 }
	elseif mem.PosTgtOrNil then
		tempDist = tempDist + npc:GetPos():Distance(mem.PosTgtOrNil)
		pounceTargetPositions[#pounceTargetPositions + 1] = { Pos = mem.PosTgtOrNil + Vector(0, 0, 2), Dist = tempDist, TimeFactor = 0.85, HeightDiff = 90 }
	end

	if #pounceTargetPositions == 0 then return nil end

	local maxSpd = mathMax(npc:GetMaxSpeed(), 100)
	local startDelay = cfg.PounceStartDelay or 0.4
	local chosenTraj = nil

	for i = #pounceTargetPositions, 1, -1 do
		local ptp = pounceTargetPositions[i]
		local trajs = AI.CanPounceToPos(npc, ptp.Pos)
		if trajs then
			local timeToTarget = ptp.Dist / maxSpd
			if ptp.ForcePounce or (ptp.HeightDiff and ptp.Pos.z - npc:GetPos().z > ptp.HeightDiff) or timeToTarget > (trajs[1].t1 + startDelay) * ptp.TimeFactor then
				chosenTraj = trajs[1]
				break
			end
		end
	end

	if not chosenTraj then return nil end

	mem.Angs = Angle(-math.deg(chosenTraj.pitch), math.deg(chosenTraj.yaw), 0)
	mem.pounceFlightTime = mathClamp(chosenTraj.t1, 0, 1.2)
	mem.pouncing = true
	mem.pouncingStartTime = ct + startDelay
	mem.pouncingTimer = ct + 0.9 + math.random() * 0.2
	mem.NextPounce = ct + AI.PounceIntervalCrab + math.random() * AI.PounceIntervalCrabRandom

	return {
		active = true,
		triggerNow = true,
		aimAngle = mem.Angs,
		trajectory = chosenTraj
	}
end

-- =========================================================================
-- 10. Main Step Evaluation & Movement Intent Synthesis (Zero-Alloc Hot Path)
-- =========================================================================

function AI.EvaluateStep(npc)
	local mem = npc.D3bot_Mem
	if not mem then
		AI.InitializeOrReset(npc)
		mem = npc.D3bot_Mem
	end

	AI.ThinkTargetAndPath(npc)
	AI.UpdatePathProgress(npc)

	local cfg = npc:GetClassConfig()
	if cfg.IsCrow then
		return AI.EvaluateCrowStep(npc)
	end

	local ct = CurTime()
	local origin = npc:GetShootPos()
	local npcPos = npc:GetPos()

	local intent = mem.StepIntent
	if not intent then
		intent = {}
		mem.StepIntent = intent
	end
	intent.hasDestination = false
	intent.movePos = nil
	intent.desiredSpeed = cfg.RunSpeed or 175
	intent.aimAngle = mem.Angs or npc:GetAngles()
	intent.shouldAttack = false
	intent.shouldRanged = false
	intent.shouldJump = false
	intent.shouldDuck = false
	intent.shouldClimb = false
	intent.climbTargetPos = nil
	intent.pounce = nil
	intent.minorStuck = false
	intent.majorStuck = false
	intent.facesHindrance = false
	intent.attackTarget = nil

	if mem.BlockMovementUntil then
		if mem.BlockMovementUntil >= ct then
			return intent
		else
			mem.BlockMovementUntil = nil
		end
	end

	-- 1. Pounce check (Fast Zombie, Lacerator, Headcrabs)
	local pounceInfo = AI.EvaluatePounce(npc)
	if pounceInfo and pounceInfo.active then
		intent.hasDestination = true
		intent.aimAngle = pounceInfo.aimAngle
		intent.pounce = pounceInfo
		return intent
	end

	-- 2. Determine navmesh path vs walkable direct chase
	local canSee = AI.CanSeeTargetCached(npc, nil, mem.TgtOrNil)
	local attackPos = AI.GetAttackPosOrNil(npc, 0.75, mem.TgtOrNil)
	local hasTgt = IsValid(mem.TgtOrNil)
	local tgtPos = hasTgt and mem.TgtOrNil:GetPos() or nil
	local distToTargetSqr = tgtPos and npcPos:DistToSqr(tgtPos) or math.huge
	local distToTarget = tgtPos and mathSqrt(distToTargetSqr) or math.huge

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil

	if not lib.UsingSourceNav then
		if nodeOrNil and (not istable(nodeOrNil) or not nodeOrNil.Pos) then nodeOrNil = nil end
		if nextNodeOrNil and (not istable(nextNodeOrNil) or not nextNodeOrNil.Pos) then nextNodeOrNil = nil end
	else
		if nodeOrNil and not IsValid(nodeOrNil) then nodeOrNil = nil end
		if nextNodeOrNil and not IsValid(nextNodeOrNil) then nextNodeOrNil = nil end
	end

	local sameNodeAsTarget = (not nextNodeOrNil) and nodeOrNil and mem.TgtNodeOrNil and (nodeOrNil == mem.TgtNodeOrNil)
	local allowNoNav = lib.ConVars.AllowNoNavFallback and lib.ConVars.AllowNoNavFallback:GetBool()
	local pathFallbackActive = (not nextNodeOrNil) and mem.PathUnavailableUntil and ct < mem.PathUnavailableUntil and allowNoNav
	local directWalkable = hasTgt and not mem.DontAttackTgt and AI.CanWalkDirectlyToTarget(npc, mem.TgtOrNil, canSee, sameNodeAsTarget)
	local shouldWalkAttack = directWalkable
	if not nextNodeOrNil and hasTgt and (directWalkable or sameNodeAsTarget or pathFallbackActive or not lib.HasNavMesh) then
		shouldWalkAttack = true
	end

	if mem.BlockedOnNode and mem.BlockedOnNode == nodeOrNil then
		mem.BlockedOnNode = nil
	end

	local duckParam, duckToParam, jumpParam, jumpToParam
	local maxHeightParam, nextMaxHeightParam
	local climbParam, pathParam, ladderParam
	local currentLinkOrNil
	local linkJumpRec = false
	local nodeNeedsCrouch = false

	if lib.UsingSourceNav then
		local p1 = IsValid(nodeOrNil) and nodeOrNil:D3botNPC_GetMetaData().Params
		local p2 = IsValid(nextNodeOrNil) and nextNodeOrNil:D3botNPC_GetMetaData().Params
		duckParam = p1 and p1.Duck
		duckToParam = p2 and p2.DuckTo
		jumpParam = p1 and p1.Jump
		jumpToParam = p2 and p2.JumpTo
		maxHeightParam = p1 and tonumber(p1.MaxHeight)
		nextMaxHeightParam = p2 and tonumber(p2.MaxHeight)
		climbParam = p2 and p2.Climbing
	else
		currentLinkOrNil = (nodeOrNil and nextNodeOrNil and nodeOrNil.LinkByLinkedNode) and nodeOrNil.LinkByLinkedNode[nextNodeOrNil] or nil
		duckParam = nodeOrNil and nodeOrNil.Params and nodeOrNil.Params.Duck
		duckToParam = nextNodeOrNil and nextNodeOrNil.Params and nextNodeOrNil.Params.DuckTo
		jumpParam = nodeOrNil and nodeOrNil.Params and nodeOrNil.Params.Jump
		jumpToParam = nextNodeOrNil and nextNodeOrNil.Params and nextNodeOrNil.Params.JumpTo
		ladderParam = nodeOrNil and nodeOrNil.Params and nodeOrNil.Params.Ladder
		pathParam = currentLinkOrNil and currentLinkOrNil.Params and currentLinkOrNil.Params.Path
		maxHeightParam = nodeOrNil and nodeOrNil.Params and tonumber(nodeOrNil.Params.MaxHeight)
		nextMaxHeightParam = nextNodeOrNil and nextNodeOrNil.Params and tonumber(nextNodeOrNil.Params.MaxHeight)
		climbParam = nextNodeOrNil and nextNodeOrNil.Params and nextNodeOrNil.Params.Climbing
		linkJumpRec = currentLinkOrNil and currentLinkOrNil.RuntimeJumpRecommended == true
		nodeNeedsCrouch = (nodeOrNil and nodeOrNil.RuntimeNeedsCrouch) or (nextNodeOrNil and nextNodeOrNil.RuntimeNeedsCrouch)

		if not jumpToParam and currentLinkOrNil and currentLinkOrNil.Params and currentLinkOrNil.Params.Jumping == "Needed" and nextNodeOrNil and nodeOrNil and nextNodeOrNil.Pos.z > nodeOrNil.Pos.z then
			jumpToParam = "Close"
		end
	end

	local targetMovePos = nil
	local aimStraight = false
	local proximity = mem.TgtProximity or 10
	local isIntermediateWaypoint = false

	if shouldWalkAttack and attackPos then
		targetMovePos = tgtPos
		aimStraight = true
		intent.attackTarget = mem.TgtOrNil
	elseif nextNodeOrNil then
		isIntermediateWaypoint = (mem.RemainingNodes and #mem.RemainingNodes > 0)
		if lib.UsingSourceNav and IsValid(nextNodeOrNil) then
			targetMovePos = nextNodeOrNil:D3botNPC_GetClosestPointOnArea(npcPos)
		elseif not lib.UsingSourceNav and nextNodeOrNil.GetClosestPointOnArea then
			targetMovePos = nextNodeOrNil:GetClosestPointOnArea(npcPos)
		end
	elseif mem.PosTgtOrNil then
		targetMovePos = mem.PosTgtOrNil
		proximity = mem.PosTgtProximity or 16
	elseif hasTgt and (not lib.HasNavMesh or pathFallbackActive) and allowNoNav then
		targetMovePos = tgtPos
		intent.attackTarget = mem.TgtOrNil
	end

	if not targetMovePos then
		return intent
	end

	scratchDir:SetUnpacked(targetMovePos.x - npcPos.x, targetMovePos.y - npcPos.y, 0)
	if scratchDir:LengthSqr() > 1 then
		scratchDir:Normalize()
	else
		local fwd = npc:GetForward()
		scratchDir:SetUnpacked(fwd.x, fwd.y, 0)
		if scratchDir:LengthSqr() > 0.001 then scratchDir:Normalize() end
	end

	-- 3. Climb / Ladder verticality handling
	local isLadderDescending = false
	if cfg.CanClimb and climbParam == "Needed" and nextNodeOrNil then
		local climbPos = lib.UsingSourceNav and nextNodeOrNil:GetCenter() or nextNodeOrNil.Pos
		if climbPos.z > npcPos.z + 18 then
			intent.shouldClimb = true
			intent.climbTargetPos = climbPos
		end
	end

	if pathParam == "Ladder" and nextNodeOrNil then
		local climbPos = lib.UsingSourceNav and nextNodeOrNil:GetCenter() or nextNodeOrNil.Pos
		mem.IsOnLadder = true
		intent.shouldClimb = true
		intent.climbTargetPos = climbPos
		isLadderDescending = (climbPos.z < npcPos.z - 24)
	else
		if mem.IsOnLadder and ladderParam ~= "NoDismount" then
			mem.LadderCrestUntil = ct + 0.30
			mem.LadderCrestDir:Set(scratchDir)
		end
		mem.IsOnLadder = false
	end

	-- 4. Local whisker obstacle/crate/overhang avoidance & wall-slide deflection
	local whiskerSteer, whiskerJump, whiskerDuck, whiskerEnt = AI.UpdateWhiskers(npc, scratchDir, cfg, distToTargetSqr)
	local isNarrow = (duckParam ~= nil or duckToParam ~= nil or nodeNeedsCrouch or (nextNodeOrNil and (nextNodeOrNil.RuntimeBottleneckScore or 0) >= 2))

	-- 5. O(1) spatial-grid crowd separation, overtaking & melee ring spread
	local crowdPush, crowdSpeedMul = vector_origin, 1.0
	if not intent.shouldClimb then
		crowdPush, crowdSpeedMul = AI.ComputeCrowdSteering(npc, scratchDir, distToTarget, isNarrow)
	end

	local steeredMovePos = mem.SteeredMoveVec
	if not steeredMovePos then
		steeredMovePos = Vector()
		mem.SteeredMoveVec = steeredMovePos
	end

	if mem.LadderCrestUntil and ct < mem.LadderCrestUntil and mem.LadderCrestDir then
		steeredMovePos:SetUnpacked(
			npcPos.x + mem.LadderCrestDir.x * 90,
			npcPos.y + mem.LadderCrestDir.y * 90,
			npcPos.z + 12
		)
	else
		steeredMovePos:SetUnpacked(
			targetMovePos.x + crowdPush.x + whiskerSteer.x,
			targetMovePos.y + crowdPush.y + whiskerSteer.y,
			targetMovePos.z
		)
	end

	-- 6. Barricade / Door / Ranged / Melee combat targeting (throttled barricade probe)
	local facesTgt = false
	local offshootAngle = AI.GetOffshoot(npc, aimStraight and 0 or 1)

	if shouldWalkAttack and attackPos then
		local meleeReachSqr = ((cfg.AttackRange or 48) + 18) ^ 2
		if origin:DistToSqr(attackPos) <= meleeReachSqr or npcPos:DistToSqr(tgtPos) <= meleeReachSqr then
			facesTgt = true
		end
		local desiredAim = (attackPos - origin):Angle()
		AI.AngsRotateTo(npc, desiredAim, lib.BotAttackAngLerpFactor)
		intent.aimAngle = mem.Angs
	else
		local cachedBarricade = mem.BarricadeAttackEntity
		if IsValid(cachedBarricade) and mem.BarricadeAttackPos then
			local bCls = cachedBarricade:GetClass()
			local isDoorOpen = (bCls == "prop_door_rotating" or bCls == "func_door" or bCls == "func_door_rotating")
				and not (cachedBarricade.IsNailed and cachedBarricade:IsNailed())
				and not cachedBarricade:GetInternalVariable("m_bLocked")
				and ((tonumber(cachedBarricade:GetInternalVariable("m_eDoorState")) or 0) ~= 0)
			local bx = mem.BarricadeAttackPos.x - npcPos.x
			local by = mem.BarricadeAttackPos.y - npcPos.y
			local behindMoveDir = (bx * scratchDir.x + by * scratchDir.y) < -12
			if not isDoorOpen and not behindMoveDir and origin:DistToSqr(mem.BarricadeAttackPos) < ((cfg.AttackRange or 48) + 34) ^ 2 then
				AI.AngsRotateTo(npc, (mem.BarricadeAttackPos - origin):Angle(), lib.BotAttackAngLerpFactor)
				intent.aimAngle = mem.Angs
				facesTgt = true
				intent.attackTarget = cachedBarricade
			else
				mem.BarricadeAttackEntity = nil
				mem.BarricadeAttackPos = nil
			end
		end
		if not IsValid(mem.BarricadeAttackEntity) then
			mem.BarricadeAttackEntity = nil
			mem.BarricadeAttackPos = nil
			local bEnt, bPos = nil, nil
			if IsValid(whiskerEnt) then
				bEnt = whiskerEnt
				bPos = whiskerEnt:WorldSpaceCenter()
			elseif mem.LastFacesHindrance or ct >= (mem.NextBarricadeProbe or 0) then
				mem.NextBarricadeProbe = ct + 0.18 + ((npc:EntIndex() % 4) * 0.02)
				bEnt, bPos = AI.FindBarricadeEntity(npc, 2, scratchDir)
			end
			if IsValid(bEnt) and bPos then
				mem.BarricadeAttackEntity = bEnt
				mem.BarricadeAttackPos = bPos
				facesTgt = true
				intent.attackTarget = bEnt
				AI.AngsRotateTo(npc, (bPos - origin):Angle(), lib.BotAttackAngLerpFactor)
				intent.aimAngle = mem.Angs
			else
				scratchLookPos:SetUnpacked(steeredMovePos.x, steeredMovePos.y, origin.z - 8)
				local desiredAim = (scratchLookPos - origin):Angle() + offshootAngle
				AI.AngsRotateTo(npc, desiredAim, lib.BotAngLerpFactor)
				intent.aimAngle = mem.Angs
			end
		end
	end

	-- Ranged spit classes (Ghoul / Poison Zombie / Bonemesh / Puke Pus)
	if cfg.RangedAttack and canSee and hasTgt and ct >= npc:GetNextRangedTime() then
		if distToTarget >= (cfg.RangedAttack.MinRange or 160) and distToTarget <= (cfg.RangedAttack.MaxRange or 700) then
			intent.shouldRanged = true
			intent.attackTarget = mem.TgtOrNil
		end
	end

	-- 7. Smooth locomotion speed (zero intermediate waypoint stutter)
	local baseMaxSpeed = npc:GetMaxSpeed() * crowdSpeedMul
	local speed = baseMaxSpeed
	if not shouldWalkAttack and not isIntermediateWaypoint and mem.PosTgtOrNil then
		local toMoveLen2D = mathSqrt((targetMovePos.x - npcPos.x) ^ 2 + (targetMovePos.y - npcPos.y) ^ 2)
		local invProximity = mathClamp((toMoveLen2D - proximity) / 60, 0.25, 1)
		speed = baseMaxSpeed * invProximity
	end

	local vel = (npc.loco and npc.loco:GetVelocity()) or npc:GetVelocity()
	local vel2D = vel:Length2D()
	local facesHindrance = vel2D < 0.25 * mathMax(speed, 40)
	mem.LastFacesHindrance = facesHindrance
	if not facesHindrance then
		mem.lastNoHindrance = ct
	end

	-- 8. Multi-tier Stuck Detection & Intelligent Recovery
	local isAttackingBarricade = IsValid(mem.BarricadeAttackEntity)
	local minorStuck, majorStuck, stuckTier = AI.CheckStuck(npc, speed, isAttackingBarricade)
	local recoveryJump = false

	if lib.ConVars.StuckRecovery and lib.ConVars.StuckRecovery:GetBool() and stuckTier >= 1 then
		local rx, ry = -scratchDir.y, scratchDir.x
		if stuckTier == 1 then
			if not mem.StrafeUntil or ct > mem.StrafeUntil + 0.35 then
				mem.StrafeUntil = ct + 0.55
				mem.LastRecoveryAction = "Tier1_WhiskerSidestep"
			end
			local s = (mem.StrafeDir or 1) * 46
			steeredMovePos:SetUnpacked(steeredMovePos.x + rx * s, steeredMovePos.y + ry * s, steeredMovePos.z)
		elseif stuckTier == 2 then
			if npc.loco and npc.loco.ClearStuck then npc.loco:ClearStuck() end
			if ct >= (mem.LastRecoveryTime or 0) + 0.8 then
				mem.LastRecoveryTime = ct
				mem.RecoveryAttempts = (mem.RecoveryAttempts or 0) + 1
				mem.StrafeUntil = ct + 0.75
				if cfg.CanJump and npc:IsOnGround() and not isNarrow then
					recoveryJump = true
					mem.LastRecoveryAction = "Tier2_JumpDodge"
				else
					mem.StrafeDir = (mem.StrafeDir or 1) * -1
					mem.LastRecoveryAction = "Tier2_ReverseDodge"
				end
			end
			local s = (mem.StrafeDir or 1) * 68
			steeredMovePos:SetUnpacked(steeredMovePos.x + rx * s, steeredMovePos.y + ry * s, steeredMovePos.z)
		elseif stuckTier == 3 then
			if ct >= (mem.LastRecoveryTime or 0) + 1.1 then
				mem.LastRecoveryTime = ct
				mem.RecoveryAttempts = (mem.RecoveryAttempts or 0) + 1
				if currentLinkOrNil then
					AI.MarkLinkFailed(npc, currentLinkOrNil, 16)
				end
				if nodeOrNil and mem.RecoveryAttempts >= 2 then
					mem.BadStartNodes = mem.BadStartNodes or {}
					mem.BadStartExpiry = mem.BadStartExpiry or {}
					mem.BadStartNodes[nodeOrNil] = true
					mem.BadStartExpiry[nodeOrNil] = ct + 10
				end
				local prevNextNode = mem.NextNodeOrNil
				mem.LastRecoveryAction = "Tier3_BlacklistLinkReroute"
				mem.ForcePathRefresh = true
				AI.UpdatePathImmediate(npc, true)
				if mem.NextNodeOrNil == prevNextNode then
					mem.ConsecutiveTier3 = (mem.ConsecutiveTier3 or 0) + 1
					if mem.ConsecutiveTier3 >= 2 then
						mem.RecoveryAttempts = mathMax(mem.RecoveryAttempts or 0, 3)
						mem.StuckTier = 4
						mem.ConsecutiveTier3 = 0
					end
				else
					mem.ConsecutiveTier3 = 0
				end
			end
		elseif stuckTier >= 4 then
			if ct >= (mem.LastRecoveryTime or 0) + 1.5 then
				mem.LastRecoveryTime = ct
				if IsValid(mem.TgtOrNil) then
					mem.UnreachableTargets = mem.UnreachableTargets or {}
					mem.UnreachableTargets[mem.TgtOrNil] = ct + 12
				end
				local prevTgt = mem.TgtOrNil
				AI.RerollTarget(npc)
				if mem.TgtOrNil ~= prevTgt then
					mem.LastRecoveryAction = "Tier4_TargetSwitch"
					mem.RecoveryAttempts = 1
					AI.UpdatePathImmediate(npc, false)
				else
					local nearestHumanDistSqr = math.huge
					local humans = AI.GetLivingHumansCached()
					for i = 1, #humans do
						local ply = humans[i]
						if IsValid(ply) then
							local hd = npcPos:DistToSqr(ply:GetPos())
							if hd < nearestHumanDistSqr then
								nearestHumanDistSqr = hd
							end
						end
					end

					if lib.ConVars.AllowLastResortTP and lib.ConVars.AllowLastResortTP:GetBool()
						and not lib.UsingSourceNav and lib.MapNavMesh and lib.MapNavMesh.GetBestNodeNear
						and nearestHumanDistSqr > 480 * 480
						and ct >= (mem.LastRepositionTime or 0) + 15
						and isPosHiddenFromHumans(npcPos) then
						local safeNode = lib.MapNavMesh:GetBestNodeNear(npcPos, {
							wave = lib.GetCurrentWave(),
							requireLinked = true,
							preferredComponentId = lib.MapNavMesh.MainComponentId,
							excludeNodes = mem.BadStartNodes
						})
						if safeNode and isvector(safeNode.Pos) and isPosHiddenFromHumans(safeNode.Pos) then
							npc:SetPos(safeNode.Pos + Vector(0, 0, 6))
							if npc.loco and npc.loco.ClearStuck then npc.loco:ClearStuck() end
							mem.LastRepositionTime = ct
							mem.RecoveryAttempts = 0
							mem.LastRecoveryAction = "Tier4_SafeNudge"
							AI.UpdatePathImmediate(npc, false)
						end
					elseif lib.GetWaveActive() and nearestHumanDistSqr > 400 * 400 then
						mem.LastRecoveryAction = "Tier4_RecycleRespawn"
						lib.DebugLog("Recycling trapped NPC %s at %s after %d recovery attempts", npc:GetNPCDisplayName(), tostring(npcPos), mem.RecoveryAttempts or 0)
						npc.m_SilentRecycle = true
						npc:TakeDamage(npc:Health() + 100, npc, npc)
					else
						mem.RecoveryAttempts = 0
						mem.FailedLinks = {}
						mem.LastRecoveryAction = "Tier4_ResetNearHuman"
						AI.UpdatePathImmediate(npc, false)
					end
				end
			end
		end
	elseif mem.StrafeUntil and ct < mem.StrafeUntil then
		local s = (mem.StrafeDir or 1) * 44
		steeredMovePos:SetUnpacked(steeredMovePos.x - scratchDir.y * s, steeredMovePos.y + scratchDir.x * s, steeredMovePos.z)
	end

	intent.hasDestination = true
	intent.movePos = steeredMovePos

	-- 9. Crouch / Duck decision (cached HalfHullWidth)
	local halfWidth = mem.HalfHullWidth or 16
	local shouldDuck = false
	if not cfg.CantDuck then
		if not duckParam and not duckToParam and not jumpParam and not jumpToParam then
			if (nextMaxHeightParam and nextMaxHeightParam < mem.Height) or (maxHeightParam and maxHeightParam < mem.Height) or nodeNeedsCrouch then
				shouldDuck = true
			end
		end
		if whiskerDuck then
			shouldDuck = true
		end
		if duckParam == "Always" or duckToParam == "Always" then
			shouldDuck = true
		elseif duckToParam == "Close" and nextNodeOrNil then
			local checkRadius = halfWidth + 8
			local cPt = lib.UsingSourceNav and nextNodeOrNil:D3botNPC_GetClosestPointOnArea(npcPos) or nextNodeOrNil:GetClosestPointOnArea(npcPos)
			if ((npcPos.x - cPt.x) ^ 2 + (npcPos.y - cPt.y) ^ 2) <= checkRadius * checkRadius then
				shouldDuck = true
			end
		end
		if not npc:IsOnGround() and npc:WaterLevel() == 0 and not intent.shouldClimb then
			shouldDuck = true
		end
		if facesHindrance and npc:IsOnGround() and math.random(lib.BotDuckAntichance) == 1 then
			shouldDuck = true
		end
		if duckParam == "Disabled" or duckToParam == "Disabled" then
			shouldDuck = false
		end
	end

	-- 10. Smart Jump & Water Swim-Up decision
	local shouldJump = false
	if npc:WaterLevel() >= 2 and targetMovePos.z > npcPos.z + 12 then
		shouldJump = true
	elseif cfg.CanJump and npc:IsOnGround() and not shouldDuck then
		local dzToNext = 0
		if not lib.UsingSourceNav and istable(nextNodeOrNil) and nextNodeOrNil.Pos then
			dzToNext = nextNodeOrNil.Pos.z - npcPos.z
		elseif lib.UsingSourceNav and IsValid(nextNodeOrNil) then
			dzToNext = nextNodeOrNil:GetCenter().z - npcPos.z
		end

		if jumpParam == "Always" or jumpToParam == "Always" or (intent.shouldClimb and not isLadderDescending) or recoveryJump or whiskerJump then
			shouldJump = true
		elseif (jumpToParam == "Close" or linkJumpRec) and nextNodeOrNil then
			local checkRadius = halfWidth + 12
			local cPt = lib.UsingSourceNav and nextNodeOrNil:D3botNPC_GetClosestPointOnArea(npcPos) or nextNodeOrNil:GetClosestPointOnArea(npcPos)
			if ((npcPos.x - cPt.x) ^ 2 + (npcPos.y - cPt.y) ^ 2) <= checkRadius * checkRadius and dzToNext > 14 then
				shouldJump = true
			end
		elseif facesHindrance and dzToNext > 16 and math.random(1, 6) == 1 then
			shouldJump = true
		elseif facesHindrance and math.random(lib.BotJumpAntichance) == 1 then
			shouldJump = true
		end

		if jumpParam == "Disabled" or jumpToParam == "Disabled" then
			shouldJump = false
		end
	end

	-- Anti-stuck below ceiling recovery
	if npc:IsOnGround() and npc:Crouching() and not shouldDuck
		and (not npc.D3bot_LastDamage or npc.D3bot_LastDamage < ct - 2)
		and (not mem.lastNoHindrance or mem.lastNoHindrance < ct - 2) then
		mem.AntiStuckCounter = (mem.AntiStuckCounter or 0) + 1
		if mem.AntiStuckCounter > 24 then
			mem.AntiStuckCounter = nil
			mem.AntiStuckTime = ct + 0.9
		end
	else
		mem.AntiStuckCounter = nil
	end

	if mem.AntiStuckTime and mem.AntiStuckTime > ct then
		shouldJump = true
	end

	intent.desiredSpeed = shouldDuck and (speed * (cfg.CrouchedWalkSpeed or 0.55)) or speed
	intent.shouldDuck = shouldDuck
	intent.shouldJump = shouldJump
	intent.shouldAttack = facesTgt or (facesHindrance and directWalkable and not intent.shouldClimb and distToTarget < 95)
	intent.minorStuck = minorStuck
	intent.majorStuck = majorStuck
	intent.facesHindrance = facesHindrance

	return intent
end
