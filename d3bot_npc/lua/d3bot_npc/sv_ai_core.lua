-- Compatibility & Bridge Module (D3botNPC.AI)
-- Delegates directly to the faithful D3bot port:
--   * sv_extend_npc.lua (D3bot_* NPC methods)
--   * sv_bot_handler/basics.lua (Basics.Walk, WalkAttackAuto, PounceAuto, SuicideOrRetarget)
--   * sv_bot_handler/handlers/undead_*.lua (Undead_Fallback, Undead_Headcrab, Undead_Crow)
--   * sv_bot_handler/handle.lua & supervisor.lua

local lib = D3botNPC

lib.AI = lib.AI or {}
local AI = lib.AI

AI.BotTgtFixationDistMin = 250
AI.PathQueue = AI.PathQueue or {}

function AI.GetLivingNPCsCached()
	if lib.GetLivingNPCsCached then
		return lib.GetLivingNPCsCached()
	end
	return lib.GetNPCs(false)
end

function AI.InitializeOrReset(npc)
	if IsValid(npc) and npc.D3bot_InitializeOrReset then
		npc:D3bot_InitializeOrReset()
	end
end

function AI.Deinitialize(npc)
	if IsValid(npc) and npc.D3bot_Deinitialize then
		npc:D3bot_Deinitialize()
	end
end

function AI.CanBeTgt(npc, target)
	if not IsValid(npc) or not IsValid(target) then return false end
	local handler = lib.FindHandler and lib.FindHandler(npc:GetZombieClass(), npc:Team(), npc)
	if handler and handler.CanBeTgt then
		return handler.CanBeTgt(npc, target) == true
	end
	return false
end

function AI.SetTgtOrNil(npc, target, dontAttack, proximity)
	if IsValid(npc) and npc.D3bot_SetTgtOrNil then
		npc:D3bot_SetTgtOrNil(target, dontAttack, proximity)
	end
end

function AI.RerollTarget(npc)
	if not IsValid(npc) then return end
	local handler = lib.FindHandler and lib.FindHandler(npc:GetZombieClass(), npc:Team(), npc)
	if handler and handler.RerollTarget then
		handler.RerollTarget(npc)
	end
end

function AI.UpdatePathImmediate(npc)
	if not IsValid(npc) or not npc.D3bot_UpdatePath then return end
	local mem = npc.D3bot_Mem
	local pathCostFunction = function(node, linkedNode, link)
		local linkPenalty = lib.GetLinkDeathCost and lib.GetLinkDeathCost(link) or 0
		return linkPenalty * ((mem and mem.ConsidersPathLethality) and 1 or 0)
	end
	npc:D3bot_UpdatePath(pathCostFunction, nil)
end

function AI.QueuePathUpdate(npc, highPriority)
	if not IsValid(npc) or not npc.D3bot_Mem then return end
	if highPriority then
		AI.UpdatePathImmediate(npc)
		return
	end
	npc.D3bot_Mem.nextUpdatePath = 0
end

function AI.ResetPathQueue()
	AI.PathQueue = {}
end

function AI.UpdatePathProgress(npc)
	if IsValid(npc) and npc.D3bot_UpdatePathProgress then
		npc:D3bot_UpdatePathProgress()
	end
end

function AI.NotifyNextBotStuck(npc)
	if not IsValid(npc) or not npc.D3bot_Mem then return end
	npc.D3bot_Mem.NextBotStuckFlag = true
	npc.D3bot_Mem.nextUpdatePath = 0
end
