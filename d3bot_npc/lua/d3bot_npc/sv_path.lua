-- High-Performance A* Pathfinding Engine for D3bot NPC
-- Upgrades:
--   * True O((V+E) log V) Binary Min-Heap with DecreaseKey (fixes SortedQueue O(N) & dropped-update bug)
--   * Full link & node validation: directional links, vertical climb/jump/drop feasibility,
--     runtime mesh audit flags (one-way uphills, world-blocked links, embedded/dead-end nodes)
--   * Crowd congestion cost & NPC-specific failed-link penalties to eliminate corridor pileups
--   * Short-lived shared path cache (bounded reuse so large hordes still distribute across alternates)
--   * Built-in path telemetry for d3bot_npc_nav_stats

local lib = D3botNPC

local mathMax = math.max
local mathMin = math.min
local mathHuge = math.huge
local mathAbs = math.abs
local tableInsert = table.insert
local Distance = FindMetaTable("Vector").Distance

lib.PathStats = lib.PathStats or {
	Solves = 0,
	CacheHits = 0,
	FailedSolves = 0,
	TotalSolveMs = 0,
	LastSolveMs = 0
}

-- Reusable Binary Min-Heap & A* Scratch State (eliminates per-solve table & closure GC pressure)
local heapArr = {}
local heapPos = {}
local heapSize = 0
local fScoreByNode = {}
local gScoreByNode = {}
local closedSet = {}
local cameFrom = {}

local function heapReset(touchedNodes)
	for i = 1, heapSize do
		local n = heapArr[i]
		if n then
			heapPos[n] = nil
			heapArr[i] = nil
		end
	end
	heapSize = 0
	for i = 1, #touchedNodes do
		local n = touchedNodes[i]
		fScoreByNode[n] = nil
		gScoreByNode[n] = nil
		closedSet[n] = nil
		cameFrom[n] = nil
	end
end

local function heapSiftUp(idx)
	local item = heapArr[idx]
	local itemScore = fScoreByNode[item] or mathHuge
	while idx > 1 do
		local parentIdx = (idx - (idx % 2)) * 0.5
		local parent = heapArr[parentIdx]
		if itemScore < (fScoreByNode[parent] or mathHuge) then
			heapArr[idx] = parent
			heapPos[parent] = idx
			idx = parentIdx
		else
			break
		end
	end
	heapArr[idx] = item
	heapPos[item] = idx
end

local function heapSiftDown(idx)
	local item = heapArr[idx]
	local itemScore = fScoreByNode[item] or mathHuge
	while true do
		local leftIdx = idx * 2
		if leftIdx > heapSize then break end
		local rightIdx = leftIdx + 1
		local bestChildIdx = leftIdx
		local bestChild = heapArr[leftIdx]
		local bestScore = fScoreByNode[bestChild] or mathHuge
		if rightIdx <= heapSize then
			local rightChild = heapArr[rightIdx]
			local rightScore = fScoreByNode[rightChild] or mathHuge
			if rightScore < bestScore then
				bestChildIdx = rightIdx
				bestChild = rightChild
				bestScore = rightScore
			end
		end
		if bestScore < itemScore then
			heapArr[idx] = bestChild
			heapPos[bestChild] = idx
			idx = bestChildIdx
		else
			break
		end
	end
	heapArr[idx] = item
	heapPos[item] = idx
end

local function heapPushOrUpdate(node)
	local existing = heapPos[node]
	if existing then
		heapSiftUp(existing)
	else
		heapSize = heapSize + 1
		heapArr[heapSize] = node
		heapPos[node] = heapSize
		heapSiftUp(heapSize)
	end
end

local function heapPop()
	if heapSize == 0 then return nil end
	local top = heapArr[1]
	heapPos[top] = nil
	local last = heapArr[heapSize]
	heapArr[heapSize] = nil
	heapSize = heapSize - 1
	if heapSize > 0 then
		heapArr[1] = last
		heapPos[last] = 1
		heapSiftDown(1)
	end
	return top
end

-- Short-lived shared path cache to reduce redundant A* calls for 87-120+ NPC hordes
-- Reuse is capped at 2 reuses before expiring so congestion-aware routing still diversifies paths!
local sharedPathCache = {}
local nextCachePrune = 0

function lib.ResetPathCache()
	sharedPathCache = {}
end

local function makeAbilityKey(abilities)
	local bits = (abilities.Walk and 1 or 0)
		+ (abilities.Pounce and 2 or 0)
		+ (abilities.Climb and 4 or 0)
		+ (abilities.Crab and 8 or 0)
		+ (abilities.NoFallDamage and 16 or 0)
	local j = math.floor((abilities.Jump or 60) + 0.5)
	local h = math.floor((abilities.Height or 36) + 0.5)
	return bits * 65536 + j * 256 + h
end

local function getLinkTraversability(node, linkedNode, link, abilities, wave, failedLinks, endNode, failPen)
	local linkedNodeParams = linkedNode.Params
	local linkParams = link.Params

	if linkedNodeParams and lib.IsNavMeshNodeBlocked(linkedNodeParams, linkedNode.Pos, wave) then
		return false, 0
	end

	-- Validate link-level Conditions / Wave blocks too
	if linkParams and (linkParams.Condition or linkParams.BlockBeforeWave or linkParams.BlockAfterWave or linkParams.BlockEntity)
		and lib.IsNavMeshNodeBlocked(linkParams, link:GetFocusPos(), wave) then
		return false, 0
	end

	local forwards = (link.Nodes[1] == node)
	if linkParams then
		if linkParams.Direction == "Forward" and not forwards then return false, 0 end
		if linkParams.Direction == "Backward" and forwards then return false, 0 end
	end

	local linkZDiff = link.CachedZDiff
	if not linkZDiff then
		linkZDiff = link.Nodes[2].Pos.z - link.Nodes[1].Pos.z
		link.CachedZDiff = linkZDiff
	end
	local dzStep = linkZDiff * (forwards and 1 or -1) -- positive = climbing up

	local slopeDeg = link.CachedSlopeDeg
	local dist2D = link.CachedDist2D
	if not slopeDeg then
		local p1, p2 = link.Nodes[1].Pos, link.Nodes[2].Pos
		local dx, dy = p2.x - p1.x, p2.y - p1.y
		dist2D = math.sqrt(dx * dx + dy * dy)
		slopeDeg = (dist2D > 1) and math.deg(math.atan2(mathAbs(linkZDiff), dist2D)) or 90
		link.CachedDist2D = dist2D
		link.CachedSlopeDeg = slopeDeg
	end
	local isSteepLedge = (slopeDeg > 46) or (dist2D < 95)

	local a_Walk = abilities.Walk
	local a_Pounce = abilities.Pounce
	local a_Climb = abilities.Climb
	local a_Crab = abilities.Crab
	local a_Jump = abilities.Jump or 60
	local a_Height = abilities.Height or 36
	local a_MaxDrop = abilities.MaxDrop or 450

	if linkParams then
		if not a_Walk and linkParams.Walking == "Needed" then return false, 0 end
		if not a_Pounce and linkParams.Pouncing == "Needed" then return false, 0 end
		if not a_Crab and linkParams.CrabPouncing == "Needed" then return false, 0 end
		if linkParams.Jumping == "Needed" and a_Jump < dzStep and isSteepLedge then return false, 0 end
	end
	if linkedNodeParams then
		if not a_Climb and linkedNodeParams.Climbing == "Needed" then return false, 0 end
		local maxH = tonumber(linkedNodeParams.MaxHeight)
		if maxH and maxH < a_Height then return false, 0 end
	end

	local hasSpecialVert = (linkParams and (linkParams.Path == "Ladder"
		or (linkParams.Pouncing == "Needed" and a_Pounce)
		or (linkParams.CrabPouncing == "Needed" and a_Crab)))
		or (linkedNodeParams and linkedNodeParams.Climbing == "Needed" and a_Climb)

	-- Enforce physical uphill limit unless zombie can climb/pounce or link is a walkable ramp/escalator
	if not hasSpecialVert then
		if link.RuntimeOneWay == "Forward" and not forwards then return false, 0 end
		if link.RuntimeOneWay == "Backward" and forwards then return false, 0 end
		if dzStep > (a_Jump + 6) and isSteepLedge then return false, 0 end
	end

	-- Avoid lethal falls unless NPC has NoFallDamage (Crow / special)
	if not abilities.NoFallDamage and (-dzStep) > a_MaxDrop and (not linkParams or linkParams.Path ~= "Ladder") then
		return false, 0
	end

	-- NPC-specific failed link blacklist after multiple failures
	local failCount = failedLinks and failedLinks[link] or 0
	if failCount >= 3 then
		return false, 0
	end

	local extra = 0
	if linkedNode.RuntimeEmbedded and linkedNode ~= endNode then
		extra = extra + 1800
	end
	if link.RuntimeWorldBlocked then
		extra = extra + 2400
	end
	if linkedNode.RuntimeIsDeadEnd and linkedNode ~= endNode then
		extra = extra + 280
	end
	if link.RuntimeHighDrop and not abilities.NoFallDamage then
		extra = extra + 500
	end
	if failCount > 0 then
		extra = extra + failCount * (failPen or 450)
	end

	return true, extra
end

function lib.GetBestMeshPathOrNil(startNode, endNode, pathCostFunction, heuristicCostFunction, abilities, opts)
	if not startNode or not endNode or not abilities then return nil end

	local t0 = SysTime()
	opts = opts or {}
	local failedLinks = opts.failedLinks
	local hasFailedOverrides = failedLinks and next(failedLinks) ~= nil
	local wave = lib.GetCurrentWave()

	-- Fast path when start == end
	if startNode == endNode then
		return { startNode }
	end

	-- Check short-lived shared path cache (only when NPC has no custom failed-link blacklist)
	local ct = CurTime()
	if ct > nextCachePrune then
		nextCachePrune = ct + 2.0
		for k, entry in pairs(sharedPathCache) do
			if entry.Expires < ct then
				sharedPathCache[k] = nil
			end
		end
	end

	local cacheKey = nil
	if not hasFailedOverrides and not opts.bypassCache then
		cacheKey = tostring(startNode.Id) .. ">" .. tostring(endNode.Id) .. ":" .. tostring(makeAbilityKey(abilities)) .. ":" .. tostring(wave)
		local cached = sharedPathCache[cacheKey]
		if cached and cached.Expires >= ct and cached.UsesLeft > 0 then
			cached.UsesLeft = cached.UsesLeft - 1
			lib.PathStats.CacheHits = lib.PathStats.CacheHits + 1
			local cachedPath = cached.Path
			local copy = {}
			for i = 1, #cachedPath do copy[i] = cachedPath[i] end
			return copy
		end
	end

	local crowdWeight = 0
	if lib.ConVars.CrowdAvoidance and lib.ConVars.CrowdAvoidance:GetBool() then
		crowdWeight = (lib.ConVars.CrowdCongestionWeight and lib.ConVars.CrowdCongestionWeight:GetFloat()) or 55
	end
	local failPen = (lib.ConVars.LinkFailPenalty and lib.ConVars.LinkFailPenalty:GetFloat()) or 450
	local nodeCongMap = lib.NodeCongestion
	local linkCongMap = lib.LinkCongestion

	local touchedNodes = { startNode }
	gScoreByNode[startNode] = 0
	fScoreByNode[startNode] = Distance(startNode.Pos, endNode.Pos)
	heapPushOrUpdate(startNode)

	local endPos = endNode.Pos
	local iterations = 0
	local maxIterations = opts.maxIterations or 8000

	while iterations < maxIterations do
		local node = heapPop()
		if not node then break end
		iterations = iterations + 1

		if node == endNode then
			-- Build reversed list then reverse into path (O(K) instead of O(K^2) table.insert at index 1!)
			local rev = {}
			local cur = node
			while cur do
				rev[#rev + 1] = cur
				cur = cameFrom[cur]
			end
			local len = #rev
			local path = {}
			for i = 1, len do
				path[i] = rev[len - i + 1]
			end

			heapReset(touchedNodes)

			local dtMs = (SysTime() - t0) * 1000
			lib.PathStats.Solves = lib.PathStats.Solves + 1
			lib.PathStats.TotalSolveMs = lib.PathStats.TotalSolveMs + dtMs
			lib.PathStats.LastSolveMs = dtMs

			if cacheKey and len >= 2 then
				local cachedCopy = {}
				for i = 1, len do cachedCopy[i] = path[i] end
				sharedPathCache[cacheKey] = {
					Path = cachedCopy,
					Expires = ct + 0.25,
					UsesLeft = 2
				}
			end

			return path
		end

		closedSet[node] = true
		local nodeG = gScoreByNode[node]
		local adj = node.LinkByLinkedNode
		if adj then
			for linkedNode, link in pairs(adj) do
				if not closedSet[linkedNode] then
					local able, auditPenalty = getLinkTraversability(node, linkedNode, link, abilities, wave, failedLinks, endNode, failPen)
					if able then
						local linkDist = link.CachedDist
						if not linkDist then
							linkDist = Distance(node.Pos, linkedNode.Pos)
							link.CachedDist = linkDist
						end

						local linkedNodeParams = linkedNode.Params
						local linkParams = link.Params
						local nodeCost = (linkedNodeParams and tonumber(linkedNodeParams.Cost)) or 0
						local linkCost = (linkParams and tonumber(linkParams.Cost)) or 0
						local extraCost = pathCostFunction and pathCostFunction(node, linkedNode, link) or 0

						-- Crowd congestion penalty distributes hordes across parallel corridors/escalators
						local congestionCost = 0
						if crowdWeight > 0 then
							local nodeOcc = (nodeCongMap and nodeCongMap[linkedNode]) or 0
							local linkOcc = (linkCongMap and linkCongMap[link]) or 0
							local chokeMul = 1 + (linkedNode.RuntimeBottleneckScore or 0) * 0.4
							congestionCost = (nodeOcc * 0.65 + linkOcc) * crowdWeight * chokeMul
						end

						local stepCost = mathMax(linkDist + nodeCost + linkCost + extraCost + auditPenalty + congestionCost, 1)
						local tentativeG = nodeG + stepCost
						local prevG = gScoreByNode[linkedNode]

						if not prevG then
							touchedNodes[#touchedNodes + 1] = linkedNode
						end
						if not prevG or tentativeG < prevG then
							cameFrom[linkedNode] = node
							gScoreByNode[linkedNode] = tentativeG
							local heuristic = heuristicCostFunction and heuristicCostFunction(linkedNode) or 0
							fScoreByNode[linkedNode] = tentativeG + heuristic + Distance(linkedNode.Pos, endPos)
							heapPushOrUpdate(linkedNode)
						end
					end
				end
			end
		end
	end

	heapReset(touchedNodes)

	local dtMs = (SysTime() - t0) * 1000
	lib.PathStats.Solves = lib.PathStats.Solves + 1
	lib.PathStats.FailedSolves = lib.PathStats.FailedSolves + 1
	lib.PathStats.TotalSolveMs = lib.PathStats.TotalSolveMs + dtMs
	lib.PathStats.LastSolveMs = dtMs
	return nil
end

function lib.GetBestValveMeshPathOrNil(startArea, endArea, pathCostFunction, heuristicCostFunction, abilities, opts)
	if not IsValid(startArea) or not IsValid(endArea) then return nil end

	local t0 = SysTime()
	local wave = lib.GetCurrentWave()
	local failedLinks = opts and opts.failedLinks
	local crowdWeight = (lib.ConVars.CrowdAvoidance and lib.ConVars.CrowdAvoidance:GetBool())
		and ((lib.ConVars.CrowdCongestionWeight and lib.ConVars.CrowdCongestionWeight:GetFloat()) or 55) or 0

	local valveCameFrom = {}
	startArea:ClearSearchLists()
	startArea:AddToOpenList()
	startArea:SetCostSoFar(0)

	while not startArea:IsOpenListEmpty() do
		local current = startArea:PopOpenList()
		if not current then break end

		if current == endArea then
			local rev = { current }
			local curID = current:GetID()
			while valveCameFrom[curID] do
				curID = valveCameFrom[curID]
				if not curID then break end
				local area = navmesh.GetNavAreaByID(curID)
				if IsValid(area) then
					rev[#rev + 1] = area
				end
			end
			local len = #rev
			local path = {}
			for i = 1, len do
				path[i] = rev[len - i + 1]
			end
			lib.PathStats.Solves = lib.PathStats.Solves + 1
			lib.PathStats.LastSolveMs = (SysTime() - t0) * 1000
			lib.PathStats.TotalSolveMs = lib.PathStats.TotalSolveMs + lib.PathStats.LastSolveMs
			return path
		end

		current:AddToClosedList()

		local curCenter = current:GetCenter()
		for _, linkedArea in pairs(current:GetAdjacentAreas()) do
			local linkedAreaData = linkedArea:D3botNPC_GetMetaData()
			local link = current:D3botNPC_SharesLink(linkedArea)
			local linkData = link and link:GetMetaData() or { Params = {} }
			local linkCenter = linkedArea:GetCenter()

			local blocked = lib.IsNavMeshNodeBlocked(linkedAreaData.Params, linkCenter, wave)
			local dzStep = linkCenter.z - curCenter.z
			local a_Jump = (abilities and abilities.Jump) or 60

			local able = true
			if linkData.Params.Walking == "Needed" and abilities and not abilities.Walk then able = false end
			if linkData.Params.Pouncing == "Needed" and abilities and not abilities.Pounce then able = false end
			if linkedAreaData.Params.Climbing == "Needed" and abilities and not abilities.Climb then able = false end
			if dzStep > (a_Jump + 8) and linkedAreaData.Params.Climbing ~= "Needed" and linkData.Params.Pouncing ~= "Needed" then
				able = false
			end
			if failedLinks and link and (failedLinks[link] or 0) >= 3 then
				able = false
			end

			if able and not blocked then
				local stepDist = Distance(curCenter, linkCenter)
				local nodeCost = tonumber(linkedAreaData.Params.Cost) or 0
				local linkCost = tonumber(linkData.Params.Cost) or 0
				local extraCost = pathCostFunction and pathCostFunction(current, linkedArea, link) or 0
				local failCost = (failedLinks and link and failedLinks[link]) and (failedLinks[link] * 450) or 0
				local congCost = (crowdWeight > 0) and ((lib.NodeCongestion[linkedArea] or 0) * crowdWeight * 0.5) or 0
				local newCostSoFar = current:GetCostSoFar() + mathMax(stepDist + nodeCost + linkCost + extraCost + failCost + congCost, 1)

				if not ((linkedArea:IsOpen() or linkedArea:IsClosed()) and linkedArea:GetCostSoFar() <= newCostSoFar) then
					if linkedArea:IsClosed() then
						linkedArea:RemoveFromClosedList()
					end

					valveCameFrom[linkedArea:GetID()] = current:GetID()
					linkedArea:SetCostSoFar(newCostSoFar)
					local heuristic = heuristicCostFunction and heuristicCostFunction(linkedArea) or 0
					linkedArea:SetTotalCost(newCostSoFar + heuristic + Distance(linkCenter, endArea:GetCenter()))

					if linkedArea:IsOpen() then
						linkedArea:UpdateOnOpenList()
					else
						linkedArea:AddToOpenList()
					end
				end
			end
		end
	end

	lib.PathStats.Solves = lib.PathStats.Solves + 1
	lib.PathStats.FailedSolves = lib.PathStats.FailedSolves + 1
	return nil
end
