-- Debug visualization, navmesh inspection & live navigation telemetry for D3bot NPC

local lib = D3botNPC

lib.DebugFilterNPC = lib.DebugFilterNPC or nil -- nil = all nearby NPCs, or Entity / "stuck"

function lib.DebugLog(fmt, ...)
	if not lib.ConVars.Debug or not lib.ConVars.Debug:GetBool() then return end
	MsgC(Color(120, 220, 120), "[D3botNPC Debug] ", Color(230, 230, 230), string.format(fmt, ...) .. "\n")
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

hook.Add("Think", lib.HookId .. ".DebugOverlay", function()
	if not lib.ConVars.Debug or not lib.ConVars.Debug:GetBool() then return end
	local ct = CurTime()
	if ct < nextDebugDraw then return end
	nextDebugDraw = ct + 0.25

	if not debugoverlay then return end

	-- Anchor spatial radius around active players so 2,883-node maps don't overflow debugoverlay
	local viewerPositions = {}
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) then
			viewerPositions[#viewerPositions + 1] = ply:GetPos()
		end
	end

	local function nearAnyViewer(pos, maxDistSqr)
		if #viewerPositions == 0 then return true end
		for _, vp in ipairs(viewerPositions) do
			if pos:DistToSqr(vp) <= maxDistSqr then return true end
		end
		return false
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
					col = Color(255, 70, 70)
				elseif node.RuntimeIsIsolated then
					col = Color(220, 70, 255)
				elseif node.RuntimeIsDeadEnd then
					col = Color(255, 165, 40)
				elseif occ >= 3 then
					col = Color(255, 230, 70)
				else
					col = Color(70, 220, 140)
				end
				debugoverlay.Cross(node.Pos, 8, 0.3, col, true)

				for linked, link in pairs(node.LinkByLinkedNode or {}) do
					if node.Id < linked.Id then
						local linkCol = Color(70, 180, 120)
						if link.RuntimeWorldBlocked then
							linkCol = Color(200, 40, 40)
						elseif link.RuntimeOneWay then
							linkCol = Color(255, 200, 50)
						elseif link.IsRuntimeVirtual then
							linkCol = Color(120, 220, 255)
						end
						debugoverlay.Line(node.Pos + Vector(0, 0, 4), linked.Pos + Vector(0, 0, 4), 0.3, linkCol, true)
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
				local origin = npc:GetPos() + Vector(0, 0, 24)
				if IsValid(mem.TgtOrNil) then
					debugoverlay.Line(origin, mem.TgtOrNil:WorldSpaceCenter(), 0.3, Color(255, 80, 80), true)
				end
				if mem.NextNodeOrNil then
					local nextPos = (lib.UsingSourceNav and IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetCenter()) or (istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Pos)
					if nextPos then
						debugoverlay.Line(origin, nextPos + Vector(0, 0, 16), 0.3, Color(80, 235, 255), true)
					end
				end
				local prevPos = origin
				for _, remNode in ipairs(mem.RemainingNodes or {}) do
					local baseRemPos = (lib.UsingSourceNav and IsValid(remNode) and remNode:GetCenter()) or (istable(remNode) and remNode.Pos)
					if baseRemPos then
						local remPos = baseRemPos + Vector(0, 0, 16)
						debugoverlay.Line(prevPos, remPos, 0.3, Color(80, 150, 255), true)
						prevPos = remPos
					end
				end
				if mem.FailedLinks then
					for fLink, cnt in pairs(mem.FailedLinks) do
						if fLink.Nodes and fLink.Nodes[1] and fLink.Nodes[2] and cnt > 0 then
							debugoverlay.Line(fLink.Nodes[1].Pos + Vector(0, 0, 12), fLink.Nodes[2].Pos + Vector(0, 0, 12), 0.3, Color(255, 110, 30), true)
						end
					end
				end
				if mem.BarricadeAttackPos then
					debugoverlay.Cross(mem.BarricadeAttackPos, 10, 0.3, Color(255, 220, 40), true)
				end

				local nodeId = (istable(mem.NodeOrNil) and mem.NodeOrNil.Id) or (IsValid(mem.NodeOrNil) and mem.NodeOrNil:GetID()) or "-"
				local nextId = (istable(mem.NextNodeOrNil) and mem.NextNodeOrNil.Id) or (IsValid(mem.NextNodeOrNil) and mem.NextNodeOrNil:GetID()) or "-"
				local tgtId = (istable(mem.TgtNodeOrNil) and mem.TgtNodeOrNil.Id) or (IsValid(mem.TgtNodeOrNil) and mem.TgtNodeOrNil:GetID()) or "-"
				local stuckInfo = mem.StuckStateName or "OK"
				if (mem.RecoveryAttempts or 0) > 0 and mem.LastRecoveryAction then
					stuckInfo = stuckInfo .. " (" .. mem.LastRecoveryAction .. ")"
				end
				debugoverlay.Text(npc:GetPos() + Vector(0, 0, 78),
					string.format("%s [%dHP] N:%s->%s (T:%s) | %s",
						npc:GetNPCDisplayName(), npc:Health(), tostring(nodeId), tostring(nextId), tostring(tgtId), stuckInfo),
					0.3, false)
			end
		end
	end
end)
