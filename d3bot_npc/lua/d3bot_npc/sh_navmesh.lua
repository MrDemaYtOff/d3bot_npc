AddCSLuaFile()

-- Ported from D3bot 1_navmesh.lua
-- Preserves 100% file format compatibility with existing D3bot navmeshes:
--   garrysmod/data/d3bot/navmesh/map/<mapname>.txt
--   garrysmod/data/d3bot/navmesh/map/<mapname>.params.txt

local lib = D3botNPC
local from = lib.From
local mathSqrt = math.sqrt

lib.NavMeshMeta = lib.NavMeshMeta or { __index = {} }
lib.NavMeshItemMeta = lib.NavMeshItemMeta or { __index = {} }
lib.NavMeshNodeMeta = lib.NavMeshNodeMeta or {
	__index = setmetatable({ Type = "node" }, lib.NavMeshItemMeta),
	__tostring = function(node) return "N" .. tostring(node.Id) end
}
lib.NavMeshLinkMeta = lib.NavMeshLinkMeta or {
	__index = setmetatable({ Type = "link" }, lib.NavMeshItemMeta),
	__tostring = function(link) return tostring(link.Id) end
}

local fallback = lib.NavMeshMeta.__index
local itemFallback = lib.NavMeshItemMeta.__index
local nodeFallback = lib.NavMeshNodeMeta.__index
local linkFallback = lib.NavMeshLinkMeta.__index

lib.NavMeshItemsSeparator = "\n"
lib.NavMeshItemsSeparatorOld = ";"
lib.NavMeshItemIdParamsPairSeparator = ":"
lib.NavMeshItemParamsSeparator = ","
lib.NavMeshItemParamNameNumPairSeparator = "="
lib.NavMeshLinkNodesSeparator = "-"

lib.Params = {
	Correct = {
		Jump = { "Disabled", "Always" },
		JumpTo = { "Disabled", "Always", "Close" },
		Duck = { "Disabled", "Always" },
		DuckTo = { "Disabled", "Always", "Close" },
		Wall = { "Suicide", "Retarget" },
		See = { "Disabled" },
		Aim = { "Straight" },
		AimTo = { "Straight" },
		Cost = {},
		Condition = { "Unblocked", "Blocked", "MapUnblocked" },
		BlockEntity = {},
		BlockRadius = {},
		BlockBeforeWave = {},
		BlockAfterWave = {},
		Direction = { "Forward", "Backward" },
		Walking = { "Needed" },
		Pouncing = { "Needed" },
		CrabPouncing = { "Needed" },
		Climbing = { "Needed" },
		Jumping = { "Needed" },
		Path = { "Ladder" },
		Ladder = { "NoDismount" },
		MaxHeight = {},
		DMGPerSecond = {},
		BotMod = {}
	},
	Replace = {
		Unidir = "Direction"
	}
}

lib.NavmeshParams = {
	Correct = {
		BotMod = {},
		ZPP = {},
		ZPPM = {},
		ZPPW = {},
		ZPM = {},
		ZPW = {},
		SPP = {},
		SCA = {}
	},
	Replace = {}
}

local paramReplaceLower = {}
local paramCorrectLower = {}
local paramValLower = {}
for k, v in pairs(lib.Params.Replace) do
	paramReplaceLower[k:lower()] = v
end
for k, values in pairs(lib.Params.Correct) do
	local kl = k:lower()
	paramCorrectLower[kl] = k
	if #values > 0 then
		local valMap = {}
		for _, v2 in ipairs(values) do
			valMap[v2:lower()] = v2
		end
		paramValLower[k] = valMap
	end
end

local navParamReplaceLower = {}
local navParamCorrectLower = {}
local navParamValLower = {}
for k, v in pairs(lib.NavmeshParams.Replace) do
	navParamReplaceLower[k:lower()] = v
end
for k, values in pairs(lib.NavmeshParams.Correct) do
	local kl = k:lower()
	navParamCorrectLower[kl] = k
	if #values > 0 then
		local valMap = {}
		for _, v2 in ipairs(values) do
			valMap[v2:lower()] = v2
		end
		navParamValLower[k] = valMap
	end
end

function lib.NormalizeParam(name, val)
	local lowerName = name:lower()
	local replaced = paramReplaceLower[lowerName]
	if replaced then
		name = replaced
		lowerName = name:lower()
	end
	local canonical = paramCorrectLower[lowerName]
	if canonical then
		name = canonical
		if type(val) == "string" then
			local valMap = paramValLower[canonical]
			if valMap then
				local vCanon = valMap[val:lower()]
				if vCanon then
					val = vCanon
				end
			end
		end
	end
	return name, val
end

function lib.NormalizeNavmeshParam(name, val)
	local lowerName = name:lower()
	local replaced = navParamReplaceLower[lowerName]
	if replaced then
		name = replaced
		lowerName = name:lower()
	end
	local canonical = navParamCorrectLower[lowerName]
	if canonical then
		name = canonical
		if type(val) == "string" then
			local valMap = navParamValLower[canonical]
			if valMap then
				local vCanon = valMap[val:lower()]
				if vCanon then
					val = vCanon
				end
			end
		end
	end
	return name, val
end

function lib.NewNavMesh()
	return setmetatable({
		ItemById = {},
		NodeById = {},
		LinkById = {},
		Params = {}
	}, lib.NavMeshMeta)
end

local function newItem(navMesh, id)
	local r = {
		NavMesh = navMesh,
		Id = id,
		Pos = Vector(),
		Params = {}
	}
	navMesh.ItemById[id] = r
	return r
end

local GRID_CELL_SIZE = 512

local function gridKey(cx, cy)
	return (cx + 32768) * 65536 + (cy + 32768)
end

function fallback:RebuildParamIndexes()
	local damageNodes = {}
	local botModNodes = {}
	local nodeCount = 0
	for _, node in pairs(self.NodeById) do
		nodeCount = nodeCount + 1
		local p = node.Params
		if p then
			local dps = tonumber(p.DMGPerSecond)
			if dps and dps > 0 then
				damageNodes[#damageNodes + 1] = node
			end
			local bm = tonumber(p.BotMod)
			if bm and bm ~= 0 then
				botModNodes[#botModNodes + 1] = node
			end
		end
	end
	self.DamageNodes = damageNodes
	self.BotModNodes = botModNodes
	self.CachedNodeCount = nodeCount
end

function fallback:RebuildSpatialGrid()
	local grid = {}
	for _, node in pairs(self.NodeById) do
		local xMin, xMax, yMin, yMax
		if node.HasArea then
			local p = node.Params
			if isnumber(p.AreaXMin) and isnumber(p.AreaXMax) and isnumber(p.AreaYMin) and isnumber(p.AreaYMax) then
				xMin, xMax = p.AreaXMin, p.AreaXMax
				yMin, yMax = p.AreaYMin, p.AreaYMax
			else
				node.HasArea = false
				xMin, xMax = node.Pos.x, node.Pos.x
				yMin, yMax = node.Pos.y, node.Pos.y
			end
		else
			xMin, xMax = node.Pos.x, node.Pos.x
			yMin, yMax = node.Pos.y, node.Pos.y
		end
		local cx0 = math.floor(xMin / GRID_CELL_SIZE)
		local cx1 = math.floor(xMax / GRID_CELL_SIZE)
		local cy0 = math.floor(yMin / GRID_CELL_SIZE)
		local cy1 = math.floor(yMax / GRID_CELL_SIZE)
		for cx = cx0, cx1 do
			for cy = cy0, cy1 do
				local k = gridKey(cx, cy)
				local bucket = grid[k]
				if not bucket then
					bucket = {}
					grid[k] = bucket
				end
				bucket[#bucket + 1] = node
			end
		end
	end
	self.SpatialGrid = grid
end

function fallback:InvalidateCache()
	for _, link in pairs(self.LinkById) do
		link.CachedDist = nil
		link.CachedZDiff = nil
		link.CachedEdgeDist = nil
	end
	self:RebuildSpatialGrid()
	self:RebuildParamIndexes()
end

function fallback:ForceGetItem(id)
	return isnumber(id) and self:ForceGetNode(id) or self:ForceGetLink(id)
end

function fallback:NewNode()
	return self:ForceGetNode(#self.ItemById + 1)
end

function fallback:ForceGetNode(id)
	local r = self.NodeById[id]
	if r then return r end
	local node = setmetatable(newItem(self, id), lib.NavMeshNodeMeta)
	node.LinkByLinkedNode = {}
	self.NodeById[id] = node
	return node
end

function fallback:ForceGetLink(idOrNodeA, nilOrNodeB)
	local nodeA, nodeB
	if nilOrNodeB == nil then
		local id = idOrNodeA
		local serializedNodeIds = string.Split(id, lib.NavMeshLinkNodesSeparator)
		if #serializedNodeIds ~= 2 then error("Link must have exactly 2 nodes to link: " .. tostring(id), 2) end
		local idA = tonumber(serializedNodeIds[1])
		local idB = tonumber(serializedNodeIds[2])
		if not idA or not idB then error("Invalid node ID in link: " .. tostring(id), 2) end
		nodeA = self:ForceGetNode(idA)
		nodeB = self:ForceGetNode(idB)
	else
		nodeA = idOrNodeA
		nodeB = nilOrNodeB
	end
	if nodeA == nodeB then return nil end
	local r = nodeA.LinkByLinkedNode[nodeB]
	if r then return r end
	local id = nodeA.Id .. lib.NavMeshLinkNodesSeparator .. nodeB.Id
	local link = setmetatable(newItem(self, id), lib.NavMeshLinkMeta)
	link.Nodes = { nodeA, nodeB }
	nodeA.LinkByLinkedNode[nodeB] = link
	nodeB.LinkByLinkedNode[nodeA] = link
	self.LinkById[id] = link
	return link
end

function fallback:SetParam(name, val)
	if not name or name == "" then return end
	name, val = lib.NormalizeNavmeshParam(name, val or "")
	if val == "" then
		self.Params[name] = nil
		return
	end
	local numOrStr = tonumber(val) or val
	self.Params[name] = numOrStr
end

local spatialParamKeys = {
	X = true, Y = true, Z = true,
	AreaXMin = true, AreaXMax = true, AreaYMin = true, AreaYMax = true
}

local function itemParamChanged(item, changedKey)
	if changedKey and not spatialParamKeys[changedKey] then return end
	local params = item.Params
	if item.Pos then
		local x = tonumber(params.X) or 0
		local y = tonumber(params.Y) or 0
		local z = tonumber(params.Z) or 0
		item.Pos:SetUnpacked(x, y, z)
	end
	item.HasArea = isnumber(params.AreaXMin) and isnumber(params.AreaXMax) and isnumber(params.AreaYMin) and isnumber(params.AreaYMax)
end

function itemFallback:SetParam(name, val)
	if not name or name == "" then return end
	name, val = lib.NormalizeParam(name, val or "")
	if val == "" then
		self.Params[name] = nil
		itemParamChanged(self, name)
		return
	end
	local numOrStr = tonumber(val) or val
	if (name .. (isstring(numOrStr) and numOrStr or "")):find("[^%w_]") then
		return
	end
	self.Params[name] = numOrStr
	itemParamChanged(self, name)
end

-- Zero-allocation scalar closest XY point on area node at node's own Z floor
function nodeFallback:GetClosestPointCoords(posX, posY)
	local nPos = self.Pos
	if not self.HasArea then
		return nPos.x, nPos.y, nPos.z
	end
	local params = self.Params
	local areaXMin = params.AreaXMin
	local areaXMax = params.AreaXMax
	local areaYMin = params.AreaYMin
	local areaYMax = params.AreaYMax
	local cx = (posX > areaXMax and areaXMax) or (posX < areaXMin and areaXMin) or posX
	local cy = (posY > areaYMax and areaYMax) or (posY < areaYMin and areaYMin) or posY
	return cx, cy, nPos.z
end

-- Returns the closest XY point on an area node AT THE NODE'S OWN Z FLOOR (fixes posZ bleed bug)
function nodeFallback:GetClosestPointOnArea(pos)
	if not self.HasArea then return self.Pos end
	local cx, cy, cz = self:GetClosestPointCoords(pos.x, pos.y)
	return Vector(cx, cy, cz)
end

function nodeFallback:GetFocusPos() return self.Pos end
function linkFallback:GetFocusPos() return LerpVector(0.5, self.Nodes[1].Pos, self.Nodes[2].Pos) end
function linkFallback:GetParam(name) return self.Params[name] or self.Nodes[1].Params[name] or self.Nodes[2].Params[name] end

-- Checks if world position `pos` is inside/at this node without snapping across floors!
-- verticalUp: max units pos.z may be ABOVE node.Pos.z (standing on node, jumping, or stairs)
-- verticalDown: max units pos.z may be BELOW node.Pos.z (slopes/stairs leading up to node)
function nodeFallback:GetContains(pos, verticalUp, verticalDown)
	local upLim = verticalUp or (lib.BotNodeArrivalVertUp or 56)
	local downLim = verticalDown or verticalUp or (lib.BotNodeArrivalVertDown or 34)
	local dz = pos.z - self.Pos.z
	if dz > upLim or dz < -downLim then
		return false
	end

	if not self.HasArea then
		local dx = pos.x - self.Pos.x
		local dy = pos.y - self.Pos.y
		return (dx * dx + dy * dy) <= (lib.BotNodeMinProximitySqr or (44 * 44))
	end

	local params = self.Params
	return pos.x >= (params.AreaXMin - 4) and pos.x <= (params.AreaXMax + 4)
		and pos.y >= (params.AreaYMin - 4) and pos.y <= (params.AreaYMax + 4)
end

local function checkNodeSetNearest(nodes, posX, posY, posZ, nearestNodeOrNil, distSqrMin, distMin, distMinNeg, filterFn)
	for _, node in pairs(nodes) do
		if istable(node) and node.Pos and (not filterFn or filterFn(node)) then
			local nodeX, nodeY, nodeZ = node.Pos:Unpack()
			if node.HasArea then
				local params = node.Params
				local areaXMin = params.AreaXMin
				local areaXMax = params.AreaXMax
				local areaYMin = params.AreaYMin
				local areaYMax = params.AreaYMax
				nodeX = (posX > areaXMax and areaXMax) or (posX < areaXMin and areaXMin) or posX
				nodeY = (posY > areaYMax and areaYMax) or (posY < areaYMin and areaYMin) or posY
			end

			local diffX = posX - nodeX
			if diffX < distMin and diffX > distMinNeg then
				local diffY = posY - nodeY
				if diffY < distMin and diffY > distMinNeg then
					local diffZ = posZ - nodeZ
					if diffZ < distMin and diffZ > distMinNeg then
						local distSqr = diffX ^ 2 + diffY ^ 2 + diffZ ^ 2
						if distSqr < distSqrMin then
							nearestNodeOrNil = node
							distSqrMin = distSqr
							distMin = mathSqrt(distSqr)
							distMinNeg = -distMin
						end
					end
				end
			end
		end
	end
	return nearestNodeOrNil, distSqrMin, distMin, distMinNeg
end

function fallback:GetNearestNodeOrNil(pos, filterFn)
	if not isvector(pos) or not self.NodeById or not next(self.NodeById) then
		return nil
	end

	local nearestNodeOrNil
	local distSqrMin = math.huge
	local distMin = math.huge
	local distMinNeg = -distMin
	local posX, posY, posZ = pos:Unpack()

	if self.SpatialGrid then
		local cx = math.floor(posX / GRID_CELL_SIZE)
		local cy = math.floor(posY / GRID_CELL_SIZE)
		local visited = {}
		local ringCandidates = {}
		for ring = 0, 2 do
			local ringStart = #ringCandidates + 1
			for dx = -ring, ring do
				for dy = -ring, ring do
					if math.abs(dx) == ring or math.abs(dy) == ring then
						local bucket = self.SpatialGrid[gridKey(cx + dx, cy + dy)]
						if bucket then
							for _, node in ipairs(bucket) do
								if not visited[node] then
									visited[node] = true
									ringCandidates[#ringCandidates + 1] = node
								end
							end
						end
					end
				end
			end
			if #ringCandidates >= ringStart then
				local slice = {}
				for i = ringStart, #ringCandidates do
					slice[#slice + 1] = ringCandidates[i]
				end
				nearestNodeOrNil, distSqrMin, distMin, distMinNeg = checkNodeSetNearest(slice, posX, posY, posZ, nearestNodeOrNil, distSqrMin, distMin, distMinNeg, filterFn)
				-- Only stop early if we actually found a valid passing node within guaranteed ring radius
				if nearestNodeOrNil and distMin <= (ring + 0.5) * GRID_CELL_SIZE then
					return nearestNodeOrNil
				end
			end
		end
		if nearestNodeOrNil then
			return nearestNodeOrNil
		end
	end

	nearestNodeOrNil = checkNodeSetNearest(self.NodeById, posX, posY, posZ, nearestNodeOrNil, distSqrMin, distMin, distMinNeg, filterFn)
	return nearestNodeOrNil
end

local candidateOutScratch = {}
local candidateVisitedScratch = {}

-- Collects nearby nodes from spatial grid (fast O(1) local lookup with full-mesh fallback)
function fallback:GetCandidateNodesNear(pos, maxRings, outTable)
	local out = outTable or {}
	if outTable then
		for i = #out, 1, -1 do out[i] = nil end
	end
	if not isvector(pos) or not self.NodeById or not next(self.NodeById) then
		return out
	end

	if self.SpatialGrid then
		local cx = math.floor(pos.x / GRID_CELL_SIZE)
		local cy = math.floor(pos.y / GRID_CELL_SIZE)
		local rings = maxRings or 2
		for k in pairs(candidateVisitedScratch) do candidateVisitedScratch[k] = nil end
		for dx = -rings, rings do
			for dy = -rings, rings do
				local bucket = self.SpatialGrid[gridKey(cx + dx, cy + dy)]
				if bucket then
					for _, node in ipairs(bucket) do
						if not candidateVisitedScratch[node] then
							candidateVisitedScratch[node] = true
							out[#out + 1] = node
						end
					end
				end
			end
		end
	end

	if #out == 0 then
		for _, node in pairs(self.NodeById) do
			out[#out + 1] = node
		end
	end

	return out
end

local scoredScratch = {}
local function sortScoredAsc(a, b) return a.Score < b.Score end

-- Floor-aware, component-aware, optional LOS-checked nearest valid node selector
-- Zero Vector allocation hot path for large horde queries.
function fallback:GetBestNodeNear(pos, opts)
	if not isvector(pos) or not self.NodeById or not next(self.NodeById) then
		return nil
	end

	opts = opts or {}
	local wave = opts.wave or (lib.GetCurrentWave and lib.GetCurrentWave() or 0)
	local requireLinked = opts.requireLinked ~= false
	local requireDirectedReachable = opts.requireDirectedReachable == true
	local preferredComp = opts.preferredComponentId
	local excludeSet = opts.excludeNodes
	local checkLOS = opts.checkLOS == true
	local maxDistSqr = opts.maxDist and (opts.maxDist * opts.maxDist) or nil
	local posX, posY, posZ = pos.x, pos.y, pos.z

	local candidates = self:GetCandidateNodesNear(pos, opts.maxRings or 2, candidateOutScratch)
	local scoredCount = 0

	local function evaluateList(list, strictLinked)
		for _, node in ipairs(list) do
			if istable(node) and node.Pos and not (excludeSet and excludeSet[node]) then
				local hasLinks = node.LinkByLinkedNode and next(node.LinkByLinkedNode) ~= nil
				if (not strictLinked or hasLinks) and not node.RuntimeEmbedded then
					local blocked = lib.IsNavMeshNodeBlocked and lib.IsNavMeshNodeBlocked(node.Params, node.Pos, wave)
					if not blocked then
						local px, py, pz = node:GetClosestPointCoords(posX, posY)
						local dx = px - posX
						local dy = py - posY
						local dz = pz - posZ
						local dist2DSqr = dx * dx + dy * dy
						local dist3DSqr = dist2DSqr + dz * dz
						if not maxDistSqr or dist3DSqr <= maxDistSqr then
							local dist2D = mathSqrt(dist2DSqr)
							local score = dist2D

							-- Strongly penalize nodes on another floor (above jump reach or deep below)
							if dz > 58 then
								score = score + dz * 4.5 + 220
							elseif dz < -64 then
								score = score + (-dz) * 3.0 + 160
							else
								score = score + math.abs(dz) * 0.65
							end

							if preferredComp and node.RuntimeComponentId and node.RuntimeComponentId ~= preferredComp then
								score = score + 12000
							elseif not hasLinks then
								score = score + 15000
							elseif node.RuntimeDirectedReachable == false and (requireDirectedReachable or preferredComp) then
								score = score + (requireDirectedReachable and 9000 or 4500)
							end

							if node.RuntimeIsDeadEnd then
								score = score + 220
							end

							scoredCount = scoredCount + 1
							local slot = scoredScratch[scoredCount]
							if slot then
								slot.Node = node
								slot.X = px
								slot.Y = py
								slot.Z = pz
								slot.Score = score
							else
								scoredScratch[scoredCount] = { Node = node, X = px, Y = py, Z = pz, Score = score }
							end
						end
					end
				end
			end
		end
	end

	local totalMeshNodes = self.CachedNodeCount or table.Count(self.NodeById)
	evaluateList(candidates, requireLinked)
	if scoredCount == 0 and #candidates < totalMeshNodes then
		local all = {}
		for _, node in pairs(self.NodeById) do all[#all + 1] = node end
		evaluateList(all, requireLinked)
	end
	if scoredCount == 0 and requireLinked then
		evaluateList(candidates, false)
	end
	if scoredCount == 0 then
		return self:GetNearestNodeOrNil(pos)
	end

	for i = #scoredScratch, scoredCount + 1, -1 do
		scoredScratch[i] = nil
	end
	table.sort(scoredScratch, sortScoredAsc)

	if checkLOS and util and util.TraceLine then
		local losTrData = self._LosTraceData
		if not losTrData then
			losTrData = { mask = MASK_SOLID_BRUSHONLY, start = Vector(), endpos = Vector() }
			self._LosTraceData = losTrData
		end
		losTrData.start:SetUnpacked(posX, posY, posZ + 28)

		local checkCount = math.min(scoredCount, 6)
		local bestVis = nil
		local bestVisScore = math.huge
		for i = 1, checkCount do
			local entry = scoredScratch[i]
			losTrData.endpos:SetUnpacked(entry.X, entry.Y, entry.Z + 28)
			local tr = util.TraceLine(losTrData)
			local adjScore = entry.Score + (tr.Hit and 650 or 0)
			if adjScore < bestVisScore then
				bestVisScore = adjScore
				bestVis = entry.Node
			end
			if not tr.Hit and i == 1 then
				return entry.Node
			end
		end
		if bestVis then return bestVis end
	end

	return scoredScratch[1].Node
end

function fallback:GetNearestValidNodeOrNil(pos, wave, maxDist, requireLinked, opts)
	if not isvector(pos) or not self.NodeById or not next(self.NodeById) then
		return nil
	end
	return self:GetBestNodeNear(pos, {
		wave = wave,
		maxDist = maxDist,
		requireLinked = requireLinked ~= false,
		requireDirectedReachable = opts and opts.requireDirectedReachable,
		preferredComponentId = opts and opts.preferredComponentId,
		excludeNodes = opts and opts.excludeNodes,
		checkLOS = opts and opts.checkLOS
	})
end

function lib.DeserializeNavMeshItemId(serializedId)
	return tonumber(serializedId) or serializedId
end

function lib.DeserializeNavMesh(serialized)
	serialized = (serialized or ""):gsub("\r\n", "\n")
	serialized = serialized:gsub("\r", "\n")
	serialized = serialized:gsub(lib.NavMeshItemsSeparatorOld, lib.NavMeshItemsSeparator)

	local navMesh = lib.NewNavMesh()
	for _, serializedItem in ipairs(lib.GetSplitStr(serialized, lib.NavMeshItemsSeparator)) do
		if serializedItem ~= "" then
			local pair = string.Split(serializedItem, lib.NavMeshItemIdParamsPairSeparator)
			local serializedId, serializedParams = pair[1], pair[2]
			if serializedId and serializedId ~= "" and serializedParams then
				local item = navMesh:ForceGetItem(lib.DeserializeNavMeshItemId(serializedId))
				for _, serializedParam in ipairs(lib.GetSplitStr(serializedParams, lib.NavMeshItemParamsSeparator)) do
					if serializedParam ~= "" then
						local kv = string.Split(serializedParam, lib.NavMeshItemParamNameNumPairSeparator)
						if kv[1] and kv[1] ~= "" then
							item:SetParam(kv[1], kv[2] or "")
						end
					end
				end
			end
		end
	end
	return navMesh
end

function fallback:DeserializeNavMeshParams(serialized)
	serialized = (serialized or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	for _, serializedItem in ipairs(lib.GetSplitStr(serialized, lib.NavMeshItemsSeparator)) do
		if serializedItem ~= "" then
			local kv = string.Split(serializedItem, lib.NavMeshItemParamNameNumPairSeparator)
			if kv[1] and kv[1] ~= "" then
				self:SetParam(kv[1], kv[2] or "")
			end
		end
	end
end
