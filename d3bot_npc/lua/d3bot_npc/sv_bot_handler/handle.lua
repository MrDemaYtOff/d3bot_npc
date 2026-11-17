-- Faithful port of D3bot sv_zs_bot_handler/handle.lua adapted for slotless base_nextbot NPCs
local lib = D3botNPC

lib.Handlers = lib.Handlers or {}

for _, filename in ipairs(file.Find("d3bot_npc/sv_bot_handler/handlers/*.lua", "LUA") or {}) do
	include("d3bot_npc/sv_bot_handler/handlers/" .. filename)
end

local handlerLookup = {}

function lib.FindHandler(zombieClass, teamId, npc)
	local tId = teamId or (TEAM_UNDEAD or 3)
	local className = nil
	if IsValid(npc) and npc.GetClassConfig then
		local cfg = npc:GetClassConfig()
		className = cfg and cfg.Name
	end
	if not className and GAMEMODE and GAMEMODE.ZombieClasses and zombieClass then
		local zc = GAMEMODE.ZombieClasses[zombieClass]
		className = zc and zc.Name
	end
	if not className and lib.GetClassConfig then
		local cfg = lib.GetClassConfig(zombieClass)
		className = cfg and cfg.Name
	end
	className = className or "Zombie"

	if handlerLookup[tId] and handlerLookup[tId][className] then
		return handlerLookup[tId][className]
	end

	for _, fallback in ipairs({ false, true }) do
		for _, handler in pairs(lib.Handlers) do
			if handler.Fallback == fallback and handler.SelectorFunction and handler.SelectorFunction(className, tId) then
				handlerLookup[tId] = handlerLookup[tId] or {}
				handlerLookup[tId][className] = handler
				return handler
			end
		end
	end

	return lib.Handlers.Undead_Fallback
end

local cachedLivingList = {}
local nextLivingRefresh = -1
function lib.GetLivingNPCsCached()
	local ct = CurTime()
	if ct ~= nextLivingRefresh then
		nextLivingRefresh = ct
		cachedLivingList = lib.GetNPCs(false)
	end
	return cachedLivingList
end

local nextSupervisorThink = 0
local nextStorePos = 0

hook.Add("Think", lib.HookId .. ".BotHandlerThink", function()
	if not lib.ConVars.Enabled or not lib.ConVars.Enabled:GetBool() then return end

	local ct = CurTime()
	local npcs = lib.GetLivingNPCsCached()
	for i = 1, #npcs do
		local bot = npcs[i]
		if IsValid(bot) and bot:Alive() then
			if not bot.D3bot_Mem and bot.D3bot_InitializeOrReset then
				bot:D3bot_InitializeOrReset()
			end
			if bot.D3bot_Mem and bot.D3bot_Cmd then
				local handler = lib.FindHandler(bot:GetZombieClass(), bot:Team(), bot)
				if handler then
					if handler.ThinkFunction then
						handler.ThinkFunction(bot)
					end
					if handler.UpdateBotCmdFunction then
						handler.UpdateBotCmdFunction(bot, bot.D3bot_Cmd)
					end
				end
			end
		end
	end

	if nextSupervisorThink < ct then
		nextSupervisorThink = ct + 0.05 + math.random() * 0.1
		if lib.SupervisorThinkFunction then
			lib.SupervisorThinkFunction()
		end
	end

	if nextStorePos < ct then
		nextStorePos = ct + 0.9 + math.random() * 0.2
		for i = 1, #npcs do
			local bot = npcs[i]
			if IsValid(bot) and bot.D3bot_StorePos then
				bot:D3bot_StorePos()
			end
		end
	end
end)

hook.Add("EntityTakeDamage", lib.HookId .. ".HandlerDamage", function(ent, dmg)
	if not lib.ConVars.Enabled or not lib.ConVars.Enabled:GetBool() then return end

	if IsValid(ent) and ent.IsD3botNPC and ent.D3bot_Mem then
		local handler = lib.FindHandler(ent:GetZombieClass(), ent:Team(), ent)
		if handler and handler.OnTakeDamageFunction then
			handler.OnTakeDamageFunction(ent, dmg)
		end
	end

	local attacker = dmg and dmg:GetAttacker()
	if IsValid(attacker) and attacker ~= ent and attacker.IsD3botNPC and attacker.D3bot_Mem then
		local handler = lib.FindHandler(attacker:GetZombieClass(), attacker:Team(), attacker)
		if handler and handler.OnDoDamageFunction then
			handler.OnDoDamageFunction(attacker, ent, dmg)
		end
		attacker.D3bot_LastDamage = CurTime()
	end
end)

function lib.OnHandlerNPCDeath(bot)
	if not IsValid(bot) or not bot.D3bot_Mem then return end
	local handler = lib.FindHandler(bot:GetZombieClass(), bot:Team(), bot)
	if handler and handler.OnDeathFunction then
		handler.OnDeathFunction(bot)
	end
end
