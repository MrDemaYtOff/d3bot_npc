AddCSLuaFile()

-- Ported from D3bot sh_utilities.lua (with v1.4.0 jump height and node blocking improvements)
-- Adapted for D3bot NPC entities without player-slot dependencies.

local lib = D3botNPC

function lib.GetTrajectories2DParams(g, initVel, distZ, distRad)
	local trajectories = {}
	if distRad <= 0.001 then return trajectories end
	local radix = initVel ^ 4 - g * (g * distRad ^ 2 + 2 * distZ * initVel ^ 2)

	if radix < 0 then return trajectories end
	local sqrtRadix = math.sqrt(radix)

	local pitchLow = math.atan((initVel ^ 2 - sqrtRadix) / (g * distRad))
	local cosLow = math.cos(pitchLow)
	if cosLow > 0.0001 then
		local t1 = distRad / (initVel * cosLow)
		table.insert(trajectories, { g = g, initVel = initVel, pitch = pitchLow, t1 = t1 })
	end

	if radix > 0 then
		local pitchHigh = math.atan((initVel ^ 2 + sqrtRadix) / (g * distRad))
		local cosHigh = math.cos(pitchHigh)
		if cosHigh > 0.0001 then
			local t1 = distRad / (initVel * cosHigh)
			table.insert(trajectories, { g = g, initVel = initVel, pitch = pitchHigh, t1 = t1 })
		end
	end

	return trajectories
end

function lib.GetTrajectory2DPoints(trajectory, segments)
	trajectory.points = {}
	for i = 0, segments do
		local t = Lerp(i / segments, 0, trajectory.t1)
		local r = Vector(
			math.cos(trajectory.pitch) * trajectory.initVel * t,
			0,
			math.sin(trajectory.pitch) * trajectory.initVel * t - trajectory.g / 2 * t ^ 2
		)
		table.insert(trajectory.points, r)
	end
	return trajectory
end

function lib.GetTrajectories(initVel, r0, r1, segments)
	local g = 600
	if physenv and physenv.GetGravity then
		local grav = math.abs(physenv.GetGravity().z)
		if grav > 1 then g = grav end
	end

	local distZ = r1.z - r0.z
	local distRad = math.sqrt((r1.x - r0.x) ^ 2 + (r1.y - r0.y) ^ 2)
	local yaw = math.atan2(r1.y - r0.y, r1.x - r0.x)

	local trajectories = lib.GetTrajectories2DParams(g, initVel, distZ, distRad)
	for i, trajectory in ipairs(trajectories) do
		trajectories[i].yaw = yaw
		trajectories[i] = lib.GetTrajectory2DPoints(trajectory, segments)
		for _, pt in ipairs(trajectory.points) do
			pt:Rotate(Angle(0, math.deg(yaw), 0))
			pt:Add(r0)
		end
	end

	return trajectories
end

-- Source SDK 2013 numerical jump height calculation (from D3bot v1.4.0)
function lib.CalculateJumpHeight(jumpPower, gravAcceleration, isCrouching)
	local tickRate = 1 / engine.TickInterval()
	local integratedAcceleration = math.abs(gravAcceleration / tickRate)

	local vel, height = -integratedAcceleration / 2, 0
	if isCrouching then
		vel = jumpPower
	else
		vel = vel + jumpPower
	end
	vel = vel - integratedAcceleration / 2

	if vel > 10000 then return 0 end
	if integratedAcceleration <= 0 then return 0 end

	while vel > 0 do
		height = height + vel / tickRate
		vel = vel - integratedAcceleration
	end

	return height
end

function lib.RemoveObsDeadTgts(tgts)
	local out = {}
	if not tgts then return out end
	for _, v in ipairs(tgts) do
		if IsValid(v) and v:GetObserverMode() == OBS_MODE_NONE and not v:IsFlagSet(FL_NOTARGET) and v:Alive() then
			out[#out + 1] = v
		end
	end
	return out
end

local nodeBlockCache = {}
local nodeBlockCacheWave = -1

function lib.ResetNodeBlockCache()
	nodeBlockCache = {}
	nodeBlockCacheWave = -1
end

local function computeNodeBlocked(nodeParams, nodePos, wave)
	if nodeParams.BlockBeforeWave and tonumber(nodeParams.BlockBeforeWave) then
		if wave < tonumber(nodeParams.BlockBeforeWave) then return true end
	end
	if nodeParams.BlockAfterWave and tonumber(nodeParams.BlockAfterWave) then
		if wave > tonumber(nodeParams.BlockAfterWave) then return true end
	end

	local nodeBlocking = lib.NodeBlocking
	local nodeBlockingMap = lib.NodeBlockingMap
	if not nodeBlocking or not nodeBlockingMap then return false end

	if not nodePos then return false end
	local cond = nodeParams.Condition
	if cond == "Unblocked" then
		local foundEnts = ents.FindInBox(nodePos + nodeBlocking.mins, nodePos + nodeBlocking.maxs)
		local classes = nodeBlocking.classes
		for i = 1, #foundEnts do
			if classes[foundEnts[i]:GetClass()] then return true end
		end
	elseif cond == "Blocked" then
		local foundEnts = ents.FindInBox(nodePos + nodeBlocking.mins, nodePos + nodeBlocking.maxs)
		local classes = nodeBlocking.classes
		local found = false
		for i = 1, #foundEnts do
			if classes[foundEnts[i]:GetClass()] then
				found = true
				break
			end
		end
		if not found then return true end
	elseif cond == "MapUnblocked" then
		local foundEnts = ents.FindInBox(nodePos + nodeBlockingMap.mins, nodePos + nodeBlockingMap.maxs)
		local classes = nodeBlockingMap.classes
		for i = 1, #foundEnts do
			if classes[foundEnts[i]:GetClass()] then return true end
		end
	end

	local blkEnt = nodeParams.BlockEntity
	if blkEnt then
		local blockRadius = tonumber(nodeParams.BlockRadius)
		if blockRadius then
			local inSphere = ents.FindInSphere(nodePos, blockRadius)
			for i = 1, #inSphere do
				if inSphere[i]:GetClass() == blkEnt then
					return true
				end
			end
		end
	end

	return false
end

function lib.IsNavMeshNodeBlocked(nodeParams, nodePos, wave)
	if not nodeParams then return false end
	-- Fast exit when node/link has zero blocking attributes at all
	if not nodeParams.Condition and not nodeParams.BlockEntity and not nodeParams.BlockBeforeWave and not nodeParams.BlockAfterWave then
		return false
	end

	if wave ~= nodeBlockCacheWave then
		nodeBlockCache = {}
		nodeBlockCacheWave = wave
	end

	local cached = nodeBlockCache[nodeParams]
	local ct = CurTime()
	if cached then
		if cached.ValidUntil > ct then
			return cached.Blocked
		end
		cached.Blocked = computeNodeBlocked(nodeParams, nodePos, wave)
		cached.ValidUntil = ct + 0.35
		return cached.Blocked
	end

	local blocked = computeNodeBlocked(nodeParams, nodePos, wave)
	nodeBlockCache[nodeParams] = {
		Blocked = blocked,
		ValidUntil = ct + 0.35
	}
	return blocked
end

function lib.NeighbourNodeFalloff(startNode, maxDepth, startValue, falloff, nodes)
	nodes = nodes or {}
	if not startNode or not maxDepth or maxDepth < 0 then return nodes end

	local visited = { [startNode] = true }
	local queueNodes = { startNode }
	local queueDepths = { 0 }
	local head = 1

	nodes[startNode] = (nodes[startNode] or 0) + startValue

	while head <= #queueNodes do
		local node = queueNodes[head]
		local depth = queueDepths[head]
		head = head + 1

		if depth < maxDepth and node.LinkByLinkedNode then
			local nextDepth = depth + 1
			local nextVal = nodes[node] * falloff
			for linkedNode, _ in pairs(node.LinkByLinkedNode) do
				if not visited[linkedNode] then
					visited[linkedNode] = true
					nodes[linkedNode] = math.max(nodes[linkedNode] or 0, nextVal)
					queueNodes[#queueNodes + 1] = linkedNode
					queueDepths[#queueDepths + 1] = nextDepth
				end
			end
		end
	end
	return nodes
end

function lib.IsBarricadeEntity(ent)
	if not IsValid(ent) then return false end
	if ent.IsNailed and ent:IsNailed() then return true end
	if ent.IsBarricadeObject then return true end
	if ent.IsBarricadeProp and ent:IsBarricadeProp() then return true end
	return false
end

-- Active slotless NPC tracking (completely independent of player.GetAll() and maxplayers)
lib.ActiveNPCs = lib.ActiveNPCs or {}

function lib.RegisterNPC(npc)
	if IsValid(npc) then
		lib.ActiveNPCs[npc] = true
	end
end

function lib.UnregisterNPC(npc)
	lib.ActiveNPCs[npc] = nil
end

function lib.GetNPCs(includeDead)
	local result = {}
	for npc, _ in pairs(lib.ActiveNPCs) do
		if not IsValid(npc) then
			lib.ActiveNPCs[npc] = nil
		elseif includeDead or (npc.Alive and npc:Alive()) then
			result[#result + 1] = npc
		end
	end
	return result
end

function lib.GetNPCCount(includeDead)
	local count = 0
	for npc, _ in pairs(lib.ActiveNPCs) do
		if not IsValid(npc) then
			lib.ActiveNPCs[npc] = nil
		elseif includeDead or (npc.Alive and npc:Alive()) then
			count = count + 1
		end
	end
	return count
end

function lib.GetInternalVar(ent, key)
	if not IsValid(ent) or not ent.GetInternalVariable then return nil end
	local val = ent:GetInternalVariable(key)
	return val
end

function lib.IsZombieSurvivalReady()
	return GAMEMODE ~= nil
		and isfunction(GAMEMODE.GetWave)
		and isfunction(GAMEMODE.GetWaveActive)
		and isfunction(GAMEMODE.GetWaveStart)
		and isfunction(GAMEMODE.SetWaveStart)
		and istable(GAMEMODE.ZombieClasses)
end

function lib.GetCurrentWave()
	if GAMEMODE and isfunction(GAMEMODE.GetWave) then
		return GAMEMODE:GetWave()
	end
	return 0
end

function lib.GetWaveActive()
	if GAMEMODE and isfunction(GAMEMODE.GetWaveActive) then
		return GAMEMODE:GetWaveActive()
	end
	return false
end
