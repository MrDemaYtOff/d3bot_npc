-- Navmesh Topology Analyzer, Runtime Self-Healing, and Safe Repair Tools for D3bot NPC
-- Inspects loaded D3bot navmeshes (e.g. zs_abandoned_mall_v6b) for:
--   * Isolated nodes & disconnected graph components
--   * Dead-end / one-way trap sinks
--   * Impossible vertical uphill links missing Climb/Pounce/Ladder attributes
--   * Solid-world wall intersections, embedded nodes, low-ceiling crouch requirements
--   * Safe virtual bridges for stranded nodes near the main component
--   * Bottleneck / choke degree scoring for crowd distribution
-- Never overwrites original <mapname>.txt files automatically; supports timestamped backups
-- and non-destructive sidecar patches (<mapname>.npc_patch.txt).

local lib = D3botNPC

lib.MeshAudit = lib.MeshAudit or {}
local Audit = lib.MeshAudit

Audit.Report = Audit.Report or nil
Audit.PendingGeometryQueue = Audit.PendingGeometryQueue or {}
Audit.ActiveMesh = nil

local mathAbs = math.abs
local mathMax = math.max
local mathMin = math.min
local mathSqrt = math.sqrt

local function isWalkableLinkDirection(link, fromNode, toNode)
	local lp = link.Params or {}
	local forwards = (link.Nodes[1] == fromNode)
	if lp.Direction == "Forward" and not forwards then return false end
	if lp.Direction == "Backward" and forwards then return false end
	if link.RuntimeOneWay == "Forward" and not forwards then return false end
	if link.RuntimeOneWay == "Backward" and forwards then return false end
	return true
end

-- Fast synchronous topology & verticality pass (safe for 3,000+ nodes in <15ms)
function Audit.RunTopologyPass(navMesh)
	if not navMesh or not navMesh.NodeById or not next(navMesh.NodeById) then
		return nil
	end

	local startClock = SysTime()
	local nodeCount = 0
	local linkCount = 0
	local isolatedNodes = {}
	local deadEndNodes = {}
	local impossibleUpLinks = {}
	local highDropLinks = {}
	local bridgeLinksAdded = 0
	local bottleneckNodes = {}

	-- Reset runtime annotations before recomputing
	for _, node in pairs(navMesh.NodeById) do
		nodeCount = nodeCount + 1
		node.RuntimeComponentId = nil
		node.RuntimeIsIsolated = false
		node.RuntimeIsDeadEnd = false
		node.RuntimeBottleneckScore = 0
		node.RuntimeNeedsCrouch = nil
		node.RuntimeEmbedded = nil
		node.RuntimeFloating = nil
	end

	-- Remove previously injected runtime-virtual links before re-evaluating
	for id, link in pairs(navMesh.LinkById) do
		if link.IsRuntimeVirtual then
			local nA, nB = link.Nodes[1], link.Nodes[2]
			if nA and nA.LinkByLinkedNode then nA.LinkByLinkedNode[nB] = nil end
			if nB and nB.LinkByLinkedNode then nB.LinkByLinkedNode[nA] = nil end
			navMesh.LinkById[id] = nil
			navMesh.ItemById[id] = nil
		end
	end

	-- 1. Analyze every link for verticality, directionality, and cached edge lengths
	for _, link in pairs(navMesh.LinkById) do
		linkCount = linkCount + 1
		local n1, n2 = link.Nodes[1], link.Nodes[2]
		if n1 and n2 and n1.Pos and n2.Pos then
			local lp = link.Params or {}
			local dz = n2.Pos.z - n1.Pos.z -- positive means n1 -> n2 goes UP
			link.CachedZDiff = dz
			link.CachedDist = n1.Pos:Distance(n2.Pos)

			local dx = n2.Pos.x - n1.Pos.x
			local dy = n2.Pos.y - n1.Pos.y
			local dist2D = mathSqrt(dx * dx + dy * dy)
			local slopeAngle = (dist2D > 1) and math.deg(math.atan2(mathAbs(dz), dist2D)) or 90

			link.CachedSlopeDeg = slopeAngle
			link.CachedDist2D = dist2D
			link.RuntimeOneWay = nil
			link.RuntimeJumpRecommended = nil
			link.RuntimeHighDrop = nil
			link.RuntimeWorldBlocked = nil
			link.RuntimeLowClearance = nil

			local hasSpecialVertical = (lp.Path == "Ladder")
				or (lp.Pouncing == "Needed")
				or (lp.CrabPouncing == "Needed")
				or (n1.Params and n1.Params.Climbing == "Needed")
				or (n2.Params and n2.Params.Climbing == "Needed")

			-- Standard walking zombie crouch-jump max is ~62u; walkable ramps/escalators
			-- (slopeAngle <= 46 deg over horizontal distance >= 95u) remain bidirectional uphill.
			local isSteepLedge = (slopeAngle > 46) or (dist2D < 95)
			if not hasSpecialVertical then
				if dz > 66 and isSteepLedge and not lp.Direction then
					-- n1 -> n2 is too steep & high to walk/jump up; treat as downhill drop only (n2 -> n1)!
					link.RuntimeOneWay = "Backward"
					impossibleUpLinks[#impossibleUpLinks + 1] = link
				elseif -dz > 66 and isSteepLedge and not lp.Direction then
					-- n2 -> n1 is too steep & high to walk/jump up; treat as downhill drop only (n1 -> n2)!
					link.RuntimeOneWay = "Forward"
					impossibleUpLinks[#impossibleUpLinks + 1] = link
				elseif mathAbs(dz) > 22 and mathAbs(dz) <= 66 and slopeAngle > 36 and dist2D < 140 then
					link.RuntimeJumpRecommended = true
				end
			end

			if mathAbs(dz) > 420 and lp.Path ~= "Ladder" and lp.Pouncing ~= "Needed" then
				link.RuntimeHighDrop = true
				highDropLinks[#highDropLinks + 1] = link
			end
		end
	end

	-- 2. Connected components (undirected) & isolated node scan
	local compId = 0
	local compNodes = {}
	local compSizes = {}
	local mainCompId = 1
	local mainCompSize = 0

	for _, node in pairs(navMesh.NodeById) do
		local deg = 0
		for _ in pairs(node.LinkByLinkedNode or {}) do
			deg = deg + 1
		end
		if deg == 0 then
			node.RuntimeIsIsolated = true
			isolatedNodes[#isolatedNodes + 1] = node
		elseif not node.RuntimeComponentId then
			compId = compId + 1
			local q = { node }
			local head = 1
			node.RuntimeComponentId = compId
			local members = { node }
			while head <= #q do
				local cur = q[head]
				head = head + 1
				for linked, _ in pairs(cur.LinkByLinkedNode or {}) do
					if not linked.RuntimeComponentId then
						linked.RuntimeComponentId = compId
						q[#q + 1] = linked
						members[#members + 1] = linked
					end
				end
			end
			compNodes[compId] = members
			compSizes[compId] = #members
			if #members > mainCompSize then
				mainCompSize = #members
				mainCompId = compId
			end
		end
	end

	navMesh.MainComponentId = mainCompId
	navMesh.ComponentSizes = compSizes

	-- 3. Directed reachability check from main component -> detect unreachable traps & sink/dead-end nodes
	local seedNode = compNodes[mainCompId] and compNodes[mainCompId][1] or nil
	if compNodes[mainCompId] then
		local bestDeg = -1
		for _, n in ipairs(compNodes[mainCompId]) do
			local d = 0
			for linked, link in pairs(n.LinkByLinkedNode or {}) do
				if isWalkableLinkDirection(link, n, linked) then d = d + 1 end
			end
			if d > bestDeg then
				bestDeg = d
				seedNode = n
			end
		end
	end

	local directedReachable = {}
	if seedNode then
		local dq = { seedNode }
		local dhead = 1
		directedReachable[seedNode] = true
		while dhead <= #dq do
			local cur = dq[dhead]
			dhead = dhead + 1
			for linked, link in pairs(cur.LinkByLinkedNode or {}) do
				if not directedReachable[linked] and isWalkableLinkDirection(link, cur, linked) then
					directedReachable[linked] = true
					dq[#dq + 1] = linked
				end
			end
		end
	end

	for _, node in pairs(navMesh.NodeById) do
		node.RuntimeDirectedReachable = directedReachable[node] == true
		local outDeg = 0
		local inDeg = 0
		for linked, link in pairs(node.LinkByLinkedNode or {}) do
			if isWalkableLinkDirection(link, node, linked) then outDeg = outDeg + 1 end
			if isWalkableLinkDirection(link, linked, node) then inDeg = inDeg + 1 end
		end
		if outDeg == 0 and inDeg > 0 then
			node.RuntimeIsDeadEnd = true
			deadEndNodes[#deadEndNodes + 1] = node
		elseif outDeg == 1 and inDeg == 1 then
			-- Potential narrow corridor / bottleneck node
			node.RuntimeBottleneckScore = 2
		elseif outDeg <= 2 then
			node.RuntimeBottleneckScore = 1
		end
		if node.RuntimeBottleneckScore >= 2 then
			bottleneckNodes[#bottleneckNodes + 1] = node
		end
	end

	-- 4. Safe virtual bridge repair for isolated / tiny-island nodes near main component
	if navMesh.SpatialGrid and compId > 0 then
		local bridgeStart = Vector()
		local bridgeEnd = Vector()
		local bridgeMin = Vector(-10, -10, 0)
		local bridgeMax = Vector(10, 10, 32)
		local bridgeTrData = {
			start = bridgeStart,
			endpos = bridgeEnd,
			mins = bridgeMin,
			maxs = bridgeMax,
			mask = MASK_SOLID_BRUSHONLY
		}
		for _, node in pairs(navMesh.NodeById) do
			if (node.RuntimeIsIsolated or (node.RuntimeComponentId and node.RuntimeComponentId ~= mainCompId)) and node.Pos then
				local candidates = navMesh:GetCandidateNodesNear(node.Pos, 1)
				local bestTarget = nil
				local bestDistSqr = 175 * 175
				for _, cand in ipairs(candidates) do
					if cand ~= node and cand.RuntimeComponentId == mainCompId and cand.Pos then
						local dz = mathAbs(cand.Pos.z - node.Pos.z)
						if dz <= 42 then
							local dSqr = node.Pos:DistToSqr(cand.Pos)
							if dSqr < bestDistSqr then
								local clear = true
								if util and util.TraceHull then
									bridgeStart:SetUnpacked(node.Pos.x, node.Pos.y, node.Pos.z + 26)
									bridgeEnd:SetUnpacked(cand.Pos.x, cand.Pos.y, cand.Pos.z + 26)
									local tr = util.TraceHull(bridgeTrData)
									clear = not tr.Hit
								end
								if clear then
									bestDistSqr = dSqr
									bestTarget = cand
								end
							end
						end
					end
				end

				if bestTarget then
					local vLink = navMesh:ForceGetLink(node, bestTarget)
					if vLink then
						local bdx = bestTarget.Pos.x - node.Pos.x
						local bdy = bestTarget.Pos.y - node.Pos.y
						local bdist2D = mathSqrt(bdx * bdx + bdy * bdy)
						local bdz = bestTarget.Pos.z - node.Pos.z
						vLink.IsRuntimeVirtual = true
						vLink.CachedDist = mathSqrt(bestDistSqr)
						vLink.CachedZDiff = bdz
						vLink.CachedDist2D = bdist2D
						vLink.CachedSlopeDeg = (bdist2D > 1) and math.deg(math.atan2(mathAbs(bdz), bdist2D)) or 90
						node.RuntimeIsIsolated = false
						node.RuntimeComponentId = mainCompId
						bridgeLinksAdded = bridgeLinksAdded + 1
					end
				end
			end
		end
	end

	local report = {
		Map = game and game.GetMap and game.GetMap() or "unknown",
		NodeCount = nodeCount,
		LinkCount = linkCount,
		ComponentCount = compId,
		MainComponentId = mainCompId,
		MainComponentSize = mainCompSize,
		IsolatedCount = #isolatedNodes,
		DeadEndCount = #deadEndNodes,
		ImpossibleUpLinkCount = #impossibleUpLinks,
		HighDropLinkCount = #highDropLinks,
		VirtualBridgesAdded = bridgeLinksAdded,
		BottleneckCount = #bottleneckNodes,
		WorldBlockedLinks = 0,
		EmbeddedNodes = 0,
		LowCeilingNodes = 0,
		GeometryPassComplete = false,
		TopologyMs = math.Round((SysTime() - startClock) * 1000, 2)
	}

	Audit.Report = report
	return report
end

local embedMin, embedMax = Vector(-12, -12, 0), Vector(12, 12, 24)
local headMin, headMax = Vector(-12, -12, 0), Vector(12, 12, 4)
local linkMin, linkMax = Vector(-10, -10, 0), Vector(10, 10, 26)
local jumpMin, jumpMax = Vector(-10, -10, 0), Vector(10, 10, 20)

local auditStartVec = Vector()
local auditEndVec = Vector()
local auditTraceData = {
	start = auditStartVec,
	endpos = auditEndVec,
	mins = embedMin,
	maxs = embedMax,
	mask = MASK_SOLID_BRUSHONLY
}

local function inspectSingleNodeGeometry(node, report)
	if not util or not util.TraceHull or not node or not node.Pos then return end
	local px, py, pz = node.Pos.x, node.Pos.y, node.Pos.z

	-- Check if node anchor is embedded inside solid world brush
	auditStartVec:SetUnpacked(px, py, pz + 18)
	auditEndVec:SetUnpacked(px, py, pz + 22)
	auditTraceData.mins = embedMin
	auditTraceData.maxs = embedMax
	local embedTr = util.TraceHull(auditTraceData)
	if embedTr.StartSolid then
		node.RuntimeEmbedded = true
		if report then report.EmbeddedNodes = report.EmbeddedNodes + 1 end
	end

	-- Check standing headroom (72u) vs crouch headroom (36u)
	auditStartVec:SetUnpacked(px, py, pz + 10)
	auditEndVec:SetUnpacked(px, py, pz + 72)
	auditTraceData.mins = headMin
	auditTraceData.maxs = headMax
	local headTr = util.TraceHull(auditTraceData)
	if headTr.Hit and headTr.Fraction < 0.88 and not (node.Params and node.Params.MaxHeight) then
		node.RuntimeNeedsCrouch = true
		if report then report.LowCeilingNodes = report.LowCeilingNodes + 1 end
	end
end

local function inspectSingleLinkGeometry(link, report)
	if not util or not util.TraceHull or not link or not link.Nodes then return end
	local n1, n2 = link.Nodes[1], link.Nodes[2]
	if not n1 or not n2 or not n1.Pos or not n2.Pos then return end

	local lp = link.Params or {}
	if lp.Path == "Ladder" or lp.Condition or lp.BlockEntity then return end

	local p1, p2 = n1.Pos, n2.Pos
	-- Sweep crouch-height hull 30u above endpoints so valid 18u stair steps don't trigger false positives
	auditStartVec:SetUnpacked(p1.x, p1.y, p1.z + 30)
	auditEndVec:SetUnpacked(p2.x, p2.y, p2.z + 30)
	auditTraceData.mins = linkMin
	auditTraceData.maxs = linkMax
	local tr = util.TraceHull(auditTraceData)

	if tr.Hit and not tr.StartSolid then
		-- Verify if a higher jump clearance (z+56) clears a low wall/railing/counter
		auditStartVec:SetUnpacked(p1.x, p1.y, p1.z + 56)
		auditEndVec:SetUnpacked(p2.x, p2.y, p2.z + 56)
		auditTraceData.mins = jumpMin
		auditTraceData.maxs = jumpMax
		local jumpTr = util.TraceHull(auditTraceData)
		if not jumpTr.Hit then
			link.RuntimeJumpRecommended = true
		else
			link.RuntimeWorldBlocked = true
			if report then report.WorldBlockedLinks = report.WorldBlockedLinks + 1 end
		end
	end
end

function Audit.QueueGeometryPass(navMesh)
	Audit.PendingGeometryQueue = {}
	Audit.ActiveMesh = navMesh
	if not navMesh then return end

	for _, node in pairs(navMesh.NodeById) do
		Audit.PendingGeometryQueue[#Audit.PendingGeometryQueue + 1] = { Kind = "node", Item = node }
	end
	for _, link in pairs(navMesh.LinkById) do
		Audit.PendingGeometryQueue[#Audit.PendingGeometryQueue + 1] = { Kind = "link", Item = link }
	end
	Audit.GeometryCursor = 1
end

function Audit.RunGeometryImmediate(navMesh)
	if not navMesh then return end
	local report = Audit.Report or Audit.RunTopologyPass(navMesh)
	if not report then return end
	report.WorldBlockedLinks = 0
	report.EmbeddedNodes = 0
	report.LowCeilingNodes = 0

	for _, node in pairs(navMesh.NodeById) do
		inspectSingleNodeGeometry(node, report)
	end
	for _, link in pairs(navMesh.LinkById) do
		inspectSingleLinkGeometry(link, report)
	end
	report.GeometryPassComplete = true
	Audit.PendingGeometryQueue = {}
	return report
end

hook.Add("Think", lib.HookId .. ".MeshGeometryAudit", function()
	local q = Audit.PendingGeometryQueue
	if not q or #q == 0 or not Audit.ActiveMesh or Audit.ActiveMesh ~= lib.MapNavMesh then return end

	local cursor = Audit.GeometryCursor or 1
	local batchEnd = mathMin(#q, cursor + 35)
	for i = cursor, batchEnd do
		local entry = q[i]
		if entry.Kind == "node" then
			inspectSingleNodeGeometry(entry.Item, Audit.Report)
		else
			inspectSingleLinkGeometry(entry.Item, Audit.Report)
		end
	end

	if batchEnd >= #q then
		Audit.PendingGeometryQueue = {}
		Audit.GeometryCursor = 1
		if Audit.Report then
			Audit.Report.GeometryPassComplete = true
			lib.DebugLog("Navmesh geometry audit complete: %d world-blocked links, %d embedded nodes, %d low-ceiling nodes.",
				Audit.Report.WorldBlockedLinks, Audit.Report.EmbeddedNodes, Audit.Report.LowCeilingNodes)
		end
	else
		Audit.GeometryCursor = batchEnd + 1
	end
end)

-- Optional non-destructive sidecar patch loader: garrysmod/data/d3bot/navmesh/map/<map>.npc_patch.txt
-- Format: identical to D3bot navmesh lines (NodeId:Param=Val or NodeA-NodeB:Param=Val), overlaid without touching base mesh!
function Audit.LoadSidecarPatch(navMesh, mapName)
	mapName = mapName or (game and game.GetMap and game.GetMap())
	if not navMesh or not mapName then return 0 end
	local patchPath = "d3bot/navmesh/map/" .. mapName .. ".npc_patch.txt"
	if not file.Exists(patchPath, "DATA") then return 0 end

	local raw = file.Read(patchPath, "DATA") or ""
	raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
	local applied = 0
	for _, line in ipairs(lib.GetSplitStr(raw, "\n")) do
		if line ~= "" and not string.StartWith(line, "#") then
			local pair = string.Split(line, lib.NavMeshItemIdParamsPairSeparator)
			local idStr, paramStr = pair[1], pair[2]
			if idStr and idStr ~= "" and paramStr then
				local item = navMesh:ForceGetItem(lib.DeserializeNavMeshItemId(idStr))
				for _, kvStr in ipairs(lib.GetSplitStr(paramStr, lib.NavMeshItemParamsSeparator)) do
					if kvStr ~= "" then
						local kv = string.Split(kvStr, lib.NavMeshItemParamNameNumPairSeparator)
						if kv[1] and kv[1] ~= "" then
							item:SetParam(kv[1], kv[2] or "")
						end
					end
				end
				applied = applied + 1
			end
		end
	end
	if applied > 0 then
		navMesh:InvalidateCache()
	end
	return applied
end

-- Serialize navmesh safely with timestamped backup of original file; never overwrites <mapname>.txt
function Audit.ExportSafeRepair(navMesh)
	if not navMesh or not navMesh.NodeById then return false, "No D3bot navmesh loaded." end
	local mapName = game.GetMap()
	local origPath = "d3bot/navmesh/map/" .. mapName .. ".txt"
	local ts = os.date("%Y%m%d_%H%M%S")
	local backupPath = "d3bot/navmesh/map/" .. mapName .. ".backup_" .. ts .. ".txt"
	local repairedPath = "d3bot/navmesh/map/" .. mapName .. ".npc_repaired.txt"
	local patchPath = "d3bot/navmesh/map/" .. mapName .. ".npc_patch.txt"

	if file.Exists(origPath, "DATA") then
		file.Write(backupPath, file.Read(origPath, "DATA") or "")
	end

	local patchLines = {
		"# D3bot NPC Safe Sidecar Patch for " .. mapName .. " (" .. ts .. ")",
		"# Original mesh backed up to: " .. backupPath
	}

	local fullLines = {}
	for id, node in lib.PairsByKeys(navMesh.NodeById) do
		local parts = {}
		for k, v in lib.PairsByKeys(node.Params or {}) do
			parts[#parts + 1] = k .. "=" .. tostring(v)
		end
		fullLines[#fullLines + 1] = tostring(id) .. ":" .. table.concat(parts, ",")
	end

	for id, link in lib.PairsByKeys(navMesh.LinkById) do
		local parts = {}
		local params = table.Copy(link.Params or {})
		if not params.Direction and link.RuntimeOneWay then
			params.Direction = link.RuntimeOneWay
			patchLines[#patchLines + 1] = tostring(id) .. ":Direction=" .. link.RuntimeOneWay
		end
		if link.IsRuntimeVirtual and link.Nodes and link.Nodes[1] and link.Nodes[2] then
			patchLines[#patchLines + 1] = tostring(link.Nodes[1].Id) .. "-" .. tostring(link.Nodes[2].Id) .. ":Cost=20"
		end
		for k, v in lib.PairsByKeys(params) do
			parts[#parts + 1] = k .. "=" .. tostring(v)
		end
		fullLines[#fullLines + 1] = tostring(id) .. ":" .. table.concat(parts, ",")
	end

	file.Write(repairedPath, table.concat(fullLines, "\n"))
	file.Write(patchPath, table.concat(patchLines, "\n"))
	return true, string.format("Backup: data/%s | Patch: data/%s | Full export: data/%s", backupPath, patchPath, repairedPath)
end

function lib.AuditNavMesh(navMesh, runImmediateGeometry)
	local report = Audit.RunTopologyPass(navMesh)
	if not report then return nil end
	if runImmediateGeometry then
		Audit.RunGeometryImmediate(navMesh)
	else
		Audit.QueueGeometryPass(navMesh)
	end
	return report
end
