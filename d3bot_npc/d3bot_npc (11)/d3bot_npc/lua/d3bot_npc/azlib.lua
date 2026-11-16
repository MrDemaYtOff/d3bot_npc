AddCSLuaFile()

-- Ported from AzBot / D3bot azlib.lua under the isolated D3botNPC namespace
-- Original authors: Azurblau (AzBot), Dadido3 & contributors (D3bot)

D3botNPC = D3botNPC or {}
local lib = D3botNPC

local consoleErrorColor = Color(255, 95, 40)
local consoleInfoColor = Color(110, 210, 130)

function lib.LogError(msg)
	MsgC(consoleErrorColor, "[D3botNPC Error] " .. tostring(msg) .. "\n")
end

function lib.LogInfo(msg)
	MsgC(consoleInfoColor, "[D3botNPC] ", color_white, tostring(msg) .. "\n")
end

function lib.TryInvoke(func, ...)
	if isfunction(func) then
		return func(...)
	end
end

function lib.TryCatch(func, onError)
	local didNotError, resultOrErr = xpcall(func, debug.traceback)
	if not didNotError and isfunction(onError) then
		onError(resultOrErr)
	end
	return didNotError, resultOrErr
end

function lib.TwoWay(a, b, func)
	func(a, b)
	func(b, a)
end

function lib.WriteOrAdd(tbl, k, v)
	if k == nil then
		table.insert(tbl, v)
	else
		tbl[k] = v
	end
end

lib.SortedQueueMeta = lib.SortedQueueMeta or { __index = {} }
local sortedQueueFallback = lib.SortedQueueMeta.__index

function lib.NewSortedQueue(func)
	return setmetatable({
		Set = {},
		Func = func
	}, lib.SortedQueueMeta)
end

function sortedQueueFallback:Enqueue(item)
	if self.Set[item] then return end
	self.Set[item] = true
	for idx, v in ipairs(self) do
		if self.Func(item, v) then
			return table.insert(self, idx, item)
		end
	end
	return table.insert(self, item)
end

function sortedQueueFallback:Dequeue()
	local item = table.remove(self)
	if item then
		self.Set[item] = nil
	end
	return item
end

function lib.GetSplitStr(str, separator)
	return str == "" and {} or string.Split(str, separator)
end

function lib.PairsByKeys(t, f)
	local a = {}
	for n in pairs(t) do
		table.insert(a, n)
	end
	table.sort(a, f)
	local i = 0
	return function()
		i = i + 1
		if a[i] == nil then
			return nil
		else
			return a[i], t[a[i]]
		end
	end
end

lib.QueryMeta = lib.QueryMeta or { __index = {} }
local queryFallback = lib.QueryMeta.__index

function lib.From(v)
	return setmetatable({ R = v }, lib.QueryMeta)
end

local from = lib.From

function queryFallback:Any(func)
	for k, v in pairs(self.R) do
		if func(k, v) then
			self.R = true
			return self
		end
	end
	self.R = false
	return self
end

function queryFallback:ShallowCopy()
	local r = {}
	for k, v in pairs(self.R) do r[k] = v end
	self.R = r
	return self
end

function queryFallback:Len()
	local len = 0
	for _ in ipairs(self.R) do len = len + 1 end
	self.R = len
	return self
end

function queryFallback:Ks()
	local r = {}
	for k in pairs(self.R) do table.insert(r, k) end
	self.R = r
	return self
end

function queryFallback:Sel(func)
	local r = {}
	for k, v in pairs(self.R) do lib.WriteOrAdd(r, func(k, v)) end
	self.R = r
	return self
end

function queryFallback:SelSort(func, sortFunc)
	local r = {}
	for k, v in lib.PairsByKeys(self.R, sortFunc) do lib.WriteOrAdd(r, func(k, v)) end
	self.R = r
	return self
end

function queryFallback:SelV(func)
	local r = {}
	for k, v in pairs(self.R) do r[k] = func(v) end
	self.R = r
	return self
end

function queryFallback:Where(func)
	local r = {}
	for k, v in pairs(self.R) do if func(k, v) then r[k] = v end end
	self.R = r
	return self
end

function queryFallback:VsSet()
	local r = {}
	for _, v in ipairs(self.R) do r[v] = true end
	self.R = r
	return self
end

function queryFallback:Concat()
	local r = {}
	for _, arr in ipairs(self.R) do
		for _, v in ipairs(arr) do
			table.insert(r, v)
		end
	end
	self.R = r
	return self
end

function queryFallback:Join(separator)
	self.R = string.Implode(separator, self.R)
	return self
end

function lib.GetEntsOfClss(clss)
	return from(clss):SelV(ents.FindByClass):Concat().R
end

lib.IsInitialized = true
