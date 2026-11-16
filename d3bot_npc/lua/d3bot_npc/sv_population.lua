-- Slotless Population Manager, Admin Console Commands, and Roster Controller for D3bot NPC
-- Spawns & manages persistent virtual bot identities backed by d3bot_npc_zombie entities
-- completely independently of server maxplayers / player.GetAll().

local lib = D3botNPC

lib.Population = lib.Population or {}
local Pop = lib.Population

Pop.NextSpawnCheck = 0
Pop.PendingRespawns = 0
Pop.NextRespawnReadyTime = 0
Pop.ZombiesCountAddition = Pop.ZombiesCountAddition or 0
Pop.ForcedGlobalClass = Pop.ForcedGlobalClass or nil

function Pop.ResetQueue()
	Pop.PendingRespawns = 0
	Pop.NextRespawnReadyTime = 0
	Pop.NextSpawnCheck = CurTime() + 1
end

cvars.AddChangeCallback("d3bot_npc_enabled", function(_, _, newVal)
	Pop.ResetQueue()
	if tonumber(newVal) == 0 and lib.ZS and lib.ZS.RemoveAllNPCs then
		lib.ZS.RemoveAllNPCs(true)
	end
end, "D3botNPC.EnabledPopulationReset")

function Pop.CountLivingHumans()
	if not team or not team.GetPlayers then return 0 end
	local count = 0
	for _, ply in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if IsValid(ply) and ply:Alive() then
			count = count + 1
		end
	end
	return count
end

function Pop.GetNodeBotMod()
	if lib.UsingSourceNav or not lib.MapNavMesh or not lib.MapNavMesh.NodeById then return 0 end
	local bmNodes = lib.MapNavMesh.BotModNodes
	if not bmNodes and lib.MapNavMesh.RebuildParamIndexes then
		lib.MapNavMesh:RebuildParamIndexes()
		bmNodes = lib.MapNavMesh.BotModNodes
	end
	if not bmNodes or #bmNodes == 0 then return 0 end

	local totalMod = 0
	local wave = lib.GetCurrentWave()
	local humans = lib.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN))

	for i = 1, #bmNodes do
		local node = bmNodes[i]
		local botMod = node.Params and tonumber(node.Params.BotMod)
		if botMod and botMod ~= 0 and not lib.IsNavMeshNodeBlocked(node.Params, node.Pos, wave) then
			for j = 1, #humans do
				if node:GetContains(humans[j]:GetPos(), 80) then
					totalMod = totalMod + botMod
					break
				end
			end
		end
	end
	return totalMod
end

function Pop.GetDesiredNPCCount()
	if not lib.ConVars.Enabled:GetBool() then return 0 end

	local maxPop = math.max(0, lib.ConVars.MaxPopulation:GetInt())
	local fixed = lib.ConVars.DesiredZombies:GetInt()
	if fixed > 0 then
		return math.Clamp(fixed + (Pop.ZombiesCountAddition or 0), 0, maxPop)
	end

	local humans = Pop.CountLivingHumans()
	if humans <= 0 then
		return 0
	end

	local wave = math.max(1, lib.GetCurrentWave())
	local mapParams = (lib.MapNavMesh and lib.MapNavMesh.Params) or {}

	local zpp = tonumber(mapParams.ZPP) or lib.ConVars.ZombiesPerHuman:GetFloat()
	local zpw = tonumber(mapParams.ZPW) or lib.ConVars.ZombiesPerWave:GetFloat()
	local zppw = tonumber(mapParams.ZPPW) or lib.ConVars.ZombiesPerHumanWave:GetFloat()
	local zpm = tonumber(mapParams.ZPM) or lib.ConVars.ZombiesMaxPerHuman:GetFloat()
	local zppm = tonumber(mapParams.ZPPM) or 0
	local mapBotMod = tonumber(mapParams.BotMod) or 0

	local raw = humans * zpp + wave * zpw + humans * wave * zppw
	if zpm > 0 then
		raw = math.min(raw, humans * zpm)
	end
	if zppm > 0 then
		raw = math.min(raw, humans * zppm)
	end

	raw = raw + mapBotMod + Pop.GetNodeBotMod() + (Pop.ZombiesCountAddition or 0)
	return math.Clamp(math.Round(raw), 0, maxPop)
end

function Pop.GetUnlockedSpawnPool()
	if not lib.ClassesBuilt then
		lib.RebuildClassConfigs()
	end

	if GAMEMODE then
		if GAMEMODE.ZombieEscape and lib.ClassConfigs["Super Zombie"] then
			return { { Config = lib.ClassConfigs["Super Zombie"], Weight = 1 } }, 1
		end
		if GAMEMODE.IsClassicMode and GAMEMODE:IsClassicMode() and lib.ClassConfigs["Classic Zombie"] then
			return { { Config = lib.ClassConfigs["Classic Zombie"], Weight = 1 } }, 1
		end
		if GAMEMODE.IsBabyMode and GAMEMODE:IsBabyMode() and lib.ClassConfigs["Gore Child"] then
			return { { Config = lib.ClassConfigs["Gore Child"], Weight = 1 } }, 1
		end
		if GAMEMODE.PantsMode and lib.ClassConfigs["Zombie"] then
			return { { Config = lib.ClassConfigs["Zombie"], Weight = 1 } }, 1
		end
	end

	local pool = {}
	local totalWeight = 0

	for name, cfg in pairs(lib.ClassConfigs) do
		if isstring(name) and not cfg.Hidden and not cfg.Boss and not cfg.IsCrow and (cfg.Weight or 0) > 0 then
			if lib.IsNPCClassUnlocked(name) then
				table.insert(pool, { Config = cfg, Weight = cfg.Weight })
				totalWeight = totalWeight + cfg.Weight
			end
		end
	end

	if #pool == 0 or totalWeight <= 0 then
		return { { Config = lib.GetClassConfig("Zombie"), Weight = 1 } }, 1
	end

	return pool, totalWeight
end

function Pop.SelectSpawnClass(forcedClassQuery)
	local query = (forcedClassQuery and forcedClassQuery ~= "" and forcedClassQuery) or Pop.ForcedGlobalClass
	if query and query ~= "" then
		local resolved = lib.ResolveClassName(query)
		if resolved then
			return lib.GetClassConfig(resolved)
		end
	end

	local pool, totalWeight = Pop.GetUnlockedSpawnPool()
	if not totalWeight or totalWeight <= 0 then
		return pool[1].Config
	end

	local roll = math.Rand(0, totalWeight)
	local accum = 0
	for _, entry in ipairs(pool) do
		accum = accum + entry.Weight
		if roll <= accum then
			return entry.Config
		end
	end
	return pool[1].Config
end

function Pop.SpawnNPCForSlot(slot, classNameOrQuery, customPos, customAng)
	if not slot then
		slot = lib.Roster.CreateSlot({ ZombieClass = "Zombie" })
	end
	if slot.Team == (TEAM_SPECTATOR or 1002) then
		return nil
	end

	local classQuery = classNameOrQuery
	if not classQuery or classQuery == "" then
		if slot.IsCrow then
			classQuery = "Crow"
		elseif slot.ForcedClass then
			classQuery = slot.ForcedClass
		end
	end

	local cfg = Pop.SelectSpawnClass(classQuery)
	local spawnPos, spawnAng = customPos, customAng

	if not spawnPos then
		spawnPos, spawnAng = lib.ZS.SelectZombieSpawnPos(cfg)
	end

	if not spawnPos then
		lib.DebugLog("Failed to find valid spawn point for %s (%s)", slot.Name or "NPC", cfg.Name)
		return nil
	end

	if IsValid(slot.Entity) then
		slot.Entity.m_RosterRemoved = true
		lib.UnregisterNPC(slot.Entity)
		slot.Entity:Remove()
	end

	local npc = ents.Create(lib.NPCEntityClass)
	if not IsValid(npc) then
		return nil
	end

	npc:SetPos(spawnPos)
	npc:SetAngles(spawnAng or Angle(0, math.random(-180, 180), 0))
	npc.PendingZombieClass = cfg.Name
	npc.PendingBotName = slot.Name
	npc.PendingRosterSlot = slot
	npc:Spawn()
	npc:Activate()

	if lib.AI and lib.AI.RerollTarget then
		lib.AI.RerollTarget(npc)
		if lib.GetNPCCount(false) > 8 then
			lib.AI.QueuePathUpdate(npc, true)
		else
			lib.AI.UpdatePathImmediate(npc)
		end
	end

	return npc
end

function Pop.SpawnNPC(classNameOrQuery, customPos, customAng, customBotName)
	local cfg = Pop.SelectSpawnClass(classNameOrQuery)
	local slot = lib.Roster.CreateSlot({
		Name = customBotName,
		Team = TEAM_UNDEAD or 3,
		ZombieClass = cfg.Name,
		DeathClass = cfg.IsCrow and "Zombie" or cfg.Name,
		IsCrow = cfg.IsCrow == true
	})

	local npc = Pop.SpawnNPCForSlot(slot, cfg.Name, customPos, customAng)
	if not IsValid(npc) then
		lib.Roster.RemoveSlot(slot)
		return nil
	end
	return npc
end

-- Ensures Roster reflects DesiredNPCCount cleanly (pre-populates scoreboard roster even before Wave 1)
function Pop.EnsureMinimumRoster()
	if not lib.ConVars.Enabled:GetBool() or not lib.ConVars.AutoSpawn:GetBool() then return end
	local maxPop = math.max(0, lib.ConVars.MaxPopulation:GetInt())
	local fixed = lib.ConVars.DesiredZombies:GetInt()
	local targetCount = fixed > 0 and math.Clamp(fixed + (Pop.ZombiesCountAddition or 0), 0, maxPop)
		or math.Clamp(math.Round(math.max(1, Pop.CountLivingHumans()) * lib.ConVars.ZombiesPerHuman:GetFloat()) + (Pop.ZombiesCountAddition or 0), 0, maxPop)

	local curRoster = lib.Roster.CountByTeam(TEAM_UNDEAD or 3)
	while curRoster < targetCount do
		local cfg = Pop.SelectSpawnClass()
		lib.Roster.CreateSlot({
			Team = TEAM_UNDEAD or 3,
			ZombieClass = cfg.Name,
			DeathClass = cfg.Name
		})
		curRoster = curRoster + 1
	end
end

function Pop.SyncPopulationNow()
	if not lib.ConVars.Enabled:GetBool() then return end
	if GAMEMODE and GAMEMODE.RoundEnded then return end

	local wave = lib.GetCurrentWave()
	local isIntermission = (wave > 0 and not lib.GetWaveActive())
	local crowMode = isIntermission and lib.ConVars.IntermissionCrows and lib.ConVars.IntermissionCrows:GetBool()

	if wave == 0 and not lib.ConVars.WaveZeroSpawn:GetBool() then
		return
	end
	if isIntermission and not crowMode then
		return
	end

	Pop.EnsureMinimumRoster()

	local desired = Pop.GetDesiredNPCCount()
	local currentLiving = lib.GetNPCCount(false)
	if currentLiving >= desired then return end

	-- First spawn from ready dead Roster slots
	local idleSlot = lib.Roster.FindIdleRespawnableSlot()
	if idleSlot then
		idleSlot.IsCrow = crowMode
		Pop.SpawnNPCForSlot(idleSlot, crowMode and "Crow" or nil)
		return
	end

	-- Create a fresh slot if Roster has fewer than desired undead bots
	if lib.Roster.CountByTeam(TEAM_UNDEAD or 3) < desired then
		Pop.SpawnNPC(crowMode and "Crow" or nil)
	end
end

-- Find NPC or Roster slot by "#id", name substring, or caller crosshair
function Pop.ResolveTarget(caller, query)
	if (not query or query == "" or string.lower(query) == "aim" or string.lower(query) == "crosshair") and IsValid(caller) and caller:IsPlayer() then
		local tr = caller:GetEyeTrace()
		if IsValid(tr.Entity) and tr.Entity.IsD3botNPC then
			return tr.Entity, tr.Entity.D3bot_RosterSlot
		end
	end

	if query and query ~= "" then
		local slot = lib.Roster.FindSlot(query)
		if slot then
			return slot.Entity, slot
		end
	end

	return nil, nil
end

function Pop.SetGlobalForcedClass(classQuery)
	if not classQuery or classQuery == "" or string.lower(classQuery) == "auto" or string.lower(classQuery) == "reset" or string.lower(classQuery) == "none" then
		Pop.ForcedGlobalClass = nil
		for _, slot in ipairs(lib.Roster.GetAll()) do
			slot.ForcedClass = nil
		end
		return true, "auto"
	end

	local resolved = lib.ResolveClassName(classQuery)
	if not resolved then
		return false, nil
	end

	Pop.ForcedGlobalClass = resolved
	for _, slot in ipairs(lib.Roster.GetAll()) do
		slot.ForcedClass = resolved
		if IsValid(slot.Entity) and slot.Entity:Alive() then
			slot.Entity:ApplyZombieClass(resolved)
		end
	end
	return true, resolved
end

hook.Add("D3botNPC_OnZombieKilled", lib.HookId .. ".QueueRespawn", function()
	if lib.ConVars.Respawn:GetBool() then
		Pop.PendingRespawns = Pop.PendingRespawns + 1
		Pop.NextRespawnReadyTime = math.max(Pop.NextRespawnReadyTime, CurTime() + lib.ConVars.RespawnDelay:GetFloat())
	end
end)

hook.Add("Think", lib.HookId .. ".PopulationThink", function()
	if not lib.ConVars.Enabled:GetBool() or not lib.ConVars.AutoSpawn:GetBool() then return end

	local ct = CurTime()
	if ct < Pop.NextSpawnCheck then return end
	Pop.NextSpawnCheck = ct + math.max(0.25, lib.ConVars.SpawnInterval:GetFloat())

	if GAMEMODE and GAMEMODE.RoundEnded then return end

	local wave = lib.GetCurrentWave()
	local isIntermission = (wave > 0 and not lib.GetWaveActive())
	local crowMode = isIntermission and lib.ConVars.IntermissionCrows and lib.ConVars.IntermissionCrows:GetBool()

	if wave == 0 and not lib.ConVars.WaveZeroSpawn:GetBool() then return end
	if isIntermission and not crowMode then return end
	if not lib.HasNavMesh and not lib.ConVars.AllowNoNavFallback:GetBool() then return end

	local desired = Pop.GetDesiredNPCCount()
	local current = lib.GetNPCCount(false)

	if current < desired then
		local rosterUndead = lib.Roster.CountByTeam(TEAM_UNDEAD or 3)
		-- Only throttle dead slot respawns; brand-new roster deficits still spawn immediately
		if rosterUndead >= desired and Pop.PendingRespawns > 0 and ct < Pop.NextRespawnReadyTime then
			return
		end
		-- Stagger up to 4 spawns per check when ramping large hordes (prevents hitches while filling 100+ queues promptly)
		local deficit = desired - current
		local batch = (deficit > 20) and 4 or ((deficit > 10) and 3 or ((deficit > 4) and 2 or 1))
		for i = 1, batch do
			Pop.SyncPopulationNow()
			if Pop.PendingRespawns > 0 then
				Pop.PendingRespawns = math.max(0, Pop.PendingRespawns - 1)
			end
		end
	end
end)

-- Admin & Server Console Commands
local function hasAdminAccess(ply)
	if not IsValid(ply) then return true end
	return ply:IsAdmin() or ply:IsSuperAdmin()
end

local function reply(ply, msg)
	if IsValid(ply) then
		ply:PrintMessage(HUD_PRINTCONSOLE, "[D3botNPC] " .. msg)
	else
		print("[D3botNPC] " .. msg)
	end
end

local function cmdSpawnHandler(ply, cmd, args)
	if not hasAdminAccess(ply) then return end

	local count = 1
	local classQuery = nil

	if args[1] then
		local asNum = tonumber(args[1])
		if asNum then
			count = math.Clamp(math.floor(asNum), 1, 200)
			classQuery = args[2]
		else
			classQuery = args[1]
			count = math.Clamp(tonumber(args[2]) or 1, 1, 200)
		end
	end

	if classQuery and classQuery ~= "" and not lib.ResolveClassName(classQuery) then
		reply(ply, "Unknown zombie class: " .. tostring(classQuery) .. " (run d3bot_npc_list_classes to inspect available classes).")
		return
	end

	local spawned = 0
	local lastName = "Zombie"
	for i = 1, count do
		local npc = Pop.SpawnNPC(classQuery)
		if IsValid(npc) then
			spawned = spawned + 1
			lastName = npc:GetClassConfig().Name
		end
	end

	reply(ply, string.format("Spawned %d slotless %s NPC(s). Active NPCs: %d | Roster: %d (Connected players: %d/%d).",
		spawned, classQuery and lastName or "weighted zombie", lib.GetNPCCount(false), lib.Roster.CountTotal(), #player.GetAll(), game.MaxPlayers()))
end

concommand.Add("d3bot_npc_spawn", cmdSpawnHandler)
concommand.Add("d3bot_npc_add", cmdSpawnHandler)

concommand.Add("d3bot_npc_spawn_here", function(ply, cmd, args)
	if not IsValid(ply) then
		reply(ply, "This command requires an in-game admin player to trace crosshair position.")
		return
	end
	if not hasAdminAccess(ply) then return end

	local tr = ply:GetEyeTrace()
	local pos = tr.HitPos + tr.HitNormal * 18
	local classQuery = args[1]
	if classQuery and classQuery ~= "" and not lib.ResolveClassName(classQuery) then
		reply(ply, "Unknown zombie class: " .. tostring(classQuery) .. " (run d3bot_npc_list_classes to inspect available classes).")
		return
	end
	local count = math.Clamp(tonumber(args[2]) or 1, 1, 20)

	local spawned = 0
	for i = 1, count do
		local offset = (i == 1) and vector_origin or Vector(math.Rand(-36, 36), math.Rand(-36, 36), 4)
		local npc = Pop.SpawnNPC(classQuery, pos + offset, Angle(0, ply:EyeAngles().y + 180, 0))
		if IsValid(npc) then
			spawned = spawned + 1
		end
	end
	reply(ply, string.format("Spawned %d zombie NPC(s) at crosshair. Active NPCs: %d.", spawned, lib.GetNPCCount(false)))
end)

concommand.Add("d3bot_npc_remove", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local npc, slot = Pop.ResolveTarget(ply, args[1])
	if slot then
		local name = slot.Name
		lib.Roster.RemoveSlot(slot)
		reply(ply, string.format("Removed D3bot NPC '%s'.", name))
	elseif IsValid(npc) then
		local name = npc:GetNPCDisplayName()
		npc:Remove()
		reply(ply, string.format("Removed D3bot NPC '%s'.", name))
	else
		reply(ply, "No matching NPC found (use bot name, #id, or look at an NPC).")
	end
end)

concommand.Add("d3bot_npc_remove_all", function(ply)
	if not hasAdminAccess(ply) then return end
	local count = lib.ZS.RemoveAllNPCs(true)
	Pop.ResetQueue()
	reply(ply, string.format("Removed %d D3bot NPC zombie(s) and cleared virtual roster.", count))
end)

concommand.Add("d3bot_npc_population", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local val = tonumber(args[1])
	if not val then
		reply(ply, string.format("Desired population: %d (0 = dynamic) | BotMod: %+d | Max cap: %d.",
			lib.ConVars.DesiredZombies:GetInt(), Pop.ZombiesCountAddition or 0, lib.ConVars.MaxPopulation:GetInt()))
		return
	end
	val = math.Clamp(math.floor(val), 0, lib.ConVars.MaxPopulation:GetInt())
	RunConsoleCommand("d3bot_npc_desired_zombies", tostring(val))
	reply(ply, string.format("Set d3bot_npc_desired_zombies to %d.", val))
end)

concommand.Add("d3bot_npc_botmod", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local num = tonumber(args[1])
	if not num then
		reply(ply, string.format("Current NPC BotMod addition: %+d", Pop.ZombiesCountAddition or 0))
		return
	end
	local old = Pop.ZombiesCountAddition or 0
	Pop.ZombiesCountAddition = math.Round(num)
	reply(ply, string.format("Zombie NPC count modifier changed from [formula + (%d)] to [formula + (%d)].", old, Pop.ZombiesCountAddition))
end)

concommand.Add("d3bot_npc_setclass", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local targetQuery = args[1]
	local classQuery = args[2]
	if not targetQuery or not classQuery then
		reply(ply, "Usage: d3bot_npc_setclass <name|#id|aim|all> <class>")
		return
	end

	local resolved = lib.ResolveClassName(classQuery)
	if not resolved then
		reply(ply, "Unknown zombie class: " .. tostring(classQuery))
		return
	end

	if string.lower(targetQuery) == "all" then
		local n = 0
		for _, slot in ipairs(lib.Roster.GetAll()) do
			slot.ZombieClass = resolved
			slot.DeathClass = resolved
			if IsValid(slot.Entity) and slot.Entity:Alive() then
				slot.Entity:ApplyZombieClass(resolved)
			end
			n = n + 1
		end
		lib.Roster.ScheduleSync()
		reply(ply, string.format("Changed %d NPC(s) to class '%s'.", n, resolved))
		return
	end

	local npc, slot = Pop.ResolveTarget(ply, targetQuery)
	if IsValid(npc) then
		npc:ApplyZombieClass(resolved)
		reply(ply, string.format("Set NPC '%s' to class '%s'.", npc:GetNPCDisplayName(), resolved))
	elseif slot then
		slot.ZombieClass = resolved
		slot.DeathClass = resolved
		lib.Roster.ScheduleSync()
		reply(ply, string.format("Set roster slot '%s' to class '%s' (next spawn).", slot.Name, resolved))
	else
		reply(ply, "Target NPC not found.")
	end
end)

concommand.Add("d3bot_npc_forceclass", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local query = table.concat(args, " ")
	local ok, resolved = Pop.SetGlobalForcedClass(query)
	if not ok then
		reply(ply, "Unknown zombie class: " .. tostring(query))
		return
	end
	if resolved == "auto" then
		reply(ply, "Cleared forced class; NPCs returned to weighted wave rotation.")
	else
		reply(ply, string.format("Forced all NPC zombies to class '%s'.", resolved))
	end
end)

concommand.Add("d3bot_npc_setname", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local targetQuery = args[1]
	local newName = args[2] and table.concat(args, " ", 2) or nil
	if not targetQuery or not newName then
		reply(ply, "Usage: d3bot_npc_setname <name|#id|aim> <newname>")
		return
	end
	local npc, slot = Pop.ResolveTarget(ply, targetQuery)
	if slot then
		local applied = lib.Roster.RenameSlot(slot, newName)
		reply(ply, applied and ("Renamed NPC to '" .. applied .. "'.") or "Invalid name.")
	elseif IsValid(npc) and npc.SetNPCName then
		local unique = lib.GenerateUniqueBotName(newName)
		npc:SetNPCName(unique)
		reply(ply, "Renamed NPC to '" .. unique .. "'.")
	else
		reply(ply, "Target NPC not found.")
	end
end)

concommand.Add("d3bot_npc_list", function(ply)
	if not hasAdminAccess(ply) then return end
	local slots = lib.Roster.GetAll()
	reply(ply, string.format("Active Virtual NPC Roster (%d slots | %d live entities):", #slots, lib.GetNPCCount(false)))
	for _, s in ipairs(slots) do
		reply(ply, string.format("  #%-2d %-20s | Class: %-16s | Alive: %-5s | Crow: %-5s | Brains: %-2d | Deaths: %d",
			s.BotID, s.Name, s.ZombieClass or "Zombie", tostring(s.IsAlive == true), tostring(s.IsCrow == true), s.Frags or 0, s.Deaths or 0))
	end
end)

concommand.Add("d3bot_npc_spawnboss", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local classQuery = args[1] and table.concat(args, " ") or nil
	local boss = lib.ZS.SpawnOrConvertBossNPC(classQuery)
	if IsValid(boss) then
		reply(ply, string.format("Boss NPC '%s' active as '%s' (%d HP).", boss:GetNPCDisplayName(), boss:GetClassConfig().Name, boss:Health()))
	else
		reply(ply, "Failed to spawn Boss NPC (check spawn points / navmesh).")
	end
end)

concommand.Add("d3bot_npc_startwave", function(ply)
	if not hasAdminAccess(ply) then return end
	if not GAMEMODE or not GAMEMODE.GetWave then
		reply(ply, "JetBoom Zombie Survival GAMEMODE not active.")
		return
	end
	if GAMEMODE:GetWaveActive() then
		reply(ply, "Wave is already active.")
		return
	end
	GAMEMODE:SetWaveStart(CurTime())
	reply(ply, "Started wave countdown immediately.")
end)

concommand.Add("d3bot_npc_resetpaths", function(ply)
	if not hasAdminAccess(ply) then return end
	local n = 0
	for _, npc in ipairs(lib.GetNPCs(false)) do
		if IsValid(npc) and lib.AI then
			lib.AI.RerollTarget(npc)
			lib.AI.UpdatePathImmediate(npc)
			n = n + 1
		end
	end
	reply(ply, string.format("Reset paths and rerolled targets for %d live NPC(s).", n))
end)

concommand.Add("d3bot_npc_autospawn", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local nextVal = args[1] and (tonumber(args[1]) ~= 0 and "1" or "0") or (lib.ConVars.AutoSpawn:GetBool() and "0" or "1")
	RunConsoleCommand("d3bot_npc_auto_spawn", nextVal)
	reply(ply, "d3bot_npc_auto_spawn = " .. nextVal)
end)

concommand.Add("d3bot_npc_debug_toggle", function(ply)
	if not hasAdminAccess(ply) then return end
	local nextVal = lib.ConVars.Debug:GetBool() and "0" or "1"
	RunConsoleCommand("d3bot_npc_debug", nextVal)
	reply(ply, "d3bot_npc_debug = " .. nextVal)
end)

concommand.Add("d3bot_npc_reloadmesh", function(ply)
	if not hasAdminAccess(ply) then return end
	local ok, mode = lib.LoadMapNavMesh(true)
	if lib.ResetNodeBlockCache then lib.ResetNodeBlockCache() end
	reply(ply, ok and ("Reloaded navmesh successfully (" .. mode .. ").") or "No navmesh available for current map.")
end)

concommand.Add("d3bot_npc_list_classes", function(ply)
	if not hasAdminAccess(ply) then return end
	if not lib.ClassesBuilt then lib.RebuildClassConfigs() end
	reply(ply, "Registered ZS / D3bot NPC classes:")
	for name, cfg in SortedPairs(lib.ClassConfigs) do
		if isstring(name) then
			reply(ply, string.format("  - %-18s | HP:%-4d Spd:%-3d Dmg:%-3d Wave:%-2d Boss:%-5s Unlocked:%s",
				cfg.Name, cfg.Health, cfg.RunSpeed, cfg.Damage, cfg.Wave or 0, tostring(cfg.Boss == true), tostring(lib.IsNPCClassUnlocked(cfg.Name))))
		end
	end
end)

concommand.Add("d3bot_npc_status", function(ply)
	if not hasAdminAccess(ply) then return end
	local navType = lib.UsingSourceNav and "Source .nav" or (lib.HasNavMesh and "D3bot custom" or "None (Direct Chase)")
	local nodeCount = (not lib.UsingSourceNav and lib.MapNavMesh and (lib.MapNavMesh.CachedNodeCount or table.Count(lib.MapNavMesh.NodeById or {})))
		or (navmesh and navmesh.GetNavAreaCount and navmesh.GetNavAreaCount()) or 0
	reply(ply, string.format("Version %s | Map: %s | Wave: %d (Active: %s)",
		lib.Version, game.GetMap(), lib.GetCurrentWave(), tostring(lib.GetWaveActive())))
	reply(ply, string.format("Navmesh: %s (%d nodes/areas) | Enabled: %s | AutoSpawn: %s | IntermissionCrows: %s",
		navType, nodeCount, tostring(lib.ConVars.Enabled:GetBool()), tostring(lib.ConVars.AutoSpawn:GetBool()), tostring(lib.ConVars.IntermissionCrows:GetBool())))
	reply(ply, string.format("NPC Zombies: %d live / %d roster / %d desired (cap %d, mod %+d) | Player Slots: %d/%d",
		lib.GetNPCCount(false), lib.Roster.CountTotal(), Pop.GetDesiredNPCCount(), lib.ConVars.MaxPopulation:GetInt(), Pop.ZombiesCountAddition or 0, #player.GetAll(), game.MaxPlayers()))
end)

concommand.Add("d3bot_npc_audit_mesh", function(ply)
	if not hasAdminAccess(ply) then return end
	if lib.UsingSourceNav or not lib.HasNavMesh or not lib.MapNavMesh then
		reply(ply, "No custom D3bot navmesh loaded to audit.")
		return
	end
	local report = lib.AuditNavMesh(lib.MapNavMesh, true)
	if not report then
		reply(ply, "Mesh audit failed (empty navmesh).")
		return
	end
	reply(ply, string.format("Audit for %s: %d nodes, %d links | %d components (main: %d nodes)",
		report.Map, report.NodeCount, report.LinkCount, report.ComponentCount, report.MainComponentSize))
	reply(ply, string.format("  Isolated: %d | Dead-Ends: %d | Uphill-Restricted: %d | High-Drops: %d | Bottlenecks: %d",
		report.IsolatedCount, report.DeadEndCount, report.ImpossibleUpLinkCount, report.HighDropLinkCount, report.BottleneckCount))
	reply(ply, string.format("  Geometry: %d world-blocked links | %d embedded nodes | %d low-ceiling crouch nodes | Virtual bridges added: %d",
		report.WorldBlockedLinks, report.EmbeddedNodes, report.LowCeilingNodes, report.VirtualBridgesAdded))
end)

concommand.Add("d3bot_npc_repair_mesh", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	if lib.UsingSourceNav or not lib.HasNavMesh or not lib.MapNavMesh then
		reply(ply, "No custom D3bot navmesh loaded to repair.")
		return
	end
	local report = lib.AuditNavMesh(lib.MapNavMesh, true)
	if lib.ResetPathCache then lib.ResetPathCache() end
	reply(ply, string.format("Applied runtime mesh repairs: %d virtual bridges, %d uphill one-way restrictions, %d world-blocked penalties.",
		report and report.VirtualBridgesAdded or 0, report and report.ImpossibleUpLinkCount or 0, report and report.WorldBlockedLinks or 0))
	if args[1] and string.lower(args[1]) == "save" and lib.MeshAudit and lib.MeshAudit.ExportSafeRepair then
		local ok, msg = lib.MeshAudit.ExportSafeRepair(lib.MapNavMesh)
		reply(ply, ok and ("Saved safely -> " .. msg) or msg)
	else
		reply(ply, "Pass 'd3bot_npc_repair_mesh save' to write a timestamped backup + sidecar patch without touching the original file.")
	end
end)

concommand.Add("d3bot_npc_inspect_node", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	if lib.UsingSourceNav or not lib.MapNavMesh or not lib.MapNavMesh.NodeById then
		reply(ply, "Node inspection requires a loaded D3bot navmesh.")
		return
	end
	local node = nil
	if args[1] and tonumber(args[1]) then
		node = lib.MapNavMesh.NodeById[tonumber(args[1])]
	elseif IsValid(ply) then
		local tr = ply:GetEyeTrace()
		node = lib.MapNavMesh:GetBestNodeNear(tr.HitPos, { requireLinked = false })
	end
	if not node then
		reply(ply, "No matching node found.")
		return
	end
	local deg = 0
	for _ in pairs(node.LinkByLinkedNode or {}) do deg = deg + 1 end
	reply(ply, string.format("Node #%s @ (%.0f, %.0f, %.0f) | Area:%s | Links:%d | Comp:%s | Occ:%.1f | Isolated:%s DeadEnd:%s Crouch:%s Embedded:%s",
		tostring(node.Id), node.Pos.x, node.Pos.y, node.Pos.z, tostring(node.HasArea == true), deg,
		tostring(node.RuntimeComponentId or "?"), lib.GetNodeCongestionCount and lib.GetNodeCongestionCount(node) or 0,
		tostring(node.RuntimeIsIsolated == true), tostring(node.RuntimeIsDeadEnd == true),
		tostring(node.RuntimeNeedsCrouch == true), tostring(node.RuntimeEmbedded == true)))
end)

concommand.Add("d3bot_npc_debug_npc", function(ply, cmd, args)
	if not hasAdminAccess(ply) then return end
	local query = args[1] and string.lower(args[1]) or "all"
	if query == "all" or query == "clear" or query == "reset" then
		lib.DebugFilterNPC = nil
		reply(ply, "Debug overlay filter cleared (showing all nearby NPCs).")
		return
	end
	if query == "stuck" then
		lib.DebugFilterNPC = "stuck"
		reply(ply, "Debug overlay filter set to STUCK NPCs only.")
		return
	end
	local npc = Pop.ResolveTarget(ply, args[1])
	if IsValid(npc) then
		lib.DebugFilterNPC = npc
		local mem = npc.D3bot_Mem or {}
		reply(ply, string.format("Inspecting %s | State:%s | Recoveries:%d (%s) | Recalcs:%d",
			npc:GetNPCDisplayName(), mem.StuckStateName or "OK", mem.RecoveryAttempts or 0, tostring(mem.LastRecoveryAction or "none"), mem.PathRecalcCount or 0))
	else
		reply(ply, "Target NPC not found (use name, #id, aim, 'stuck', or 'all').")
	end
end)

concommand.Add("d3bot_npc_nav_stats", function(ply)
	if not hasAdminAccess(ply) then return end
	if not lib.GetNavStatsSummary then return end
	local s = lib.GetNavStatsSummary()
	reply(ply, string.format("Nav Stats: %d live NPCs | Queue:%d | Solves:%d (Hits:%d, Fails:%d) | Avg:%.3fms Last:%.3fms | PeakNodeOcc:%.1f",
		s.LiveNPCs, s.QueueDepth, s.Solves, s.CacheHits, s.FailedSolves, s.AvgSolveMs, s.LastSolveMs, s.PeakNodeCongestion))
	reply(ply, string.format("  States -> OK:%d Combat:%d MicroStall:%d ObstacleStall:%d RouteFail:%d Critical:%d",
		s.StuckCounts.OK or 0, s.StuckCounts.COMBAT or 0, s.StuckCounts.MICRO_STALL or 0,
		s.StuckCounts.OBSTACLE_STALL or 0, s.StuckCounts.ROUTE_FAIL or 0, s.StuckCounts.CRITICAL_TRAP or 0))
end)
