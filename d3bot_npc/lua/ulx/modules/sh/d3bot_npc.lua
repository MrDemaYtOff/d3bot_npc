-- ULX & ULib Integration Module for D3bot NPC
-- Automatically discovered by ULX/ULib in lua/ulx/modules/sh/.
-- Safely no-ops if ULX or ULib is not installed; uses unique `ulx d3botnpc_*` namespace
-- so it never conflicts with original D3bot (`ulx d3bot*`) commands.

if not ulx or not ULib or not ulx.command then return end

local CATEGORY_NAME = "D3bot NPC"

local function replyCaller(caller, msg)
	if IsValid(caller) then
		ULib.tsayColor(caller, false, Color(120, 220, 120), "[D3botNPC] ", Color(255, 255, 255), msg)
	else
		print("[D3botNPC] " .. msg)
	end
end

local function ensureReady(caller)
	if not D3botNPC then
		replyCaller(caller, "D3botNPC core library is not loaded.")
		return false
	end
	return true
end

local function registerNPCCommand(cmdSuffix, func, chatCmd, defaultAccess, helpText, params)
	local fullCmd = "ulx " .. cmdSuffix
	ulx[cmdSuffix] = func

	local cmd = ulx.command(CATEGORY_NAME, fullCmd, func, chatCmd)
	if params then
		for _, param in ipairs(params) do
			cmd:addParam(param)
		end
	end
	cmd:defaultAccess(defaultAccess or ULib.ACCESS_ADMIN)
	if helpText then
		cmd:help(helpText)
	end
	return cmd
end

-- 1. Spawn / Add NPCs
local function ulxSpawnNPCs(calling_ply, count, classQuery)
	if not ensureReady(calling_ply) then return end
	count = math.Clamp(math.floor(tonumber(count) or 1), 1, 200)
	classQuery = (classQuery and classQuery ~= "") and classQuery or nil
	if classQuery and not D3botNPC.ResolveClassName(classQuery) then
		replyCaller(calling_ply, "Unknown zombie class: " .. tostring(classQuery))
		return
	end

	local spawned = 0
	local resolvedName = "Weighted Zombie"
	local crowMode = D3botNPC.ZS and D3botNPC.ZS.ShouldNPCsBeCrows and D3botNPC.ZS.ShouldNPCsBeCrows()
	for i = 1, count do
		local npc = D3botNPC.Population.SpawnNPC(classQuery)
		if IsValid(npc) then
			spawned = spawned + 1
			resolvedName = npc:GetClassConfig().Name
		end
	end

	local label = crowMode and ("Crow (queued: " .. (classQuery or "Weighted") .. ")") or (classQuery and resolvedName or "Weighted Rotation")
	ulx.fancyLogAdmin(calling_ply, "#A spawned #i slotless D3bot NPC(s) (#s)", spawned, label)
end

registerNPCCommand("d3botnpc_add", ulxSpawnNPCs, "!d3botnpc_add", ULib.ACCESS_ADMIN,
	"Spawns slotless D3bot zombie NPC(s) without consuming player slots.", {
		{ type = ULib.cmds.NumArg, min = 1, max = 200, default = 1, hint = "count", ULib.cmds.optional, ULib.cmds.round },
		{ type = ULib.cmds.StringArg, default = "", hint = "class (optional)", ULib.cmds.optional, ULib.cmds.takeRestOfLine }
	})

registerNPCCommand("d3botnpc_spawn", ulxSpawnNPCs, "!d3botnpc_spawn", ULib.ACCESS_ADMIN,
	"Alias for d3botnpc_add: spawns slotless D3bot zombie NPC(s) at zombie spawn points.", {
		{ type = ULib.cmds.NumArg, min = 1, max = 200, default = 1, hint = "count", ULib.cmds.optional, ULib.cmds.round },
		{ type = ULib.cmds.StringArg, default = "", hint = "class (optional)", ULib.cmds.optional, ULib.cmds.takeRestOfLine }
	})

-- 2. Spawn Specific Class
registerNPCCommand("d3botnpc_spawnclass", function(calling_ply, classQuery, count)
	if not ensureReady(calling_ply) then return end
	local resolved = D3botNPC.ResolveClassName(classQuery)
	if not resolved then
		replyCaller(calling_ply, "Unknown zombie class: " .. tostring(classQuery))
		return
	end
	count = math.Clamp(math.floor(tonumber(count) or 1), 1, 64)
	local spawned = 0
	for i = 1, count do
		local npc = D3botNPC.Population.SpawnNPC(resolved)
		if IsValid(npc) then spawned = spawned + 1 end
	end
	ulx.fancyLogAdmin(calling_ply, "#A spawned #i #s D3bot NPC(s)", spawned, resolved)
end, "!d3botnpc_spawnclass", ULib.ACCESS_ADMIN,
	"Spawns N D3bot NPCs of a specific ZS zombie or boss class.", {
		{ type = ULib.cmds.StringArg, hint = "zombie class" },
		{ type = ULib.cmds.NumArg, min = 1, max = 64, default = 1, hint = "count", ULib.cmds.optional, ULib.cmds.round }
	})

-- 3. Spawn at Crosshair
registerNPCCommand("d3botnpc_spawnhere", function(calling_ply, count, classQuery)
	if not ensureReady(calling_ply) then return end
	if not IsValid(calling_ply) then
		replyCaller(calling_ply, "d3botnpc_spawnhere requires an in-game admin to trace crosshair.")
		return
	end
	local tr = calling_ply:GetEyeTrace()
	local pos = tr.HitPos + tr.HitNormal * 18
	count = math.Clamp(math.floor(tonumber(count) or 1), 1, 20)
	classQuery = (classQuery and classQuery ~= "") and classQuery or nil
	if classQuery and not D3botNPC.ResolveClassName(classQuery) then
		replyCaller(calling_ply, "Unknown zombie class: " .. tostring(classQuery))
		return
	end

	local spawned = 0
	local lastClass = "Weighted Zombie"
	for i = 1, count do
		local offset = (i == 1) and vector_origin or Vector(math.Rand(-36, 36), math.Rand(-36, 36), 4)
		local npc = D3botNPC.Population.SpawnNPC(classQuery, pos + offset, Angle(0, calling_ply:EyeAngles().y + 180, 0))
		if IsValid(npc) then
			spawned = spawned + 1
			lastClass = npc:GetClassConfig().Name
		end
	end
	ulx.fancyLogAdmin(calling_ply, "#A spawned #i D3bot NPC(s) (#s) at crosshair", spawned, classQuery and lastClass or "Weighted")
end, "!d3botnpc_spawnhere", ULib.ACCESS_ADMIN,
	"Spawns D3bot zombie NPC(s) at the caller's crosshair.", {
		{ type = ULib.cmds.NumArg, min = 1, max = 20, default = 1, hint = "count", ULib.cmds.optional, ULib.cmds.round },
		{ type = ULib.cmds.StringArg, default = "", hint = "class (optional)", ULib.cmds.optional, ULib.cmds.takeRestOfLine }
	})

-- 4. Spawn Boss NPC
registerNPCCommand("d3botnpc_spawnboss", function(calling_ply, classQuery)
	if not ensureReady(calling_ply) then return end
	classQuery = (classQuery and classQuery ~= "") and classQuery or nil
	local boss = D3botNPC.ZS.SpawnOrConvertBossNPC(classQuery)
	if not IsValid(boss) then
		replyCaller(calling_ply, "Failed to spawn Boss NPC.")
		return
	end
	ulx.fancyLogAdmin(calling_ply, "#A spawned Boss NPC #s as #s", boss:GetNPCDisplayName(), boss:GetClassConfig().Name)
end, "!d3botnpc_spawnboss", ULib.ACCESS_ADMIN,
	"Spawns or promotes a D3bot NPC into a ZS Boss Zombie.", {
		{ type = ULib.cmds.StringArg, default = "", hint = "boss class (optional)", ULib.cmds.optional, ULib.cmds.takeRestOfLine }
	})

-- 5. Remove NPC / Remove All
registerNPCCommand("d3botnpc_remove", function(calling_ply, targetQuery)
	if not ensureReady(calling_ply) then return end
	local npc, slot = D3botNPC.Population.ResolveTarget(calling_ply, targetQuery)
	if slot then
		local name = slot.Name
		D3botNPC.Roster.RemoveSlot(slot)
		ulx.fancyLogAdmin(calling_ply, "#A removed D3bot NPC #s", name)
	elseif IsValid(npc) then
		local name = npc:GetNPCDisplayName()
		npc:Remove()
		ulx.fancyLogAdmin(calling_ply, "#A removed D3bot NPC #s", name)
	else
		replyCaller(calling_ply, "No matching D3bot NPC found (pass Bot Name, #BotID, or 'aim').")
	end
end, "!d3botnpc_remove", ULib.ACCESS_ADMIN,
	"Removes a D3bot NPC by name, #BotID, or crosshair ('aim').", {
		{ type = ULib.cmds.StringArg, default = "aim", hint = "name, #id, or aim", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_removeall", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	local count = D3botNPC.ZS.RemoveAllNPCs(true)
	D3botNPC.Population.ResetQueue()
	ulx.fancyLogAdmin(calling_ply, "#A removed all #i D3bot NPC zombie(s)", count)
end, "!d3botnpc_removeall", ULib.ACCESS_ADMIN,
	"Removes all D3bot NPCs and clears the virtual NPC roster.")

-- 6. Respawn NPC(s)
registerNPCCommand("d3botnpc_respawn", function(calling_ply, targetQuery)
	if not ensureReady(calling_ply) then return end
	if not targetQuery or targetQuery == "" or string.lower(targetQuery) == "all" then
		local count = 0
		for _, slot in ipairs(D3botNPC.Roster.GetAll()) do
			if slot.Team == (TEAM_UNDEAD or 3) then
				local npc = D3botNPC.Population.SpawnNPCForSlot(slot)
				if IsValid(npc) then count = count + 1 end
			end
		end
		ulx.fancyLogAdmin(calling_ply, "#A respawned #i D3bot NPC(s)", count)
		return
	end

	local _, slot = D3botNPC.Population.ResolveTarget(calling_ply, targetQuery)
	if slot then
		local npc = D3botNPC.Population.SpawnNPCForSlot(slot)
		if IsValid(npc) then
			ulx.fancyLogAdmin(calling_ply, "#A respawned D3bot NPC #s", slot.Name)
		else
			replyCaller(calling_ply, "Could not find a valid spawn point for " .. slot.Name)
		end
	else
		replyCaller(calling_ply, "Target NPC not found.")
	end
end, "!d3botnpc_respawn", ULib.ACCESS_ADMIN,
	"Respawns a specific D3bot NPC or all rostered NPCs.", {
		{ type = ULib.cmds.StringArg, default = "all", hint = "name, #id, aim, or all", ULib.cmds.optional }
	})

-- 7. Population & Scaling (matches D3bot ULX botmod parity)
registerNPCCommand("d3botnpc_count", function(calling_ply, count)
	if not ensureReady(calling_ply) then return end
	count = math.Clamp(math.floor(count), 0, D3botNPC.ConVars.MaxPopulation:GetInt())
	RunConsoleCommand("d3bot_npc_desired_zombies", tostring(count))
	ulx.fancyLogAdmin(calling_ply, "#A set fixed D3bot NPC count to #i (0 = dynamic formula)", count)
end, "!d3botnpc_count", ULib.ACCESS_ADMIN,
	"Sets fixed desired zombie NPC count (0 = dynamic wave/human scaling).", {
		{ type = ULib.cmds.NumArg, min = 0, max = 200, default = 0, hint = "desired count", ULib.cmds.round }
	})

registerNPCCommand("d3botnpc_botmod", function(calling_ply, mod)
	if not ensureReady(calling_ply) then return end
	mod = math.Round(mod)
	D3botNPC.Population.ZombiesCountAddition = mod
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC count modifier to [formula + (#i)]", mod)
end, "!d3botnpc_botmod", ULib.ACCESS_ADMIN,
	"Modifies dynamic NPC count formula by a flat offset (parity with D3bot !botmod).", {
		{ type = ULib.cmds.NumArg, min = -64, max = 64, default = 0, hint = "modifier", ULib.cmds.round }
	})

registerNPCCommand("d3botnpc_zombiesperplayer", function(calling_ply, val)
	if not ensureReady(calling_ply) then return end
	val = math.Clamp(val, 0, 32)
	RunConsoleCommand("d3bot_npc_zombies_per_human", tostring(val))
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC zombies per human to #s", string.format("%.2f", val))
end, "!d3botnpc_zombiesperplayer", ULib.ACCESS_ADMIN,
	"Sets dynamic formula zombie NPCs per living human.", {
		{ type = ULib.cmds.NumArg, min = 0, max = 32, default = 4, hint = "ratio" }
	})

registerNPCCommand("d3botnpc_maxpopulation", function(calling_ply, val)
	if not ensureReady(calling_ply) then return end
	val = math.Clamp(math.floor(val), 1, 200)
	RunConsoleCommand("d3bot_npc_max_population", tostring(val))
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC max population cap to #i", val)
end, "!d3botnpc_maxpopulation", ULib.ACCESS_SUPERADMIN,
	"Sets hard cap on simultaneous D3bot NPC zombies.", {
		{ type = ULib.cmds.NumArg, min = 1, max = 200, default = 32, hint = "max cap", ULib.cmds.round }
	})

registerNPCCommand("d3botnpc_autospawn", function(calling_ply, state)
	if not ensureReady(calling_ply) then return end
	local enabled
	if state == "" then
		enabled = not D3botNPC.ConVars.AutoSpawn:GetBool()
	else
		enabled = (tonumber(state) or 0) ~= 0 or string.lower(state) == "true" or string.lower(state) == "on"
	end
	RunConsoleCommand("d3bot_npc_auto_spawn", enabled and "1" or "0")
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC auto-spawn to #s", enabled and "ON" or "OFF")
end, "!d3botnpc_autospawn", ULib.ACCESS_ADMIN,
	"Enables or disables automatic wave-aware D3bot NPC spawning.", {
		{ type = ULib.cmds.StringArg, default = "", hint = "0/1 (blank toggles)", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_enabled", function(calling_ply, state)
	if not ensureReady(calling_ply) then return end
	local enabled
	if state == "" then
		enabled = not D3botNPC.ConVars.Enabled:GetBool()
	else
		enabled = (tonumber(state) or 0) ~= 0 or string.lower(state) == "true" or string.lower(state) == "on"
	end
	RunConsoleCommand("d3bot_npc_enabled", enabled and "1" or "0")
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC system to #s", enabled and "ENABLED" or "DISABLED")
end, "!d3botnpc_enabled", ULib.ACCESS_SUPERADMIN,
	"Master toggle for the entire D3bot NPC system.", {
		{ type = ULib.cmds.StringArg, default = "", hint = "0/1 (blank toggles)", ULib.cmds.optional }
	})

-- 8. Class, Name & Team Management
registerNPCCommand("d3botnpc_setclass", function(calling_ply, targetQuery, classQuery)
	if not ensureReady(calling_ply) then return end
	local resolved = D3botNPC.ResolveClassName(classQuery)
	if not resolved then
		replyCaller(calling_ply, "Unknown zombie class: " .. tostring(classQuery))
		return
	end

	local shouldBeCrow = D3botNPC.ZS and D3botNPC.ZS.ShouldNPCsBeCrows and D3botNPC.ZS.ShouldNPCsBeCrows()
	if string.lower(targetQuery) == "all" then
		for _, slot in ipairs(D3botNPC.Roster.GetAll()) do
			slot.DeathClass = (resolved ~= "Crow") and resolved or (slot.DeathClass or "Zombie")
			slot.ZombieClass = (shouldBeCrow and resolved ~= "Crow") and "Crow" or resolved
			if IsValid(slot.Entity) and slot.Entity:Alive() then
				if shouldBeCrow and resolved ~= "Crow" then
					slot.Entity.m_NonCrowClass = resolved
				else
					slot.Entity:ApplyZombieClass(resolved)
				end
			end
		end
		D3botNPC.Roster.ScheduleSync()
		ulx.fancyLogAdmin(calling_ply, "#A switched all D3bot NPCs to class #s", resolved)
		return
	end

	local npc, slot = D3botNPC.Population.ResolveTarget(calling_ply, targetQuery)
	if IsValid(npc) then
		if shouldBeCrow and resolved ~= "Crow" then
			npc.m_NonCrowClass = resolved
			if slot then slot.DeathClass = resolved end
			ulx.fancyLogAdmin(calling_ply, "#A queued D3bot NPC #s next class #s (Crow phase)", npc:GetNPCDisplayName(), resolved)
		else
			npc:ApplyZombieClass(resolved)
			ulx.fancyLogAdmin(calling_ply, "#A switched D3bot NPC #s to class #s", npc:GetNPCDisplayName(), resolved)
		end
	elseif slot then
		slot.DeathClass = (resolved ~= "Crow") and resolved or (slot.DeathClass or "Zombie")
		slot.ZombieClass = (shouldBeCrow and resolved ~= "Crow") and "Crow" or resolved
		D3botNPC.Roster.ScheduleSync()
		ulx.fancyLogAdmin(calling_ply, "#A switched D3bot NPC #s to class #s", slot.Name, resolved)
	else
		replyCaller(calling_ply, "Target NPC not found.")
	end
end, "!d3botnpc_setclass", ULib.ACCESS_ADMIN,
	"Changes a D3bot NPC (or 'all') to the given ZS zombie class.", {
		{ type = ULib.cmds.StringArg, hint = "name, #id, aim, or all" },
		{ type = ULib.cmds.StringArg, hint = "zombie class", ULib.cmds.takeRestOfLine }
	})

registerNPCCommand("d3botnpc_forceclass", function(calling_ply, classQuery)
	if not ensureReady(calling_ply) then return end
	local ok, resolved = D3botNPC.Population.SetGlobalForcedClass(classQuery)
	if not ok then
		replyCaller(calling_ply, "Unknown zombie class: " .. tostring(classQuery))
		return
	end
	if resolved == "auto" then
		ulx.fancyLogAdmin(calling_ply, "#A cleared D3bot NPC forced class (returned to dynamic rotation)")
	else
		ulx.fancyLogAdmin(calling_ply, "#A forced all D3bot NPCs to class #s", resolved)
	end
end, "!d3botnpc_forceclass", ULib.ACCESS_ADMIN,
	"Forces all current and future D3bot NPCs to a single class (pass 'auto' to reset).", {
		{ type = ULib.cmds.StringArg, default = "auto", hint = "class or auto", ULib.cmds.takeRestOfLine }
	})

registerNPCCommand("d3botnpc_setname", function(calling_ply, targetQuery, newName)
	if not ensureReady(calling_ply) then return end
	local npc, slot = D3botNPC.Population.ResolveTarget(calling_ply, targetQuery)
	if slot then
		local applied = D3botNPC.Roster.RenameSlot(slot, newName)
		ulx.fancyLogAdmin(calling_ply, "#A renamed D3bot NPC to #s", applied)
	elseif IsValid(npc) and npc.SetNPCName then
		local unique = D3botNPC.GenerateUniqueBotName(newName)
		npc:SetNPCName(unique)
		ulx.fancyLogAdmin(calling_ply, "#A renamed D3bot NPC to #s", unique)
	else
		replyCaller(calling_ply, "Target NPC not found.")
	end
end, "!d3botnpc_setname", ULib.ACCESS_ADMIN,
	"Renames a D3bot NPC on the scoreboard, TargetID, and killfeed.", {
		{ type = ULib.cmds.StringArg, hint = "name, #id, or aim" },
		{ type = ULib.cmds.StringArg, hint = "new name", ULib.cmds.takeRestOfLine }
	})

registerNPCCommand("d3botnpc_setteam", function(calling_ply, targetQuery, teamQuery)
	if not ensureReady(calling_ply) then return end
	local npc, slot = D3botNPC.Population.ResolveTarget(calling_ply, targetQuery)
	if not slot then
		replyCaller(calling_ply, "Target NPC not found.")
		return
	end

	local tLower = string.lower(teamQuery or "")
	if tLower == "crow" then
		slot.Team = TEAM_UNDEAD or 3
		slot.IsCrow = true
		if IsValid(slot.Entity) and slot.Entity:Alive() then
			slot.Entity:MorphToCrow()
		else
			D3botNPC.Population.SpawnNPCForSlot(slot, "Crow")
		end
		D3botNPC.Roster.ScheduleSync()
		ulx.fancyLogAdmin(calling_ply, "#A turned D3bot NPC #s into Crow", slot.Name)
	elseif tLower == "undead" or tLower == "zombie" or tLower == "3" then
		slot.Team = TEAM_UNDEAD or 3
		slot.IsCrow = false
		if IsValid(slot.Entity) and slot.Entity:Alive() then
			slot.Entity:RestoreFromCrow()
		else
			D3botNPC.Population.SpawnNPCForSlot(slot)
		end
		D3botNPC.Roster.ScheduleSync()
		ulx.fancyLogAdmin(calling_ply, "#A assigned D3bot NPC #s to Undead", slot.Name)
	elseif tLower == "spectator" or tLower == "spec" then
		slot.Team = TEAM_SPECTATOR or 1002
		slot.IsCrow = false
		if IsValid(slot.Entity) then
			slot.Entity.m_RosterRemoved = true
			D3botNPC.UnregisterNPC(slot.Entity)
			slot.Entity:Remove()
			slot.Entity = NULL
		end
		D3botNPC.Roster.ScheduleSync()
		ulx.fancyLogAdmin(calling_ply, "#A moved D3bot NPC #s to Spectator (dormant)", slot.Name)
	else
		replyCaller(calling_ply, "Supported NPC team states: 'undead', 'crow', or 'spectator' (human survivors are real player slots only).")
	end
end, "!d3botnpc_setteam", ULib.ACCESS_ADMIN,
	"Changes a D3bot NPC's active team state (undead, crow, spectator).", {
		{ type = ULib.cmds.StringArg, hint = "name, #id, or aim" },
		{ type = ULib.cmds.StringArg, hint = "undead | crow | spectator" }
	})

-- 9. Inspection, Wave Control, Navmesh & Debug
registerNPCCommand("d3botnpc_list", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	local slots = D3botNPC.Roster.GetAll()
	replyCaller(calling_ply, string.format("Virtual Roster: %d slot(s), %d live entity(s)", #slots, D3botNPC.GetNPCCount(false)))
	for _, s in ipairs(slots) do
		local line = string.format("#%d %s | %s | Alive:%s | Brains:%d Deaths:%d",
			s.BotID, s.Name, s.IsCrow and "Crow" or (s.ZombieClass or "Zombie"), tostring(s.IsAlive == true), s.Frags or 0, s.Deaths or 0)
		if IsValid(calling_ply) then
			calling_ply:PrintMessage(HUD_PRINTCONSOLE, "  " .. line)
		else
			print("  " .. line)
		end
	end
end, "!d3botnpc_list", ULib.ACCESS_ADMIN,
	"Prints all active D3bot NPCs (ID, Name, Class, Brains, Deaths) to console.")

registerNPCCommand("d3botnpc_status", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	local navType = D3botNPC.UsingSourceNav and "Source .nav" or (D3botNPC.HasNavMesh and "D3bot custom" or "None (Direct Chase)")
	local lifecycle = (D3botNPC.ZS and D3botNPC.ZS.GetRoundLifecycleState and D3botNPC.ZS.GetRoundLifecycleState()) or "UNKNOWN"
	replyCaller(calling_ply, string.format("v%s | Map: %s | Wave: %d (%s) | Nav: %s | NPCs: %d live / %d roster / %d desired (cap %d) | Real Slots: %d/%d",
		D3botNPC.Version or "3.1.0",
		game.GetMap(),
		D3botNPC.GetCurrentWave(),
		lifecycle,
		navType,
		D3botNPC.GetNPCCount(false),
		D3botNPC.Roster.CountTotal(),
		D3botNPC.Population.GetDesiredNPCCount(),
		D3botNPC.ConVars.MaxPopulation:GetInt(),
		#player.GetAll(),
		game.MaxPlayers()))
end, "!d3botnpc_status", ULib.ACCESS_ADMIN,
	"Shows D3bot NPC version, navmesh mode, wave lifecycle state, and slotless population counts.")

registerNPCCommand("d3botnpc_startwave", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	if not D3botNPC.IsZombieSurvivalReady() then
		replyCaller(calling_ply, "Zombie Survival GAMEMODE not found.")
		return
	end
	if GAMEMODE:GetWaveActive() then
		replyCaller(calling_ply, "Wave is already active.")
		return
	end
	GAMEMODE:SetWaveStart(CurTime())
	ulx.fancyLogAdmin(calling_ply, "#A started the ZS wave countdown immediately")
end, "!d3botnpc_startwave", ULib.ACCESS_ADMIN,
	"Immediately ends Wave 0 / intermission waiting timer so the next wave begins.")

registerNPCCommand("d3botnpc_intermissioncrows", function(calling_ply, state)
	if not ensureReady(calling_ply) then return end
	local enabled
	if state == "" then
		enabled = not D3botNPC.ConVars.IntermissionCrows:GetBool()
	else
		enabled = (tonumber(state) or 0) ~= 0 or string.lower(state) == "true" or string.lower(state) == "on"
	end
	RunConsoleCommand("d3bot_npc_intermission_crows", enabled and "1" or "0")
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC intermission crows to #s", enabled and "ON" or "OFF")
end, "!d3botnpc_intermissioncrows", ULib.ACCESS_ADMIN,
	"Toggles transforming NPC zombies into Crows during wave intermissions.", {
		{ type = ULib.cmds.StringArg, default = "", hint = "0/1 (blank toggles)", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_reloadmesh", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	local ok, mode = D3botNPC.LoadMapNavMesh(true)
	if D3botNPC.ResetNodeBlockCache then D3botNPC.ResetNodeBlockCache() end
	if ok then
		ulx.fancyLogAdmin(calling_ply, "#A reloaded D3bot NPC navmesh (#s)", mode)
	else
		replyCaller(calling_ply, "No D3bot or Source navmesh available for " .. game.GetMap())
	end
end, "!d3botnpc_reloadmesh", ULib.ACCESS_SUPERADMIN,
	"Reloads D3bot / Source navmesh for the current map.")

registerNPCCommand("d3botnpc_resetpaths", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	local n = 0
	for _, npc in ipairs(D3botNPC.GetNPCs(false)) do
		if IsValid(npc) and D3botNPC.AI then
			D3botNPC.AI.RerollTarget(npc)
			D3botNPC.AI.UpdatePathImmediate(npc)
			n = n + 1
		end
	end
	ulx.fancyLogAdmin(calling_ply, "#A reset paths and rerolled targets for #i D3bot NPC(s)", n)
end, "!d3botnpc_resetpaths", ULib.ACCESS_ADMIN,
	"Forces all live D3bot NPCs to drop cached paths and recalculate routes.")

registerNPCCommand("d3botnpc_debug", function(calling_ply, state)
	if not ensureReady(calling_ply) then return end
	local enabled
	if state == "" then
		enabled = not D3botNPC.ConVars.Debug:GetBool()
	else
		enabled = (tonumber(state) or 0) ~= 0 or string.lower(state) == "true" or string.lower(state) == "on"
	end
	RunConsoleCommand("d3bot_npc_debug", enabled and "1" or "0")
	ulx.fancyLogAdmin(calling_ply, "#A set D3bot NPC debug mode to #s", enabled and "ON" or "OFF")
end, "!d3botnpc_debug", ULib.ACCESS_SUPERADMIN,
	"Toggles D3bot NPC debug overlays and server diagnostic logs.", {
		{ type = ULib.cmds.StringArg, default = "", hint = "0/1 (blank toggles)", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_auditmesh", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	if D3botNPC.UsingSourceNav or not D3botNPC.HasNavMesh or not D3botNPC.MapNavMesh then
		replyCaller(calling_ply, "No custom D3bot navmesh loaded to audit.")
		return
	end
	local r = D3botNPC.AuditNavMesh(D3botNPC.MapNavMesh, true)
	replyCaller(calling_ply, string.format("Audit (%s): %d nodes, %d links, %d components (main %d) | Isolated:%d DeadEnds:%d UphillRestricted:%d WorldBlocked:%d Bridges:%d",
		r.Map, r.NodeCount, r.LinkCount, r.ComponentCount, r.MainComponentSize,
		r.IsolatedCount, r.DeadEndCount, r.ImpossibleUpLinkCount, r.WorldBlockedLinks, r.VirtualBridgesAdded))
end, "!d3botnpc_auditmesh", ULib.ACCESS_SUPERADMIN,
	"Audits the loaded D3bot navmesh for isolated nodes, dead ends, impossible vertical links, and world obstructions.")

registerNPCCommand("d3botnpc_repairmesh", function(calling_ply, mode)
	if not ensureReady(calling_ply) then return end
	if D3botNPC.UsingSourceNav or not D3botNPC.HasNavMesh or not D3botNPC.MapNavMesh then
		replyCaller(calling_ply, "No custom D3bot navmesh loaded to repair.")
		return
	end
	local r = D3botNPC.AuditNavMesh(D3botNPC.MapNavMesh, true)
	if D3botNPC.ResetPathCache then D3botNPC.ResetPathCache() end
	if string.lower(mode or "") == "save" and D3botNPC.MeshAudit and D3botNPC.MeshAudit.ExportSafeRepair then
		local ok, msg = D3botNPC.MeshAudit.ExportSafeRepair(D3botNPC.MapNavMesh)
		replyCaller(calling_ply, ok and ("Repaired & saved safely: " .. msg) or msg)
	else
		replyCaller(calling_ply, string.format("Applied runtime repairs (%d bridges, %d uphill restrictions, %d world-blocked). Pass 'save' to export backup + sidecar patch.",
			r.VirtualBridgesAdded, r.ImpossibleUpLinkCount, r.WorldBlockedLinks))
	end
end, "!d3botnpc_repairmesh", ULib.ACCESS_SUPERADMIN,
	"Applies runtime D3bot navmesh repairs (pass 'save' for timestamped backup + sidecar patch).", {
		{ type = ULib.cmds.StringArg, default = "", hint = "save (optional)", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_inspectnode", function(calling_ply, nodeIdStr)
	if not ensureReady(calling_ply) then return end
	if D3botNPC.UsingSourceNav or not D3botNPC.MapNavMesh or not D3botNPC.MapNavMesh.NodeById then
		replyCaller(calling_ply, "Requires a loaded D3bot navmesh.")
		return
	end
	local node = tonumber(nodeIdStr) and D3botNPC.MapNavMesh.NodeById[tonumber(nodeIdStr)] or nil
	if not node and IsValid(calling_ply) then
		node = D3botNPC.MapNavMesh:GetBestNodeNear(calling_ply:GetEyeTrace().HitPos, { requireLinked = false })
	end
	if not node then
		replyCaller(calling_ply, "Node not found.")
		return
	end
	local deg = 0
	for _ in pairs(node.LinkByLinkedNode or {}) do deg = deg + 1 end
	replyCaller(calling_ply, string.format("Node #%s (%.0f,%.0f,%.0f) | Links:%d | Comp:%s | Occ:%.1f | Isolated:%s DeadEnd:%s Crouch:%s",
		tostring(node.Id), node.Pos.x, node.Pos.y, node.Pos.z, deg, tostring(node.RuntimeComponentId or "?"),
		D3botNPC.GetNodeCongestionCount and D3botNPC.GetNodeCongestionCount(node) or 0,
		tostring(node.RuntimeIsIsolated == true), tostring(node.RuntimeIsDeadEnd == true), tostring(node.RuntimeNeedsCrouch == true)))
end, "!d3botnpc_inspectnode", ULib.ACCESS_ADMIN,
	"Inspects a D3bot navmesh node by ID or crosshair.", {
		{ type = ULib.cmds.StringArg, default = "", hint = "node id (optional)", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_debugnpc", function(calling_ply, targetQuery)
	if not ensureReady(calling_ply) then return end
	local q = string.lower(targetQuery or "all")
	if q == "all" or q == "clear" then
		D3botNPC.DebugFilterNPC = nil
		replyCaller(calling_ply, "Cleared NPC debug overlay filter.")
		return
	elseif q == "stuck" then
		D3botNPC.DebugFilterNPC = "stuck"
		replyCaller(calling_ply, "Debug overlay filter set to STUCK NPCs.")
		return
	end
	local npc = D3botNPC.Population.ResolveTarget(calling_ply, targetQuery)
	if IsValid(npc) then
		D3botNPC.DebugFilterNPC = npc
		local mem = npc.D3bot_Mem or {}
		replyCaller(calling_ply, string.format("Inspecting %s | State:%s | Recoveries:%d (%s)",
			npc:GetNPCDisplayName(), mem.StuckStateName or "OK", mem.RecoveryAttempts or 0, tostring(mem.LastRecoveryAction or "none")))
	else
		replyCaller(calling_ply, "Target NPC not found.")
	end
end, "!d3botnpc_debugnpc", ULib.ACCESS_ADMIN,
	"Filters debug overlays to a specific NPC (#id, name, aim), 'stuck', or 'all'.", {
		{ type = ULib.cmds.StringArg, default = "all", hint = "name, #id, aim, stuck, or all", ULib.cmds.optional }
	})

registerNPCCommand("d3botnpc_navstats", function(calling_ply)
	if not ensureReady(calling_ply) then return end
	if not D3botNPC.GetNavStatsSummary then return end
	local s = D3botNPC.GetNavStatsSummary()
	replyCaller(calling_ply, string.format("NavStats | NPCs:%d Queue:%d Solves:%d (CacheHits:%d Fails:%d) Avg:%.3fms | Stuck->Micro:%d Obst:%d Route:%d Crit:%d",
		s.LiveNPCs, s.QueueDepth, s.Solves, s.CacheHits, s.FailedSolves, s.AvgSolveMs,
		s.StuckCounts.MICRO_STALL or 0, s.StuckCounts.OBSTACLE_STALL or 0, s.StuckCounts.ROUTE_FAIL or 0, s.StuckCounts.CRITICAL_TRAP or 0))
end, "!d3botnpc_navstats", ULib.ACCESS_ADMIN,
	"Prints live A* performance, queue depth, congestion, and stuck-state telemetry.")
