-- Client-side JetBoom Zombie Survival Scoreboard, Team Counts, TargetID, Killfeed & Labels for D3bot NPC
-- Integrates virtual slotless NPC roster cleanly into ZSScoreBoard, DTeamHeading, DPingMeter, HUDDrawTargetID,
-- and cleans up zs_death notifications without touching ZS core files or requiring player slots.

local lib = D3botNPC

language.Add("d3bot_npc_zombie", "Zombie")

-- 1. Client Virtual Player Proxies built from D3botNPC.Roster.Slots
lib.ClientProxies = lib.ClientProxies or {}

local ProxyMeta = {}
ProxyMeta.__index = ProxyMeta

function ProxyMeta:IsValid()
	return lib.Roster and lib.Roster.ById and lib.Roster.ById[self.BotID] ~= nil
end

function ProxyMeta:IsValidPlayer() return false end
function ProxyMeta:IsPlayer() return false end
function ProxyMeta:IsBot() return true end
function ProxyMeta:IsD3botNPCProxy() return true end
function ProxyMeta:IsSpectator() return self:Team() == (TEAM_SPECTATOR or 1002) end
function ProxyMeta:IsMuted() return true end
function ProxyMeta:Ping() return 0 end
function ProxyMeta:GetZSRemortLevel() return 0 end
function ProxyMeta:GetZSLevel() return 1 end
function ProxyMeta:SteamID() return "NPC_BOT_" .. tostring(self.BotID or 0) end
function ProxyMeta:UniqueID() return "d3bot_npc_" .. tostring(self.BotID or 0) end
function ProxyMeta:EntIndex()
	local s = self:GetSlot()
	return (s and s.EntIndex and s.EntIndex > 0) and s.EntIndex or (9000 + (self.BotID or 0))
end

function ProxyMeta:GetSlot()
	return lib.Roster and lib.Roster.ById and lib.Roster.ById[self.BotID]
end

function ProxyMeta:Name()
	local s = self:GetSlot()
	return (s and s.Name) or ("Bot #" .. tostring(self.BotID or 0))
end

ProxyMeta.Nick = ProxyMeta.Name
ProxyMeta.ClippedName = ProxyMeta.Name

function ProxyMeta:Frags()
	local s = self:GetSlot()
	return (s and s.Frags) or 0
end

function ProxyMeta:Deaths()
	local s = self:GetSlot()
	return (s and s.Deaths) or 0
end

function ProxyMeta:Team()
	local s = self:GetSlot()
	return (s and s.Team) or (TEAM_UNDEAD or 3)
end

function ProxyMeta:GetZombieClassTable()
	local s = self:GetSlot()
	local clsName = (s and (s.IsCrow and "Crow" or s.ZombieClass)) or "Zombie"
	if GAMEMODE and GAMEMODE.ZombieClasses and GAMEMODE.ZombieClasses[clsName] then
		return GAMEMODE.ZombieClasses[clsName]
	end
	if lib.GetClassConfig then
		return lib.GetClassConfig(clsName)
	end
	return { Name = clsName }
end

function lib.GetClientProxy(botId)
	local id = tonumber(botId)
	if not id then return nil end
	local proxy = lib.ClientProxies[id]
	if not proxy then
		proxy = setmetatable({ BotID = id }, ProxyMeta)
		lib.ClientProxies[id] = proxy
	end
	return proxy
end

-- 2. VGUI Extensions for ZSScoreBoard, ZSPlayerPanel, DPingMeter, and DTeamHeading
local function installScoreboardHooks()
	local sbCtrl = vgui.GetControlTable("ZSScoreBoard")
	if sbCtrl and not sbCtrl.D3botNPC_Patched then
		local origRefresh = sbCtrl.RefreshScoreboard
		sbCtrl.RefreshScoreboard = function(self)
			origRefresh(self)
			if not self.PlayerPanels then self.PlayerPanels = {} end

			-- Clean up stale NPC proxies removed from roster
			for pl, panel in pairs(self.PlayerPanels) do
				if istable(pl) and pl.IsD3botNPCProxy and not pl:IsValid() then
					self:RemovePlayerPanel(panel)
				end
			end

			-- Inject active virtual NPC roster slots into TAB scoreboard
			if lib.Roster and lib.Roster.Slots then
				for _, slot in ipairs(lib.Roster.Slots) do
					if slot.Team ~= (TEAM_SPECTATOR or 1002) then
						local proxy = lib.GetClientProxy(slot.BotID)
						if proxy and proxy:IsValid() then
							self:CreatePlayerPanel(proxy)
						end
					end
				end
			end
		end
		sbCtrl.D3botNPC_Patched = true
	end

	local panelCtrl = vgui.GetControlTable("ZSPlayerPanel")
	if panelCtrl and not panelCtrl.D3botNPC_Patched then
		local origSetPlayer = panelCtrl.SetPlayer
		local origRefreshPlayer = panelCtrl.RefreshPlayer

		panelCtrl.SetPlayer = function(self, pl)
			if istable(pl) and pl.IsD3botNPCProxy then
				self.m_Player = pl
				if IsValid(self.m_Avatar) then self.m_Avatar:SetVisible(false) end
				if IsValid(self.m_SpecialImage) then
					self.m_SpecialImage:SetImage("icon16/computer.png")
					self.m_SpecialImage:SetTooltip("D3bot Slotless NPC")
					self.m_SpecialImage:SetVisible(true)
				end
				if IsValid(self.m_PingMeter) then
					self.m_PingMeter:SetPlayer(pl)
				end
				self:RefreshPlayer()
				return
			end
			return origSetPlayer(self, pl)
		end

		panelCtrl.RefreshPlayer = function(self)
			local pl = self:GetPlayer()
			if istable(pl) and pl.IsD3botNPCProxy then
				if not pl:IsValid() then
					self:Remove()
					return
				end

				local name = pl:Name()
				if #name > 23 then
					name = string.sub(name, 1, 21) .. ".."
				end
				self.m_PlayerLabel:SetText(name)
				self.m_PlayerLabel:SetAlpha(240)
				self.m_ScoreLabel:SetText(pl:Frags())
				self.m_ScoreLabel:SetAlpha(240)
				self.m_RemortLabel:SetText("")

				local ct = pl:GetZombieClassTable()
				local localTeam = IsValid(MySelf) and MySelf:Team() or (TEAM_HUMAN or 4)
				if ct and ct.Icon and (localTeam == (TEAM_UNDEAD or 3) or localTeam == (TEAM_SPECTATOR or 1002)) then
					self.m_ClassImage:SetVisible(true)
					self.m_ClassImage:SetImage(ct.Icon)
					self.m_ClassImage:SetImageColor(ct.IconColor or color_white)
				else
					self.m_ClassImage:SetVisible(false)
				end

				if IsValid(self.m_Mute) then self.m_Mute:SetVisible(false) end
				if IsValid(self.m_Friend) then self.m_Friend:SetVisible(false) end

				self:SetZPos(-pl:Frags())
				if pl:Team() ~= self._LastTeam and IsValid(ScoreBoard) then
					self._LastTeam = pl:Team()
					self:SetParent(self._LastTeam == TEAM_HUMAN and ScoreBoard.HumanList or ScoreBoard.ZombieList)
				end
				self:InvalidateLayout()
				return
			end
			return origRefreshPlayer(self)
		end
		panelCtrl.D3botNPC_Patched = true
	end

	local pingCtrl = vgui.GetControlTable("DPingMeter")
	local npcPingTextColor = Color(170, 240, 170)
	if pingCtrl and not pingCtrl.D3botNPC_Patched then
		local origPaint = pingCtrl.Paint
		pingCtrl.Paint = function(self)
			local pl = self:GetPlayer()
			if istable(pl) and pl.IsD3botNPCProxy then
				local wid, hei = self:GetWide(), self:GetTall()
				surface.SetDrawColor(25, 25, 25, 200)
				surface.DrawRect(0, 0, wid, hei)
				surface.SetDrawColor(110, 175, 110, 180)
				surface.DrawOutlinedRect(0, 0, wid, hei)
				draw.SimpleText("NPC", "ZSScoreBoardPing", wid * 0.5, hei * 0.5, npcPingTextColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
				return true
			end
			return origPaint(self)
		end
		pingCtrl.D3botNPC_Patched = true
	end

	local headingCtrl = vgui.GetControlTable("DTeamHeading")
	if headingCtrl and not headingCtrl.D3botNPC_Patched then
		local origRefreshContents = headingCtrl.RefreshContents
		headingCtrl.RefreshContents = function(self)
			origRefreshContents(self)
			local teamid = self:GetTeam()
			local extra = (lib.Roster and lib.Roster.CountByTeam and lib.Roster.CountByTeam(teamid)) or 0
			if extra > 0 then
				self.m_TeamCountLabel:SetText(team.NumPlayers(teamid) + extra)
				self.m_TeamCountLabel:SizeToContents()
				self:InvalidateLayout()
			end
		end
		headingCtrl.D3botNPC_Patched = true
	end
end

-- 3. TargetID Bridge for Hovering d3bot_npc_zombie Entities
local targetTrace = { mask = MASK_SHOT, mins = Vector(-2, -2, -2), maxs = Vector(2, 2, 2), filter = {} }
local targetTraceFilter = targetTrace.filter
local npcTargetList = {}

local function installTargetIDAndDeathNoticeHooks()
	if GAMEMODE and GAMEMODE.HUDDrawTargetID and not GAMEMODE.D3botNPC_PatchedTargetID then
		local origHUDDrawTargetID = GAMEMODE.HUDDrawTargetID
		GAMEMODE.HUDDrawTargetID = function(self, teamid)
			origHUDDrawTargetID(self, teamid)

			if not IsValid(MySelf) then return end
			local myTeam = MySelf:Team()
			local isSpectator = MySelf:IsSpectator()
			local showEnemy = lib.ConVars.ShowEnemyTargetID and lib.ConVars.ShowEnemyTargetID:GetBool()
			local canSeeUndeadID = (myTeam == (TEAM_UNDEAD or 3)) or isSpectator or showEnemy
			if not canSeeUndeadID then return end

			local start = EyePos()
			targetTrace.start = start
			targetTrace.endpos = start + EyeVector() * 2048
			targetTraceFilter[1] = MySelf.TargetIDFilter or MySelf
			targetTraceFilter[2] = MySelf:GetObserverTarget()

			local ent = util.TraceHull(targetTrace).Entity
			if IsValid(ent) and ent.IsD3botNPC and ent:Alive() then
				npcTargetList[ent] = CurTime()
			end

			for npcEnt, t in pairs(npcTargetList) do
				if IsValid(npcEnt) and npcEnt.Alive and npcEnt:Alive() and CurTime() < t + 1.5 then
					self:DrawTargetID(npcEnt, 1 - math.Clamp((CurTime() - t) / 1.5, 0, 1))
				else
					npcTargetList[npcEnt] = nil
				end
			end
		end
		GAMEMODE.D3botNPC_PatchedTargetID = true
	end

	-- Replace generic "#d3bot_npc_zombie" zs_death message since server emits named TopNotifyAll
	if net and net.Receivers and net.Receivers["zs_death"] and not lib.ZSDeathPatched then
		net.Receivers["zs_death"] = function(length)
			local victim = net.ReadEntity()
			local inflictor = net.ReadString()
			local attackerClass = net.ReadString()
			local victimteam = net.ReadUInt(8)

			if attackerClass == (lib.NPCEntityClass or "d3bot_npc_zombie") or attackerClass == "#d3bot_npc_zombie" then
				if IsValid(victim) then
					if victim == MySelf and victimteam == TEAM_HUMAN then
						gamemode.Call("LocalPlayerDied")
					end
					if victim.CallZombieFunction5 then
						victim:CallZombieFunction5("OnKilled", "#" .. attackerClass, NULL, false, false, DamageInfo())
					end
				end
				return
			end

			-- Fallback cleanly for all other non-NPC world deaths
			if IsValid(victim) then
				local attacker = "#" .. attackerClass
				if victim == MySelf and victimteam == TEAM_HUMAN then
					gamemode.Call("LocalPlayerDied")
				end
				if victim.CallZombieFunction5 then
					victim:CallZombieFunction5("OnKilled", attacker, NULL, attacker == victim, false, DamageInfo())
				end
				local victimname = victim:Name()
				MsgC(team.GetColor(victimteam), victimname, color_white, " was killed by ", COLOR_YELLOW, attacker, color_white, " with ", COLOR_YELLOW, inflictor, "\n")
				if GAMEMODE and GAMEMODE.TopNotify then
					GAMEMODE:TopNotify(COLOR_RED, attacker, " ", { deathicon = inflictor }, " ", victim)
				end
			end
		end
		lib.ZSDeathPatched = true
	end
end

hook.Add("D3botNPC_OnRosterUpdated", lib.HookId .. ".RefreshSBOnSync", function()
	if IsValid(ScoreBoard) and ScoreBoard:IsVisible() and ScoreBoard.RefreshScoreboard then
		ScoreBoard:RefreshScoreboard()
	end
end)

hook.Add("Initialize", lib.HookId .. ".ClientInit", function()
	if killicon and killicon.AddAlias then
		killicon.AddAlias("d3bot_npc_zombie", "weapon_zs_zombie")
	end
end)

hook.Add("InitPostEntity", lib.HookId .. ".ClientZSPatches", function()
	timer.Simple(0.35, function()
		installScoreboardHooks()
		installTargetIDAndDeathNoticeHooks()
	end)
end)
