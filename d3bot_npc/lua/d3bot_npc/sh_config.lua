AddCSLuaFile()

-- Configuration and ConVars for D3bot NPC
-- Preserves D3bot navigation & AI tuning constants alongside slotless NPC population ConVars.

local cvFlags = bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY)

D3botNPC.ConVars = D3botNPC.ConVars or {}

D3botNPC.ConVars.Enabled = CreateConVar("d3bot_npc_enabled", "1", cvFlags, "Enable or disable the D3bot NPC zombie system (0/1).")
D3botNPC.ConVars.AutoSpawn = CreateConVar("d3bot_npc_auto_spawn", "1", cvFlags, "Enable automatic wave-aware NPC zombie spawning (0/1).")
D3botNPC.ConVars.Respawn = CreateConVar("d3bot_npc_respawn", "1", cvFlags, "Respawn dead NPC zombies to maintain desired population during active waves (0/1).")
D3botNPC.ConVars.DesiredZombies = CreateConVar("d3bot_npc_desired_zombies", "0", cvFlags, "Fixed desired zombie NPC count. Set to 0 to use the dynamic wave/human scaling formula.")
D3botNPC.ConVars.MaxPopulation = CreateConVar("d3bot_npc_max_population", "32", cvFlags, "Hard cap on simultaneously active zombie NPCs (independent of maxplayers).")

D3botNPC.ConVars.ZombiesPerHuman = CreateConVar("d3bot_npc_zombies_per_human", "4.0", cvFlags, "Dynamic formula: zombie NPCs per living human.")
D3botNPC.ConVars.ZombiesPerWave = CreateConVar("d3bot_npc_zombies_per_wave", "2.0", cvFlags, "Dynamic formula: additional zombie NPCs per wave.")
D3botNPC.ConVars.ZombiesPerHumanWave = CreateConVar("d3bot_npc_zombies_per_human_wave", "1.0", cvFlags, "Dynamic formula: additional zombie NPCs per (living human * wave).")
D3botNPC.ConVars.ZombiesPerMinute = CreateConVar("d3bot_npc_zombies_per_minute", "0.0", cvFlags, "Dynamic formula: additional zombie NPCs per minute elapsed since round start.")
D3botNPC.ConVars.ZombiesMaxPerHuman = CreateConVar("d3bot_npc_zombies_max_per_human", "16.0", cvFlags, "Dynamic formula: max NPCs per living human before BotMod.")

D3botNPC.ConVars.SpawnInterval = CreateConVar("d3bot_npc_spawn_interval", "1.2", cvFlags, "Seconds between automatic NPC spawn checks.")
D3botNPC.ConVars.RespawnDelay = CreateConVar("d3bot_npc_respawn_delay", "2.5", cvFlags, "Minimum delay in seconds before replacing a killed NPC zombie.")
D3botNPC.ConVars.WaveZeroSpawn = CreateConVar("d3bot_npc_wave_zero_spawn", "1", cvFlags, "Allow NPC bots to spawn as harmless Crows during Wave 0 waiting-for-players period (0/1).")
D3botNPC.ConVars.IntermissionCleanup = CreateConVar("d3bot_npc_intermission_cleanup", "0", cvFlags, "Remove surviving NPC zombies during wave intermissions when intermission crows are disabled (0/1).")
D3botNPC.ConVars.IntermissionCrows = CreateConVar("d3bot_npc_intermission_crows", "1", cvFlags, "Transform NPC zombies into flying Crows during wave intermissions and restore them when the next wave begins (0/1).")
D3botNPC.ConVars.NoCollideZombies = CreateConVar("d3bot_npc_nocollide_zombies", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED), "Allow zombie NPCs to pass through each other and undead players to prevent doorway jams (0/1).")
if SERVER and cvars and cvars.AddChangeCallback then
	cvars.RemoveChangeCallback("d3bot_npc_nocollide_zombies", "D3botNPC.SyncCollisionRules")
	cvars.AddChangeCallback("d3bot_npc_nocollide_zombies", function()
		if D3botNPC and D3botNPC.GetNPCs then
			for _, npc in ipairs(D3botNPC.GetNPCs(true)) do
				if IsValid(npc) then
					npc:CollisionRulesChanged()
				end
			end
		end
	end, "D3botNPC.SyncCollisionRules")
end
D3botNPC.ConVars.RagdollLifetime = CreateConVar("d3bot_npc_ragdoll_lifetime", "8", cvFlags, "Seconds before NPC zombie ragdolls are cleaned up (0 = remove immediately).")

D3botNPC.ConVars.NameList = CreateConVar("d3bot_npc_name_list", "fng_usernames", cvFlags, "Name list used for NPC bots: fng_usernames, bottish, or classic.")
D3botNPC.ConVars.NamePrefix = CreateConVar("d3bot_npc_name_prefix", "", cvFlags, "Optional tag prefix prepended to generated NPC bot names (e.g. '[NPC] ').")

D3botNPC.ConVars.MinPlayersBridge = CreateConVar("d3bot_npc_min_players_bridge", "1", cvFlags, "Count NPC zombies toward JetBoom ZS starting zombie/round checks so 1 human + NPCs starts cleanly (0/1).")
D3botNPC.ConVars.SoloWaveZeroSeconds = CreateConVar("d3bot_npc_solo_wave_zero_seconds", "30", cvFlags, "On solo 1-human servers, cap Wave 0 pre-round wait to this many seconds (-1 = keep ZS WaveZeroLength).")
D3botNPC.ConVars.Bosses = CreateConVar("d3bot_npc_bosses", "1", cvFlags, "Spawn Boss Zombie NPCs on wave starts once virtual participant count meets BossZombiePlayersRequired (0/1).")

D3botNPC.ConVars.PathBudget = CreateConVar("d3bot_npc_path_budget", "4", cvFlags, "Minimum A* path calculations processed per server tick across all NPCs (scales adaptively with queue backlog; 0 = unlimited).")
D3botNPC.ConVars.CrowdAvoidance = CreateConVar("d3bot_npc_crowd_avoidance", "0", cvFlags, "Enable A* route congestion weighting across parallel corridors without pushing or slowing NPCs (0/1).")
D3botNPC.ConVars.CrowdCongestionWeight = CreateConVar("d3bot_npc_crowd_congestion_weight", "55", cvFlags, "Extra A* path cost added per NPC occupying/traversing a node or link to distribute hordes across parallel routes.")
D3botNPC.ConVars.WhiskerAvoidance = CreateConVar("d3bot_npc_whisker_avoidance", "1", cvFlags, "Enable local hull/ray whisker steering around crates, pillars, railings, and walls (0/1).")
D3botNPC.ConVars.StuckRecovery = CreateConVar("d3bot_npc_stuck_recovery", "1", cvFlags, "Enable multi-tier stuck detection, link blacklisting, jump/crouch recovery, and rerouting (0/1).")
D3botNPC.ConVars.LinkFailPenalty = CreateConVar("d3bot_npc_link_fail_penalty", "450", cvFlags, "Temporary A* cost penalty applied to a link when an NPC fails to traverse it.")
D3botNPC.ConVars.PathRecalcInterval = CreateConVar("d3bot_npc_path_recalc_interval", "1.1", cvFlags, "Base seconds between routine path checks (scales dynamically with distance and target movement).")
D3botNPC.ConVars.AuditAddBridges = CreateConVar("d3bot_npc_audit_add_bridges", "0", cvFlags, "Let the navmesh audit inject runtime virtual links into the mesh. 0 keeps the original D3bot mesh untouched (recommended).")
D3botNPC.ConVars.AutoAuditMesh = CreateConVar("d3bot_npc_auto_audit_mesh", "0", cvFlags, "Automatically validate D3bot navmesh topology, vertical transitions, and geometry obstructions on load (0/1).")
D3botNPC.ConVars.AllowLastResortTP = CreateConVar("d3bot_npc_allow_last_resort_tp", "0", cvFlags, "Allow last-resort out-of-LOS nudge to nearest valid navmesh node if trapped in inescapable geometry (0 = recycle/respawn, 1 = safe nudge).")
D3botNPC.ConVars.ShowEnemyTargetID = CreateConVar("d3bot_npc_show_enemy_targetid", "0", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), "Show ZS TargetID nameplate when humans look at NPC zombies (0 = undead/spectators only, 1 = everyone).")

D3botNPC.ConVars.UseSourceNav = CreateConVar("d3bot_npc_use_source_nav", "1", cvFlags, "Fallback to Source .nav mesh if no D3bot navmesh exists for the map (0/1).")
D3botNPC.ConVars.SourceNavOverride = CreateConVar("d3bot_npc_source_nav_override", "0", cvFlags, "Prefer Source .nav mesh over D3bot navmesh when both exist (0/1).")
D3botNPC.ConVars.NodeDamage = CreateConVar("d3bot_npc_node_damage", "1", cvFlags, "Apply D3bot navmesh DMGPerSecond triggers to humans/deployables (0/1).")
D3botNPC.ConVars.SuppressD3botSpawns = CreateConVar("d3bot_npc_suppress_d3bot_spawns", "0", cvFlags, "If D3bot addon is also installed, prevent it from spawning fake-player bots when D3bot NPC is enabled (0/1).")
D3botNPC.ConVars.ContributeInfliction = CreateConVar("d3bot_npc_contribute_infliction", "1", cvFlags, "Allow NPC zombie kills/presence to unlock infliction-gated classes safely without ending round (0/1).")
D3botNPC.ConVars.AllowNoNavFallback = CreateConVar("d3bot_npc_no_nav_fallback", "1", cvFlags, "Allow NPCs to spawn and use direct line-of-sight/NextBot chasing if the map has no D3bot or Source navmesh (0/1).")
D3botNPC.ConVars.Debug = CreateConVar("d3bot_npc_debug", "0", cvFlags, "Toggle server debug logging and admin debugoverlay visualization (0/1).")

-- D3bot AI & Navigation Constants (reused from D3bot sv_config.lua)
D3botNPC.BotSeeTr = {
	mins = Vector(-15, -15, -15),
	maxs = Vector(15, 15, 15),
	mask = MASK_PLAYERSOLID
}

D3botNPC.NodeBlocking = {
	mins = Vector(-1, -1, -1),
	maxs = Vector(1, 1, 1),
	classes = {
		func_breakable = true,
		prop_physics = true,
		prop_dynamic = true,
		prop_door_rotating = true,
		func_door = true,
		func_door_rotating = true,
		func_physbox = true,
		func_physbox_multiplayer = true,
		func_movelinear = true
	}
}

D3botNPC.NodeBlockingMap = {
	mins = Vector(-1, -1, -1),
	maxs = Vector(1, 1, 1),
	classes = {
		func_breakable = true,
		prop_dynamic = true,
		prop_door_rotating = true,
		func_door = true,
		func_door_rotating = true,
		func_movelinear = true
	}
}

D3botNPC.NodeDamageEnts = { "prop_*turret*", "prop_arsenalcrate", "prop_resupply*" }
D3botNPC.PotentialTargetEntClasses = { "prop_obj_sigil", "prop_*turret*", "prop_arsenalcrate", "prop_manhack*", "prop_zapper*" }

D3botNPC.LinkDeathCostRaise = 300
D3botNPC.BotConsideringDeathCostAntichance = 3
D3botNPC.BotAngLerpFactor = 0.125
D3botNPC.BotAttackAngLerpFactor = 0.125
D3botNPC.BotAimAngLerpFactor = 0.5
D3botNPC.BotAimPosVelocityOffshoot = 0.4
D3botNPC.BotJumpAntichance = 25
D3botNPC.BotDuckAntichance = 25
D3botNPC.FaceTargetOffshootFactor = 0.2
D3botNPC.NodeDamageInterval = 1.0
D3botNPC.BotNodeMinProximitySqr = 40 * 40
D3botNPC.BotNodeArrivalVertUp = 56
D3botNPC.BotNodeArrivalVertDown = 34
D3botNPC.NPCEntityClass = "d3bot_npc_zombie"

-- Default weighted class rotation (matches D3bot's Undead_Fallback.BotClasses + Zombine/Headcrab/Lacerator support)
D3botNPC.DefaultClassWeights = {
	["Zombie"] = 4,
	["Ghoul"] = 1,
	["Wraith"] = 3,
	["Bloated Zombie"] = 3,
	["Fast Zombie"] = 4,
	["Poison Zombie"] = 3,
	["Zombine"] = 4,
	["Headcrab"] = 2,
	["Fast Headcrab"] = 1,
	["Lacerator"] = 2,
	["Skeletal Walker"] = 1
}
