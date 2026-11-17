-- JetBoom Zombie Survival Integration & Compatibility Layer for D3bot NPC
-- Bridges ZS combat, points, kill attribution, TopNotifyAll killfeed, deployable targeting,
-- spawn selection, min-player/solo round startup, boss waves, safe infliction, and intermission Crows
-- WITHOUT editing ZS gamemode files or consuming server player slots.

local lib = D3botNPC

lib.ZS = lib.ZS or {}
local ZS = lib.ZS

-- 1. Zombie Spawn Point Selection (mirrors ZS spawn selection + D3bot anti-LOS checks)
local spawnStartVec, spawnEndVec = Vector(), Vector()
local spawnHullTrData = { start = spawnStartVec, endpos = spawnEndVec, mask = MASK_NPCSOLID }
local spawnLosTrData = { start = Vector(), endpos = spawnEndVec, mask = MASK_SOLID_BRUSHONLY }

local function spawnNonZombieFilter(ent)
	if not IsValid(ent) then return false end
	if ent.IsD3botNPC then return false end
	if ent:IsPlayer() and ent:Team() == (TEAM_UNDEAD or 3) then return false end
	return true
end

local function isHullClear(pos, hullMins, hullMaxs)
	spawnStartVec:SetUnpacked(pos.x, pos.y, pos.z + 2)
	spawnEndVec:SetUnpacked(pos.x, pos.y, pos.z + 4)
	spawnHullTrData.mins = hullMins
	spawnHullTrData.maxs = hullMaxs
	if lib.ConVars.NoCollideZombies and lib.ConVars.NoCollideZombies:GetBool() then
		spawnHullTrData.filter = spawnNonZombieFilter
	else
		spawnHullTrData.filter = nil
	end
	local tr = util.TraceHull(spawnHullTrData)
	spawnHullTrData.filter = nil
	return not tr.Hit and not tr.StartSolid
end

local function isVisibleToAnyHuman(pos)
	spawnEndVec:SetUnpacked(pos.x, pos.y, pos.z + 56)
	for _, ply in ipairs(team.GetPlayers(TEAM_HUMAN)) do
		if IsValid(ply) and ply:Alive() then
			local eye = ply:EyePos()
			if eye:DistToSqr(spawnEndVec) < 180 * 180 then
				return true
			end
			spawnLosTrData.start = eye
			spawnLosTrData.filter = ply
			local tr = util.TraceLine(spawnLosTrData)
			if not tr.Hit then
				return true
			end
		end
	end
	return false
end

function ZS.GetCandidateSpawnPositions(classCfg)
	local candidates = {}
	local hullMins = (classCfg and classCfg.Hull and classCfg.Hull[1]) or Vector(-16, -16, 0)
	local hullMaxs = (classCfg and classCfg.Hull and classCfg.Hull[2]) or Vector(16, 16, 72)

	local function addPos(pos, ang, priority)
		if isvector(pos) and isHullClear(pos, hullMins, hullMaxs) then
			table.insert(candidates, {
				Pos = pos,
				Ang = ang or Angle(0, math.random(-180, 180), 0),
				Priority = priority or 1
			})
		end
	end

	-- ZS valid undead spawn points (includes enabled info_player_zombie / info_player_undead)
	if team and team.GetValidSpawnPoint then
		for _, sp in ipairs(team.GetValidSpawnPoint(TEAM_UNDEAD) or {}) do
			if IsValid(sp) and not sp.Disabled then
				addPos(sp:GetPos(), sp:GetAngles(), 3)
			end
		end
	end

	for _, cls in ipairs({ "info_player_zombie", "info_player_undead" }) do
		for _, sp in ipairs(ents.FindByClass(cls)) do
			if IsValid(sp) and not sp.Disabled then
				addPos(sp:GetPos(), sp:GetAngles(), 3)
			end
		end
	end

	-- ZS dynamic creeper nests / zombie spawn beacons
	if GAMEMODE and GAMEMODE.GetDynamicSpawns then
		local ok, dynSpawns = pcall(GAMEMODE.GetDynamicSpawns, GAMEMODE, TEAM_UNDEAD)
		if ok and istable(dynSpawns) then
			for _, sp in ipairs(dynSpawns) do
				if IsValid(sp) then
					addPos(sp:GetPos(), sp:GetAngles(), 2)
				end
			end
		end
	end

	-- Fallback to D3bot navmesh nodes sampled evenly across main component if spawn entities are absent
	if #candidates == 0 and not lib.UsingSourceNav and lib.MapNavMesh and lib.MapNavMesh.NodeById then
		local wave = lib.GetCurrentWave()
		local mainComp = lib.MapNavMesh.MainComponentId
		local validNodes = {}
		for _, node in pairs(lib.MapNavMesh.NodeById) do
			if istable(node) and node.Pos and not node.RuntimeEmbedded
				and (not mainComp or not node.RuntimeComponentId or node.RuntimeComponentId == mainComp)
				and not lib.IsNavMeshNodeBlocked(node.Params, node.Pos, wave) then
				validNodes[#validNodes + 1] = node
			end
		end
		local total = #validNodes
		if total > 0 then
			local step = math.max(1, math.floor(total / 24))
			for idx = 1, total, step do
				local n = validNodes[idx]
				addPos(n.Pos + Vector(0, 0, 4), Angle(0, math.random(-180, 180), 0), 1)
				if #candidates >= 24 then break end
			end
		end
	end

	-- Final fallback to standard map player spawns
	if #candidates == 0 then
		for _, sp in ipairs(ents.FindByClass("info_player_start")) do
			if IsValid(sp) then
				addPos(sp:GetPos(), sp:GetAngles(), 0)
			end
		end
	end

	return candidates
end

function ZS.SelectZombieSpawnPos(classCfg)
	local candidates = ZS.GetCandidateSpawnPositions(classCfg)
	if #candidates == 0 then return nil, nil end

	local hidden = {}
	for _, c in ipairs(candidates) do
		if not isVisibleToAnyHuman(c.Pos) then
			table.insert(hidden, c)
		end
	end

	local pool = (#hidden > 0) and hidden or candidates
	local chosen = pool[math.random(1, #pool)]
	return chosen.Pos, chosen.Ang
end

-- 2. Minimum Player / Solo Round / Boss / Safe Infliction Bridges
local function getEffectiveVirtualZombies()
	local rosterUndead = lib.Roster and lib.Roster.CountByTeam(TEAM_UNDEAD or 3) or 0
	if rosterUndead > 0 then
		return rosterUndead
	end
	if lib.Population and lib.Population.GetDesiredNPCCount then
		-- Preview expected horde when at least 1 active player is connected
		local activePlayers = player.GetAllActive and #player.GetAllActive() or #player.GetAll()
		if activePlayers > 0 and lib.ConVars.AutoSpawn and lib.ConVars.AutoSpawn:GetBool() then
			local fixed = lib.ConVars.DesiredZombies and lib.ConVars.DesiredZombies:GetInt() or 0
			if fixed > 0 then return fixed end
			return math.max(1, math.Round(lib.ConVars.ZombiesPerHuman:GetFloat()))
		end
	end
	return 0
end

function ZS.GetRoundLifecycleState()
	if not lib.IsZombieSurvivalReady() then
		return "UNINITIALIZED"
	end
	if GAMEMODE.RoundEnded then
		return "ROUND_ENDED"
	end
	local wave = lib.GetCurrentWave()
	local active = lib.GetWaveActive()
	if wave <= 0 and not active then
		return "WAITING_FOR_PLAYERS"
	end
	if active then
		return "ACTIVE_WAVE"
	end
	return "INTERMISSION"
end

function ZS.ShouldNPCsBeCrows()
	local state = ZS.GetRoundLifecycleState()
	if state == "WAITING_FOR_PLAYERS" then
		return true
	end
	if state == "INTERMISSION" then
		return (lib.ConVars.IntermissionCrows and lib.ConVars.IntermissionCrows:GetBool()) == true
	end
	return false
end

function ZS.ApplyLifecycleState()
	local state = ZS.GetRoundLifecycleState()
	if state == "UNINITIALIZED" or state == "ROUND_ENDED" then return end

	local errHandler = ErrorNoHaltWithStack or ErrorNoHalt
	local crowMode = ZS.ShouldNPCsBeCrows()
	if crowMode then
		for _, slot in ipairs(lib.Roster and lib.Roster.GetAll() or {}) do
			if slot.Team == (TEAM_UNDEAD or 3) then
				if slot.ZombieClass and slot.ZombieClass ~= "Crow" then
					slot.DeathClass = slot.ZombieClass
				end
				slot.IsCrow = true
				slot.ZombieClass = "Crow"
			end
		end
		for _, npc in ipairs(lib.GetNPCs(false)) do
			if IsValid(npc) and npc.MorphToCrow then
				xpcall(function()
					npc:MorphToCrow()
				end, errHandler)
			end
		end
		if lib.Roster and lib.Roster.ScheduleSync then
			lib.Roster.ScheduleSync()
		end
	elseif state == "ACTIVE_WAVE" then
		for _, slot in ipairs(lib.Roster and lib.Roster.GetAll() or {}) do
			slot.IsCrow = false
			if slot.ZombieClass == "Crow" then
				slot.ZombieClass = slot.ForcedClass or slot.DeathClass or "Zombie"
			end
		end
		for _, npc in ipairs(lib.GetNPCs(false)) do
			if IsValid(npc) and npc:IsCrow() and npc.RestoreFromCrow then
				xpcall(function()
					npc:RestoreFromCrow()
				end, errHandler)
			end
		end
		if lib.Roster and lib.Roster.ScheduleSync then
			lib.Roster.ScheduleSync()
		end
		if lib.Population then
			lib.Population.NextSpawnCheck = 0
			if lib.Population.SyncPopulationNow then
				xpcall(function()
					lib.Population.SyncPopulationNow()
				end, errHandler)
			end
		end
	elseif state == "INTERMISSION" then
		if lib.ConVars.IntermissionCleanup and lib.ConVars.IntermissionCleanup:GetBool() then
			ZS.RemoveAllNPCs(false)
		end
	end
end

function ZS.CapSoloWaveZeroTimer()
	if not lib.IsZombieSurvivalReady() or not lib.ConVars.Enabled:GetBool() or not lib.ConVars.MinPlayersBridge:GetBool() then return end
	if GAMEMODE.RoundEnded or GAMEMODE:GetWave() ~= 0 or GAMEMODE:GetWaveActive() then return end

	local cap = lib.ConVars.SoloWaveZeroSeconds and lib.ConVars.SoloWaveZeroSeconds:GetFloat() or 30
	if cap < 0 then return end

	local realPlayers = player.GetAllActive and #player.GetAllActive() or #player.GetAll()
	if realPlayers <= 1 and getEffectiveVirtualZombies() > 0 then
		local curStart = GAMEMODE:GetWaveStart()
		local targetStart = CurTime() + cap
		if curStart > targetStart then
			GAMEMODE:SetWaveStart(targetStart)
			if isfunction(GAMEMODE.GetWaveOneLength) and isfunction(GAMEMODE.SetWaveEnd) then
				GAMEMODE:SetWaveEnd(targetStart + GAMEMODE:GetWaveOneLength())
			end
			net.Start("zs_waveend")
				net.WriteInt(0, 16)
				net.WriteFloat(targetStart)
			net.Broadcast()
		end
	end
end

function ZS.SpawnOrConvertBossNPC(forcedBossClass)
	if not lib.IsZombieSurvivalReady() or not lib.ConVars.Enabled:GetBool() then return nil end
	local bossPool = {}
	for _, zsClass in ipairs(GAMEMODE.ZombieClasses or {}) do
		if zsClass.Boss and not zsClass.Hidden and not zsClass.Locked then
			if lib.ClassConfigs and lib.ClassConfigs[zsClass.Name] then
				table.insert(bossPool, zsClass.Name)
			end
		end
	end
	if #bossPool == 0 then
		bossPool = { "Nightmare", "Bonemesh", "The Butcher", "Puke Pus", "The Tickle Monster" }
	end

	local chosenBoss = forcedBossClass and lib.ResolveClassName(forcedBossClass) or bossPool[math.random(1, #bossPool)]
	local bossCfg = lib.GetClassConfig(chosenBoss)
	if not bossCfg then return nil end

	local shouldBeCrow = ZS.ShouldNPCsBeCrows()

	-- Prefer promoting an active undead NPC slot cleanly so the Boss uses an existing bot identity (O(N) scan)
	local candidates = lib.GetNPCs(false)
	local promoted = nil
	if #candidates > 0 then
		local bestFrags = -1
		for i = 1, #candidates do
			local c = candidates[i]
			if IsValid(c) and c:Frags() > bestFrags then
				bestFrags = c:Frags()
				promoted = c
			end
		end
		if IsValid(promoted) then
			if shouldBeCrow then
				promoted.m_NonCrowClass = bossCfg.Name
				if promoted.D3bot_RosterSlot then
					promoted.D3bot_RosterSlot.DeathClass = bossCfg.Name
				end
				return promoted
			end
			local spawnPos, spawnAng = ZS.SelectZombieSpawnPos(bossCfg)
			if spawnPos then
				promoted:SetPos(spawnPos)
				if spawnAng then promoted:SetAngles(spawnAng) end
			end
			promoted:ApplyZombieClass(bossCfg.Name)
		end
	elseif lib.Population and lib.Population.SpawnNPC then
		promoted = lib.Population.SpawnNPC(bossCfg.Name)
		if shouldBeCrow and IsValid(promoted) then
			return promoted
		end
	end

	if IsValid(promoted) and not shouldBeCrow then
		GAMEMODE.D3botNPC_LastBossWave = lib.GetCurrentWave()
		if lib.AI and lib.AI.RerollTarget then
			lib.AI.RerollTarget(promoted)
			lib.AI.UpdatePathImmediate(promoted)
		end
		if GAMEMODE.TopNotifyAll then
			local undeadCol = (team and team.GetColor and team.GetColor(TEAM_UNDEAD)) or Color(200, 60, 60)
			GAMEMODE:TopNotifyAll(undeadCol, promoted:GetNPCDisplayName(), color_white, " has risen as ", COLOR_RED, bossCfg.Name, color_white, "!")
		end
	end

	return promoted
end

function ZS.InstallGamemodeBridges()
	if not lib.IsZombieSurvivalReady() then return false end

	if not GAMEMODE.D3botNPC_OrigGetDesiredStartingZombies and isfunction(GAMEMODE.GetDesiredStartingZombies) then
		GAMEMODE.D3botNPC_OrigGetDesiredStartingZombies = GAMEMODE.GetDesiredStartingZombies
		GAMEMODE.GetDesiredStartingZombies = function(self)
			local baseDesired = self:D3botNPC_OrigGetDesiredStartingZombies()
			if lib.ConVars.Enabled:GetBool() and lib.ConVars.MinPlayersBridge:GetBool() then
				local realPlayers = player.GetAllActive and #player.GetAllActive() or #player.GetAll()
				local npcZombies = getEffectiveVirtualZombies()
				if realPlayers >= 1 and npcZombies > 0 and baseDesired <= 0 then
					local total = realPlayers + npcZombies
					return math.Clamp(math.ceil(total * (self.WaveOneZombies or 0.25)), 1, math.max(1, npcZombies))
				end
			end
			return baseDesired
		end
	end

	if not GAMEMODE.D3botNPC_OrigSetClosestsToZombie and GAMEMODE.SetClosestsToZombie then
		GAMEMODE.D3botNPC_OrigSetClosestsToZombie = GAMEMODE.SetClosestsToZombie
		GAMEMODE.SetClosestsToZombie = function(self)
			if lib.ConVars.Enabled:GetBool() and lib.ConVars.MinPlayersBridge:GetBool() then
				local realPlayers = player.GetAllActive and #player.GetAllActive() or #player.GetAll()
				local npcZombies = getEffectiveVirtualZombies()
				if realPlayers <= 1 and npcZombies > 0 then
					-- Sole human stays survivor; NPCs fill all starting zombies cleanly!
					if lib.Population and lib.Population.EnsureMinimumRoster then
						lib.Population.EnsureMinimumRoster()
					end
					return
				end
				-- For small co-op teams with enough NPC zombies already configured, count NPCs toward starting undead quota
				if realPlayers > 1 and npcZombies >= self:GetDesiredStartingZombies() then
					return
				end
			end
			return self:D3botNPC_OrigSetClosestsToZombie()
		end
	end

	if not GAMEMODE.D3botNPC_OrigCalculateInfliction and GAMEMODE.CalculateInfliction then
		GAMEMODE.D3botNPC_OrigCalculateInfliction = GAMEMODE.CalculateInfliction
		GAMEMODE.CalculateInfliction = function(self, victim, attacker)
			local infliction = self:D3botNPC_OrigCalculateInfliction(victim, attacker)
			if not lib.ConVars.Enabled:GetBool() or not lib.ConVars.ContributeInfliction:GetBool() then
				return infliction
			end
			if self.RoundEnded or self:GetWave() == 0 then
				return infliction
			end

			-- Gentle virtual class-unlock infliction capped strictly below 1.0 so solo/co-op players
			-- see ZS higher-tier zombie classes unlock organically across waves without ending rounds early.
			local wave = self:GetWave()
			local numWaves = math.max(self.GetNumberOfWaves and self:GetNumberOfWaves() or 6, 1)
			local npcKills = self.D3botNPC_Kills or 0
			local virtualInf = math.Clamp((wave - 1) / numWaves * 0.65 + npcKills * 0.012, 0, 0.85)
			local unlockThreshold = math.max(infliction or 0, virtualInf)

			if not self:IsClassicMode() and not self.ZombieEscape and not self:IsBabyMode() and not self.PantsMode then
				for k, v in ipairs(self.ZombieClasses or {}) do
					if v.Infliction and unlockThreshold >= v.Infliction and not self:IsClassUnlocked(v.Name) then
						v.Unlocked = true
						for _, ent in pairs(ents.FindByClass("logic_classunlock")) do
							if ent.Class == string.lower(v.Name) then
								ent:Input("onclassunlocked", ent, ent, v.Name)
							end
						end
						if not v.Locked then
							net.Start("zs_classunlockstate")
								net.WriteInt(k, 8)
								net.WriteBool(v.Unlocked)
							net.Broadcast()
							for _, pl in pairs(player.GetAll()) do
								if pl.CenterNotify and translate then
									pl:CenterNotify(COLOR_RED, translate.ClientFormat(pl, "infliction_reached", v.Infliction * 100))
									pl:CenterNotify(translate.ClientFormat(pl, "x_unlocked", translate.ClientGet(pl, v.TranslationName)))
								end
							end
						end
					end
				end
			end

			return infliction
		end
	end

	ZS.BridgesInstalled = true
	return true
end

-- 3. Damage & Point Attribution + Complete Crow Zero-Damage Enforcement
hook.Add("EntityTakeDamage", lib.HookId .. ".ZSDamageCompat", function(ent, dmginfo)
	local attacker = dmginfo:GetAttacker()
	local inflictor = dmginfo:GetInflictor()

	-- Harmless Crows: never deal damage to players, sigils, barricades, or deployables under any circumstance
	if IsValid(attacker) and attacker.IsD3botNPC and attacker.IsCrow and attacker:IsCrow() then
		dmginfo:SetDamage(0)
		return true
	end
	if IsValid(inflictor) and inflictor.IsD3botNPC and inflictor.IsCrow and inflictor:IsCrow() then
		dmginfo:SetDamage(0)
		return true
	end
	if IsValid(attacker) and attacker.GetOwner then
		local owner = attacker:GetOwner()
		if IsValid(owner) and owner.IsD3botNPC and owner.IsCrow and owner:IsCrow() then
			dmginfo:SetDamage(0)
			return true
		end
	end

	if not IsValid(ent) or not ent.IsD3botNPC then return end

	local dmg = dmginfo:GetDamage()

	-- Prevent undead players/NPCs from hurting zombie NPCs unless self/world
	if IsValid(attacker) and (attacker.IsD3botNPC or (attacker:IsPlayer() and attacker:Team() == TEAM_UNDEAD)) and attacker ~= ent then
		dmginfo:SetDamage(0)
		return true
	end

	if dmg <= 0 then return end

	if IsValid(attacker) and attacker:IsPlayer() and attacker:Team() == TEAM_HUMAN then
		ent.DamagedBy = ent.DamagedBy or {}
		ent.DamagedBy[attacker] = (ent.DamagedBy[attacker] or 0) + dmg
		ent.LastAttacker = attacker
		ent.LastAttacked = CurTime()

		-- Award ZS Damage-to-Points Queue & Damage Floater matching ZS GM:EntityTakeDamage
		local pointsMul = (POINTSMULTIPLIER or 1)
		local pointRatio = (GAMEMODE and GAMEMODE.PointRatio) or 100
		if attacker.PointQueue ~= nil then
			attacker.PointQueue = attacker.PointQueue + (dmg / pointRatio) * pointsMul
		end
		if IsValid(inflictor) and inflictor.PointsMultiplier then
			attacker.PointQueue = (attacker.PointQueue or 0) + (dmg / pointRatio) * (inflictor.PointsMultiplier - 1)
		end

		local dmgpos = dmginfo:GetDamagePosition()
		if dmgpos == vector_origin then
			dmgpos = ent:WorldSpaceCenter()
		end
		attacker.LastDamageDealtPos = dmgpos

		local hasDmgSess = attacker.HasDamageNumberSession and attacker:HasDamageNumberSession()
		if hasDmgSess and attacker.CollectDamageNumberSession then
			attacker:CollectDamageNumberSession(dmg, dmgpos, true)
		elseif GAMEMODE and GAMEMODE.DamageFloater then
			GAMEMODE:DamageFloater(attacker, ent, dmgpos, dmg, true)
		end
	end
end)

-- 4. Zombie Friendly-Fire & Crow vs Any-Player Damage Prevention
hook.Add("PlayerShouldTakeDamage", lib.HookId .. ".PreventUndeadFF", function(pl, attacker)
	if not IsValid(pl) or not pl:IsPlayer() then return end
	if not IsValid(attacker) then return end

	local attackerNpc = attacker.IsD3botNPC and attacker or (attacker.GetOwner and attacker:GetOwner())
	if IsValid(attackerNpc) and attackerNpc.IsD3botNPC then
		if attackerNpc.IsCrow and attackerNpc:IsCrow() then
			return false
		end
		if pl:Team() == (TEAM_UNDEAD or 3) then
			return false
		end
	end
end)

-- 5. Kill Attribution, Points Cash-Out, ZS TopNotify Killfeed & Link Lethality Recording
function ZS.OnNPCZombieKilled(npc, dmginfo)
	if not IsValid(npc) then return end

	local attacker = dmginfo and dmginfo:GetAttacker() or npc.LastAttacker
	local inflictor = dmginfo and dmginfo:GetInflictor() or attacker

	-- Record NPC bot death statistic onto persistent Roster slot and invoke ported D3bot OnDeath handler
	if npc.D3bot_RosterSlot and lib.Roster and lib.Roster.AddDeath then
		lib.Roster.AddDeath(npc.D3bot_RosterSlot, 1)
	end
	if not npc.m_SilentRecycle and lib.OnHandlerNPCDeath then
		lib.OnHandlerNPCDeath(npc)
	elseif npc.D3bot_RosterSlot and not npc.m_SilentRecycle and not npc:IsCrow() and not npc.D3bot_RosterSlot.ForcedClass
		and lib.Population and lib.Population.SelectSpawnClass then
		local nextCfg = lib.Population.SelectSpawnClass()
		if nextCfg and not nextCfg.IsCrow then
			npc.D3bot_RosterSlot.DeathClass = nextCfg.Name
		end
	end

	-- Record link death cost for D3bot smart path avoidance
	local mem = npc.D3bot_Mem
	if mem and mem.NodeOrNil then
		lib.NodeMetadata_ZombieDeath(mem.NodeOrNil)
		if mem.NextNodeOrNil then
			local link = lib.UsingSourceNav
				and (IsValid(mem.NodeOrNil) and IsValid(mem.NextNodeOrNil) and mem.NodeOrNil:D3botNPC_SharesLink(mem.NextNodeOrNil))
				or (mem.NodeOrNil.LinkByLinkedNode and mem.NodeOrNil.LinkByLinkedNode[mem.NextNodeOrNil])
			if link then
				lib.LinkMetadata_ZombieDeath(link, lib.LinkDeathCostRaise)
			end
		end
	end

	if GAMEMODE and GAMEMODE.RoundEnded then return end
	if not IsValid(attacker) or not attacker:IsPlayer() or attacker:Team() ~= TEAM_HUMAN then return end

	if npc:IsCrow() then
		attacker.CrowKills = (attacker.CrowKills or 0) + 1
		if GAMEMODE and GAMEMODE.TopNotifyAll then
			local infClass = IsValid(inflictor) and inflictor:GetClass() or "default"
			local undeadCol = (team and team.GetColor and team.GetColor(TEAM_UNDEAD)) or Color(200, 60, 60)
			GAMEMODE:TopNotifyAll(attacker, " ", { killicon = infClass }, " ", undeadCol, npc:GetNPCDisplayName() .. " (Crow)")
		end
		hook.Run("D3botNPC_OnZombieKilled", npc, attacker, inflictor, dmginfo, nil, false)
		return
	end

	local totalDamage = 0
	for otherPl, d in pairs(npc.DamagedBy or {}) do
		if IsValid(otherPl) and otherPl:IsPlayer() and otherPl:Team() == TEAM_HUMAN then
			totalDamage = totalDamage + d
		end
	end

	local mostAssistDamage = 0
	local halfTotal = totalDamage * 0.5
	local mostDamager = nil
	for otherPl, d in pairs(npc.DamagedBy or {}) do
		if otherPl ~= attacker and IsValid(otherPl) and otherPl:IsPlayer() and otherPl:Team() == TEAM_HUMAN
			and d > mostAssistDamage and d >= halfTotal then
			mostAssistDamage = d
			mostDamager = otherPl
		end
	end

	attacker.ZombiesKilled = (attacker.ZombiesKilled or 0) + 1
	local headshot = npc:WasHitInHead()
	if headshot then
		attacker.Headshots = (attacker.Headshots or 0) + 1
	end

	local classtab = npc:GetZombieClassTable()
	if (classtab.Points or 0) > 0 then
		if attacker.PointCashOut then
			if IsValid(mostDamager) then
				attacker:PointCashOut(npc, FM_LOCALKILLOTHERASSIST)
				if mostDamager.PointCashOut then
					mostDamager:PointCashOut(npc, FM_LOCALASSISTOTHERKILL)
				end
				mostDamager.ZombiesKilledAssists = (mostDamager.ZombiesKilledAssists or 0) + 1
			else
				attacker:PointCashOut(npc, FM_NONE)
			end
		elseif attacker.AddPoints then
			attacker:AddPoints(classtab.Points or 3)
		end
	end

	if IsValid(inflictor) and inflictor == attacker:GetActiveWeapon() then
		local wep = inflictor
		if attacker.MeleeMovementSpeedOnKill and attacker.MeleeMovementSpeedOnKill ~= 0 and wep.IsMelee and attacker.GiveStatus then
			local boost = attacker:GiveStatus("adrenalineamp", 10)
			if IsValid(boost) and boost.SetSpeed then
				boost:SetSpeed(attacker.MeleeMovementSpeedOnKill)
			end
		end
		if GAMEMODE and GAMEMODE.StatTracking and GAMEMODE.StatTracking.IncreaseElementKV then
			GAMEMODE.StatTracking:IncreaseElementKV(STATTRACK_TYPE_WEAPON, wep:GetClass(), "Kills", 1)
		end
		if wep.OnZombieKilled then
			pcall(wep.OnZombieKilled, wep, npc, totalDamage, dmginfo)
		end
	end

	if lib.ConVars.ContributeInfliction and lib.ConVars.ContributeInfliction:GetBool() and GAMEMODE then
		GAMEMODE.D3botNPC_Kills = (GAMEMODE.D3botNPC_Kills or 0) + 1
	end

	-- ZS native top-right killfeed notification displaying the NPC's persistent bot Name
	if GAMEMODE and GAMEMODE.TopNotifyAll then
		local infClass = IsValid(inflictor) and inflictor:GetClass() or "default"
		local undeadCol = (team and team.GetColor and team.GetColor(TEAM_UNDEAD)) or Color(200, 60, 60)
		local displayName = npc:GetNPCDisplayName()
		if IsValid(mostDamager) then
			GAMEMODE:TopNotifyAll(
				attacker, " & ", mostDamager, " ",
				{ killicon = infClass, headshot = headshot }, " ",
				undeadCol, displayName
			)
		else
			GAMEMODE:TopNotifyAll(
				attacker, " ",
				{ killicon = infClass, headshot = headshot }, " ",
				undeadCol, displayName
			)
		end
	end

	hook.Run("D3botNPC_OnZombieKilled", npc, attacker, inflictor, dmginfo, mostDamager, headshot)
end

-- 6. When an NPC kills a human, mirror ZS GM:ZombieKilledHuman side effects + credit Bot Name & Frags + crisp TopNotifyAll
hook.Add("DoPlayerDeath", lib.HookId .. ".NPCKilledHuman", function(pl, attacker, dmginfo)
	if not IsValid(pl) or not pl:IsPlayer() or pl:Team() ~= TEAM_HUMAN then return end

	local npcAttacker = attacker
	if IsValid(attacker) and not attacker.IsD3botNPC and attacker.GetOwner then
		local owner = attacker:GetOwner()
		if IsValid(owner) and owner.IsD3botNPC then
			npcAttacker = owner
		end
	end

	if not IsValid(npcAttacker) or not npcAttacker.IsD3botNPC then return end
	if not GAMEMODE or GAMEMODE.RoundEnded then return end

	if not pl.Gibbed and pl.GiveStatus then
		local status = pl:GiveStatus("revive_slump_human")
		if IsValid(status) then
			if status.SetReviveTime then status:SetReviveTime(CurTime() + 4) end
			if status.SetZombieInitializeTime then status:SetZombieInitializeTime(CurTime() + 2) end
		end
		if pl.SetZombieClassName then
			local reviveClass = GAMEMODE.ZombieEscape and "Super Zombie"
				or (GAMEMODE.IsClassicMode and GAMEMODE:IsClassicMode() and "Classic Zombie")
				or (GAMEMODE.IsBabyMode and GAMEMODE:IsBabyMode() and "Gore Child")
				or "Fresh Dead"
			pl:SetZombieClassName(reviveClass)
		end
	end

	npcAttacker.NPCBrainsEaten = (npcAttacker.NPCBrainsEaten or 0) + 1
	if npcAttacker.D3bot_RosterSlot and lib.Roster and lib.Roster.AddFrag then
		lib.Roster.AddFrag(npcAttacker.D3bot_RosterSlot, 1)
	end

	local cfg = npcAttacker:GetClassConfig()
	local clsName = cfg and cfg.Name
	if clsName and GAMEMODE.StatTracking and GAMEMODE.StatTracking.IncreaseElementKV then
		GAMEMODE.StatTracking:IncreaseElementKV(STATTRACK_TYPE_ZOMBIECLASS, clsName, "BrainsEaten", 1)
	end

	if GAMEMODE.TopNotifyAll then
		local undeadCol = (team and team.GetColor and team.GetColor(TEAM_UNDEAD)) or Color(200, 60, 60)
		local killIcon = (cfg and cfg.SWEP) or "weapon_zs_zombie"
		GAMEMODE:TopNotifyAll(undeadCol, npcAttacker:GetNPCDisplayName(), " ", { killicon = killIcon }, " ", pl)
	end
end)

-- 7. Wrap ZS deployables & prop_obj_sigil so turrets/zappers target zombies and sigils accept real NextBot damage
lib.SigilStats = lib.SigilStats or { Native = 0, Fallback = 0 }

function ZS.ApplySigilDamage(sigil, npc, dmgAmount, dmginfo)
	if not IsValid(sigil) or sigil:GetClass() ~= "prop_obj_sigil" then return false end
	if not IsValid(npc) or not npc.IsD3botNPC or not npc:Alive() or (npc.IsCrow and npc:IsCrow()) then return false end
	if GAMEMODE and GAMEMODE.RoundEnded then return false end
	if sigil.GetSigilCorrupted and sigil:GetSigilCorrupted() then return false end
	if sigil.IsSigilCorrupted and sigil:IsSigilCorrupted() then return false end

	local amt = tonumber(dmgAmount) or 0
	if amt <= 0 then return false end

	local curHp = sigil.GetSigilHealth and tonumber(sigil:GetSigilHealth()) or 0
	if curHp <= 0 then return false end

	lib.SigilStats.Fallback = lib.SigilStats.Fallback + 1
	local newHp = math.max(0, curHp - amt)
	if sigil.SetSigilLastDamaged then
		sigil:SetSigilLastDamaged(CurTime())
	end
	if sigil.SetSigilHealth then
		sigil:SetSigilHealth(newHp)
	end

	npc.D3bot_LastDamage = CurTime()

	if newHp <= 0 and not sigil.D3botNPC_Corrupting then
		sigil.D3botNPC_Corrupting = true
		if sigil.SetSigilCorrupted then
			sigil:SetSigilCorrupted(true)
		end
		if GAMEMODE and GAMEMODE.SigilCorrupted and dmginfo then
			pcall(gamemode.Call, "SigilCorrupted", sigil, dmginfo)
		end
		if lib.AI and lib.AI.RerollTarget then
			for _, other in ipairs(lib.GetNPCs(false)) do
				if IsValid(other) and other.D3bot_Mem and other.D3bot_Mem.TgtOrNil == sigil then
					lib.AI.RerollTarget(other)
				end
			end
		end
		sigil.D3botNPC_Corrupting = nil
	end

	return true
end

function ZS.PatchDeployableTargeting()
	local turretClasses = { "prop_gunturret", "prop_gunturret_beam", "prop_gunturret_rocket" }
	for _, cls in ipairs(turretClasses) do
		local stored = scripted_ents.GetStored(cls)
		local entTab = stored and stored.t
		if entTab and entTab.IsValidTarget and not entTab.D3botNPC_PatchedTarget then
			local origIsValidTarget = entTab.IsValidTarget
			entTab.IsValidTarget = function(self, target)
				if IsValid(target) and target.IsD3botNPC and target:Alive() then
					local ct = target:GetZombieClassTable()
					if ct and ct.NoTurretTarget then return false end
					if self:GetForward():Dot(self:GetAnglesToTarget(target):Forward()) < (self.MinimumAimDot or 0.5) then
						return false
					end
					if TrueVisibleFilters then
						return TrueVisibleFilters(self:ShootPos(), self:GetTargetPos(target), self, self.Hitbox)
					end
					return true
				end
				return origIsValidTarget(self, target)
			end
			entTab.D3botNPC_PatchedTarget = true
		end
	end

	local zapperClasses = { "prop_zapper", "prop_zapper_arc" }
	for _, cls in ipairs(zapperClasses) do
		local stored = scripted_ents.GetStored(cls)
		local entTab = stored and stored.t
		if entTab and entTab.FindZapperTarget and not entTab.D3botNPC_PatchedZapper then
			local origFind = entTab.FindZapperTarget
			entTab.FindZapperTarget = function(self, pos, owner)
				local target = origFind(self, pos, owner)
				if IsValid(target) then return target end

				local range = 135 * ((IsValid(owner) and owner.FieldRangeMul) or 1)
				local bestTarget = nil
				local bestHealth = 99999
				for _, ent in ipairs(ents.FindInSphere(pos, range)) do
					if IsValid(ent) and ent.IsD3botNPC and ent:Alive() and not ent:IsCrow() then
						local isHC = ent:IsHeadcrab()
						if (isHC or ent:Health() < bestHealth) and (not TrueVisibleFilters or TrueVisibleFilters(pos, ent:NearestPoint(pos), self, ent)) then
							bestHealth = ent:Health()
							bestTarget = ent
							if isHC then break end
						end
					end
				end
				return bestTarget
			end
			entTab.D3botNPC_PatchedZapper = true
		end
	end

	-- Bridge JetBoom ZS prop_obj_sigil:OnTakeDamage when ZS rejects non-player base_nextbot attackers
	local sigilStored = scripted_ents.GetStored("prop_obj_sigil")
	local sigilTab = sigilStored and sigilStored.t
	if sigilTab and sigilTab.OnTakeDamage and not sigilTab.D3botNPC_PatchedSigilDmg then
		local origSigilDamage = sigilTab.OnTakeDamage
		sigilTab.OnTakeDamage = function(self, dmginfo)
			local attacker = dmginfo and dmginfo:GetAttacker()
			local beforeHp = (not self.D3botNPC_Corrupting and self.GetSigilHealth) and tonumber(self:GetSigilHealth()) or nil
			local res = origSigilDamage(self, dmginfo)
			if beforeHp and beforeHp > 0 and IsValid(attacker) and attacker.IsD3botNPC and attacker:Alive() and not (attacker.IsCrow and attacker:IsCrow()) then
				local stillCorrupted = (self.GetSigilCorrupted and self:GetSigilCorrupted()) or (self.IsSigilCorrupted and self:IsSigilCorrupted())
				local afterHp = self.GetSigilHealth and tonumber(self:GetSigilHealth()) or beforeHp
				if afterHp < beforeHp or stillCorrupted then
					lib.SigilStats.Native = lib.SigilStats.Native + 1
				elseif dmginfo:GetDamage() > 0 then
					ZS.ApplySigilDamage(self, attacker, dmginfo:GetDamage(), dmginfo)
				end
			end
			return res
		end
		sigilTab.D3botNPC_PatchedSigilDmg = true
	end
end

-- 8. Optional suppression of D3bot fake-player zombie spawns if D3bot is co-installed
function ZS.SyncD3botSuppression()
	if not D3bot then return end
	if lib.ConVars.Enabled:GetBool() and lib.ConVars.SuppressD3botSpawns:GetBool() then
		for _, bot in ipairs(player.GetBots()) do
			if IsValid(bot) and bot:Team() == TEAM_UNDEAD and bot.D3bot_Mem then
				bot:Kick("Replaced by D3bot NPC slotless zombies")
			end
		end
	end
end

-- 9. Navmesh Node Damage Trigger Tick (Indexed DMGPerSecond from D3bot navmesh nodes)
local nextNodeDamageTick = 0
hook.Add("Think", lib.HookId .. ".NodeDamageTick", function()
	if not lib.ConVars.Enabled:GetBool() or not lib.ConVars.NodeDamage:GetBool() then return end
	if lib.UsingSourceNav or not lib.MapNavMesh or not lib.MapNavMesh.NodeById then return end

	local dmgNodes = lib.MapNavMesh.DamageNodes
	if dmgNodes and #dmgNodes == 0 then return end

	local ct = CurTime()
	if ct < nextNodeDamageTick then return end
	nextNodeDamageTick = ct + (lib.NodeDamageInterval or 1.0)

	if not dmgNodes and lib.MapNavMesh.RebuildParamIndexes then
		lib.MapNavMesh:RebuildParamIndexes()
		dmgNodes = lib.MapNavMesh.DamageNodes
	end
	if not dmgNodes or #dmgNodes == 0 then return end

	local wave = lib.GetCurrentWave()
	local humanTargets = lib.RemoveObsDeadTgts(team.GetPlayers(TEAM_HUMAN))
	local extraEnts = {}
	for _, pat in ipairs(lib.NodeDamageEnts) do
		for _, ent in ipairs(ents.FindByClass(pat)) do
			if IsValid(ent) then extraEnts[#extraEnts + 1] = ent end
		end
	end

	local worldEnt = game.GetWorld()
	for i = 1, #dmgNodes do
		local node = dmgNodes[i]
		local dps = node.Params and tonumber(node.Params.DMGPerSecond)
		if dps and dps > 0 and not lib.IsNavMeshNodeBlocked(node.Params, node.Pos, wave) then
			local amt = dps * (lib.NodeDamageInterval or 1.0)
			for j = 1, #humanTargets do
				local ply = humanTargets[j]
				if node:GetContains(ply:GetPos(), 64) then
					local dInfo = DamageInfo()
					dInfo:SetDamage(amt)
					dInfo:SetAttacker(worldEnt)
					dInfo:SetInflictor(worldEnt)
					dInfo:SetDamageType(DMG_GENERIC)
					dInfo:SetDamagePosition(ply:WorldSpaceCenter())
					dInfo:SetDamageForce(Vector(0, 0, -120))
					ply:TakeDamageInfo(dInfo)
				end
			end
			for j = 1, #extraEnts do
				local ent = extraEnts[j]
				if node:GetContains(ent:GetPos(), 64) then
					local dInfo = DamageInfo()
					dInfo:SetDamage(amt)
					dInfo:SetAttacker(worldEnt)
					dInfo:SetInflictor(worldEnt)
					dInfo:SetDamageType(DMG_GENERIC)
					dInfo:SetDamagePosition(ent:WorldSpaceCenter())
					dInfo:SetDamageForce(Vector(0, 0, -120))
					ent:TakeDamageInfo(dInfo)
				end
			end
		end
	end
end)

-- 10. Round Lifecycle Cleanup, Intermission Crow Transitions, and Solo Wave0 Ready Bridge
function ZS.RemoveAllNPCs(clearRoster)
	local removed = 0
	for _, npc in ipairs(lib.GetNPCs(true)) do
		if IsValid(npc) then
			lib.UnregisterNPC(npc)
			if clearRoster then npc.m_RosterRemoved = true end
			npc:Remove()
			removed = removed + 1
		end
	end
	for _, ent in ipairs(ents.FindByClass(lib.NPCEntityClass)) do
		if IsValid(ent) then
			if clearRoster then ent.m_RosterRemoved = true end
			ent:Remove()
			removed = removed + 1
		end
	end
	if clearRoster and lib.Roster and lib.Roster.ClearAll then
		lib.Roster.ClearAll()
	end
	return removed
end

local function runDeferredZSBootstrap()
	if not lib.IsZombieSurvivalReady() then return false end
	ZS.InstallGamemodeBridges()
	ZS.PatchDeployableTargeting()
	ZS.SyncD3botSuppression()
	ZS.CapSoloWaveZeroTimer()
	if lib.Population and lib.Population.EnsureMinimumRoster then
		lib.Population.EnsureMinimumRoster()
	end
	ZS.ApplyLifecycleState()
	return true
end

hook.Add("OnGamemodeLoaded", lib.HookId .. ".OnGamemodeLoadedInit", function()
	timer.Simple(0.1, runDeferredZSBootstrap)
end)

hook.Add("InitPostEntity", lib.HookId .. ".InitZSPatch", function()
	timer.Simple(0.25, function()
		if not runDeferredZSBootstrap() then
			timer.Simple(0.75, runDeferredZSBootstrap)
		end
	end)
end)

hook.Add("PlayerInitialSpawn", lib.HookId .. ".SoloWaveZeroCap", function()
	timer.Simple(0.5, function()
		if not lib.IsZombieSurvivalReady() then return end
		if not ZS.BridgesInstalled then
			runDeferredZSBootstrap()
			return
		end
		ZS.CapSoloWaveZeroTimer()
		if lib.Population and lib.Population.EnsureMinimumRoster then
			lib.Population.EnsureMinimumRoster()
		end
		ZS.ApplyLifecycleState()
	end)
end)

hook.Add("PreRestartRound", lib.HookId .. ".RoundCleanup", function()
	if GAMEMODE then
		GAMEMODE.D3botNPC_Kills = 0
		GAMEMODE.D3botNPC_LastBossWave = nil
	end
	ZS.RemoveAllNPCs(false)
	if lib.Roster and lib.Roster.ResetStatsForNewRound then
		lib.Roster.ResetStatsForNewRound()
	end
	if lib.Population and lib.Population.ResetRoundTimer then
		lib.Population.ResetRoundTimer()
	end
	if lib.Population and lib.Population.ResetQueue then
		lib.Population.ResetQueue()
	end
	if lib.AI and lib.AI.ResetPathQueue then
		lib.AI.ResetPathQueue()
	end
	if lib.ResetNodeBlockCache then
		lib.ResetNodeBlockCache()
	end
	if lib.ResetPathCache then
		lib.ResetPathCache()
	end
	timer.Simple(0.5, function()
		if not lib.IsZombieSurvivalReady() then return end
		ZS.CapSoloWaveZeroTimer()
		if lib.Population and lib.Population.EnsureMinimumRoster then
			lib.Population.EnsureMinimumRoster()
		end
		ZS.ApplyLifecycleState()
		if lib.Population and lib.Population.SyncPopulationNow then
			lib.Population.SyncPopulationNow()
		end
	end)
end)

hook.Add("PostCleanupMap", lib.HookId .. ".MapCleanup", function()
	ZS.RemoveAllNPCs(false)
	if lib.Population and lib.Population.ResetQueue then
		lib.Population.ResetQueue()
	end
	if lib.AI and lib.AI.ResetPathQueue then
		lib.AI.ResetPathQueue()
	end
	if lib.ResetNodeBlockCache then
		lib.ResetNodeBlockCache()
	end
	if lib.ResetPathCache then
		lib.ResetPathCache()
	end
end)

hook.Add("SetWaveActive", lib.HookId .. ".WaveIntermission", function(active)
	timer.Simple(0.05, function()
		if not lib.IsZombieSurvivalReady() or GAMEMODE.RoundEnded then return end
		ZS.ApplyLifecycleState()

		if active then
			local wave = lib.GetCurrentWave()
			-- Boss Zombie check when virtual participants satisfy BossZombiePlayersRequired
			if lib.ConVars.Bosses and lib.ConVars.Bosses:GetBool()
				and GAMEMODE.BossZombies and not GAMEMODE.PantsMode
				and not (isfunction(GAMEMODE.IsClassicMode) and GAMEMODE:IsClassicMode())
				and not GAMEMODE.ZombieEscape
				and wave >= 2 then
				local totalParticipants = #player.GetAll() + (lib.Roster and lib.Roster.CountTotal() or 0)
				local req = GAMEMODE.BossZombiePlayersRequired or 8
				if (req <= 0 or totalParticipants >= req)
					and GAMEMODE.LastBossZombieSpawned ~= wave
					and GAMEMODE.D3botNPC_LastBossWave ~= wave then
					ZS.SpawnOrConvertBossNPC()
				end
			end
		end
	end)
end)
