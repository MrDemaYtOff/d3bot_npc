-- Faithful port of D3bot sv_zs_bot_handler/supervisor.lua adapted for slotless NPCs
-- Keeps D3bot's GetDesiredBotCount formula and SupervisorThinkFunction cadence
-- while spawning/managing zero-slot base_nextbot entities through D3botNPC.Population.

local lib = D3botNPC

local roundStartTime = CurTime()
hook.Add("PreRestartRound", lib.HookId .. ".SupervisorRoundReset", function()
	roundStartTime = CurTime()
	lib.NodeZombiesCountAddition = nil
end)

function lib.GetDesiredBotCount()
	if not lib.Population then return 0, 0, game.MaxPlayers() end
	local zombiesCount = lib.Population.GetDesiredNPCCount()
	-- Slotless architecture intentionally disables Survivor fake-client bots
	return zombiesCount, 0, lib.ConVars.MaxPopulation and lib.ConVars.MaxPopulation:GetInt() or 32
end

function lib.DoNodeTrigger()
	if not lib.ConVars.Enabled or not lib.ConVars.Enabled:GetBool() then return end
	if lib.UsingSourceNav or not lib.MapNavMesh or not lib.MapNavMesh.NodeById then return end
	if lib.Population and lib.Population.GetNodeBotMod then
		lib.NodeZombiesCountAddition = lib.Population.GetNodeBotMod()
	end
end

local nextMaintain = 0
local nextTrigger = 0
function lib.SupervisorThinkFunction()
	local ct = CurTime()
	if nextMaintain < ct then
		nextMaintain = ct + 0.5
		if lib.ZS and lib.ZS.CapSoloWaveZeroTimer then
			lib.ZS.CapSoloWaveZeroTimer()
		end
	end
	if nextTrigger < ct then
		nextTrigger = ct + (lib.NodeDamageInterval or 1.0)
		lib.DoNodeTrigger()
	end
end
