-- BloomRoute 3.5.0 (WoW Forever build) by ruin9k
-- Learn-as-you-go: ships with no node data. Every herb or mining vein you gather is
-- remembered by map and position, and the herbs and ores you pick are turned into
-- farming loops on the world map and minimap, with a next-stop tracker.

local ADDON = ...
BloomRoute = {}
local BR = BloomRoute
local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\media\\"

-- Gathering casts and what they gather
local GATHER_SPELLS = {
	["Herb Gathering"] = "herb", ["Herbalism"] = "herb",
	["Mining"] = "ore",
}

-- Name prefixes that are folded into the base node type, so rich, small, poor and
-- similar variants count as the same herb or vein ("Rich Thorium Vein" -> "Thorium Vein")
local VARIANT_PREFIXES = { "Ooze Covered ", "Rich ", "Small ", "Poor ", "Stunted ", "Wilted " }

local LEARN_DISTANCE = 20   -- yards: a gather this close to a known spawn of the same type is that spawn

local DEFAULTS = {
	selected = {},       -- [type name] = true for every herb or ore you're farming
	types = {},          -- [type name] = { kind = "herb" | "ore" }, learned as you gather
	spawns = {},         -- [type name][mapID] = { {u, v}, ... } learned spawn points (0-1 map coords)
	map = true,          -- draw the loop on the world map
	minimapPath = true,  -- draw the loop on the minimap
	tracker = true,      -- main window shown
	radius = 25,         -- yards: reaching this close to a stop clears it
	dotSpacing = 9,      -- map pixels between trail dots
	progress = {},       -- [route key] = index of the next stop
	progressId = {},     -- [route key] = node id of the next stop
	reverse = {},        -- [route key] = true when the loop runs backwards
	minimap = { angle = 200, hide = false },
	memory = true,       -- skip nodes you checked until they respawn
	nodes = {},          -- [node id] = time() you last checked or picked it
	respawnDefault = 15, -- minutes
	respawn = {},        -- [type] = minutes
	respawnZone = {},    -- [type|mapID] = minutes
	ignored = {},        -- [node id] = true
	colors = {
		trail = { 1, 0.54, 0.24 },
		ring = { 1, 0.82, 0.25 },
		target = { 0.3, 0.9, 0.55 },
	},
	ringsByType = true,
	variants = {},       -- [variant] = false to leave that variant out of loops ("Poor", "Rich", ...)
	pickerTab = "herb",
	optionsTab = "general",
}
local DEFAULT_COLORS = {
	trail = { 1, 0.54, 0.24 }, ring = { 1, 0.82, 0.25 }, target = { 0.3, 0.9, 0.55 },
}
local PALETTE = {
	{ 1, 0.82, 0.25 }, { 0.45, 0.75, 1 }, { 1, 0.45, 0.75 }, { 0.6, 1, 0.4 },
	{ 0.85, 0.6, 1 }, { 1, 0.6, 0.3 }, { 0.4, 1, 0.9 }, { 1, 1, 0.6 },
}
local GRAY = { 0.45, 0.45, 0.45 }
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local db
local overlay, tracker, picker, options, minimapButton, mmFrame
local playerMap            -- uiMapID you're on
local lastU, lastV         -- your position (0-1) on playerMap

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cffff8a3dBloomRoute|r: " .. msg)
end

local function CopyDefaults(src, dst)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			CopyDefaults(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

-- Values the client hides from addons (Midnight-era "secret values") are treated as missing
local function Plain(v)
	if v == nil then return nil end
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

---------------------------------------------------------------------------
-- Maps
---------------------------------------------------------------------------

local sizeCache = {}
-- Width and height of a map in yards (from the game's own map-to-world conversion)
local function MapSize(map)
	local c = sizeCache[map]
	if c then return c end
	local w, h = 4000, 2666.67
	if C_Map.GetWorldPosFromMapPos and CreateVector2D then
		local _, p0 = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(0, 0))
		local _, p1 = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(1, 1))
		if p0 and p1 then
			local x0, y0 = p0:GetXY()
			local x1, y1 = p1:GetXY()
			if math.abs(y1 - y0) > 1 and math.abs(x1 - x0) > 1 then
				w, h = math.abs(y1 - y0), math.abs(x1 - x0)
			end
		end
	end
	local info = C_Map.GetMapInfo(map)
	c = { width = w, height = h, name = (info and info.name) or ("Map " .. map) }
	sizeCache[map] = c
	return c
end

local function MapName(map)
	return MapSize(map).name
end

-- yards between two points (u, v in 0-1) on a map
local function Yards(map, u1, v1, u2, v2)
	local s = MapSize(map)
	local dx, dy = (u2 - u1) * s.width, (v2 - v1) * s.height
	return math.sqrt(dx * dx + dy * dy), dx, dy
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function Compass(dx, dy)
	local ang = math.deg(math.atan2(dx, -dy))
	if ang < 0 then ang = ang + 360 end
	return DIRS[(math.floor((ang + 22.5) / 45) % 8) + 1]
end

local function PlayerPosition()
	local map = C_Map.GetBestMapForUnit("player")
	map = Plain(map)
	if not map then return nil end
	local pos = C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return map end
	local u, v = pos:GetXY()
	u, v = Plain(u), Plain(v)
	if not u or (u == 0 and v == 0) then return map end
	return map, u, v
end

local function PlayerFacing()
	return Plain(GetPlayerFacing and GetPlayerFacing())
end

---------------------------------------------------------------------------
-- Node types and selection
---------------------------------------------------------------------------

-- Strips variant prefixes ("Ooze Covered Rich Thorium Vein" -> "Thorium Vein") and returns
-- the base name plus the variants that were stripped ("Normal" when there were none)
local function BaseName(name)
	local variants = {}
	local found = true
	while found do
		found = false
		for i = 1, #VARIANT_PREFIXES do
			local p = VARIANT_PREFIXES[i]
			if string.sub(name, 1, #p) == p then
				variants[string.sub(p, 1, -2)] = true
				name = string.sub(name, #p + 1)
				found = true
			end
		end
	end
	if not next(variants) then variants.Normal = true end
	return name, variants
end

-- A spawn stays on the loop if any variant seen there is turned on. Spawns learned before
-- variants were recorded count as normal.
local function VariantAllowed(s)
	local seen = s[4]
	if type(seen) ~= "table" or seen.Normal then return true end
	for v in pairs(seen) do
		if db.variants[v] ~= false then return true end
	end
	return false
end

-- learned types of one kind, sorted by name
local function TypesOfKind(kind)
	local list = {}
	for name, t in pairs(db.types) do
		if t.kind == kind then table.insert(list, name) end
	end
	table.sort(list)
	return list
end

-- selected types: herbs first, then ores, each by name
local function Selected()
	local list = {}
	for _, kind in ipairs({ "herb", "ore" }) do
		for _, name in ipairs(TypesOfKind(kind)) do
			if db.selected[name] then table.insert(list, name) end
		end
	end
	return list
end

local function TypeColor(name)
	local sel = Selected()
	for i = 1, #sel do
		if sel[i] == name then return PALETTE[((i - 1) % #PALETTE) + 1] end
	end
	return PALETTE[1]
end

local function StopColor(name)
	if db.ringsByType and #Selected() > 1 then return TypeColor(name) end
	return db.colors.ring
end

local function SpawnCount(name, map)
	local s = db.spawns[name] and db.spawns[name][map]
	return s and #s or 0
end

local function TotalSpawns(name)
	local n = 0
	for _, list in pairs(db.spawns[name] or {}) do n = n + #list end
	return n
end

local function ZoneList(names, limit)
	local totals, maps = {}, {}
	for _, name in ipairs(names) do
		for map, list in pairs(db.spawns[name] or {}) do
			if #list > 0 then
				if not totals[map] then totals[map] = 0; table.insert(maps, map) end
				totals[map] = totals[map] + #list
			end
		end
	end
	table.sort(maps, function(a, b) return totals[a] > totals[b] end)
	local out = {}
	for i = 1, math.min(limit or 99, #maps) do
		table.insert(out, MapName(maps[i]) .. " (" .. totals[maps[i]] .. ")")
	end
	if #maps > #out then table.insert(out, "+" .. (#maps - #out) .. " more") end
	if #out == 0 then return "nowhere yet" end
	return table.concat(out, ", ")
end

local function SelectionLabel()
	local sel = Selected()
	if #sel == 0 then return "Pick herbs or ores..." end
	if #sel == 1 then return sel[1] end
	return sel[1] .. "  |cffa8968a+" .. (#sel - 1) .. " more|r"
end

---------------------------------------------------------------------------
-- Node memory and ignored nodes
---------------------------------------------------------------------------

local function NodeId(map, s)
	return s[3] .. "|" .. map .. "|" .. string.format("%.4f,%.4f", s[1], s[2])
end

function BR:RespawnMinutes(name, map)
	return db.respawnZone[name .. "|" .. map] or db.respawn[name] or db.respawnDefault
end

local function Cooldown(map, s)
	if not db.memory then return nil end
	local t = db.nodes[NodeId(map, s)]
	if not t then return nil end
	local left = t + BR:RespawnMinutes(s[3], map) * 60 - time()
	if left > 0 then return left end
end

local function MarkNode(map, s)
	if db.memory then db.nodes[NodeId(map, s)] = time() end
end

local function PruneMemory()
	local now = time()
	for id, t in pairs(db.nodes) do
		if now - t > 24 * 3600 then db.nodes[id] = nil end
	end
end

local ignoreVersion = 0

---------------------------------------------------------------------------
-- Routes (solved in game, a slice at a time)
---------------------------------------------------------------------------

local routeCache = {}
local job

-- Nearest-neighbor tour, 2-opt, then leave out far-off spots (keeps at least 80%).
local function Solve(pts, w, h)
	local n0 = #pts
	local ops = 0
	local function tick()
		ops = ops + 1
		if ops >= 4000 then ops = 0; coroutine.yield() end
	end
	local function D(i, j)
		local a, b = pts[i], pts[j]
		local dx, dy = (a[1] - b[1]) * w, (a[2] - b[2]) * h
		return math.sqrt(dx * dx + dy * dy)
	end
	if n0 <= 3 then
		local t = {}
		for i = 1, n0 do t[i] = i end
		return t, {}
	end
	local used, t = { [1] = true }, { 1 }
	for k = 2, n0 do
		local last, best, bd = t[k - 1]
		for j = 1, n0 do
			if not used[j] then
				local d = D(last, j)
				if not bd or d < bd then best, bd = j, d end
				tick()
			end
		end
		t[k] = best; used[best] = true
	end
	local function TwoOpt()
		local n = #t
		local improved = true
		while improved do
			improved = false
			for i = 1, n - 2 do
				for j = i + 2, n do
					if not (i == 1 and j == n) then
						local e = t[(j % n) + 1]
						if D(t[i], t[j]) + D(t[i + 1], e) < D(t[i], t[i + 1]) + D(t[j], e) - 0.01 then
							local lo, hi = i + 1, j
							while lo < hi do
								t[lo], t[hi] = t[hi], t[lo]
								lo, hi = lo + 1, hi - 1
							end
							improved = true
						end
						tick()
					end
				end
			end
		end
	end
	TwoOpt()
	local dropped = {}
	local minKeep = math.max(3, math.ceil(0.8 * n0))
	while #t > minKeep do
		local n = #t
		local legs = {}
		for i = 1, n do legs[i] = D(t[i], t[(i % n) + 1]) end
		table.sort(legs)
		local med = legs[math.floor((n + 1) / 2)]
		local best, bi
		for i = 1, n do
			local p, q = t[((i - 2 + n) % n) + 1], t[(i % n) + 1]
			local save = D(p, t[i]) + D(t[i], q) - D(p, q)
			if not best or save > best then best, bi = save, i end
		end
		if best <= 2 * med then break end
		table.insert(dropped, t[bi])
		table.remove(t, bi)
		TwoOpt()
	end
	return t, dropped
end

local function TypesOn(map)
	local list = {}
	for _, name in ipairs(Selected()) do
		if SpawnCount(name, map) > 0 then table.insert(list, name) end
	end
	return list
end

-- The loop for a map, or nil (nothing you farm has been seen there, or it's still being built)
local function Route(map)
	if not map then return nil end
	local names = TypesOn(map)
	if #names == 0 then return nil end
	local key = table.concat(names, "+") .. "|" .. map
	local count = 0
	for _, name in ipairs(names) do count = count + SpawnCount(name, map) end
	local cacheKey = key .. "#" .. count .. "#" .. ignoreVersion
	if routeCache[cacheKey] then return routeCache[cacheKey] end
	if not job then
		local pts, ignored = {}, {}
		for _, name in ipairs(names) do
			for _, p in ipairs(db.spawns[name][map]) do
				local s = { p[1], p[2], name, p[3] }
				if not VariantAllowed(s) then
					-- variant turned off in Options > Node Types
				elseif db.ignored[NodeId(map, s)] then
					table.insert(ignored, s)
				else
					table.insert(pts, s)
				end
			end
		end
		local size = MapSize(map)
		job = { map = map }
		job.co = coroutine.create(function()
			local order, drop = Solve(pts, size.width, size.height)
			local stops, skipped = {}, {}
			for i = 1, #order do stops[i] = pts[order[i]] end
			for i = 1, #drop do skipped[i] = pts[drop[i]] end
			routeCache[cacheKey] = {
				key = key, map = map, name = size.name, stops = stops, skipped = skipped,
				ignoredStops = ignored, types = names,
			}
		end)
	end
	return nil
end

local function Building(map)
	return job and job.map == map
end

local function SetProgress(map, route, i)
	db.progress[route.key] = i
	db.progressId[route.key] = i and route.stops[i] and NodeId(map, route.stops[i]) or nil
end

local function Target(map)
	local route = Route(map)
	if not route or #route.stops == 0 then return nil end
	local i, id = db.progress[route.key], db.progressId[route.key]
	local n = #route.stops
	if i and i >= 1 and i <= n and (not id or NodeId(map, route.stops[i]) == id) then return i end
	if id then
		for k = 1, n do
			if NodeId(map, route.stops[k]) == id then
				db.progress[route.key] = k
				return k
			end
		end
	end
	return nil
end

local function Wrap(i, n)
	return ((i - 1) % n) + 1
end

local function NextReady(map, route, from, dir)
	local n = #route.stops
	for k = 1, n - 1 do
		local i = Wrap(from + dir * k, n)
		if not Cooldown(map, route.stops[i]) then return i end
	end
	return Wrap(from + dir, n)
end

local function Nearest(map, u, v, readyOnly)
	local route = Route(map)
	local best, bestD
	for i = 1, #route.stops do
		local s = route.stops[i]
		if not readyOnly or not Cooldown(map, s) then
			local d = Yards(map, u, v, s[1], s[2])
			if not bestD or d < bestD then best, bestD = i, d end
		end
	end
	if not best and readyOnly then return Nearest(map, u, v, false) end
	return best
end

local function AllCooling(map, route)
	local soonest
	for i = 1, #route.stops do
		local left = Cooldown(map, route.stops[i])
		if not left then return nil end
		if not soonest or left < soonest then soonest = left end
	end
	return soonest
end

function BR:Direction(map)
	local route = Route(map)
	if route and db.reverse[route.key] then return -1 end
	return 1
end

local function FormatMinutes(sec)
	local m = math.ceil(sec / 60)
	if m <= 1 then return "under a minute" end
	return m .. " min"
end

---------------------------------------------------------------------------
-- World map overlay
---------------------------------------------------------------------------

local dots, pins, crosses = {}, {}, {}

local function Canvas()
	return WorldMapFrame.ScrollContainer.Child
end

local function CanvasScale()
	return (WorldMapFrame.GetCanvasScale and WorldMapFrame:GetCanvasScale()) or 1
end

local function GetDot(i)
	local t = dots[i]
	if not t then
		t = overlay:CreateTexture(nil, "ARTWORK")
		t:SetTexture(MEDIA .. "dot")
		dots[i] = t
	end
	return t
end

local function GetCross(i)
	local t = crosses[i]
	if not t then
		t = overlay:CreateTexture(nil, "OVERLAY")
		t:SetTexture(MEDIA .. "cross")
		crosses[i] = t
	end
	return t
end

local function PinOnEnter(self)
	local route = Route(self.map)
	if not route or not route.stops[self.index] then return end
	local s = route.stops[self.index]
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(s[3] .. " - stop " .. self.index .. " of " .. #route.stops, 1, 0.54, 0.24)
	GameTooltip:AddLine(string.format("%.1f, %.1f", s[1] * 100, s[2] * 100), 1, 1, 1)
	local left = Cooldown(self.map, s)
	if left then GameTooltip:AddLine("Checked recently - ready in about " .. FormatMinutes(left), 0.7, 0.7, 0.7) end
	GameTooltip:AddLine("Click to make this the next stop", 0.6, 0.6, 0.6)
	GameTooltip:AddLine("Shift-right-click to ignore this node", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function PinOnClick(self, button)
	if button == "RightButton" then
		if IsShiftKeyDown() then BR:IgnoreStop(self.map, self.index) end
	else
		BR:SetTarget(self.map, self.index)
	end
end

local function GetPin(i)
	local b = pins[i]
	if not b then
		b = CreateFrame("Button", nil, overlay)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b.tex = b:CreateTexture(nil, "ARTWORK")
		b.tex:SetAllPoints(b)
		b.tex:SetTexture(MEDIA .. "dot")
		b.ring = b:CreateTexture(nil, "OVERLAY")
		b.ring:SetPoint("CENTER", b, "CENTER", 0, 0)
		b.ring:SetTexture(MEDIA .. "ring")
		b.label = b:CreateFontString(nil, "OVERLAY")
		b.label:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
		b.label:SetTextColor(1, 1, 1)
		b.label:SetPoint("BOTTOMLEFT", b, "TOPRIGHT", -3, -4)
		b:SetScript("OnEnter", PinOnEnter)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetScript("OnClick", PinOnClick)
		pins[i] = b
	end
	return b
end

local function HideMap()
	for _, t in ipairs(dots) do t:Hide() end
	for _, t in ipairs(pins) do t:Hide() end
	for _, t in ipairs(crosses) do t:Hide() end
end

function BR:DrawMap()
	if not overlay or not WorldMapFrame:IsShown() then return end
	HideMap()
	local map = WorldMapFrame:GetMapID()
	local route = db.map and map and Route(map)
	if not route then
		overlay.pending = db.map and map and Building(map)
		return
	end
	overlay.pending = nil
	local canvas = Canvas()
	local W, H = canvas:GetWidth(), canvas:GetHeight()
	local k = 1 / CanvasScale()           -- keep pins the same size on screen at any zoom
	overlay.drawnScale = CanvasScale()
	local n = #route.stops
	local target = Target(map)
	local trail = db.colors.trail
	local dotN = 0

	if n > 1 then
		for i = 1, n do
			local a, b = route.stops[i], route.stops[(i % n) + 1]
			local ax, ay = a[1] * W, -a[2] * H
			local bx, by = b[1] * W, -b[2] * H
			local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
			local steps = math.floor(len / (db.dotSpacing * k))
			for s = 1, steps - 1 do
				local f = s / steps
				dotN = dotN + 1
				local t = GetDot(dotN)
				t:SetSize(6 * k, 6 * k)
				t:SetVertexColor(trail[1], trail[2], trail[3], 0.95)
				t:ClearAllPoints()
				t:SetPoint("CENTER", overlay, "TOPLEFT", ax + (bx - ax) * f, ay + (by - ay) * f)
				t:Show()
			end
		end
	end

	for i = 1, n do
		local s = route.stops[i]
		local p = GetPin(i)
		p.map, p.index = map, i
		p:SetSize(12 * k, 12 * k)
		p.ring:SetSize(26 * k, 26 * k)
		p.label:SetFont(STANDARD_TEXT_FONT, math.max(1, 9 * k), "OUTLINE")
		p:ClearAllPoints()
		p:SetPoint("CENTER", overlay, "TOPLEFT", s[1] * W, -s[2] * H)
		p.label:SetText(i)
		if i == target then
			local c = db.colors.target
			p.tex:SetVertexColor(c[1], c[2], c[3])
			p.ring:SetVertexColor(c[1], c[2], c[3], 1)
			p.ring:Show()
		else
			local c = StopColor(s[3])
			if Cooldown(map, s) then c = GRAY end
			p.tex:SetVertexColor(c[1], c[2], c[3])
			p.ring:Hide()
		end
		p:Show()
	end

	local nc = 0
	local function Cross(s, r, g, b, a)
		nc = nc + 1
		local c = GetCross(nc)
		c:SetSize(14 * k, 14 * k)
		c:SetVertexColor(r, g, b, a)
		c:ClearAllPoints()
		c:SetPoint("CENTER", overlay, "TOPLEFT", s[1] * W, -s[2] * H)
		c:Show()
	end
	for _, s in ipairs(route.skipped) do Cross(s, 0.9, 0.28, 0.3, 1) end
	for _, s in ipairs(route.ignoredStops) do Cross(s, 0.55, 0.55, 0.55, 0.9) end
end

local function CreateOverlay()
	overlay = CreateFrame("Frame", "BloomRouteMapOverlay", Canvas())
	overlay:SetAllPoints(Canvas())
	overlay:SetFrameLevel(Canvas():GetFrameLevel() + 20)
	overlay:SetScript("OnUpdate", function(self)
		if self.pending or (self.drawnScale and self.drawnScale ~= CanvasScale()) then BR:DrawMap() end
	end)
	hooksecurefunc(WorldMapFrame, "OnMapChanged", function() BR:DrawMap() end)
	WorldMapFrame:HookScript("OnShow", function() BR:DrawMap() end)
end

---------------------------------------------------------------------------
-- Minimap path
---------------------------------------------------------------------------

local MINIMAP_RADIUS = {
	outdoor = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 },
	indoor = { [0] = 150, 120, 90, 60, 40, 25 },
}
local mmDots, mmPins = {}, {}

local function MMTexture(pool, i, size, texture)
	local t = pool[i]
	if not t then
		t = mmFrame:CreateTexture(nil, "OVERLAY")
		t:SetTexture(MEDIA .. texture)
		pool[i] = t
	end
	t:SetSize(size, size)
	return t
end

function BR:UpdateMinimapPath()
	if not mmFrame then return end
	local nDots, nPins = 0, 0
	local route = db.minimapPath and playerMap and Route(playerMap)
	local map, u, v = PlayerPosition()
	if route and map == playerMap and u then
		local size = MapSize(map)
		local half = Minimap:GetWidth() / 2
		local radii = IsIndoors() and MINIMAP_RADIUS.indoor or MINIMAP_RADIUS.outdoor
		local R = radii[Minimap:GetZoom()] or radii[0]
		local scale = half / R
		local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
		local lim = half - 4
		local rotate = GetCVar("rotateMinimap") == "1"
		local facing = rotate and PlayerFacing() or 0
		local cf, sf = math.cos(facing), math.sin(facing)
		local function Inside(ox, oy)
			if square then return math.abs(ox) <= lim and math.abs(oy) <= lim end
			return ox * ox + oy * oy <= lim * lim
		end
		local function Offset(s)
			local ox = (s[1] - u) * size.width * scale
			local oy = -(s[2] - v) * size.height * scale
			if rotate then return ox * cf + oy * sf, -ox * sf + oy * cf end
			return ox, oy
		end
		local n = #route.stops
		local target = Target(map)
		local tc = db.colors.trail
		if n > 1 then
			local reach = half + 20
			for i = 1, n do
				local ax, ay = Offset(route.stops[i])
				local bx, by = Offset(route.stops[(i % n) + 1])
				if not ((ax > reach and bx > reach) or (ax < -reach and bx < -reach)
					or (ay > reach and by > reach) or (ay < -reach and by < -reach)) then
					local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
					local steps = math.floor(len / 7)
					for s = 1, steps - 1 do
						local f = s / steps
						local ox, oy = ax + (bx - ax) * f, ay + (by - ay) * f
						if Inside(ox, oy) and nDots < 400 then
							nDots = nDots + 1
							local t = MMTexture(mmDots, nDots, 4, "dot")
							t:SetVertexColor(tc[1], tc[2], tc[3], 0.9)
							t:ClearAllPoints()
							t:SetPoint("CENTER", mmFrame, "CENTER", ox, oy)
							t:Show()
						end
					end
				end
			end
		end
		-- each ring's outer edge is the reach radius
		local ring = math.max(6, 2 * db.radius * scale)
		for i = 1, n do
			local s = route.stops[i]
			local ox, oy = Offset(s)
			local isTarget = (i == target)
			if Inside(ox, oy) or isTarget then
				if not Inside(ox, oy) then
					if square then
						local m = math.max(math.abs(ox), math.abs(oy))
						ox, oy = ox / m * lim, oy / m * lim
					else
						local d = math.sqrt(ox * ox + oy * oy)
						ox, oy = ox / d * lim, oy / d * lim
					end
				end
				nPins = nPins + 1
				local t = MMTexture(mmPins, nPins, ring, "hollow")
				local c
				if isTarget then c = db.colors.target
				else
					c = StopColor(s[3])
					if Cooldown(map, s) then c = GRAY end
				end
				t:SetVertexColor(c[1], c[2], c[3])
				t:ClearAllPoints()
				t:SetPoint("CENTER", mmFrame, "CENTER", ox, oy)
				t:Show()
			end
		end
	end
	for i = nDots + 1, #mmDots do mmDots[i]:Hide() end
	for i = nPins + 1, #mmPins do mmPins[i]:Hide() end
end

local function CreateMinimapPath()
	mmFrame = CreateFrame("Frame", "BloomRouteMinimapPath", Minimap)
	mmFrame:SetAllPoints(Minimap)
	mmFrame:SetFrameLevel(Minimap:GetFrameLevel() + 2)
	mmFrame.elapsed = 0
	mmFrame:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		if self.elapsed < 0.05 then return end
		self.elapsed = 0
		BR:UpdateMinimapPath()
	end)
end

---------------------------------------------------------------------------
-- Picker (Herbs and Ores tabs, filled with what you've learned)
---------------------------------------------------------------------------

local PICK_W, PICK_H, PICK_ROWS = 200, 20, 14

local function MakeButton(parent, label, width, tip, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 20)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(tip, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function MakePanel(name, width, height)
	local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
	f:SetSize(width, height)
	f:SetFrameStrata("DIALOG")
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(0.08, 0.06, 0.05, 0.95)
	f:SetBackdropBorderColor(1, 0.54, 0.24, 0.9)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOP", f, "TOP", 0, -10)
	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
	f:Hide()
	tinsert(UISpecialFrames, name)
	return f
end

local function CheckText(c)
	return c.Text or c.text or _G[(c:GetName() or "") .. "Text"]
end

local function CreatePicker()
	local f = MakePanel("BloomRoutePicker", 2 * PICK_W + 20, PICK_ROWS * PICK_H + 96)

	f.tabs = {}
	for i, t in ipairs({ { "herb", "Herbs" }, { "ore", "Ores" } }) do
		local tab = MakeButton(f, t[2], 80, "Show learned " .. string.lower(t[2]), function(self)
			db.pickerTab = self.kind
			f.Refresh()
		end)
		tab:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * 84, -30)
		tab.kind = t[1]
		f.tabs[i] = tab
	end

	f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -64)
	f.empty:SetWidth(2 * PICK_W - 10)
	f.empty:SetJustifyH("LEFT")

	f.rows = {}
	for i = 1, 2 * PICK_ROWS do
		local col, row = math.floor((i - 1) / PICK_ROWS), (i - 1) % PICK_ROWS
		local b = CreateFrame("Button", nil, f)
		b:SetSize(PICK_W - 4, PICK_H)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + col * PICK_W, -56 - row * PICK_H)
		b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		b.check = CreateFrame("CheckButton", nil, b, "UICheckButtonTemplate")
		b.check:SetSize(20, 20)
		b.check:SetPoint("LEFT", b, "LEFT", 0, 0)
		b.check:SetScript("OnClick", function(self) BR:ToggleType(self:GetParent().name) end)
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", b.check, "RIGHT", 2, 0)
		b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		b.count:SetPoint("RIGHT", b, "RIGHT", -4, 0)
		b:SetScript("OnClick", function(self) BR:ToggleType(self.name) end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(self.name, 1, 0.82, 0)
			GameTooltip:AddLine(TotalSpawns(self.name) .. " spawns learned", 1, 1, 1)
			GameTooltip:AddLine(ZoneList({ self.name }, 8), 0.75, 0.75, 0.75, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f.rows[i] = b
	end

	local clear = MakeButton(f, "Clear all", 80, "Untick everything", function()
		db.selected = {}
		BR:SelectionChanged()
	end)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
	local done = MakeButton(f, "Done", 80, "Close the picker", function() f:Hide() end)
	done:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)

	f.Refresh = function()
		local kind = db.pickerTab
		for _, tab in ipairs(f.tabs) do
			if tab.kind == kind then tab:LockHighlight() else tab:UnlockHighlight() end
		end
		f.title:SetText(kind == "ore" and "Pick ores" or "Pick herbs")
		local names = TypesOfKind(kind)
		for i, b in ipairs(f.rows) do
			local name = names[i]
			if name then
				b.name = name
				local label = name
				if playerMap and SpawnCount(name, playerMap) > 0 then label = label .. " |cff4cc38a*|r" end
				b.text:SetText(label)
				b.count:SetText(TotalSpawns(name))
				b.check:SetChecked(db.selected[name] and true or false)
				if db.selected[name] then
					local c = TypeColor(name)
					b.text:SetTextColor(c[1], c[2], c[3])
				else
					b.text:SetTextColor(1, 1, 1)
				end
				b:Show()
			else
				b:Hide()
			end
		end
		if #names == 0 then
			f.empty:SetText(kind == "ore"
				and "No veins learned yet. Mine any vein and it will show up here."
				or "No herbs learned yet. Gather any herb and it will show up here.")
			f.empty:Show()
		else
			f.empty:Hide()
		end
	end
	f:SetScript("OnShow", function(self) self.Refresh() end)
	picker = f
end

function BR:TogglePicker(anchor, kind)
	if kind then db.pickerTab = kind end
	if picker:IsShown() then
		if kind then picker.Refresh() else picker:Hide() end
		return
	end
	if options then options:Hide() end
	picker:ClearAllPoints()
	if anchor and anchor:GetTop() and anchor:GetTop() < GetScreenHeight() / 2 then
		picker:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
	elseif anchor then
		picker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
	else
		picker:SetPoint("CENTER")
	end
	picker:Show()
end

function BR:ToggleType(name)
	if not db.types[name] then return end
	db.selected[name] = not db.selected[name] or nil
	self:SelectionChanged()
end

function BR:SelectionChanged()
	lastU, lastV = nil, nil
	if picker and picker:IsShown() then picker.Refresh() end
	if options and options:IsShown() then options.Refresh() end
	self:DrawMap()
	self:UpdatePosition()
	self:UpdateTrackerText()
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------

local function CreateTracker()
	local f = CreateFrame("Frame", "BloomRouteTracker", UIParent, "BackdropTemplate")
	f:SetSize(324, 110)
	f:SetPoint("TOP", UIParent, "TOP", 0, -140)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(0.08, 0.06, 0.05, 0.8)
	f:SetBackdropBorderColor(1, 0.54, 0.24, 0.8)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" and Route(playerMap) then
			local d = BR:Direction(playerMap)
			if IsShiftKeyDown() then BR:Step(-d) else BR:Step(d) end
		end
	end)

	f.herbButton = MakeButton(f, "", 196, "Pick which herbs and ores to farm", function(self) BR:TogglePicker(self) end)
	f.herbButton:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
	f.optionsButton = MakeButton(f, "Options", 64, "BloomRoute options", function() BR:ToggleOptions() end)
	f.optionsButton:SetPoint("LEFT", f.herbButton, "RIGHT", 4, 0)
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetSize(24, 24)
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() BR:ToggleWindow(false) end)

	f.arrow = f:CreateTexture(nil, "ARTWORK")
	f.arrow:SetTexture(MEDIA .. "arrow")
	f.arrow:SetSize(52, 52)
	f.arrow:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -30)

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 58, -36)
	f.title:SetJustifyH("LEFT")
	f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.info:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -5)
	f.info:SetWidth(256)
	f.info:SetJustifyH("LEFT")

	f.prev = MakeButton(f, "<", 26, "Previous stop (skips nodes still respawning)", function() BR:Step(-1) end)
	f.prev:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 58, 8)
	f.next = MakeButton(f, ">", 26, "Next stop (skips nodes still respawning)", function() BR:Step(1) end)
	f.next:SetPoint("LEFT", f.prev, "RIGHT", 4, 0)
	f.nearest = MakeButton(f, "Nearest", 64, "Head for the closest stop that's ready", function() BR:GoNearest() end)
	f.nearest:SetPoint("LEFT", f.next, "RIGHT", 8, 0)
	f.reverse = MakeButton(f, "Reverse", 64, "Run the loop in the opposite direction", function() BR:ToggleReverse() end)
	f.reverse:SetPoint("LEFT", f.nearest, "RIGHT", 4, 0)

	-- Find Herbs / Find Minerals: shown when you have that tracking and it's off
	local function TrackButton(spell, icon)
		local b = CreateFrame("Button", nil, f)
		b:SetSize(20, 20)
		b:SetNormalTexture(icon)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b.spell = spell
		b:SetScript("OnClick", function(self) BR:SetTracking(self.spell) end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText("Turn on " .. self.spell, 1, 1, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:Hide()
		return b
	end
	f.findHerbs = TrackButton("Find Herbs", "Interface\\Icons\\INV_Misc_Flower_02")
	f.findHerbs:SetPoint("LEFT", f.reverse, "RIGHT", 4, 0)
	f.findMinerals = TrackButton("Find Minerals", "Interface\\Icons\\Spell_Nature_Earthquake")
	f.findMinerals:SetPoint("LEFT", f.findHerbs, "RIGHT", 4, 0)

	f.elapsed = 0
	f:SetScript("OnUpdate", function(self, elapsed)
		BR:UpdateArrow()
		self.elapsed = self.elapsed + elapsed
		if self.elapsed >= 0.25 then
			self.elapsed = 0
			BR:UpdateTrackingButtons()
		end
	end)
	f:Hide()
	tracker = f
end

-- Minimap tracking entries by name: { index, active, icon }
local function TrackingEntries()
	local list = {}
	if not (C_Minimap and C_Minimap.GetNumTrackingTypes) then return list end
	for i = 1, C_Minimap.GetNumTrackingTypes() do
		local a, b, c = C_Minimap.GetTrackingInfo(i)
		local name, icon, active
		if type(a) == "table" then name, icon, active = a.name, a.texture, a.active
		else name, icon, active = a, b, c end
		if name then list[name] = { index = i, active = active, icon = icon } end
	end
	return list
end

function BR:SetTracking(name)
	local e = TrackingEntries()[name]
	if e and C_Minimap.SetTracking then C_Minimap.SetTracking(e.index, true) end
end

function BR:UpdateTrackingButtons()
	if not tracker then return end
	local entries = TrackingEntries()
	for _, b in ipairs({ tracker.findHerbs, tracker.findMinerals }) do
		local e = entries[b.spell]
		if e and not e.active then
			if e.icon then b:SetNormalTexture(e.icon) end
			b:Show()
		else
			b:Hide()
		end
	end
end

function BR:UpdateArrow()
	local a = tracker and tracker.arrow
	if not a then return end
	local route = Route(playerMap)
	local i = route and Target(playerMap)
	local facing = PlayerFacing()
	if not i or not lastU or not facing then a:Hide() return end
	local s = route.stops[i]
	local _, dx, dy = Yards(playerMap, lastU, lastV, s[1], s[2])
	local rel = (math.deg(math.atan2(dx, -dy)) + math.deg(facing)) % 360
	a:SetRotation(-math.rad(rel))
	local off = rel > 180 and 360 - rel or rel
	local t = off / 180
	a:SetVertexColor(0.3 + 0.6 * t, 0.85 - 0.55 * t, 0.4 - 0.15 * t)
	a:Show()
end

local function SetNavEnabled(on)
	for _, b in ipairs({ tracker.prev, tracker.next, tracker.nearest, tracker.reverse }) do
		if on then b:Enable() else b:Disable() end
	end
end

function BR:UpdateTrackerText()
	if not tracker then return end
	if not db.tracker then tracker:Hide() return end
	tracker:Show()
	tracker.herbButton:SetText(SelectionLabel())
	local sel = Selected()
	if next(db.types) == nil then
		SetNavEnabled(false)
		tracker.title:SetText("|cffa8968aNothing learned yet|r")
		tracker.info:SetText("Gather any herb or vein. Each one you pick is remembered and added to your loops.")
		return
	end
	if #sel == 0 then
		SetNavEnabled(false)
		tracker.title:SetText("|cffa8968aNothing picked|r")
		tracker.info:SetText("Click the button at the top to tick the herbs or ores you want to farm.")
		return
	end
	local route = Route(playerMap)
	if not route then
		SetNavEnabled(false)
		if Building(playerMap) then
			tracker.title:SetText("Building the loop...")
			tracker.info:SetText("")
		else
			tracker.title:SetText("|cffa8968aNone of your picks learned here yet|r")
			tracker.info:SetText("Learned in: " .. ZoneList(sel, 4))
		end
		return
	end
	SetNavEnabled(true)
	local i = Target(playerMap)
	if not i then
		tracker.title:SetText(route.name)
		tracker.info:SetText(#route.stops == 0 and "Every learned node here is ignored." or "Finding the nearest stop...")
		return
	end
	local s = route.stops[i]
	local rev = db.reverse[route.key] and "  |cffa8968a(reversed)|r" or ""
	tracker.title:SetText(string.format("%s  |cffffffff%d/%d|r%s", route.name, i, #route.stops, rev))
	local tag = ""
	if #route.types > 1 then
		local c = TypeColor(s[3])
		tag = string.format("|cff%02x%02x%02x%s|r  ", c[1] * 255, c[2] * 255, c[3] * 255, s[3])
	end
	local wait = AllCooling(playerMap, route)
	local note = wait and ("\n|cffa8968aAll nodes checked - next ready in about " .. FormatMinutes(wait) .. "|r") or ""
	if lastU then
		local d, dx, dy = Yards(playerMap, lastU, lastV, s[1], s[2])
		local dir = PlayerFacing() and "" or (" " .. Compass(dx, dy))
		tracker.info:SetText(string.format("%s|cff4cc38a%d yd%s|r  (%.1f, %.1f)%s", tag, math.floor(d + 0.5), dir, s[1] * 100, s[2] * 100, note))
	else
		tracker.info:SetText(string.format("%s(%.1f, %.1f)%s", tag, s[1] * 100, s[2] * 100, note))
	end
end

function BR:ToggleWindow(show)
	if show == nil then show = not db.tracker end
	db.tracker = show
	if not show then
		if picker then picker:Hide() end
		if options then options:Hide() end
	end
	self:UpdateTrackerText()
end

---------------------------------------------------------------------------
-- Options (General and Visuals tabs)
---------------------------------------------------------------------------

local RESPAWN_ROWS = 8

local function CreateOptions()
	local f = MakePanel("BloomRouteOptions", 330, 200)
	f.title:SetText("BloomRoute Options")
	local general = CreateFrame("Frame", nil, f)
	general:SetAllPoints(f)
	local visuals = CreateFrame("Frame", nil, f)
	visuals:SetAllPoints(f)

	-- General -------------------------------------------------------------
	local checks = {}
	local function Check(parent, i, label, tip, get, set, name)
		local c = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
		c:SetSize(24, 24)
		c:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -28 - (i - 1) * 24)
		local fs = CheckText(c)
		if fs then fs:SetText(label) else
			fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
			fs:SetText(label)
		end
		c.get, c.set = get, set
		c:SetScript("OnClick", function(self) self.set(self:GetChecked() and true or false) end)
		c:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(tip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		c:SetScript("OnLeave", function() GameTooltip:Hide() end)
		table.insert(checks, c)
		return c
	end
	Check(general, 1, "Show path on world map", "Draw the loop on the world map.",
		function() return db.map end, function(v) db.map = v; BR:DrawMap() end, "BloomRouteOptMap")
	Check(general, 2, "Show path on minimap", "Draw the loop and nearby stops on your minimap.",
		function() return db.minimapPath end, function(v) db.minimapPath = v end, "BloomRouteOptMinimapPath")
	Check(general, 3, "Show minimap button", "Show the BloomRoute button on the minimap edge.",
		function() return not db.minimap.hide end,
		function(v) db.minimap.hide = not v; minimapButton:SetShown(v) end, "BloomRouteOptMinimapButton")
	Check(general, 4, "Remember checked nodes", "Nodes you reach or pick are grayed out and skipped until their respawn time has passed.",
		function() return db.memory end, function(v) db.memory = v; BR:DrawMap(); BR:UpdateTrackerText() end, "BloomRouteOptMemory")

	-- reach radius slider (built by hand so it doesn't depend on a template)
	local radiusLabel = general:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	radiusLabel:SetPoint("TOPLEFT", general, "TOPLEFT", 16, -128)
	local slider = CreateFrame("Slider", "BloomRouteOptRadius", general, "BackdropTemplate")
	slider:SetOrientation("HORIZONTAL")
	slider:SetSize(200, 14)
	slider:SetPoint("TOPLEFT", general, "TOPLEFT", 20, -146)
	slider:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true, tileSize = 8, edgeSize = 8,
		insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	slider:SetMinMaxValues(5, 60)
	slider:SetValueStep(5)
	slider:SetObeyStepOnDrag(true)
	slider:SetScript("OnValueChanged", function(_, value)
		value = math.floor(value / 5 + 0.5) * 5
		db.radius = value
		radiusLabel:SetText("Reach radius: " .. value .. " yd")
	end)

	-- respawn times
	local head = general:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	head:SetPoint("TOPLEFT", general, "TOPLEFT", 14, -176)
	head:SetText("Respawn times (minutes)")
	local colAll = general:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	colAll:SetPoint("TOPLEFT", general, "TOPLEFT", 160, -196)
	colAll:SetText("All zones")
	local colZone = general:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	colZone:SetPoint("TOPLEFT", general, "TOPLEFT", 236, -196)
	colZone:SetWidth(84)
	colZone:SetJustifyH("LEFT")

	local function Box(x, y)
		local e = CreateFrame("EditBox", nil, general, "InputBoxTemplate")
		e:SetSize(44, 18)
		e:SetPoint("TOPLEFT", general, "TOPLEFT", x, y)
		e:SetAutoFocus(false)
		e:SetMaxLetters(4)
		e:SetScript("OnEscapePressed", function(self) self.cancel = true; self:ClearFocus() end)
		e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		e:SetScript("OnEditFocusLost", function(self)
			if self.cancel then
				self.cancel = nil
				f.Refresh()
			elseif self.save then
				local v = tonumber(self:GetText())
				self.save(v and v > 0 and v or nil)
			end
		end)
		return e
	end
	local function SetBox(box, value) box:SetText(value and tostring(value) or "") end
	local function Changed() f.Refresh(); BR:DrawMap(); BR:UpdateTrackerText() end

	local defLabel = general:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	defLabel:SetPoint("TOPLEFT", general, "TOPLEFT", 16, -214)
	defLabel:SetText("Default (any node)")
	local defBox = Box(164, -210)
	defBox.save = function(v) if v then db.respawnDefault = v end; Changed() end

	local rows = {}
	for i = 1, RESPAWN_ROWS do
		local y = -214 - i * 22
		local r = {}
		r.label = general:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.label:SetPoint("TOPLEFT", general, "TOPLEFT", 16, y)
		r.label:SetWidth(140)
		r.label:SetJustifyH("LEFT")
		r.all = Box(164, y + 4)
		r.zone = Box(240, y + 4)
		r.all.save = function(v) if r.name then db.respawn[r.name] = v end; Changed() end
		r.zone.save = function(v)
			if r.name and playerMap then db.respawnZone[r.name .. "|" .. playerMap] = v end
			Changed()
		end
		rows[i] = r
	end
	local empty = general:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty:SetPoint("TOPLEFT", general, "TOPLEFT", 16, -238)
	empty:SetText("Tick herbs or ores in the picker to set their times.")

	local clearMem = MakeButton(general, "Clear node memory", 140, "Forget every checked node so all of them count as ready", function()
		db.nodes = {}
		Print("node memory cleared")
		BR:DrawMap(); BR:UpdateTrackerText()
	end)
	local help = MakeButton(general, "List chat commands", 140, "Print every /bloom command in your chat window", function() BR:ShowHelp() end)
	help:SetPoint("LEFT", clearMem, "RIGHT", 6, 0)
	local unZone = MakeButton(general, "Unignore this zone", 140, "Bring back every node you ignored in the zone you're in", function() BR:Unignore(playerMap) end)
	unZone:SetPoint("TOPLEFT", clearMem, "BOTTOMLEFT", 0, -6)
	local unAll = MakeButton(general, "Unignore all zones", 140, "Bring back every node you ignored, in every zone", function() BR:Unignore(nil) end)
	unAll:SetPoint("LEFT", unZone, "RIGHT", 6, 0)
	local hint = general:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", general, "BOTTOMLEFT", 14, 8)
	hint:SetText("Blank = use the time to the left.")

	local function RefreshGeneral()
		for _, c in ipairs(checks) do c:SetChecked(c.get() and true or false) end
		slider:SetValue(db.radius)
		radiusLabel:SetText("Reach radius: " .. db.radius .. " yd")
		SetBox(defBox, db.respawnDefault)
		colZone:SetText(playerMap and (MapName(playerMap) .. " only") or "This zone only")
		local sel = Selected()
		local shown = math.min(#sel, RESPAWN_ROWS)
		for i, r in ipairs(rows) do
			local name = sel[i]
			if i <= shown then
				r.name = name
				local c = TypeColor(name)
				r.label:SetText(name)
				r.label:SetTextColor(c[1], c[2], c[3])
				r.label:Show(); r.all:Show(); r.zone:Show()
				SetBox(r.all, db.respawn[name])
				SetBox(r.zone, playerMap and db.respawnZone[name .. "|" .. playerMap])
				r.zone:SetShown(playerMap ~= nil)
			else
				r.name = nil
				r.label:Hide(); r.all:Hide(); r.zone:Hide()
			end
		end
		empty:SetShown(shown == 0)
		local bottom = -214 - math.max(shown, 1) * 22 - 30
		clearMem:ClearAllPoints()
		clearMem:SetPoint("TOPLEFT", general, "TOPLEFT", 14, bottom)
		return -bottom + 58
	end

	-- Visuals -------------------------------------------------------------
	local colorsHead = visuals:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colorsHead:SetPoint("TOPLEFT", visuals, "TOPLEFT", 14, -30)
	colorsHead:SetText("Colors")
	local swatches = {}
	local function Apply() f.Refresh(); BR:DrawMap() end
	local function PickColor(key)
		local c = db.colors[key]
		local info = {
			r = c[1], g = c[2], b = c[3], hasOpacity = false,
			swatchFunc = function()
				local r, g, b = ColorPickerFrame:GetColorRGB()
				db.colors[key] = { r, g, b }
				Apply()
			end,
			cancelFunc = function()
				db.colors[key] = { c[1], c[2], c[3] }
				Apply()
			end,
		}
		ColorPickerFrame:SetupColorPickerAndShow(info)
	end
	local function Swatch(i, label, key, tip)
		local b = CreateFrame("Button", nil, visuals)
		b:SetSize(20, 20)
		b:SetPoint("TOPLEFT", visuals, "TOPLEFT", 16, -52 - (i - 1) * 26)
		local edge = b:CreateTexture(nil, "BACKGROUND")
		edge:SetAllPoints(b)
		edge:SetColorTexture(0, 0, 0, 1)
		b.color = b:CreateTexture(nil, "ARTWORK")
		b.color:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
		b.color:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
		b.color:SetColorTexture(1, 1, 1, 1)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		local text = visuals:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", b, "RIGHT", 8, 0)
		text:SetText(label)
		b.key = key
		b:SetScript("OnClick", function(self) PickColor(self.key) end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(tip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		table.insert(swatches, b)
	end
	Swatch(1, "Trail between nodes", "trail", "Color of the dotted path on the world map and minimap.")
	Swatch(2, "Node rings", "ring", "Color of the node rings on the minimap and the pins on the world map.")
	Swatch(3, "Next stop", "target", "Color of the ring and pin for your next stop.")
	local byType = CreateFrame("CheckButton", "BloomRouteOptByType", visuals, "UICheckButtonTemplate")
	byType:SetSize(24, 24)
	byType:SetPoint("TOPLEFT", visuals, "TOPLEFT", 14, -130)
	local bt = CheckText(byType)
	if bt then bt:SetText("Color rings by type when several are picked") end
	byType:SetScript("OnClick", function(self) db.ringsByType = self:GetChecked() and true or false; BR:DrawMap() end)
	local reset = MakeButton(visuals, "Reset colors", 120, "Go back to the original colors", function()
		db.colors = {}
		for k, c in pairs(DEFAULT_COLORS) do db.colors[k] = { c[1], c[2], c[3] } end
		db.ringsByType = true
		Apply()
	end)
	reset:SetPoint("TOPLEFT", visuals, "TOPLEFT", 14, -162)
	local function RefreshVisuals()
		for _, b in ipairs(swatches) do
			local c = db.colors[b.key]
			b.color:SetColorTexture(c[1], c[2], c[3], 1)
		end
		byType:SetChecked(db.ringsByType and true or false)
		return 200
	end

	-- Tabs --------------------------------------------------------------------
	f.tabs = {}
	-- Node Types ------------------------------------------------------------
	local types = CreateFrame("Frame", nil, f)
	types:SetAllPoints(f)
	local typesHead = types:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	typesHead:SetPoint("TOPLEFT", types, "TOPLEFT", 14, -30)
	typesHead:SetText("Include in loops")
	local variantChecks = {}
	for i, prefix in ipairs(VARIANT_PREFIXES) do
		local var = string.sub(prefix, 1, -2)
		local c = CreateFrame("CheckButton", "BloomRouteOptVariant" .. i, types, "UICheckButtonTemplate")
		c:SetSize(24, 24)
		c:SetPoint("TOPLEFT", types, "TOPLEFT", 14, -48 - (i - 1) * 24)
		local fs = CheckText(c)
		local label = var .. " nodes"
		if fs then fs:SetText(label) else
			fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			fs:SetPoint("LEFT", c, "RIGHT", 2, 0)
			fs:SetText(label)
		end
		c.var = var
		c:SetScript("OnClick", function(self) BR:SetVariant(self.var, self:GetChecked() and true or false) end)
		c:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Include \"" .. self.var .. "\" herbs and veins in loops. Spots where a normal node has also been seen stay on the loop.", 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		c:SetScript("OnLeave", function() GameTooltip:Hide() end)
		variantChecks[i] = c
	end
	local typesHint = types:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	typesHint:SetPoint("TOPLEFT", types, "TOPLEFT", 16, -56 - #VARIANT_PREFIXES * 24)
	typesHint:SetWidth(298)
	typesHint:SetJustifyH("LEFT")
	typesHint:SetText("Unticked variants are left out of every loop. A spot where a normal node has also been seen stays on the loop.")
	local function RefreshTypes()
		for _, c in ipairs(variantChecks) do c:SetChecked(db.variants[c.var] ~= false) end
		return 96 + #VARIANT_PREFIXES * 24
	end

	for i, t in ipairs({ { "general", "General" }, { "visuals", "Visuals" }, { "types", "Node Types" } }) do
		local tab = MakeButton(f, t[2], 80, t[2] .. " options", function(self)
			db.optionsTab = self.id
			f.Refresh()
		end)
		tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 6 + (i - 1) * 84, -2)
		tab.id = t[1]
		f.tabs[i] = tab
	end
	f.Refresh = function()
		for _, tab in ipairs(f.tabs) do
			if tab.id == db.optionsTab then tab:LockHighlight() else tab:UnlockHighlight() end
		end
		general:Hide(); visuals:Hide(); types:Hide()
		if db.optionsTab == "visuals" then
			visuals:Show()
			f:SetHeight(RefreshVisuals())
		elseif db.optionsTab == "types" then
			types:Show()
			f:SetHeight(RefreshTypes())
		else
			general:Show()
			f:SetHeight(RefreshGeneral())
		end
	end
	f:SetScript("OnShow", function(self) self.Refresh() end)
	options = f
end

function BR:ToggleOptions()
	if options:IsShown() then options:Hide() return end
	if picker then picker:Hide() end
	options:ClearAllPoints()
	if tracker:GetTop() and tracker:GetTop() < GetScreenHeight() / 2 then
		options:SetPoint("BOTTOMRIGHT", tracker, "TOPRIGHT", 0, 26)
	else
		options:SetPoint("TOPRIGHT", tracker, "BOTTOMRIGHT", 0, -4)
	end
	options:Show()
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

local function PlaceMinimapButton()
	local a = math.rad(db.minimap.angle)
	local r = Minimap:GetWidth() / 2 + 10
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(a), r * math.sin(a))
end

local function CreateMinimapButton()
	local b = CreateFrame("Button", "BloomRouteMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Flower_02")
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -5)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			if not db.tracker then BR:ToggleWindow(true) end
			BR:TogglePicker(tracker.herbButton)
		else
			BR:ToggleWindow()
		end
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local s = Minimap:GetEffectiveScale()
			db.minimap.angle = math.deg(math.atan2(cy / s - my, cx / s - mx))
			PlaceMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("BloomRoute", 1, 0.54, 0.24)
		local sel = Selected()
		GameTooltip:AddLine(#sel > 0 and ("Farming: " .. table.concat(sel, ", ")) or "Nothing picked", 1, 1, 1, true)
		GameTooltip:AddLine("Left-click: show/hide window", 0.75, 0.75, 0.75)
		GameTooltip:AddLine("Right-click: pick herbs or ores", 0.75, 0.75, 0.75)
		GameTooltip:AddLine("Drag: move this button", 0.75, 0.75, 0.75)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	minimapButton = b
	PlaceMinimapButton()
	b:SetShown(not db.minimap.hide)
end

function BloomRoute_OnAddonCompartmentClick()
	if db then BR:ToggleWindow() end
end

---------------------------------------------------------------------------
-- Position, clearing and learning
---------------------------------------------------------------------------

local function Advance(map, route, i)
	MarkNode(map, route.stops[i])
	SetProgress(map, route, NextReady(map, route, i, BR:Direction(map)))
	BR:DrawMap()
end

function BR:UpdatePosition()
	local map, u, v = PlayerPosition()
	local changed = map ~= playerMap
	playerMap = map
	if changed then
		if options and options:IsShown() then options.Refresh() end
		if picker and picker:IsShown() then picker.Refresh() end
	end
	local route = Route(map)
	if not route or not u then
		lastU, lastV = nil, nil
		if changed or Building(map) then self:UpdateTrackerText() end
		return
	end
	lastU, lastV = u, v
	if #route.stops == 0 then self:UpdateTrackerText() return end
	local i = Target(map)
	if not i then
		SetProgress(map, route, Nearest(map, u, v, true))
		i = Target(map)
		self:DrawMap()
	end
	-- reaching any ready stop (not only the target) moves your place in the loop to it
	if #route.stops > 1 then
		local hit, hd
		for k = 1, #route.stops do
			local s = route.stops[k]
			if k == i or not Cooldown(map, s) then
				local d = Yards(map, u, v, s[1], s[2])
				if d <= db.radius and (not hd or d < hd) then hit, hd = k, d end
			end
		end
		if hit then Advance(map, route, hit) end
	end
	self:UpdateTrackerText()
end

-- After a loop is rebuilt with a spawn you just learned, move your place to that stop
function BR:ApplyPendingPick()
	local p = self.pendingPick
	if not p then return end
	local route = Route(p.map)
	if not route then
		if not Building(p.map) then self.pendingPick = nil end
		return
	end
	self.pendingPick = nil
	for k = 1, #route.stops do
		if NodeId(p.map, route.stops[k]) == p.id then
			Advance(p.map, route, k)
			return
		end
	end
end

local gather   -- { kind, target, time } from the gathering cast in progress

-- A herb or vein was looted: learn it (or match it to a known spawn), clear it, and
-- move your place in the loop to it
function BR:OnHarvest(g)
	local name = Plain(g.target)
	if not name or name == "" then
		-- the cast didn't say what it was aimed at; fall back to the first looted item
		local _, item = GetLootSlotInfo(1)
		name = Plain(item)
	end
	if not name or name == "" then return end
	local variants
	name, variants = BaseName(name)
	local map, u, v = PlayerPosition()
	if not map or not u then return end

	local isNewType = not db.types[name]
	db.types[name] = db.types[name] or { kind = g.kind }
	db.spawns[name] = db.spawns[name] or {}
	db.spawns[name][map] = db.spawns[name][map] or {}
	local list = db.spawns[name][map]
	local spot
	for _, p in ipairs(list) do
		if Yards(map, u, v, p[1], p[2]) <= LEARN_DISTANCE then spot = p break end
	end
	local learned = false
	if not spot then
		spot = { math.floor(u * 10000 + 0.5) / 10000, math.floor(v * 10000 + 0.5) / 10000, {} }
		table.insert(list, spot)
		learned = true
	end
	-- remember which variants have been seen at this spot (e.g. Poor, Rich, Normal)
	if type(spot[3]) ~= "table" then spot[3] = { Normal = true } end
	local newVariant = false
	for var in pairs(variants) do
		if not spot[3][var] then spot[3][var] = true; newVariant = true end
	end
	if newVariant and not learned then routeCache = {} end
	if isNewType then
		Print(string.format("learned a new %s: %s. Tick it in the picker to route it.", g.kind == "ore" and "vein" or "herb", name))
		-- the very first thing you learn gets picked for you
		if not next(db.selected) then db.selected[name] = true end
		if picker and picker:IsShown() then picker.Refresh() end
	elseif learned then
		Print(string.format("learned a new %s spawn in %s (%.1f, %.1f) - %d known here",
			name, MapName(map), spot[1] * 100, spot[2] * 100, #list))
	end

	local node = { spot[1], spot[2], name }
	MarkNode(map, node)
	if not db.selected[name] then return end
	local route = Route(map)
	if route and not learned and not isNewType then
		for k = 1, #route.stops do
			if NodeId(map, route.stops[k]) == NodeId(map, node) then
				Advance(map, route, k)
				break
			end
		end
	else
		-- the loop is being rebuilt with the new spawn; move to it once it's ready
		self.pendingPick = { map = map, id = NodeId(map, node) }
	end
	self:DrawMap()
	self:UpdateTrackerText()
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

function BR:SetTarget(map, i)
	local route = Route(map)
	if not route or #route.stops == 0 then return end
	SetProgress(map, route, Wrap(i, #route.stops))
	self:DrawMap()
	self:UpdateTrackerText()
end

local function NotHere()
	Print("None of your picked herbs or ores have been learned in this zone yet.")
end

function BR:GoNearest()
	if Route(playerMap) and lastU then
		self:SetTarget(playerMap, Nearest(playerMap, lastU, lastV, true))
	else
		NotHere()
	end
end

function BR:ToggleReverse()
	local route = Route(playerMap)
	if not route then NotHere() return end
	db.reverse[route.key] = not db.reverse[route.key] or nil
	Print(route.name .. " loop now runs " .. (db.reverse[route.key] and "in reverse" or "in list order"))
	self:UpdateTrackerText()
end

function BR:Step(delta)
	local route = Route(playerMap)
	if not route or #route.stops == 0 then NotHere() return end
	local i = Target(playerMap) or 1
	local dir = delta < 0 and -1 or 1
	for _ = 1, math.abs(delta) do i = NextReady(playerMap, route, i, dir) end
	self:SetTarget(playerMap, i)
end

function BR:SetVariant(var, on)
	if on then db.variants[var] = nil else db.variants[var] = false end
	ignoreVersion = ignoreVersion + 1
	self:DrawMap()
	self:UpdateTrackerText()
end

function BR:IgnoreStop(map, i)
	local route = Route(map)
	if not route or not route.stops[i] then return end
	local s = route.stops[i]
	db.ignored[NodeId(map, s)] = true
	ignoreVersion = ignoreVersion + 1
	Print(string.format("ignored the %s node at %.1f, %.1f in %s (Options > Unignore to bring it back)",
		s[3], s[1] * 100, s[2] * 100, MapName(map)))
	self:DrawMap()
	self:UpdateTrackerText()
end

function BR:Unignore(map)
	local n = 0
	for key in pairs(db.ignored) do
		local _, _, m = string.find(key, "^.-|(%d+)|")
		if not map or tonumber(m) == map then
			db.ignored[key] = nil
			n = n + 1
		end
	end
	ignoreVersion = ignoreVersion + 1
	Print(n .. " ignored node" .. (n == 1 and "" or "s") .. " brought back" .. (map and (" in " .. MapName(map)) or " in all zones"))
	self:DrawMap()
	self:UpdateTrackerText()
end

local function FindType(text, kind)
	text = string.lower(text)
	local all = {}
	for name, t in pairs(db.types) do
		if not kind or t.kind == kind then table.insert(all, name) end
	end
	table.sort(all)
	for _, name in ipairs(all) do if string.lower(name) == text then return name end end
	for _, name in ipairs(all) do if string.find(string.lower(name), text, 1, true) then return name end end
end

local function Help()
	Print("commands:")
	Print("  /bloom show - show or hide the window (or click the minimap button)")
	Print("  /bloom herb [name] | ore [name] - tick or untick a learned herb or ore (no name opens the picker)")
	Print("  /bloom learned - list what you've learned and where")
	Print("  /bloom options - open the options panel")
	Print("  /bloom map | mmpath - toggle the path on the world map | minimap")
	Print("  /bloom next | prev | nearest | reverse - move around the loop")
	Print("  /bloom goto <n> - make stop n the next stop")
	Print("  /bloom radius <yards> - how close counts as reaching a stop (now " .. db.radius .. ")")
	Print("  /bloom respawn <minutes> <name> [here] - set a respawn time, all zones or this zone")
	Print("  /bloom forget - clear node memory")
	Print("  /bloom unignore [all] - bring back ignored nodes in this zone, or everywhere")
	Print("  /bloom unlearn <name> here|all - erase learned spawns of one type in this zone, or everywhere")
	Print("  /bloom minimap - show or hide the minimap button")
end
function BR:ShowHelp() Help() end

SLASH_BLOOMROUTE1 = "/bloom"
SLASH_BLOOMROUTE2 = "/bloomroute"
SlashCmdList["BLOOMROUTE"] = function(msg)
	local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	if cmd == "show" then
		BR:ToggleWindow()
	elseif cmd == "herb" or cmd == "ore" then
		if rest == "" then
			BR:ToggleWindow(true)
			BR:TogglePicker(tracker.herbButton, cmd)
		else
			local name = FindType(rest, cmd)
			if name then
				BR:ToggleType(name)
				Print(name .. (db.selected[name] and " added" or " removed"))
			else
				Print("nothing learned matches \"" .. rest .. "\". Try /bloom learned")
			end
		end
	elseif cmd == "learned" then
		local any = false
		for _, kind in ipairs({ "herb", "ore" }) do
			for _, name in ipairs(TypesOfKind(kind)) do
				any = true
				Print(string.format("  %s (%d): %s", name, TotalSpawns(name), ZoneList({ name }, 5)))
			end
		end
		if not any then Print("nothing learned yet - gather a herb or vein") end
	elseif cmd == "options" then
		BR:ToggleWindow(true)
		BR:ToggleOptions()
	elseif cmd == "map" then
		db.map = not db.map
		Print("world map loop " .. (db.map and "on" or "off"))
		BR:DrawMap()
	elseif cmd == "mmpath" then
		db.minimapPath = not db.minimapPath
		Print("minimap path " .. (db.minimapPath and "on" or "off"))
	elseif cmd == "next" then BR:Step(1)
	elseif cmd == "prev" then BR:Step(-1)
	elseif cmd == "nearest" then BR:GoNearest()
	elseif cmd == "reverse" then BR:ToggleReverse()
	elseif cmd == "goto" then
		local n = tonumber(rest)
		if n and Route(playerMap) then BR:SetTarget(playerMap, math.floor(n)) else Print("usage: /bloom goto <stop number>") end
	elseif cmd == "radius" then
		local n = tonumber(rest)
		if n and n > 0 then db.radius = n; Print("reach radius set to " .. n .. " yards") else Print("usage: /bloom radius <yards>") end
	elseif cmd == "respawn" then
		local mins, name = string.match(rest, "^(%d+)%s+(.+)$")
		local here = false
		if name then
			local n2 = string.match(name, "^(.-)%s+here$")
			if n2 then name, here = n2, true end
		end
		local t = name and FindType(name)
		if not mins or not t then
			Print("usage: /bloom respawn <minutes> <name> [here]  e.g. /bloom respawn 10 peacebloom here")
		elseif here then
			if not playerMap then Print("can't tell which zone you're in") return end
			db.respawnZone[t .. "|" .. playerMap] = tonumber(mins)
			Print(t .. " respawn in " .. MapName(playerMap) .. " set to " .. mins .. " min")
		else
			db.respawn[t] = tonumber(mins)
			Print(t .. " respawn set to " .. mins .. " min in all zones")
		end
		if options and options:IsShown() then options.Refresh() end
	elseif cmd == "forget" then
		db.nodes = {}
		Print("node memory cleared")
		BR:DrawMap(); BR:UpdateTrackerText()
	elseif cmd == "unignore" then
		if string.lower(rest) == "all" then BR:Unignore(nil)
		elseif playerMap then BR:Unignore(playerMap)
		else Print("usage: /bloom unignore [all]") end
	elseif cmd == "unlearn" then
		local name, where = string.match(rest, "^(.-)%s+(%S+)$")
		local t = name and FindType(name)
		where = where and string.lower(where)
		if not t or (where ~= "here" and where ~= "all") then
			Print("usage: /bloom unlearn <name> here|all")
		elseif where == "here" then
			local n = SpawnCount(t, playerMap)
			if db.spawns[t] and playerMap then db.spawns[t][playerMap] = nil end
			Print(string.format("erased %d learned %s spawn%s in %s", n, t, n == 1 and "" or "s", playerMap and MapName(playerMap) or "?"))
		else
			db.spawns[t], db.types[t], db.selected[t] = nil, nil, nil
			Print("erased everything learned about " .. t)
		end
		routeCache = {}
		BR:SelectionChanged()
	elseif cmd == "minimap" then
		db.minimap.hide = not db.minimap.hide
		minimapButton:SetShown(not db.minimap.hide)
		Print("minimap button " .. (db.minimap.hide and "hidden (/bloom minimap to bring it back)" or "shown"))
	else
		Help()
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("UNIT_SPELLCAST_SENT")
events:RegisterEvent("LOOT_OPENED")
events:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		-- the world map may load after this addon; hook it once it exists
		if ... == "Blizzard_WorldMap" and db and not overlay then CreateOverlay() return end
		if ... ~= ADDON then return end
		if type(BloomRouteDB) ~= "table" then BloomRouteDB = {} end
		db = BloomRouteDB
		CopyDefaults(DEFAULTS, db)
		PruneMemory()
		if WorldMapFrame and WorldMapFrame.ScrollContainer then CreateOverlay() end
		CreateTracker()
		CreatePicker()
		CreateOptions()
		CreateMinimapButton()
		CreateMinimapPath()
		self.elapsed = 0
		self:SetScript("OnUpdate", function(f, elapsed)
			-- finish any loop being built, a few slices per frame
			for _ = 1, 4 do
				if not job then break end
				local ok, err = coroutine.resume(job.co)
				if not ok then
					Print("couldn't build the loop: " .. tostring(err))
					job = nil
				elseif coroutine.status(job.co) == "dead" then
					job = nil
					BR:ApplyPendingPick()
					BR:DrawMap()
					BR:UpdateTrackerText()
				end
			end
			f.elapsed = f.elapsed + elapsed
			if f.elapsed < 0.2 then return end
			f.elapsed = 0
			BR:UpdatePosition()
		end)
	elseif not db then
		return
	elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
		BR:UpdatePosition()
		BR:UpdateTrackerText()
	elseif event == "UNIT_SPELLCAST_SENT" then
		local unit, target, _, spellID = ...
		if unit ~= "player" then return end
		spellID = Plain(spellID)
		local spell = spellID and ((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
			or (GetSpellInfo and GetSpellInfo(spellID)))
		local kind = spell and GATHER_SPELLS[Plain(spell)]
		if kind then gather = { kind = kind, target = target, time = GetTime() } end
	elseif event == "LOOT_OPENED" then
		if gather and GetTime() - gather.time < 8 then
			local g = gather
			gather = nil
			BR:OnHarvest(g)
		end
	end
end)
