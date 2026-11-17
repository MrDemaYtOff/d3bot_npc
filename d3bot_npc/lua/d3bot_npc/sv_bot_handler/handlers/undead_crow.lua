-- Faithful port of D3bot sv_zs_bot_handler/handlers/undead_crow.lua
-- Enforces strict harmless Crow invariant: Crows never attack or use doors/buttons.
local lib = D3botNPC

lib.Handlers = lib.Handlers or {}
lib.Handlers.Undead_Crow = lib.Handlers.Undead_Crow or {}
local HANDLER = lib.Handlers.Undead_Crow

HANDLER.angOffshoot = 40

HANDLER.Fallback = false
function HANDLER.SelectorFunction(zombieClassName, teamId)
	return teamId == (TEAM_UNDEAD or 3) and zombieClassName == "Crow"
end

function HANDLER.UpdateBotCmdFunction(bot, cmd)
	cmd:ClearButtons()
	cmd:ClearMovement()

	if bot.KnockedDown and IsValid(bot.KnockedDown) or bot.Revive and type(bot.Revive) ~= "function" and IsValid(bot.Revive) then
		return
	end

	if not bot:Alive() and math.random(1, 50) == 1 then
		cmd:SetButtons(IN_ATTACK)
		return
	end

	bot:D3bot_UpdatePathProgress()
	local mem = bot.D3bot_Mem
	if not mem then return end

	local nextNodeOrNil = mem.NextNodeOrNil

	local result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle
	forwardSpeed = 0.0

	if nextNodeOrNil and lib.UsingSourceNav and IsValid(nextNodeOrNil) then
		local pos = nextNodeOrNil:GetCenter() + Vector(0, 0, 64)
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle = lib.Basics.Walk(bot, pos, nil)
	elseif nextNodeOrNil and nextNodeOrNil.Pos then
		local pos = nextNodeOrNil.Pos + Vector(0, 0, 64)
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle = lib.Basics.Walk(bot, pos, nil)
	elseif IsValid(mem.TgtOrNil) then
		local tgtPos = mem.TgtOrNil:GetPos()
		local ang = CurTime() * 0.9 + (bot:EntIndex() % 17)
		local orbitPos = tgtPos + Vector(math.cos(ang) * 200, math.sin(ang) * 200, 72)
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle = lib.Basics.Walk(bot, orbitPos, nil)
	end

	local buttons = 0
	if actions then
		buttons = bit.bor(
			IN_FORWARD,
			actions.Duck and IN_DUCK or 0,
			actions.Jump and IN_JUMP or 0
		)
	end

	-- Strict Crow harmless invariant: never press IN_USE, IN_ATTACK, or IN_ATTACK2
	buttons = bit.band(buttons, bit.bnot(bit.bor(IN_USE, IN_ATTACK, IN_ATTACK2)))
	buttons = bit.bor(buttons or 0, (math.random(1, 2) == 1) and result and IN_JUMP or 0)

	if aimAngle then
		bot:SetEyeAngles(aimAngle)
		cmd:SetViewAngles(aimAngle)
	end
	if forwardSpeed then cmd:SetForwardMove(forwardSpeed) end
	if sideSpeed then cmd:SetSideMove(sideSpeed) end
	cmd:SetButtons(buttons)
end

function HANDLER.ThinkFunction(bot)
	local mem = bot.D3bot_Mem
	if not mem then return end
	local ct = CurTime()

	if not mem.nextCheckTarget or mem.nextCheckTarget < ct then
		mem.nextCheckTarget = ct + 0.9 + math.random() * 0.2
		if not HANDLER.CanBeTgt(bot, mem.TgtOrNil) or math.random(60) == 1 then
			HANDLER.RerollTarget(bot)
		end
	end

	if not mem.nextUpdateOffshoot or mem.nextUpdateOffshoot < ct then
		mem.nextUpdateOffshoot = ct + 0.4 + math.random() * 0.2
		bot:D3bot_UpdateAngsOffshoot(HANDLER.angOffshoot)
	end

	if not mem.nextUpdatePath or mem.nextUpdatePath < ct then
		mem.nextUpdatePath = ct + 0.9 + math.random() * 0.2
		bot:D3bot_UpdatePath(nil, nil)
	end
end

function HANDLER.OnTakeDamageFunction(bot, dmg)
end

function HANDLER.OnDoDamageFunction(bot, ent, dmg)
end

function HANDLER.OnDeathFunction(bot)
	HANDLER.RerollTarget(bot)
end

function HANDLER.CanBeTgt(bot, target)
	if not target or not IsValid(target) then return false end
	if target:IsPlayer() and not target.D3bot_Mem and target ~= bot
		and target:GetObserverMode() == OBS_MODE_NONE and target:Alive() then
		return true
	end
	return false
end

function HANDLER.RerollTarget(bot)
	local players = lib.RemoveObsDeadTgts(player.GetHumans())
	local chosen = (#players > 0) and players[math.random(1, #players)] or nil
	bot:D3bot_SetTgtOrNil(chosen, false, nil)
end
