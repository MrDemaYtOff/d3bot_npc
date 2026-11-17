-- Unique Bot Name Manager for D3bot NPC
-- Reuses D3bot's username generator lists while preventing name collisions
-- across both connected players and active persistent NPC roster slots.

local lib = D3botNPC

lib.NameLists = lib.NameLists or {}
include("names/fng_usernames.lua")
include("names/bottish.lua")

lib.NameLists.classic = {
	"Zombie", "Undead", "Crawler", "Stalker", "Shambler", "Drifter",
	"Ghoul", "Husk", "Revenant", "Walker", "Biter", "Lurker",
	"Risen", "Shade", "Wraith", "Gnawer"
}

local namePool = {}
local lastListKey = nil

local function getActiveListKey()
	local key = lib.ConVars.NameList and lib.ConVars.NameList:GetString() or "fng_usernames"
	if key == "" or not lib.NameLists[key] then
		key = "fng_usernames"
	end
	return key
end

local function collectTakenNames()
	local taken = {}
	for _, ply in ipairs(player.GetAll()) do
		if IsValid(ply) and ply.Nick then
			taken[ply:Nick()] = true
		end
	end
	if lib.Roster and lib.Roster.Slots then
		for _, slot in ipairs(lib.Roster.Slots) do
			if slot.Name then
				taken[slot.Name] = true
			end
		end
	end
	for _, npc in ipairs(lib.GetNPCs(true)) do
		if IsValid(npc) and npc.GetNPCDisplayName then
			taken[npc:GetNPCDisplayName()] = true
		end
	end
	return taken
end

function lib.ResetNamePool()
	namePool = {}
	lastListKey = nil
end

function lib.GenerateUniqueBotName(customName)
	local prefix = lib.ConVars.NamePrefix and lib.ConVars.NamePrefix:GetString() or ""
	local taken = collectTakenNames()

	local baseName
	if isstring(customName) and customName ~= "" then
		baseName = string.Trim(customName)
	else
		local listKey = getActiveListKey()
		if #namePool == 0 or lastListKey ~= listKey then
			lastListKey = listKey
			namePool = table.Copy(lib.NameLists[listKey] or lib.NameLists.fng_usernames or { "D3bot" })
		end
		baseName = table.remove(namePool, math.random(1, #namePool)) or "D3bot"
	end

	local candidate = prefix .. baseName
	if not taken[candidate] then
		return candidate
	end

	local suffix = 2
	while taken[candidate .. "(" .. suffix .. ")"] do
		suffix = suffix + 1
	end
	return candidate .. "(" .. suffix .. ")"
end
