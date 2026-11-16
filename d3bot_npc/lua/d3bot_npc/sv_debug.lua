-- Debug visualization, navmesh inspection & live navigation telemetry for D3bot NPC

local lib = D3botNPC

lib.DebugFilterNPC = lib.DebugFilterNPC or nil -- nil = all nearby NPCs, or Entity / "stuck"

local COL_DBG_PREFIX = Color(120, 220, 120)
local COL_DBG_TEXT = Color(230, 230, 230)
local COL_NODE_BLOCKED = Color(255, 70, 70)
local COL_NODE_ISOLATED = Color(220, 70, 255)
local COL_NODE_DEADEND = Color(255, 165, 40)
local COL_NODE_CONGESTED = Color(255, 230, 70)
local COL_NODE_OK = Color(70, 220, 140)
local COL_LINK_OK = Color(70, 180, 120)
local COL_LINK_BLOCKED = Color(200, 40, 40)
local COL_LINK_ONEWAY = Color(255, 200, 50)
local COL_LINK_VIRTUAL = Color(120, 220, 255)
local COL_TARGET_LINE = Color(255, 80, 80)
local COL_NEXT_LINE = Color(80, 235, 255)
local COL_PATH_LINE = Color(80, 150, 255)
local COL_FAILED_LINK = Color(255, 110, 30)
local COL_BARRICADE = Color(255, 220, 40)

local VEC_Z4 = Vector(0, 0, 4)
local VEC_Z12 = Vector(0, 0, 12)
local VEC_Z16 = Vector(0, 0, 16)
local VEC_Z24 = Vector(0, 0, 24)
local VEC_Z78 = Vector(0, 0, 78)

function lib.DebugLog(fmt, ...)
	if not lib.ConVars.Debug or not lib.ConVars.Debug:GetBool() then return end
	MsgC(COL_DBG_PREFIX, "[D3botNPC Debug] ", COL_DBG_TEXT, string.format(fmt, ...) .. "\n")
end

function lib.GetNavStatsSummary()
	local stats = lib.PathStats or {}
	local solves = stats.Solves or 0
	local avgMs = solves > 0 and ((stats.TotalSolveMs or 0) / solves) or 0
	local qLen = (lib.AI and lib.AI.PathQueue) and #lib.AI.PathQueue or 0

	local npcCount = 0
	local stuckCounts = { OK = 0, COMBAT = 0, MICRO_STALL = 0, OBSTACLE_STALL = 0, ROUTE_FAIL = 0, CRITICAL_TRAP = 0 }
	local totalRecalcs = 0
	local totalRecoveries = 0

	local list = (lib.AI and lib.AI.GetLivingNPCsCached) and lib.AI.GetLivingNPCsCached() or lib.GetNPCs(false)
	for _, npc in ipairs(list) do
		if IsValid(npc) and npc.D3bot_Mem then
			npcCount = npcCount + 1
			local mem = npc.D3bot_Mem
			local state = mem.StuckStateName or "OK"
			stuckCounts[state] = (stuckCounts[state] or 0) + 1
			totalRecalcs = totalRecalcs + (mem.PathRecalcCount or 0)
			totalRecoveries = totalRecoveries + (mem.RecoveryAttempts or 0)
		end
	end

	local peakNodeCong = 0
	for _, occ in pairs(lib.NodeCongestion or {}) do
		if occ > peakNodeCong then peakNodeCong = occ end
	end

	return {
		LiveNPCs = npcCount,
		QueueDepth = qLen,
		Solves = solves,
		CacheHits = stats.CacheHits or 0,
		FailedSolves = stats.FailedSolves or 0,
		AvgSolveMs = avgMs,
		LastSolveMs = stats.LastSolveMs or 0,
		TotalRecalcs = totalRecalcs,
		ActiveRecoveries = totalRecoveries,
		PeakNodeCongestion = peakNodeCong,
		StuckCounts = stuckCounts
	}
end

local nextDebugDraw = 0
local viewerPositions = {}

local function nearAnyViewer(pos, maxDistSqr)
	if #viewerPositions == 0 then return true end
	for i = 1, #viewerPositions do
		if pos:DistToSqr(viewerPositions[i]) <= maxDistSqr then return true end
	end
	return false
end

hook.Add("Think", lib.HookId .. ".DebugOverlay", function()
	if not lib.ConVars.Debug or not lib.ConVars.Debug:GetBool() then return end
	local ct = CurTime()
	if ct < nextDebugDraw then return end
	nextDebugDraw = ct + 0.25

	if not debugoverlay then return end

	-- Anchor spatial radius around active players so 2,883-node maps don't overflow debugoverlay
	local vpCount = 0
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) then
			vpCount = vpCount + 1
			viewerPositions[vpCount] = ply:GetPos()
		end
	end
	for i = #viewerPositions, vpCount + 1, -1 do
		viewerPositions[i] = nil
	end

	local wave = lib.GetCurrentWave()
	if not lib.UsingSourceNav and lib.MapNavMesh and lib.MapNavMesh.NodeById then
		local nodeDrawDistSqr = 1500 * 1500
		for _, node in pairs(lib.MapNavMesh.NodeById) do
			if nearAnyViewer(node.Pos, nodeDrawDistSqr) then
				local blocked = lib.IsNavMeshNodeBlocked(node.Params, node.Pos, wave)
				local occ = lib.NodeCongestion and lib.NodeCongestion[node] or 0
				local col
				if blocked then
					col = COL_NODE_BLOCKED
				elseif node.RuntimeIsIsolated then
					col = COL_NODE_ISOLATED
				elseif node.RuntimeIsDeadEnd then
					col = COL_NODE_DEADEND
				elseif occ >= 3 then
					col = COL_NODE_CONGESTED
				else
					col = COL_NODE_OK
				end
				debugoverlay.Cross(node.Pos, 8, 0.3, col, true)

				for linked, link in pairs(node.LinkByLinkedNode or {}) do
					if node.Id < linked.Id then
						local linkCol = COL_LINK_OK
						if link.RuntimeWorldBlocked then
							linkCol = COL_LINK_BLOCKED
						elseif link.RuntimeOneWay then
							linkCol = COL_LINK_ONEWAY
						elseif link.IsRuntimeVirtual then
							linkCol = COL_LINK_VIRTUAL
						end
						debugoverlay.Line(node.Pos + VEC_Z4, linked.Pos + VEC_Z4, 0.3, linkCol, true)
					end
				end
			end
		end
	end

	local filter = lib.DebugFilterNPC
	local npcList = (lib.AI and lib.AI.GetLivingNPCsCached) and lib.AI.GetLivingNPCsCached() or lib.GetNPCs(false)
	for _, npc in ipairs(npcList) do
		local mem = npc.D3bot_Mem
		if mem and nearAnyViewer(npc:GetPos(), 2200 * 2200) then
			local showThis = (filter == nil)
				or (filter == "stuck" and (mem.StuckTier or 0) >= 1)
				or (IsValid(filter) and filter == npc)
			if showThis then
				local npcPos = npc:GetPos()
				local origin = npcPos + VEC_Z24
				if IsValid(mem.TgtOrNil) then
					debugoverlay.Line(origin, mem.TgtOrNil:WorldSpaceCenter(), 0.3, COL_TARGET_LINE, true)
				end
				if mem.NextNodeOrNil then
					local nextPos = (lib.UsingSourceNav and IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetCenter()) or (istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Pos)
					if nextPos then
						debugoverlay.Line(origin, nextPos + VEC_Z16, 0.3, COL_NEXT_LINE, true)
					end
				end
				local prevPos = origin
				for _, remNode in ipairs(mem.RemainingNodes or {}) do
					local baseRemPos = (lib.UsingSourceNav and IsValid(remNode) and remNode:GetCenter()) or (istable(remNode) and remNode.Pos)
					if baseRemPos then
						local remPos = baseRemPos + VEC_Z16
						debugoverlay.Line(prevPos, remPos, 0.3, COL_PATH_LINE, true)
						prevPos = remPos
					end
				end
				if mem.FailedLinks then
					for fLink, cnt in pairs(mem.FailedLinks) do
						if fLink.Nodes and fLink.Nodes[1] and fLink.Nodes[2] and cnt > 0 then
							debugoverlay.Line(fLink.Nodes[1].Pos + VEC_Z12, fLink.Nodes[2].Pos + VEC_Z12, 0.3, COL_FAILED_LINK, true)
						end
					end
				end
				if mem.BarricadeAttackPos then
					debugoverlay.Cross(mem.BarricadeAttackPos, 10, 0.3, COL_BARRICADE, true)
				end

				local nodeId = (istable(mem.NodeOrNil) and mem.NodeOrNil.Id) or (IsValid(mem.NodeOrNil) and mem.NodeOrNil:GetID()) or "-"
				local nextId = (istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Id) or (IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetID()) or "-"
				local tgtId = (istable(mem.TgtNodeOrNil) and mem.TgtNodeOrNil.Id) or (IsValid(mem.TgtNodeOrNil) and mem.TgtNodeOrNil:GetID()) or "-"
				local stuckInfo = mem.StuckStateName or "OK"
				if (mem.RecoveryAttempts or 0) > 0 and mem.LastRecoveryAction then
					stuckInfo = stuckInfo .. " (" .. mem.LastRecoveryAction .. ")"
				end
				debugoverlay.Text(npcPos + VEC_Z78,
					string.format("%s [%dHP] N:%s->%s (T:%s) | %s",
						npc:GetNPCDisplayName(), npc:Health(), tostring(nodeId), tostring(nextId), tostring(tgtId), stuckInfo),
					0.3, false)
			end
		end
	end
end)
