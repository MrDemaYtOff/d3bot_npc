-- Ported from D3bot sv_zs_bot_handler/node_metadata.lua and extended for crowd congestion tracking
-- Tracks per-link/per-node zombie lethality AND real-time horde occupancy so NPCs route around
-- lethal killzones AND distribute naturally across parallel corridors/stairs.

local lib = D3botNPC

lib.NodeMetadata = lib.NodeMetadata or {}
lib.LinkMetadata = lib.LinkMetadata or {}
lib.NodeCongestion = lib.NodeCongestion or {}
lib.LinkCongestion = lib.LinkCongestion or {}

function lib.ResetNodeMetadata()
	lib.NodeMetadata = {}
	lib.LinkMetadata = {}
	lib.NodeCongestion = {}
	lib.LinkCongestion = {}
end

function lib.LinkMetadata_ZombieDeath(link, raiseCost)
	if not link then return end
	if lib.UsingSourceNav and link.GetMetaData then
		local metadata = link:GetMetaData()
		metadata.ZombieDeathCost = (metadata.ZombieDeathCost or 0) + (raiseCost or lib.LinkDeathCostRaise)
		return
	end
	if not lib.LinkMetadata[link] then
		lib.LinkMetadata[link] = {}
	end
	local metadata = lib.LinkMetadata[link]
	metadata.ZombieDeathCost = (metadata.ZombieDeathCost or 0) + (raiseCost or lib.LinkDeathCostRaise)
end

function lib.NodeMetadata_ZombieDeath(node)
	if not node then return end
	if lib.UsingSourceNav and node.D3botNPC_GetMetaData then
		local metadata = node:D3botNPC_GetMetaData()
		metadata.ZombieDeathFactor = math.Clamp((metadata.ZombieDeathFactor or 0) + 0.1, 0, 1)
		return
	end
	if not lib.NodeMetadata[node] then
		lib.NodeMetadata[node] = {}
	end
	local metadata = lib.NodeMetadata[node]
	metadata.ZombieDeathFactor = math.Clamp((metadata.ZombieDeathFactor or 0) + 0.1, 0, 1)
end

function lib.GetLinkDeathCost(link)
	if not link then return 0 end
	if lib.UsingSourceNav and link.GetMetaData then
		return link:GetMetaData().ZombieDeathCost or 0
	end
	local meta = lib.LinkMetadata[link]
	return meta and meta.ZombieDeathCost or 0
end

function lib.GetNodeCongestionCount(node)
	return (node and lib.NodeCongestion[node]) or 0
end

function lib.GetLinkCongestionCount(link)
	return (link and lib.LinkCongestion[link]) or 0
end

local nextMetadataDecay = 0
hook.Add("Think", lib.HookId .. ".MetadataDecay", function()
	local ct = CurTime()
	if nextMetadataDecay > ct then return end
	nextMetadataDecay = ct + 10

	for link, meta in pairs(lib.LinkMetadata) do
		if meta.ZombieDeathCost then
			meta.ZombieDeathCost = meta.ZombieDeathCost * 0.9
			if meta.ZombieDeathCost < 10 then
				meta.ZombieDeathCost = nil
			end
		end
		if next(meta) == nil then
			lib.LinkMetadata[link] = nil
		end
	end

	for node, meta in pairs(lib.NodeMetadata) do
		if meta.ZombieDeathFactor then
			meta.ZombieDeathFactor = meta.ZombieDeathFactor * 0.85
			if meta.ZombieDeathFactor <= 0.1 then
				meta.ZombieDeathFactor = nil
			end
		end
		if next(meta) == nil then
			lib.NodeMetadata[node] = nil
		end
	end
end)

hook.Add("PreRestartRound", lib.HookId .. ".MetadataReset", function()
	lib.ResetNodeMetadata()
end)
