-- Faithful port of D3bot sv_zs_bot_handler/basics.lua
local lib = D3botNPC

lib.Basics = lib.Basics or {}

---Let the bot suicide or retarget, based on the node parameters of the current and next node.
function lib.Basics.SuicideOrRetarget(bot)
	local mem = bot.D3bot_Mem
	if not mem then return end

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil

	if lib.UsingSourceNav then return end

	if nodeOrNil and nextNodeOrNil and nextNodeOrNil.Pos and nodeOrNil.Pos and nextNodeOrNil.Pos.z > nodeOrNil.Pos.z + 55 then
		local wallParam = nextNodeOrNil.Params and nextNodeOrNil.Params.Wall
		if wallParam == "Retarget" then
			local handler = lib.FindHandler and lib.FindHandler(bot:GetZombieClass(), bot:Team(), bot)
			if handler and handler.RerollTarget then handler.RerollTarget(bot) end
			return
		elseif wallParam == "Suicide" then
			bot:Kill()
			return
		end
	end
end

local function getClosestNodePt(node, origin)
	if lib.UsingSourceNav then
		if IsValid(node) and node.D3botNPC_GetClosestPointOnArea then
			return node:D3botNPC_GetClosestPointOnArea(origin)
		end
		return IsValid(node) and node:GetCenter() or origin
	end
	if node and node.GetClosestPointOnArea then
		return node:GetClosestPointOnArea(origin)
	end
	return (node and node.Pos) or origin
end

---Basic walking handler.
function lib.Basics.Walk(bot, pos, aimAngle, slowdown, proximity)
	local mem = bot.D3bot_Mem
	if not mem then
		return false, {}, nil, nil, nil, angle_zero, false, false, false
	end

	if mem.BlockMovementUntil then
		if mem.BlockMovementUntil >= CurTime() and mem.BlockedOnNode and mem.BlockedOnNode.GetContains and mem.BlockedOnNode:GetContains(bot:GetPos(), nil) then
			return false, {}, nil, nil, nil, mem.Angs or angle_zero, false, false, false
		else
			mem.BlockMovementUntil = nil
			mem.BlockedOnNode = nil
		end
	end

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil
	local currentLinkOrNil
	if lib.UsingSourceNav then
		currentLinkOrNil = (IsValid(nodeOrNil) and IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_SharesLink) and nextNodeOrNil:D3botNPC_SharesLink(nodeOrNil) or nil
	else
		currentLinkOrNil = (nodeOrNil and nextNodeOrNil and nextNodeOrNil.LinkByLinkedNode) and nextNodeOrNil.LinkByLinkedNode[nodeOrNil] or nil
	end

	local offshootAngle = angle_zero
	local origin = bot:GetPos()
	local actions = {}

	local shouldClimb
	if lib.UsingSourceNav then
		local nMd = IsValid(nodeOrNil) and nodeOrNil.D3botNPC_GetMetaData and nodeOrNil:D3botNPC_GetMetaData()
		local nnMd = IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_GetMetaData and nextNodeOrNil:D3botNPC_GetMetaData()
		shouldClimb = (nMd and nMd.Params and nMd.Params.Climbing == "Needed") or (nnMd and nnMd.Params and nnMd.Params.Climbing == "Needed")
	else
		shouldClimb = (nodeOrNil and nodeOrNil.Params and nodeOrNil.Params.Climbing == "Needed") or (nextNodeOrNil and nextNodeOrNil.Params and nextNodeOrNil.Params.Climbing == "Needed")
	end

	local aimStraight = false
	if lib.UsingSourceNav then
		if nodeOrNil and navmesh and navmesh.GetNavArea and not navmesh.GetNavArea(origin, 8) then aimStraight = true end
	else
		if nodeOrNil and nodeOrNil.GetContains and not nodeOrNil:GetContains(origin, nil) then aimStraight = true end
	end

	if shouldClimb then
		local weapon = bot:GetActiveWeapon()
		if weapon and weapon.GetClimbing and weapon:GetClimbing() and weapon.GetClimbSurface then
			local tr = weapon:GetClimbSurface()
			if tr and tr.Hit then
				bot:D3bot_AngsRotateTo((-tr.HitNormal):Angle(), 1)
			end
		else
			bot:D3bot_AngsRotateTo(Vector(pos.x - origin.x, pos.y - origin.y, 0):Angle(), 0.5)
		end
	else
		if mem.BarricadeAttackEntity and mem.BarricadeAttackPos and IsValid(mem.BarricadeAttackEntity) and mem.BarricadeAttackPos:DistToSqr(origin) < 100 * 100 then
			offshootAngle = bot:D3bot_GetOffshoot(0.1)
			aimAngle = aimAngle or (mem.BarricadeAttackPos - bot:GetShootPos()):Angle()
			bot:D3bot_AngsRotateTo(aimAngle + offshootAngle, 0.5)
		else
			offshootAngle = bot:D3bot_GetOffshoot(aimStraight and 0 or 1)
			aimAngle = aimAngle or (pos - origin):Angle()
			bot:D3bot_AngsRotateTo(aimAngle + offshootAngle, aimStraight and 1 or (lib.BotAngLerpFactor or 0.2))
			mem.BarricadeAttackPos, mem.BarricadeAttackEntity = nil, nil
		end
	end

	local duckParam, duckToParam, jumpParam, jumpToParam
	local maxHeightParam, nextMaxHeightParam
	local pathParam, ladderParam

	if lib.UsingSourceNav then
		local nP = IsValid(nodeOrNil) and nodeOrNil.D3botNPC_GetMetaData and nodeOrNil:D3botNPC_GetMetaData().Params or nil
		local nnP = IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_GetMetaData and nextNodeOrNil:D3botNPC_GetMetaData().Params or nil
		duckParam = nP and nP.Duck
		duckToParam = nnP and nnP.DuckTo
		jumpParam = nP and nP.Jump
		jumpToParam = nnP and nnP.JumpTo
		maxHeightParam = nP and tonumber(nP.MaxHeight)
		nextMaxHeightParam = nnP and tonumber(nnP.MaxHeight)
	else
		local nP = nodeOrNil and nodeOrNil.Params or nil
		local nnP = nextNodeOrNil and nextNodeOrNil.Params or nil
		local lP = currentLinkOrNil and currentLinkOrNil.Params or nil
		duckParam = nP and nP.Duck
		duckToParam = nnP and nnP.DuckTo
		jumpParam = nP and nP.Jump
		jumpToParam = nnP and nnP.JumpTo
		ladderParam = nP and nP.Ladder
		pathParam = lP and lP.Path

		if not jumpToParam and lP and lP.Jumping == "Needed" and nextNodeOrNil and nodeOrNil and nextNodeOrNil.Pos.z > nodeOrNil.Pos.z then
			jumpToParam = "Close"
		end

		maxHeightParam = nP and tonumber(nP.MaxHeight)
		nextMaxHeightParam = nnP and tonumber(nnP.MaxHeight)
	end

	local movementVector = pos - origin
	local invProximity = math.Clamp((movementVector:Length2D() - (proximity or 10)) / 60, 0, 1)
	local speed = bot:GetMaxSpeed() * (slowdown and invProximity or 1)
	movementVector.z = 0
	if movementVector:Length2DSqr() > 0.01 then
		movementVector:Normalize()
	end
	movementVector:Mul(speed)
	movementVector:Rotate(Angle(0, offshootAngle.yaw - (mem.Angs and mem.Angs.yaw or 0), 0))

	if mem.AntiStuckTime and mem.AntiStuckTime > CurTime() then
		if not bot:Crouching() then
			mem.AntiStuckTime = nil
		else
			movementVector = -0.5 * movementVector
			actions.Jump = true
			actions.Attack = true
		end
	end

	local velVec = bot.loco and bot.loco:GetVelocity() or bot:GetVelocity()
	local velocity = velVec:Length2D()
	local facesHindrance = velocity < 0.25 * math.max(speed, 1)
	local minorStuck, majorStuck = bot:D3bot_CheckStuck()

	if not facesHindrance then
		mem.lastNoHindrance = CurTime()
	end

	if not duckParam and not duckToParam and not jumpParam and not jumpToParam then
		if nextMaxHeightParam and nextMaxHeightParam < (mem.Height or 72) then
			actions.Duck = true
		elseif maxHeightParam and maxHeightParam < (mem.Height or 72) then
			actions.Duck = true
		end
	end
	if duckParam == "Always" or duckToParam == "Always" then
		actions.Duck = true
	end
	if duckToParam == "Close" and nextNodeOrNil then
		local _, hullTop = bot:GetHull()
		local hullX, hullY = hullTop.x, hullTop.y
		local halfHullWidth = math.max(hullX, hullY) + 5
		local closestDiff = origin - getClosestNodePt(nextNodeOrNil, origin)
		if closestDiff:Length2DSqr() <= halfHullWidth * halfHullWidth then
			actions.Duck = true
		end
	end

	if pathParam == "Ladder" then
		mem.IsOnLadder = true
	else
		if mem.IsOnLadder and ladderParam ~= "NoDismount" then
			actions.Use = true
			actions.Jump = true
			mem.BlockMovementUntil = CurTime() + 0.5
			if not lib.UsingSourceNav then mem.BlockedOnNode = nodeOrNil end
		end
		mem.IsOnLadder = false
	end

	if bot:GetMoveType() ~= MOVETYPE_LADDER then
		mem.IsOnLadder = false

		local botOnGround = bot:IsOnGround()
		if botOnGround or bot:WaterLevel() > 0 then
			if shouldClimb or jumpParam == "Always" or jumpToParam == "Always" then
				actions.Jump = true
			end
			if jumpToParam == "Close" and nextNodeOrNil then
				local _, hullTop = bot:GetHull()
				local hullX, hullY = hullTop.x, hullTop.y
				local halfHullWidth = math.max(hullX, hullY) + 5
				local closestDiff = origin - getClosestNodePt(nextNodeOrNil, origin)
				if closestDiff:Length2DSqr() <= halfHullWidth * halfHullWidth then
					actions.Jump = true
				end
			end
			if facesHindrance then
				if math.random(lib.BotJumpAntichance or 22) == 1 then
					actions.Jump = true
				end
				if math.random(lib.BotDuckAntichance or 22) == 1 then
					actions.Duck = true
				end
			end
		else
			actions.Duck = true
		end

		if shouldClimb and not botOnGround then
			actions.Attack2 = true
			local weapon = bot:GetActiveWeapon()
			if weapon and weapon.GetClimbing and weapon:GetClimbing() then
				local yaw1 = bot:GetForward():Angle().yaw
				local yaw2 = Vector(pos.x - origin.x, pos.y - origin.y, 0):Angle().yaw
				movementVector.y = math.AngleDifference(yaw2, yaw1)
				movementVector.x = (pos.z - origin.z + 20) * 10
				if (math.abs(movementVector.x) < 20 or velVec:Length() < 10) and math.abs(movementVector.y) > 1 then
					movementVector.x = 0
				end
			end
		end
	elseif minorStuck then
		actions.Jump = true
		actions.Duck = true
		actions.Use = true
	end

	if duckParam == "Disabled" or duckToParam == "Disabled" then
		actions.Duck = false
	end
	if math.random(1, 2) == 1 or jumpParam == "Disabled" or jumpToParam == "Disabled" or (not actions.Duck and bot:Crouching()) then
		actions.Jump = false
	end

	if bot:GetMoveType() ~= MOVETYPE_LADDER and bot:IsOnGround() and bot:Crouching() and not actions.Duck
		and (not bot.D3bot_LastDamage or bot.D3bot_LastDamage < CurTime() - 2)
		and (not mem.lastNoHindrance or mem.lastNoHindrance < CurTime() - 2) then
		mem.AntiStuckCounter = (mem.AntiStuckCounter or 0) + 1
		if mem.AntiStuckCounter > 30 then
			mem.AntiStuckCounter = nil
			mem.AntiStuckTime = CurTime() + 1
		end
	else
		mem.AntiStuckCounter = nil
	end

	actions.Attack = facesHindrance and not shouldClimb
	actions.Use = actions.Use or facesHindrance

	if movementVector.x > 0 then actions.MoveForward = true end
	if movementVector.x < 0 then actions.MoveBackward = true end
	if movementVector.y < 0 then actions.MoveRight = true end
	if movementVector.y > 0 then actions.MoveLeft = true end

	return true, actions, movementVector.x, -movementVector.y, nil, mem.Angs, minorStuck, majorStuck, facesHindrance
end

---Basic walk and attack handler.
function lib.Basics.WalkAttackAuto(bot)
	local mem = bot.D3bot_Mem
	if not mem then
		return false, {}, nil, nil, nil, angle_zero, false, false, false
	end

	if mem.BlockMovementUntil then
		if mem.BlockMovementUntil >= CurTime() and mem.BlockedOnNode and mem.BlockedOnNode.GetContains and mem.BlockedOnNode:GetContains(bot:GetPos(), nil) then
			return false, {}, nil, nil, nil, mem.Angs or angle_zero, false, false, false
		else
			mem.BlockMovementUntil = nil
			mem.BlockedOnNode = nil
		end
	end

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil
	local currentLinkOrNil
	if lib.UsingSourceNav then
		currentLinkOrNil = (IsValid(nodeOrNil) and IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_SharesLink) and nextNodeOrNil:D3botNPC_SharesLink(nodeOrNil) or nil
	else
		currentLinkOrNil = (nodeOrNil and nextNodeOrNil and nextNodeOrNil.LinkByLinkedNode) and nextNodeOrNil.LinkByLinkedNode[nodeOrNil] or nil
	end

	local actions = {}

	local shouldClimb
	if lib.UsingSourceNav then
		local nMd = IsValid(nodeOrNil) and nodeOrNil.D3botNPC_GetMetaData and nodeOrNil:D3botNPC_GetMetaData()
		local nnMd = IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_GetMetaData and nextNodeOrNil:D3botNPC_GetMetaData()
		shouldClimb = (nMd and nMd.Params and nMd.Params.Climbing == "Needed") or (nnMd and nnMd.Params and nnMd.Params.Climbing == "Needed")
	else
		shouldClimb = (nodeOrNil and nodeOrNil.Params and nodeOrNil.Params.Climbing == "Needed") or (nextNodeOrNil and nextNodeOrNil.Params and nextNodeOrNil.Params.Climbing == "Needed")
	end

	if shouldClimb and nextNodeOrNil then
		if lib.UsingSourceNav then
			return lib.Basics.Walk(bot, nextNodeOrNil:GetCenter(), nil)
		else
			return lib.Basics.Walk(bot, nextNodeOrNil.Pos, nil)
		end
	elseif not bot:D3bot_CanSeeTargetCached() and nextNodeOrNil then
		if lib.UsingSourceNav then
			return lib.Basics.Walk(bot, nextNodeOrNil:GetCenter(), nil)
		else
			return lib.Basics.Walk(bot, nextNodeOrNil.Pos, nil)
		end
	elseif IsValid(mem.TgtOrNil) and mem.DontAttackTgt then
		return lib.Basics.Walk(bot, mem.TgtOrNil:GetPos(), nil, true, mem.TgtProximity)
	elseif mem.PosTgtOrNil then
		return lib.Basics.Walk(bot, mem.PosTgtOrNil, nil, true, mem.PosTgtProximity)
	end

	local weapon = bot:GetActiveWeapon()
	local range = (weapon and weapon.MeleeReach or 75) + 25

	local facesTgt = false
	local origin = bot:GetShootPos()
	local attackPos = bot:D3bot_GetAttackPosOrNilFuture(nil, math.Rand(0, lib.BotAimPosVelocityOffshoot or 0.35))
	local movePos = attackPos or bot:GetPos()

	if attackPos and attackPos:DistToSqr(origin) < math.pow(range, 2) then
		facesTgt = true
		if attackPos.z < bot:GetPos().z + bot:GetViewOffsetDucked().z then
			actions.Duck = true
		end
	elseif mem.BarricadeAttackEntity and mem.BarricadeAttackPos then
		if IsValid(mem.BarricadeAttackEntity) and mem.BarricadeAttackPos:DistToSqr(origin) < math.pow(range, 2) then
			attackPos = mem.BarricadeAttackPos
			facesTgt = true
		else
			mem.BarricadeAttackPos, mem.BarricadeAttackEntity = nil, nil
		end
	end

	local offshootAngle = bot:D3bot_GetOffshoot(facesTgt and (lib.FaceTargetOffshootFactor or 0.2) or 1)
	if attackPos then
		bot:D3bot_AngsRotateTo((attackPos - origin):Angle() + offshootAngle, lib.BotAttackAngLerpFactor or 0.35)
	end

	local duckParam, duckToParam, jumpParam, jumpToParam
	local maxHeightParam, nextMaxHeightParam
	local pathParam, ladderParam

	if lib.UsingSourceNav then
		local nP = IsValid(nodeOrNil) and nodeOrNil.D3botNPC_GetMetaData and nodeOrNil:D3botNPC_GetMetaData().Params or nil
		local nnP = IsValid(nextNodeOrNil) and nextNodeOrNil.D3botNPC_GetMetaData and nextNodeOrNil:D3botNPC_GetMetaData().Params or nil
		duckParam = nP and nP.Duck
		duckToParam = nnP and nnP.DuckTo
		jumpParam = nP and nP.Jump
		jumpToParam = nnP and nnP.JumpTo
		maxHeightParam = nP and tonumber(nP.MaxHeight)
		nextMaxHeightParam = nnP and tonumber(nnP.MaxHeight)
	else
		local nP = nodeOrNil and nodeOrNil.Params or nil
		local nnP = nextNodeOrNil and nextNodeOrNil.Params or nil
		local lP = currentLinkOrNil and currentLinkOrNil.Params or nil
		duckParam = nP and nP.Duck
		duckToParam = nnP and nnP.DuckTo
		jumpParam = nP and nP.Jump
		jumpToParam = nnP and nnP.JumpTo
		ladderParam = nP and nP.Ladder
		pathParam = lP and lP.Path

		if not jumpToParam and lP and lP.Jumping == "Needed" and nextNodeOrNil and nodeOrNil and nextNodeOrNil.Pos.z > nodeOrNil.Pos.z then
			jumpToParam = "Close"
		end

		maxHeightParam = nP and tonumber(nP.MaxHeight)
		nextMaxHeightParam = nnP and tonumber(nnP.MaxHeight)
	end

	local movementVector = movePos - origin
	local invProximity = math.Clamp((movementVector:Length2D() - 10) / 60, 0.01, 1)
	local speed = bot:GetMaxSpeed() * invProximity
	movementVector.z = 0
	if movementVector:Length2DSqr() > 0.01 then
		movementVector:Normalize()
	end
	movementVector:Mul(speed)
	movementVector:Rotate(Angle(0, offshootAngle.yaw - (mem.Angs and mem.Angs.yaw or 0), 0))

	if mem.AntiStuckTime and mem.AntiStuckTime > CurTime() then
		if not bot:Crouching() then
			mem.AntiStuckTime = nil
		else
			movementVector = -0.5 * movementVector
			actions.Jump = true
			actions.Attack = true
		end
	end

	local velVec = bot.loco and bot.loco:GetVelocity() or bot:GetVelocity()
	local velocity = velVec:Length2D()
	local facesHindrance = velocity < 0.25 * math.max(speed, 1)
	local minorStuck, majorStuck = bot:D3bot_CheckStuck()

	if not facesHindrance then
		mem.lastNoHindrance = CurTime()
	end

	if not duckParam and not duckToParam and not jumpParam and not jumpToParam then
		if nextMaxHeightParam and nextMaxHeightParam < (mem.Height or 72) then
			actions.Duck = true
		elseif maxHeightParam and maxHeightParam < (mem.Height or 72) then
			actions.Duck = true
		end
	end
	if duckParam == "Always" or duckToParam == "Always" then
		actions.Duck = true
	end
	if duckToParam == "Close" and nextNodeOrNil then
		local _, hullTop = bot:GetHull()
		local hullX, hullY = hullTop.x, hullTop.y
		local halfHullWidth = math.max(hullX, hullY) + 5
		local closestDiff = origin - getClosestNodePt(nextNodeOrNil, origin)
		if closestDiff:Length2DSqr() <= halfHullWidth * halfHullWidth then
			actions.Duck = true
		end
	end

	if pathParam == "Ladder" then
		mem.IsOnLadder = true
	else
		if mem.IsOnLadder and ladderParam ~= "NoDismount" then
			actions.Use = true
			actions.Jump = true
			mem.BlockMovementUntil = CurTime() + 0.5
			if not lib.UsingSourceNav then mem.BlockedOnNode = nodeOrNil end
		end
		mem.IsOnLadder = false
	end

	if bot:GetMoveType() ~= MOVETYPE_LADDER then
		mem.IsOnLadder = false

		if bot:IsOnGround() or bot:WaterLevel() > 0 then
			if jumpParam == "Always" or jumpToParam == "Always" then
				actions.Jump = true
			end
			if jumpToParam == "Close" and nextNodeOrNil then
				local _, hullTop = bot:GetHull()
				local hullX, hullY = hullTop.x, hullTop.y
				local halfHullWidth = math.max(hullX, hullY) + 5
				local closestDiff = origin - getClosestNodePt(nextNodeOrNil, origin)
				if closestDiff:Length2DSqr() <= halfHullWidth * halfHullWidth then
					actions.Jump = true
				end
			end
			if facesHindrance then
				if math.random(lib.BotJumpAntichance or 22) == 1 then
					actions.Jump = true
				end
				if math.random(lib.BotDuckAntichance or 22) == 1 then
					actions.Duck = true
				end
			end
		else
			actions.Duck = true
		end
	elseif minorStuck then
		actions.Jump = true
		actions.Duck = true
		actions.Use = true
	end

	if duckParam == "Disabled" or duckToParam == "Disabled" then
		actions.Duck = false
	end
	if math.random(1, 2) == 1 or jumpParam == "Disabled" or jumpToParam == "Disabled" or (not actions.Duck and bot:Crouching()) then
		actions.Jump = false
	end

	if bot:GetMoveType() ~= MOVETYPE_LADDER and bot:IsOnGround() and bot:Crouching() and not actions.Duck
		and (not bot.D3bot_LastDamage or bot.D3bot_LastDamage < CurTime() - 2)
		and (not mem.lastNoHindrance or mem.lastNoHindrance < CurTime() - 2) then
		mem.AntiStuckCounter = (mem.AntiStuckCounter or 0) + 1
		if mem.AntiStuckCounter > 30 then
			mem.AntiStuckCounter = nil
			mem.AntiStuckTime = CurTime() + 1
		end
	else
		mem.AntiStuckCounter = nil
	end

	actions.Attack = facesTgt or facesHindrance
	actions.Use = actions.Use or facesHindrance

	if movementVector.x > 0 then actions.MoveForward = true end
	if movementVector.x < 0 then actions.MoveBackward = true end
	if movementVector.y < 0 then actions.MoveRight = true end
	if movementVector.y > 0 then actions.MoveLeft = true end

	return true, actions, movementVector.x, -movementVector.y, nil, mem.Angs, minorStuck, majorStuck, facesHindrance
end

---Pouncing handler.
function lib.Basics.PounceAuto(bot, crab)
	local mem = bot.D3bot_Mem
	if not mem then
		return false, {}, nil, nil, nil, angle_zero, false, false, false
	end

	local nodeOrNil = mem.NodeOrNil
	local nextNodeOrNil = mem.NextNodeOrNil

	if not bot:IsOnGround() or bot:GetMoveType() == MOVETYPE_LADDER then
		return false, {}, nil, nil, nil, angle_zero, false, false, false
	end

	local weapon = bot:GetActiveWeapon()
	if (not weapon or not weapon.PounceVelocity) and not crab then
		return false, {}, nil, nil, nil, angle_zero, false, false, false
	end

	local tempPos = bot:GetPos()
	local tempDist = 0
	local pounceTargetPositions = {}
	if nextNodeOrNil and lib.UsingSourceNav then
		local center = nextNodeOrNil:GetCenter()
		tempDist = tempDist + tempPos:Distance(center)
		tempPos = center
		local link = (IsValid(nodeOrNil) and nextNodeOrNil.D3botNPC_SharesLink) and nextNodeOrNil:D3botNPC_SharesLink(nodeOrNil) or nil
		local lParams = link and link.GetMetaData and link:GetMetaData().Params or nil
		table.insert(pounceTargetPositions, {
			Pos = center + Vector(0, 0, 1),
			Dist = tempDist,
			TimeFactor = 1.1,
			ForcePounce = (lParams and ((crab and lParams.CrabPouncing == "Needed") or (not crab and lParams.Pouncing == "Needed"))) or false
		})
	elseif nextNodeOrNil then
		tempDist = tempDist + tempPos:Distance(nextNodeOrNil.Pos)
		tempPos = nextNodeOrNil.Pos
		local link = (nodeOrNil and nextNodeOrNil.LinkByLinkedNode) and nextNodeOrNil.LinkByLinkedNode[nodeOrNil] or nil
		local lParams = link and link.Params or nil
		table.insert(pounceTargetPositions, {
			Pos = nextNodeOrNil.Pos + Vector(0, 0, 1),
			Dist = tempDist,
			TimeFactor = 1.1,
			ForcePounce = (lParams and ((crab and lParams.CrabPouncing == "Needed") or (not crab and lParams.Pouncing == "Needed"))) or false
		})
	end

	if lib.UsingSourceNav then
		for i, v in ipairs(mem.RemainingNodes or {}) do
			if IsValid(v) then
				local center = v:GetCenter()
				tempDist = tempDist + tempPos:Distance(center)
				tempPos = center
				table.insert(pounceTargetPositions, { Pos = center + Vector(0, 0, 1), Dist = tempDist, TimeFactor = 1.1 })
			end
			if i >= 2 then break end
		end
	else
		for i, v in ipairs(mem.RemainingNodes or {}) do
			if v and v.Pos then
				tempDist = tempDist + tempPos:Distance(v.Pos)
				tempPos = v.Pos
				table.insert(pounceTargetPositions, { Pos = v.Pos + Vector(0, 0, 1), Dist = tempDist, TimeFactor = 1.1 })
			end
			if i >= 2 then break end
		end
	end

	local tempAttackPosOrNil = bot:D3bot_GetAttackPosOrNilFuturePlatforms(0, mem.pounceFlightTime or 0)
	if tempAttackPosOrNil then
		tempDist = tempDist + bot:GetPos():Distance(tempAttackPosOrNil)
		table.insert(pounceTargetPositions, { Pos = tempAttackPosOrNil + Vector(0, 0, 1), Dist = tempDist, TimeFactor = 0.8, HeightDiff = 100 })
	elseif mem.PosTgtOrNil then
		tempDist = tempDist + bot:GetPos():Distance(mem.PosTgtOrNil)
		table.insert(pounceTargetPositions, { Pos = mem.PosTgtOrNil + Vector(0, 0, 1), Dist = tempDist, TimeFactor = 0.8, HeightDiff = 100 })
	end

	local trajectory
	local maxSpeed = math.max(bot:GetMaxSpeed(), 1)
	local startDelay = (weapon and weapon.PounceStartDelay) or 0
	for _, pounceTargetPos in ipairs(table.Reverse(pounceTargetPositions)) do
		local trajectories = bot:D3bot_CanPounceToPos(pounceTargetPos.Pos)
		local timeToTarget = pounceTargetPos.Dist / maxSpeed
		if trajectories and (pounceTargetPos.ForcePounce or (pounceTargetPos.HeightDiff and pounceTargetPos.Pos.z - bot:GetPos().z > pounceTargetPos.HeightDiff) or timeToTarget > (trajectories[1].t1 + startDelay) * pounceTargetPos.TimeFactor) then
			trajectory = trajectories[1]
			break
		end
	end

	local actions = {}
	local ct = CurTime()
	local nextPrimary = weapon and weapon.GetNextPrimaryFire and weapon:GetNextPrimaryFire() or 0
	local nextSecondary = weapon and weapon.GetNextSecondaryFire and weapon:GetNextSecondaryFire() or 0
	local nextAllowPounce = (weapon and weapon.NextAllowPounce) or nextPrimary

	if (trajectory and ct >= nextPrimary and ct >= nextSecondary and ct >= nextAllowPounce) or mem.pouncing then
		if trajectory then
			mem.Angs = Angle(-math.deg(trajectory.pitch), math.deg(trajectory.yaw), 0)
			mem.pounceFlightTime = math.Clamp(trajectory.t1 + (mem.pouncingStartTime or ct) - ct, 0, 1)
		end
		if not mem.pouncing then
			actions.Attack2 = crab and false or true
			actions.Attack = crab and true or false
			mem.pouncingTimer = ct + 0.9 + math.random() * 0.2
			mem.pouncingStartTime = ct + startDelay
			mem.pouncing = true
		elseif mem.pouncingTimer and mem.pouncingTimer < ct and (ct - mem.pouncingTimer > 5 or bot:WaterLevel() >= 2 or bot:IsOnGround()) then
			mem.pouncing = false
			mem.pounceFlightTime = nil
			bot:D3bot_UpdatePathProgress()
		end

		return true, actions, 0, nil, nil, mem.Angs, false, false, false
	end

	return false, {}, nil, nil, nil, angle_zero, false, false, false
end
