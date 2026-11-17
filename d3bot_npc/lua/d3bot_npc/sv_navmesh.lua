-- Server navmesh loader & Source .nav fallback for D3bot NPC
-- Reads directly from D3bot's existing map navmesh directory:
--   garrysmod/data/d3bot/navmesh/map/<mapname>.txt
--   garrysmod/data/d3bot/navmesh/map/<mapname>.params.txt

local lib = D3botNPC

lib.MapNavMesh = lib.MapNavMesh or lib.NewNavMesh()
lib.UsingSourceNav = false
lib.HasNavMesh = false

function lib.DesiredNavmeshType()
	local mapName = game.GetMap()
	local d3botPath = "d3bot/navmesh/map/" .. mapName .. ".txt"
	local hasD3bot = file.Exists(d3botPath, "DATA")
	local useSource = lib.ConVars.UseSourceNav and lib.ConVars.UseSourceNav:GetBool()
	local sourceOverride = lib.ConVars.SourceNavOverride and lib.ConVars.SourceNavOverride:GetBool()
	local hasSource = navmesh and navmesh.IsLoaded and navmesh.IsLoaded()

	if sourceOverride and hasSource then
		return "source"
	end
	if hasD3bot then
		return "d3bot"
	end
	if useSource and hasSource then
		return "source"
	end
	return "none"
end

function lib.GetNavMeshPath(mapName)
	mapName = mapName or game.GetMap()
	return "d3bot/navmesh/map/" .. mapName .. ".txt", "d3bot/navmesh/map/" .. mapName .. ".params.txt"
end

function lib.LoadMapNavMesh(forceSourceReload)
	local mapName = game.GetMap()
	local meshPath, paramsPath = lib.GetNavMeshPath(mapName)

	lib.UsingSourceNav = false
	lib.HasNavMesh = false
	lib.MapNavMesh = lib.NewNavMesh()

	local useSource = lib.ConVars.UseSourceNav and lib.ConVars.UseSourceNav:GetBool()
	local sourceOverride = lib.ConVars.SourceNavOverride and lib.ConVars.SourceNavOverride:GetBool()
	local hasD3botFile = file.Exists(meshPath, "DATA")

	if (sourceOverride or (useSource and not hasD3botFile)) and navmesh and (forceSourceReload or not navmesh.IsLoaded()) then
		navmesh.Load()
	end

	local desired = lib.DesiredNavmeshType()

	if desired == "d3bot" and hasD3botFile then
		local rawMesh = file.Read(meshPath, "DATA")
		local parsed = lib.DeserializeNavMesh(rawMesh)
		if file.Exists(paramsPath, "DATA") then
			parsed:DeserializeNavMeshParams(file.Read(paramsPath, "DATA"))
		end
		parsed:InvalidateCache()

		local patchCount = (lib.MeshAudit and lib.MeshAudit.LoadSidecarPatch) and lib.MeshAudit.LoadSidecarPatch(parsed, mapName) or 0
		lib.MapNavMesh = parsed
		lib.UsingSourceNav = false
		lib.HasNavMesh = next(parsed.NodeById) ~= nil

		local auditReport = nil
		if lib.HasNavMesh and lib.AuditNavMesh and (not lib.ConVars.AutoAuditMesh or lib.ConVars.AutoAuditMesh:GetBool()) then
			auditReport = lib.AuditNavMesh(parsed, false)
		end

		MsgC(
			Color(120, 220, 120), "[D3botNPC] ",
			Color(255, 255, 255),
			string.format("Loaded D3bot navmesh for %s (%d nodes, %d links%s).\n",
				mapName,
				table.Count(parsed.NodeById),
				table.Count(parsed.LinkById),
				patchCount > 0 and (", " .. patchCount .. " sidecar patches") or "")
		)
		if auditReport then
			MsgC(
				Color(120, 220, 120), "[D3botNPC] ",
				Color(220, 220, 220),
				string.format("Mesh audit: %d components (main %d nodes), %d isolated, %d dead-ends, %d uphill-restricted, %d virtual bridges (%.1fms).\n",
					auditReport.ComponentCount, auditReport.MainComponentSize, auditReport.IsolatedCount,
					auditReport.DeadEndCount, auditReport.ImpossibleUpLinkCount, auditReport.VirtualBridgesAdded, auditReport.TopologyMs)
			)
		end
		return true, "d3bot"
	elseif desired == "source" and navmesh and navmesh.IsLoaded() then
		lib.UsingSourceNav = true
		lib.HasNavMesh = navmesh.GetNavAreaCount() > 0
		if lib.SetupSourceNavLinks then
			lib.SetupSourceNavLinks()
		end
		MsgC(
			Color(120, 220, 120), "[D3botNPC] ",
			Color(255, 255, 255),
			string.format("Using Source .nav mesh fallback for %s (%d nav areas).\n",
				mapName, navmesh.GetNavAreaCount())
		)
		return true, "source"
	end

	-- Also check if D3bot itself is running and already loaded an in-memory navmesh
	if D3bot and D3bot.MapNavMesh and next(D3bot.MapNavMesh.NodeById or {}) ~= nil then
		lib.MapNavMesh = D3bot.MapNavMesh
		if lib.MeshAudit and lib.MeshAudit.LoadSidecarPatch then
			lib.MeshAudit.LoadSidecarPatch(lib.MapNavMesh, mapName)
		end
		if lib.MapNavMesh.RebuildParamIndexes then
			lib.MapNavMesh:RebuildParamIndexes()
		end
		if lib.MapNavMesh.RebuildSpatialGrid then
			lib.MapNavMesh:RebuildSpatialGrid()
		end
		lib.UsingSourceNav = false
		lib.HasNavMesh = true
		if lib.AuditNavMesh and (not lib.ConVars.AutoAuditMesh or lib.ConVars.AutoAuditMesh:GetBool()) then
			lib.AuditNavMesh(lib.MapNavMesh, false)
		end
		MsgC(
			Color(120, 220, 120), "[D3botNPC] ",
			Color(255, 255, 255),
			string.format("Bound to live D3bot.MapNavMesh for %s (%d nodes).\n",
				mapName, table.Count(D3bot.MapNavMesh.NodeById))
		)
		return true, "d3bot_live"
	end

	MsgC(
		Color(255, 200, 90), "[D3botNPC] ",
		Color(255, 255, 255),
		string.format("No D3bot or Source navmesh found for %s. NPCs will use direct chase fallback if enabled.\n", mapName)
	)
	return false, "none"
end

hook.Add("InitPostEntity", lib.HookId .. ".LoadNavMesh", function()
	timer.Simple(0.15, function()
		lib.LoadMapNavMesh(false)
	end)
end)
