AddCSLuaFile()

-- Persistent Virtual Bot Roster for D3bot NPC
-- Gives every slotless NPC a stable identity (BotID, Name, Team, Frags/Brains, Deaths, ZombieClass, Crow state)
-- across deaths, intermission crow transformations, and wave transitions without using any player slot.

local lib = D3botNPC

lib.Roster = lib.Roster or {}
local Roster = lib.Roster

Roster.Slots = Roster.Slots or {}
Roster.ById = Roster.ById or {}
Roster.NextBotID = Roster.NextBotID or 1

if SERVER then
	util.AddNetworkString("d3bot_npc_roster_sync")
end

local function sanitizeTeam(t)
	if t == TEAM_HUMAN or t == TEAM_SPECTATOR or t == TEAM_UNDEAD then
		return t
	end
	return TEAM_UNDEAD or 3
end

function Roster.GetAll()
	return Roster.Slots
end

function Roster.GetById(botId)
	return Roster.ById[tonumber(botId) or -1]
end

function Roster.CountByTeam(teamId)
	local count = 0
	for _, slot in ipairs(Roster.Slots) do
		if slot.Team == teamId then
			count = count + 1
		end
	end
	return count
end

function Roster.CountTotal()
	return #Roster.Slots
end

function Roster.FindSlot(query)
	if not query or query == "" then return nil end

	-- Direct number or "#12" BotID
	local cleanId = tostring(query):gsub("^#", "")
	local asNum = tonumber(cleanId)
	if asNum and Roster.ById[asNum] then
		return Roster.ById[asNum]
	end

	local lower = string.lower(tostring(query))
	-- Exact case-insensitive match first
	for _, slot in ipairs(Roster.Slots) do
		if slot.Name and string.lower(slot.Name) == lower then
			return slot
		end
	end
	-- Substring match
	for _, slot in ipairs(Roster.Slots) do
		if slot.Name and string.find(string.lower(slot.Name), lower, 1, true) then
			return slot
		end
	end
	return nil
end

if SERVER then
	function Roster.BroadcastSync(targetPly)
		if IsValid(targetPly) then
			if not targetPly:IsPlayer() or targetPly:IsBot() then return end
		else
			if player.GetHumanCount and player.GetHumanCount() == 0 then return end
			if #player.GetHumans() == 0 then return end
		end

		net.Start("d3bot_npc_roster_sync")
		local count = math.min(#Roster.Slots, 511)
		net.WriteUInt(count, 9)
		for i = 1, count do
			local slot = Roster.Slots[i]
			net.WriteUInt(slot.BotID or i, 16)
			net.WriteString(slot.Name or "Bot")
			net.WriteUInt(sanitizeTeam(slot.Team), 8)
			net.WriteInt(slot.Frags or 0, 16)
			net.WriteUInt(math.max(0, slot.Deaths or 0), 16)
			net.WriteString(slot.ZombieClass or "Zombie")
			net.WriteBool(slot.IsCrow == true)
			net.WriteBool(slot.IsAlive == true)
			net.WriteUInt(IsValid(slot.Entity) and slot.Entity:EntIndex() or 0, 16)
		end
		if IsValid(targetPly) then
			net.Send(targetPly)
		else
			net.Broadcast()
		end
	end

	local syncScheduled = false
	function Roster.ScheduleSync()
		if syncScheduled then return end
		if #player.GetHumans() == 0 then return end
		syncScheduled = true
		timer.Simple(0.20, function()
			syncScheduled = false
			Roster.BroadcastSync()
		end)
	end

	function Roster.CreateSlot(opts)
		opts = opts or {}
		local botId = Roster.NextBotID
		Roster.NextBotID = Roster.NextBotID + 1

		local slot = {
			BotID = botId,
			Name = lib.GenerateUniqueBotName(opts.Name),
			Team = sanitizeTeam(opts.Team or TEAM_UNDEAD),
			Frags = 0,
			Deaths = 0,
			BrainsEaten = 0,
			ZombieClass = opts.ZombieClass or "Zombie",
			DeathClass = opts.DeathClass or opts.ZombieClass or "Zombie",
			ForcedClass = opts.ForcedClass or nil,
			IsCrow = opts.IsCrow == true,
			IsAlive = false,
			Entity = NULL,
			EntIndex = 0,
			LastDeathAt = 0,
			CreatedAt = CurTime()
		}

		table.insert(Roster.Slots, slot)
		Roster.ById[botId] = slot
		Roster.ScheduleSync()
		return slot
	end

	function Roster.RemoveSlot(slotOrId)
		local slot = istable(slotOrId) and slotOrId or Roster.ById[tonumber(slotOrId) or -1]
		if not slot then return false end

		if IsValid(slot.Entity) then
			lib.UnregisterNPC(slot.Entity)
			slot.Entity.m_RosterRemoved = true
			slot.Entity:Remove()
		end

		Roster.ById[slot.BotID] = nil
		for i, entry in ipairs(Roster.Slots) do
			if entry == slot then
				table.remove(Roster.Slots, i)
				break
			end
		end

		Roster.ScheduleSync()
		return true
	end

	function Roster.ClearAll()
		for i = #Roster.Slots, 1, -1 do
			local slot = Roster.Slots[i]
			if IsValid(slot.Entity) then
				lib.UnregisterNPC(slot.Entity)
				slot.Entity.m_RosterRemoved = true
				slot.Entity:Remove()
			end
		end
		Roster.Slots = {}
		Roster.ById = {}
		Roster.NextBotID = 1
		if lib.ResetNamePool then
			lib.ResetNamePool()
		end
		Roster.BroadcastSync()
	end

	function Roster.ResetStatsForNewRound()
		local startAsCrow = (lib.ZS and lib.ZS.ShouldNPCsBeCrows and lib.ZS.ShouldNPCsBeCrows()) == true
		for _, slot in ipairs(Roster.Slots) do
			slot.Frags = 0
			slot.Deaths = 0
			slot.BrainsEaten = 0
			slot.IsCrow = startAsCrow
			slot.IsAlive = false
			slot.LastDeathAt = 0
			if not startAsCrow and slot.ZombieClass == "Crow" then
				slot.ZombieClass = slot.DeathClass or slot.ForcedClass or "Zombie"
			elseif startAsCrow then
				if slot.ZombieClass and slot.ZombieClass ~= "Crow" then
					slot.DeathClass = slot.ZombieClass
				end
				slot.ZombieClass = "Crow"
			end
			if IsValid(slot.Entity) then
				lib.UnregisterNPC(slot.Entity)
				slot.Entity.m_RosterRemoved = true
				slot.Entity:Remove()
			end
			slot.Entity = NULL
			slot.EntIndex = 0
		end
		Roster.ScheduleSync()
	end

	function Roster.BindEntity(slot, npc)
		if not slot or not IsValid(npc) then return end
		slot.Entity = npc
		slot.EntIndex = npc:EntIndex()
		slot.IsAlive = true
		npc.D3bot_RosterSlot = slot
		if npc.SetNPCBotID then npc:SetNPCBotID(slot.BotID) end
		if npc.SetNPCName then npc:SetNPCName(slot.Name) end
		if npc.SetNPCFrags then npc:SetNPCFrags(slot.Frags) end
		if npc.SetNPCDeaths then npc:SetNPCDeaths(slot.Deaths) end
		if npc.SetNPCTeam then npc:SetNPCTeam(slot.Team) end
		if npc.SetNPCCrow then npc:SetNPCCrow(slot.IsCrow == true) end
		Roster.ScheduleSync()
	end

	function Roster.UnbindEntityOnDeath(npc)
		if not IsValid(npc) then return end
		local slot = npc.D3bot_RosterSlot
		if not slot then return end
		slot.IsAlive = false
		slot.Entity = NULL
		slot.EntIndex = 0
		slot.LastDeathAt = CurTime()
		Roster.ScheduleSync()
	end

	function Roster.RenameSlot(slot, newName)
		if not slot or not isstring(newName) or string.Trim(newName) == "" then return nil end
		local unique = lib.GenerateUniqueBotName(newName)
		slot.Name = unique
		if IsValid(slot.Entity) and slot.Entity.SetNPCName then
			slot.Entity:SetNPCName(unique)
		end
		Roster.ScheduleSync()
		return unique
	end

	function Roster.AddFrag(slot, amount)
		if not slot then return end
		slot.Frags = (slot.Frags or 0) + (amount or 1)
		slot.BrainsEaten = (slot.BrainsEaten or 0) + (amount or 1)
		if IsValid(slot.Entity) and slot.Entity.SetNPCFrags then
			slot.Entity:SetNPCFrags(slot.Frags)
		end
		Roster.ScheduleSync()
	end

	function Roster.AddDeath(slot, amount)
		if not slot then return end
		slot.Deaths = (slot.Deaths or 0) + (amount or 1)
		if IsValid(slot.Entity) and slot.Entity.SetNPCDeaths then
			slot.Entity:SetNPCDeaths(slot.Deaths)
		end
		Roster.ScheduleSync()
	end

	function Roster.FindIdleRespawnableSlot()
		local delay = lib.ConVars.RespawnDelay and lib.ConVars.RespawnDelay:GetFloat() or 2.5
		local ct = CurTime()
		local bestSlot = nil
		local oldestDeath = math.huge

		for _, slot in ipairs(Roster.Slots) do
			if slot.Team == (TEAM_UNDEAD or 3) and not IsValid(slot.Entity) then
				if (slot.LastDeathAt or 0) + delay <= ct and (slot.LastDeathAt or 0) < oldestDeath then
					oldestDeath = slot.LastDeathAt or 0
					bestSlot = slot
				end
			end
		end
		return bestSlot
	end

	hook.Add("PlayerInitialSpawn", lib.HookId .. ".SendRosterOnJoin", function(ply)
		timer.Simple(1.5, function()
			if IsValid(ply) and not ply:IsBot() then
				Roster.BroadcastSync(ply)
			end
		end)
	end)
else
	net.Receive("d3bot_npc_roster_sync", function()
		local count = net.ReadUInt(9)
		local newSlots = {}
		local newById = {}
		for i = 1, count do
			local botId = net.ReadUInt(16)
			local slot = {
				BotID = botId,
				Name = net.ReadString(),
				Team = net.ReadUInt(8),
				Frags = net.ReadInt(16),
				Deaths = net.ReadUInt(16),
				ZombieClass = net.ReadString(),
				IsCrow = net.ReadBool(),
				IsAlive = net.ReadBool(),
				EntIndex = net.ReadUInt(16)
			}
			newSlots[i] = slot
			newById[botId] = slot
		end
		Roster.Slots = newSlots
		Roster.ById = newById
		if lib.ClientProxies then
			for id, _ in pairs(lib.ClientProxies) do
				if not newById[id] then
					lib.ClientProxies[id] = nil
				end
			end
		end
		hook.Run("D3botNPC_OnRosterUpdated")
	end)
end
