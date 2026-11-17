-- Faithful port of D3bot sv_zs_bot_handler/handlers/undead_fallback.lua
local lib = D3botNPC

lib.Handlers = lib.Handlers or {}
lib.Handlers.Undead_Fallback = lib.Handlers.Undead_Fallback or {}
local HANDLER = lib.Handlers.Undead_Fallback

HANDLER.AngOffshoot = 45
HANDLER.BotTgtFixationDistMin = 250
HANDLER.BotClasses = {
	"Zombie", "Zombie", "Zombie",
	"Ghoul",
	"Wraith", "Wraith", "Wraith",
	"Bloated Zombie", "Bloated Zombie", "Bloated Zombie",
	"Fast Zombie", "Fast Zombie", "Fast Zombie", "Fast Zombie",
	"Poison Zombie", "Poison Zombie", "Poison Zombie",
	"Zombine", "Zombine", "Zombine", "Zombine", "Zombine"
}
HANDLER.RandomSecondaryAttack = {
	Ghoul = { MinTime = 5, MaxTime = 7 }
}

HANDLER.Fallback = true
function HANDLER.SelectorFunction(zombieClassName, teamId)
	return teamId == (TEAM_UNDEAD or 3)
end

function HANDLER.UpdateBotCmdFunction(bot, cmd)
	cmd:ClearButtons()
	cmd:ClearMovement()

	if bot.KnockedDown and IsValid(bot.KnockedDown) or bot.Revive and type(bot.Revive) ~= "function" and IsValid(bot.Revive) then
		return
	end

	if not bot:Alive() then
		cmd:SetButtons(IN_ATTACK)
		return
	end

	local mem = bot.D3bot_Mem
	if not mem then return end

	bot:D3bot_UpdatePathProgress()
	lib.Basics.SuicideOrRetarget(bot)

	local result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = lib.Basics.PounceAuto(bot, false)
	if not result then
		result, actions, forwardSpeed, sideSpeed, upSpeed, aimAngle, minorStuck, majorStuck, facesHindrance = lib.Basics.WalkAttackAuto(bot)
		if not result then
			return
		end
	end

	-- Search for nearby barricades when hindered and no recent damage has been dealt
	if facesHindrance and CurTime() - (bot.D3bot_LastDamage or 0) > 2 then
		local entity, entityPos = bot:D3bot_FindBarricadeEntity(1)
		if entity and entityPos then
			mem.BarricadeAttackEntity, mem.BarricadeAttackPos = entity, entityPos
		end
	end

	local ct = bot:GetZombieClassTable()
	local secAttack = ct and HANDLER.RandomSecondaryAttack[ct.Name]
	if secAttack then
		if not mem.NextThrowPoisonTime or mem.NextThrowPoisonTime <= CurTime() then
			mem.NextThrowPoisonTime = CurTime() + secAttack.MinTime + math.random() * (secAttack.MaxTime - secAttack.MinTime)
			actions = actions or {}
			actions.Attack2 = true
		end
	end

	local buttons = 0
	if actions then
		buttons = bit.bor(
			actions.MoveForward and IN_FORWARD or 0,
			actions.MoveBackward and IN_BACK or 0,
			actions.MoveLeft and IN_MOVELEFT or 0,
			actions.MoveRight and IN_MOVERIGHT or 0,
			actions.Attack and IN_ATTACK or 0,
			actions.Attack2 and IN_ATTACK2 or 0,
			actions.Duck and IN_DUCK or 0,
			actions.Jump and IN_JUMP or 0,
			actions.Use and IN_USE or 0
		)
	end

	if majorStuck and lib.GetWaveActive and lib.GetWaveActive() then
		bot:Kill()
		return
	end

	if aimAngle then
		bot:SetEyeAngles(aimAngle)
		cmd:SetViewAngles(aimAngle)
	end
	if forwardSpeed then cmd:SetForwardMove(forwardSpeed) end
	if sideSpeed then cmd:SetSideMove(sideSpeed) end
	if upSpeed then cmd:SetUpMove(upSpeed) end
	cmd:SetButtons(buttons)
end

function HANDLER.ThinkFunction(bot)
	local mem = bot.D3bot_Mem
	if not mem then return end

	local botPos = bot:GetPos()
	local ct = CurTime()

	if not mem.nextUpdateSurroundingPlayers or mem.nextUpdateSurroundingPlayers < ct then
		if not IsValid(mem.TgtOrNil) or mem.TgtOrNil:GetPos():Distance(botPos) > HANDLER.BotTgtFixationDistMin then
			mem.nextUpdateSurroundingPlayers = ct + 0.9 + math.random() * 0.2
			local targets = player.GetAll()
			table.sort(targets, function(a, b) return botPos:DistToSqr(a:GetPos()) < botPos:DistToSqr(b:GetPos()) end)
			for k, v in ipairs(targets) do
				if IsValid(v) and botPos:DistToSqr(v:GetPos()) < 500 * 500 and HANDLER.CanBeTgt(bot, v) and bot:D3bot_CanSeeTarget(nil, v) then
					bot:D3bot_SetTgtOrNil(v, false, nil)
					mem.nextUpdateSurroundingPlayers = ct + 5
					break
				end
				if k > 3 then break end
			end
		end
	end

	if not mem.nextCheckTarget or mem.nextCheckTarget < ct then
		mem.nextCheckTarget = ct + 0.9 + math.random() * 0.2
		if not HANDLER.CanBeTgt(bot, mem.TgtOrNil) then
			HANDLER.RerollTarget(bot)
		end
	end

	if not mem.nextUpdateOffshoot or mem.nextUpdateOffshoot < ct then
		mem.nextUpdateOffshoot = ct + 0.4 + math.random() * 0.2
		bot:D3bot_UpdateAngsOffshoot(HANDLER.AngOffshoot)
	end

	local function pathCostFunction(node, linkedNode, link)
		local linkPenalty = lib.GetLinkDeathCost and lib.GetLinkDeathCost(link) or 0
		return linkPenalty * (mem.ConsidersPathLethality and 1 or 0)
	end

	if not mem.nextUpdatePath or mem.nextUpdatePath < ct then
		mem.nextUpdatePath = ct + 0.9 + math.random() * 0.2
		bot:D3bot_UpdatePath(pathCostFunction, nil)
	end
end

function HANDLER.OnTakeDamageFunction(bot, dmg)
	local attacker = dmg and dmg:GetAttacker()
	if not HANDLER.CanBeTgt(bot, attacker) then return end
	local mem = bot.D3bot_Mem
	if not mem then return end
	if IsValid(mem.TgtOrNil) and mem.TgtOrNil:GetPos():DistToSqr(bot:GetPos()) <= math.pow(HANDLER.BotTgtFixationDistMin, 2) then return end
	bot:D3bot_SetTgtOrNil(attacker, false, nil)
end

function HANDLER.OnDoDamageFunction(bot, ent, dmg)
	local mem = bot.D3bot_Mem
	if not mem then return end
	if IsValid(ent) and ent.D3bot_IsBarricade and ent:D3bot_IsBarricade() then
		mem.BarricadeAttackEntity, mem.BarricadeAttackPos = ent, dmg:GetDamagePosition()
	end
end

function HANDLER.OnDeathFunction(bot)
	bot:D3bot_RerollClass(HANDLER.BotClasses)
	HANDLER.RerollTarget(bot)
end

-----------------------------------
-- Target validation & rerolling --
-----------------------------------

local potTargetEntClasses = lib.PotentialTargetEntClasses or { "prop_obj_sigil", "prop_*turret*", "prop_arsenalcrate", "prop_manhack*", "prop_zapper*" }
local potEntTargets = nil
local potEntTargetSet = nil
local nextPotEntRefresh = 0

local function refreshPotEntTargets(force)
	local ct = CurTime()
	if not force and potEntTargets and ct < nextPotEntRefresh then return end
	nextPotEntRefresh = ct + 1.0
	potEntTargets = lib.GetEntsOfClss(potTargetEntClasses)
	potEntTargetSet = {}
	for _, ent in ipairs(potEntTargets) do
		if IsValid(ent) then
			potEntTargetSet[ent] = true
		end
	end
end

-- Safe non-player ZS SENT health helper (ENT.MaxHealth in ZS is numeric, never callable MaxHealth method)
local function isValidNonPlayerTargetHealth(ent, isSigil)
	if not IsValid(ent) then return false end
	if isSigil and isfunction(ent.GetSigilHealth) then
		return (tonumber(ent:GetSigilHealth()) or 0) > 0
	end
	if isfunction(ent.GetObjectHealth) then
		return (tonumber(ent:GetObjectHealth()) or 0) > 0
	end
	if isfunction(ent.GetMaxHealth) and isfunction(ent.Health) then
		local engineMax = tonumber(ent:GetMaxHealth()) or 0
		if engineMax > 0 and (tonumber(ent:Health()) or 0) <= 0 then
			return false
		end
	end
	return true
end

function HANDLER.CanBeTgt(bot, target)
	if not target or not IsValid(target) then return false end
	if target:IsPlayer() and target ~= bot and target:Team() ~= (TEAM_UNDEAD or 3)
		and target:GetObserverMode() == OBS_MODE_NONE and not target:IsFlagSet(FL_NOTARGET) and target:Alive() then
		return true
	end
	if target:GetClass() == "prop_obj_sigil" then
		if isfunction(target.GetSigilCorrupted) and target:GetSigilCorrupted() then return false end
		if isfunction(target.IsSigilCorrupted) and target:IsSigilCorrupted() then return false end
		return isValidNonPlayerTargetHealth(target, true)
	end
	refreshPotEntTargets(false)
	if potEntTargetSet and potEntTargetSet[target] then
		return isValidNonPlayerTargetHealth(target, false)
	end
	return false
end

function HANDLER.RerollTarget(bot)
	local players = lib.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN or 4))
	if #players == 0 and TEAM_UNDEAD then
		players = lib.RemoveObsDeadTgts(player.GetAll())
		players = lib.From(players):Where(function(k, v) return v:Team() ~= TEAM_UNDEAD end).R
	end
	if #players == 0 then
		players = lib.RemoveObsDeadTgts(player.GetAll())
	end

	refreshPotEntTargets(true)
	local validEnts = {}
	for _, ent in ipairs(potEntTargets or {}) do
		if HANDLER.CanBeTgt(bot, ent) then
			validEnts[#validEnts + 1] = ent
		end
	end

	local mem = bot.D3bot_Mem
	local unreachable = mem and mem.UnreachableTargets
	local ct = CurTime()

	local potTargets = table.Add(players, validEnts)
	if unreachable and #potTargets > 1 then
		local filtered = {}
		for _, tgt in ipairs(potTargets) do
			if not unreachable[tgt] or unreachable[tgt] <= ct then
				filtered[#filtered + 1] = tgt
			end
		end
		if #filtered > 0 then
			potTargets = filtered
		end
	end

	local chosen = (#potTargets > 0) and potTargets[math.random(1, #potTargets)] or nil
	bot:D3bot_SetTgtOrNil(chosen, false, nil)
end
