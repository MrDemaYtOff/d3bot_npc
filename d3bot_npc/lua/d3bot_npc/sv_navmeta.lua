-- Ported from D3bot sv_navmeta.lua
-- Provides CNavArea and CNavLink metadata compatibility when falling back to Source .nav meshes.

local lib = D3botNPC

local CNavArea = FindMetaTable("CNavArea")
if not CNavArea then return end

lib.NavAreaMetadata = lib.NavAreaMetadata or {}
lib.NavAreaLinks = lib.NavAreaLinks or {}

local CNavLink = {}
CNavLink.__index = CNavLink

function lib.NewCNavLink(areaA, areaB, metaData)
	return setmetatable({
		area1 = areaA,
		area2 = areaB,
		metaData = metaData or { Params = {} }
	}, CNavLink)
end

function CNavLink:GetLinkedAreas()
	return self.area1, self.area2
end

function CNavLink:GetMetaData()
	if not self.metaData then
		self.metaData = { Params = {} }
	end
	self.metaData.Params = self.metaData.Params or {}
	return self.metaData
end

function CNavLink:GetFocusPos()
	return LerpVector(0.5, self.area1:GetCenter(), self.area2:GetCenter())
end

function CNavArea:D3botNPC_GetMetaData()
	local id = self:GetID()
	local data = lib.NavAreaMetadata[id]
	if not data then
		data = { Params = {} }
		lib.NavAreaMetadata[id] = data
	end
	data.Params = data.Params or {}
	return data
end

function CNavArea:D3botNPC_CreateLink(area, data)
	local idSelf = self:GetID()
	local idOther = area:GetID()
	local areaLinksSelf = lib.NavAreaLinks[idSelf] or {}
	local areaLinksOther = lib.NavAreaLinks[idOther] or {}
	local link = lib.NewCNavLink(self, area, data)
	areaLinksSelf[#areaLinksSelf + 1] = link
	areaLinksOther[#areaLinksOther + 1] = link
	lib.NavAreaLinks[idSelf] = areaLinksSelf
	lib.NavAreaLinks[idOther] = areaLinksOther
	return link
end

function CNavArea:D3botNPC_SharesLink(area)
	if not IsValid(area) then return false end
	local idSelf = self:GetID()
	local areaLinks = lib.NavAreaLinks[idSelf]
	if not areaLinks then
		areaLinks = {}
		lib.NavAreaLinks[idSelf] = areaLinks
	end
	for _, link in ipairs(areaLinks) do
		local a1, a2 = link:GetLinkedAreas()
		if (self == a1 or self == a2) and (area == a1 or area == a2) then
			return link
		end
	end
	return false
end

function CNavArea:D3botNPC_GetClosestPointOnArea(pos)
	if self.GetClosestPointOnArea then
		return self:GetClosestPointOnArea(pos)
	end
	return self:GetCenter()
end

function lib.SetupSourceNavLinks()
	if not lib.UsingSourceNav or not navmesh or not navmesh.IsLoaded() then return end

	lib.NavAreaMetadata = {}
	lib.NavAreaLinks = {}

	for _, area in pairs(navmesh.GetAllNavAreas()) do
		for _, neighbor in pairs(area:GetAdjacentAreas()) do
			if not area:D3botNPC_SharesLink(neighbor) and area:IsConnected(neighbor) then
				local link = area:D3botNPC_CreateLink(neighbor)
				local linkData = link:GetMetaData()

				if area:HasAttributes(NAV_MESH_WALK) and neighbor:HasAttributes(NAV_MESH_WALK) then
					linkData.Params.Walking = "Needed"
				end
				if area:HasAttributes(NAV_MESH_CLIFF + NAV_MESH_RUN) then
					linkData.Params.Pouncing = "Needed"
				end
			end
		end

		local areaData = area:D3botNPC_GetMetaData()

		if area:HasAttributes(NAV_MESH_CLIFF + NAV_MESH_OBSTACLE_TOP) then
			areaData.Params.Climbing = "Needed"
		end
		if area:HasAttributes(NAV_MESH_JUMP) then
			areaData.Params.Jump, areaData.Params.JumpTo = "Always", "Always"
		end
		if area:HasAttributes(NAV_MESH_NO_JUMP) then
			areaData.Params.Jump, areaData.Params.JumpTo = "Disabled", "Disabled"
		end
		if area:HasAttributes(NAV_MESH_CROUCH) then
			areaData.Params.Duck, areaData.Params.DuckTo = "Always", "Always"
		end
		if area:HasAttributes(NAV_MESH_STAND) then
			areaData.Params.Duck, areaData.Params.DuckTo = "Disabled", "Disabled"
		end
		if area:HasAttributes(NAV_MESH_AVOID) then
			areaData.Params.See = "Disabled"
		end
		if area:HasAttributes(NAV_MESH_DONT_HIDE) then
			areaData.Params.Aim, areaData.Params.AimTo = "Straight", "Straight"
		end
		if area:HasAttributes(NAV_MESH_FUNC_COST) then
			areaData.Params.Cost = 150
		end
		if area:HasAttributes(NAV_MESH_TRANSIENT) then
			areaData.Params.Condition = "Unblocked"
		end
		if area:HasAttributes(NAV_MESH_NAV_BLOCKER) then
			areaData.Params.Condition = "Blocked"
		end
	end
end
