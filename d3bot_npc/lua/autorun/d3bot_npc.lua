AddCSLuaFile()

-- D3bot NPC: Slotless AI Zombies for Original JetBoom Zombie Survival
-- Derivative adaptation of AzBot / D3bot (https://github.com/Dadido3/D3bot | https://github.com/delstre/D3bot)
-- Reuses D3bot's navmesh format, pathfinding, node/link conditions, username lists, and AI decision core,
-- executing behaviors on real base_nextbot entities (d3bot_npc_zombie) without consuming player slots.

if D3botNPC and D3botNPC.IsInitialized then
	-- Support hot-reloading during development without duplicating state
	D3botNPC.IsReload = true
end

include("d3bot_npc/azlib.lua")

D3botNPC.Version = "3.1.0"
D3botNPC.HookId = "D3botNPC"
D3botNPC.AttributionNotice = "D3bot NPC v3.1.0 - Slotless AI Zombies for JetBoom Zombie Survival (Derivative of AzBot/D3bot)"
D3botNPC.IsInitialized = true

-- Shared files
AddCSLuaFile("d3bot_npc/sh_config.lua")
AddCSLuaFile("d3bot_npc/sh_utilities.lua")
AddCSLuaFile("d3bot_npc/sh_extend_entity.lua")
AddCSLuaFile("d3bot_npc/sh_navmesh.lua")
AddCSLuaFile("d3bot_npc/sh_classes.lua")
AddCSLuaFile("d3bot_npc/sh_roster.lua")
AddCSLuaFile("d3bot_npc/cl_init.lua")

include("d3bot_npc/sh_config.lua")
include("d3bot_npc/sh_utilities.lua")
include("d3bot_npc/sh_extend_entity.lua")
include("d3bot_npc/sh_navmesh.lua")
include("d3bot_npc/sh_classes.lua")
include("d3bot_npc/sh_roster.lua")

if CLIENT then
	include("d3bot_npc/cl_init.lua")
end

if SERVER then
	include("d3bot_npc/sv_names.lua")
	include("d3bot_npc/sv_navmesh.lua")
	include("d3bot_npc/sv_navmesh_audit.lua")
	include("d3bot_npc/sv_navmeta.lua")
	include("d3bot_npc/sv_path.lua")
	include("d3bot_npc/sv_node_metadata.lua")
	include("d3bot_npc/sv_extend_npc.lua")
	include("d3bot_npc/sv_bot_handler/basics.lua")
	include("d3bot_npc/sv_bot_handler/supervisor.lua")
	include("d3bot_npc/sv_bot_handler/handle.lua")
	include("d3bot_npc/sv_ai_core.lua")
	include("d3bot_npc/sv_zs_compat.lua")
	include("d3bot_npc/sv_population.lua")
	include("d3bot_npc/sv_debug.lua")

	hook.Add("Initialize", D3botNPC.HookId .. ".Attribution", function()
		MsgC(Color(120, 220, 120), "[D3botNPC] ", Color(255, 255, 255), D3botNPC.AttributionNotice .. "\n")
	end)
end
