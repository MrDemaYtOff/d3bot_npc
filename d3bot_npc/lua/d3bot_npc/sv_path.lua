-- D3bot pathfinding, ported 1:1 from the original D3bot sv_path.lua.
--
-- This file used to contain a rewritten A* (binary heap, shared path cache, crowd congestion costs,
-- audit-derived one-way/uphill rejection, failed-link blacklists). None of that exists in D3bot and it
-- changed which routes bots chose, so it has been removed. The algorithm below is the original one:
--   * same link traversability rules (Walking/Pouncing/CrabPouncing/Climbing/Jumping/MaxHeight/Direction)
--   * same cost model (link length + node Cost + link Cost + pathCostFunction, clamped to >= 0)
--   * same heuristic (straight line distance to the end node + optional heuristicCostFunction)
-- Only the player/gamemode accessors are renamed (GAMEMODE:GetWave() -> lib.GetCurrentWave()).

local lib = D3botNPC

local mathMax = math.max
local mathHuge = math.huge
local tableInsert = table.insert
local Distance = FindMetaTable("Vector").Distance

lib.PathStats = lib.PathStats or {
	Solves = 0,
	CacheHits = 0,
	FailedSolves = 0,
	TotalSolveMs = 0,
	LastSolveMs = 0
}

-- Kept so older console/debug commands that reset the cache keep working. There is no cache anymore.
function lib.ResetPathCache() end

local function recordSolve(t0, ok)
	local dtMs = (SysTime() - t0) * 1000
	local s = lib.PathStats
	s.Solves = s.Solves + 1
	if not ok then s.FailedSolves = s.FailedSolves + 1 end
	s.TotalSolveMs = s.TotalSolveMs + dtMs
	s.LastSolveMs = dtMs
end

---Returns the best path (or nil if there is no possible path) between startNode and endNode.
function lib.GetBestMeshPathOrNil(startNode, endNode, pathCostFunction, heuristicCostFunction, abilities)
	if not abilities or not startNode or not endNode then return nil end
	local t0 = SysTime()

	local a_Walk, a_Pounce, a_Climb, a_Crab, a_Jump, a_Height = abilities.Walk, abilities.Pounce, abilities.Climb, abilities.Crab, abilities.Jump, abilities.Height
	local wave = lib.GetCurrentWave()

	local minimalTotalPathCostByNode = {}
	local minimalPathCostByNode = { [startNode] = 0 }
	local entranceByNode = {}

	local evaluationNodeQueue = lib.NewSortedQueue(function(nodeA, nodeB)
		return (minimalTotalPathCostByNode[nodeA] or mathHuge) > (minimalTotalPathCostByNode[nodeB] or mathHuge)
	end)
	evaluationNodeQueue:Enqueue(startNode)

	while true do
		local node = evaluationNodeQueue:Dequeue()
		if not node then
			recordSolve(t0, false)
			return
		end

		if node == endNode then
			local path = { node }
			while true do
				node = entranceByNode[node]
				if not node then break end
				tableInsert(path, 1, node)
			end
			recordSolve(t0, true)
			return path
		end

		for linkedNode, link in pairs(node.LinkByLinkedNode) do
			local linkedNodeParams = linkedNode.Params
			local linkParams = link.Params

			-- The height difference between the nodes that this link connects (relative to link.Nodes order).
			local linkZDiff = link.CachedZDiff
			if not linkZDiff then
				linkZDiff = link.Nodes[2].Pos.z - link.Nodes[1].Pos.z
				link.CachedZDiff = linkZDiff
			end

			local blocked = lib.IsNavMeshNodeBlocked(linkedNodeParams, linkedNode.Pos, wave)

			local forwards = link.Nodes[1] == node

			local able = true
			if not a_Walk and linkParams.Walking == "Needed" then able = false end
			if not a_Pounce and linkParams.Pouncing == "Needed" then able = false end
			if not a_Crab and linkParams.CrabPouncing == "Needed" then able = false end
			if not a_Climb and linkedNodeParams.Climbing == "Needed" then able = false end
			if linkParams.Jumping == "Needed" and (a_Jump or 0) < linkZDiff * (forwards and 1 or -1) then able = false end
			if linkedNodeParams.MaxHeight and linkedNodeParams.MaxHeight < (a_Height or 0) then able = false end

			local blockedForward = (linkParams.Direction == "Forward" and not forwards)
			local blockedBackward = (linkParams.Direction == "Backward" and forwards)

			if able and not blocked and not blockedForward and not blockedBackward then
				local linkDist = link.CachedDist
				if not linkDist then
					linkDist = Distance(node.Pos, linkedNode.Pos)
					link.CachedDist = linkDist
				end
				local linkedNodePathCost = minimalPathCostByNode[node] + mathMax(linkDist + (linkedNodeParams.Cost or 0) + (linkParams.Cost or 0) + (pathCostFunction and pathCostFunction(node, linkedNode, link) or 0), 0)
				if linkedNodePathCost < (minimalPathCostByNode[linkedNode] or mathHuge) then
					entranceByNode[linkedNode] = node
					minimalPathCostByNode[linkedNode] = linkedNodePathCost
					local heuristic = (heuristicCostFunction and heuristicCostFunction(linkedNode) or 0)
					minimalTotalPathCostByNode[linkedNode] = linkedNodePathCost + heuristic + Distance(linkedNode.Pos, endNode.Pos)
					evaluationNodeQueue:Enqueue(linkedNode)
				end
			end
		end
	end
end

---Valve (.nav) variant, ported 1:1 from original D3bot.GetBestValveMeshPathOrNil.
function lib.GetBestValveMeshPathOrNil(startArea, endArea, pathCostFunction, heuristicCostFunction, abilities)
	if not IsValid(startArea) or not IsValid(endArea) then return nil end
	local t0 = SysTime()
	local wave = lib.GetCurrentWave()

	local cameFrom = {}

	startArea:ClearSearchLists()
	startArea:AddToOpenList()
	startArea:SetCostSoFar(0)

	while not startArea:IsOpenListEmpty() do
		local current = startArea:PopOpenList()
		if not current then recordSolve(t0, false) return end

		if current == endArea then
			local path = { current }
			current = current:GetID()
			while cameFrom[current] do
				current = cameFrom[current]
				if not current then break end
				tableInsert(path, 1, navmesh.GetNavAreaByID(current))
			end
			recordSolve(t0, true)
			return path
		end
		current:AddToClosedList()

		for _, linkedArea in pairs(current:GetAdjacentAreas()) do
			local linkedAreaData = linkedArea:D3botNPC_GetMetaData()
			local link = current:D3botNPC_SharesLink(linkedArea)
			local linkData = link and link:GetMetaData() or { Params = {} }

			local blocked = lib.IsNavMeshNodeBlocked(linkedAreaData.Params, linkedArea:GetCenter(), wave)

			local able = true
			if linkData.Params.Walking == "Needed" and abilities and not abilities.Walk then able = false end
			if linkData.Params.Pouncing == "Needed" and abilities and not abilities.Pounce then able = false end
			if linkedAreaData.Params.Climbing == "Needed" and abilities and not abilities.Climb then able = false end

			if able and not blocked then
				local newCostSoFar = current:GetCostSoFar() + math.max(Distance(current:GetCenter(), linkedArea:GetCenter()) + ((linkedAreaData.Params.Cost and current:GetCostSoFar() / 4) or 0) + ((linkData.Params.Cost and current:GetCostSoFar() / 4) or 0) + (pathCostFunction and pathCostFunction(current, linkedArea, link) or 0), 0)
				if not (linkedArea:IsOpen() or linkedArea:IsClosed() and linkedArea:GetCostSoFar() <= newCostSoFar) then
					cameFrom[linkedArea:GetID()] = current:GetID()
					linkedArea:SetCostSoFar(newCostSoFar)
					local heuristic = (heuristicCostFunction and heuristicCostFunction(linkedArea) or 0)
					linkedArea:SetTotalCost(newCostSoFar + heuristic + Distance(linkedArea:GetCenter(), endArea:GetCenter()))
					if linkedArea:IsClosed() then
						linkedArea:RemoveFromClosedList()
					end
					if linkedArea:IsOpen() then
						linkedArea:UpdateOnOpenList()
					else
						linkedArea:AddToOpenList()
					end
				end
			end
		end
	end
	recordSolve(t0, false)
end
