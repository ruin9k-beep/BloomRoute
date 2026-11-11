-- BloomRoute 3.3.0 by ruin9k
-- Farming loops for alchemy herbs and mining veins: pick any mix of herbs and ores,
-- follow the loop on the world map and minimap, and skip nodes you checked until
-- they respawn.
-- Written for the 1.12 client (Lua 5.0): no '#', no '%', varargs via 'arg'.

BloomRoute = {}
local BR = BloomRoute
-- every gatherable node type, herbs then ores (kind = "herb" or "ore")
local HERBS = BloomRoute_Nodes
local MEDIA = "Interface\\AddOns\\BloomRoute\\media\\"

local HERB_BY_NAME = {}   -- node name -> node type
local BY_LOOT = {}        -- looted item name ("Firebloom", "Thorium Ore") -> node type
for i = 1, table.getn(HERBS) do
	HERB_BY_NAME[HERBS[i].name] = HERBS[i]
	BY_LOOT[HERBS[i].loot] = HERBS[i]
end

-- the gathering casts that open a herb or vein
local GATHER_SPELLS = { ["Herb Gathering"] = true, ["Mining"] = true }

local DEFAULTS = {
	herbs = {},          -- [node name] = true for every selected herb or ore
	map = true,          -- draw the loop on the world map
	minimapPath = true,  -- draw the loop on the minimap
	colors = {           -- Visuals tab: {r, g, b}
		trail = { 1, 0.54, 0.24 },    -- dotted path between nodes
		ring = { 1, 0.82, 0.25 },     -- node rings and pins
		target = { 0.3, 0.9, 0.55 },  -- the next stop
	},
	ringsByType = true,  -- with several herbs/ores picked, color each type's rings differently
	tracker = true,      -- main window shown
	radius = 25,         -- yards: reaching this close to a stop counts as checking it
	dotSpacing = 9,      -- map pixels between route dots
	progress = {},       -- [route key] = index of the next stop
	progressId = {},     -- [route key] = node id of the next stop (survives loop rebuilds)
	learned = {},        -- [herb][zone] = { {x, y}, ... } spawns you picked that the database lacked
	ignored = {},        -- [node id] = true for nodes you shift-right-clicked to leave out
	reverse = {},        -- [route key] = true when the loop runs backwards
	minimap = { angle = 200, hide = false },
	memory = true,       -- skip nodes you checked until they respawn
	nodes = {},          -- [node id] = time() you last checked or picked it
	respawnDefault = 15, -- minutes, used when a herb has no time of its own
	respawn = {},        -- [herb] = minutes
	respawnZone = {},    -- [herb|mapFile] = minutes, overrides the herb's time in that zone
}

-- pin colors for each selected herb, in picker order
local PALETTE = {
	{ 1, 0.82, 0.25 }, { 0.45, 0.75, 1 }, { 1, 0.45, 0.75 }, { 0.6, 1, 0.4 },
	{ 0.85, 0.6, 1 }, { 1, 0.6, 0.3 }, { 0.4, 1, 0.9 }, { 1, 1, 0.6 },
}
local GRAY = { 0.45, 0.45, 0.45 }
local DEFAULT_COLORS = {
	trail = { 1, 0.54, 0.24 }, ring = { 1, 0.82, 0.25 }, target = { 0.3, 0.9, 0.55 },
}

local db
local overlay, tracker, picker, minimapButton, options
local dots, pins, crosses = {}, {}, {}
local playerZone           -- map file of the zone you're in
local lastX, lastY         -- your position as map fractions (only where a route exists)
local curX, curY           -- your position as map fractions in any zone

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

-- Name of the zone the world map is showing ("Tanaris", "Gilneas", ...), or nil on a
-- continent or world view. Routes are keyed by zone name so Turtle's custom zones work.
local function DisplayedMap()
	local c, z = GetCurrentMapContinent(), GetCurrentMapZone()
	if not c or c < 1 or not z or z < 1 then return nil end
	local zones = { GetMapZones(c) }
	return zones[z]
end

---------------------------------------------------------------------------
-- Selection
---------------------------------------------------------------------------

-- selected herbs in picker (skill) order
local function Selected()
	local list = {}
	for i = 1, table.getn(HERBS) do
		if db.herbs[HERBS[i].name] then table.insert(list, HERBS[i]) end
	end
	return list
end

local function HerbColor(name)
	local sel = Selected()
	for i = 1, table.getn(sel) do
		if sel[i].name == name then return PALETTE[math.mod(i - 1, table.getn(PALETTE)) + 1] end
	end
	return PALETTE[1]
end

-- ring/pin color for a stop: the Visuals "Node rings" color, or each type's own color
-- when several herbs/ores are picked and "color by type" is on
local function StopColor(name)
	if db.ringsByType and table.getn(Selected()) > 1 then return HerbColor(name) end
	return db.colors.ring
end

local function SelectionLabel()
	local sel = Selected()
	local n = table.getn(sel)
	if n == 0 then return "Pick herbs or ores..." end
	if n == 1 then return sel[1].name .. "  |cffa8968a(" .. sel[1].skill .. ")|r" end
	return sel[1].name .. "  |cffa8968a+" .. (n - 1) .. " more|r"
end

-- Zones any selected herb grows in, most spawns first
local function ZoneList(herbs, limit)
	local totals, names = {}, {}
	for i = 1, table.getn(herbs) do
		for _, z in pairs(herbs[i].zones) do
			if not totals[z.name] then totals[z.name] = 0; table.insert(names, z.name) end
			totals[z.name] = totals[z.name] + z.spawns
		end
	end
	table.sort(names, function(a, b) return totals[a] > totals[b] end)
	local out = {}
	for i = 1, math.min(limit or 99, table.getn(names)) do
		table.insert(out, names[i] .. " (" .. totals[names[i]] .. ")")
	end
	local more = table.getn(names) - table.getn(out)
	local s = table.concat(out, ", ")
	if more > 0 then s = s .. ", +" .. more .. " more" end
	if s == "" then s = "nowhere" end
	return s
end

---------------------------------------------------------------------------
-- Distances
---------------------------------------------------------------------------

local function Yards(route, x1, y1, x2, y2)
	local dx = (x2 - x1) / 100 * route.width
	local dy = (y2 - y1) / 100 * route.height
	return math.sqrt(dx * dx + dy * dy), dx, dy
end

local DIRS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
local function Compass(dx, dy)
	local ang = math.deg(math.atan2(dx, -dy))
	if ang < 0 then ang = ang + 360 end
	return DIRS[math.mod(math.floor((ang + 22.5) / 45), 8) + 1]
end

---------------------------------------------------------------------------
-- Routes (single herb from data, several herbs solved in game)
---------------------------------------------------------------------------

local routeCache = {}  -- [key] = route
local job              -- route being solved in the background

-- Nearest-neighbor tour, 2-opt, then drop far-off spots (keeps >= 80%).
-- Runs inside a coroutine and yields regularly so the game never freezes.
local function Solve(pts, w, h)
	local n0 = table.getn(pts)
	local ops = 0
	local function tick()
		ops = ops + 1
		if ops >= 2500 then ops = 0; coroutine.yield() end
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
		local n = table.getn(t)
		local improved = true
		while improved do
			improved = false
			for i = 1, n - 2 do
				for j = i + 2, n do
					if not (i == 1 and j == n) then
						local e = t[math.mod(j, n) + 1]
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
	while table.getn(t) > minKeep do
		local n = table.getn(t)
		local legs = {}
		for i = 1, n do legs[i] = D(t[i], t[math.mod(i, n) + 1]) end
		table.sort(legs)
		local med = legs[math.floor((n + 1) / 2)]
		local best, bi
		for i = 1, n do
			local p, q = t[math.mod(i - 2 + n, n) + 1], t[math.mod(i, n) + 1]
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

local function MakeRoute(zoneData, key, stops, skipped, herbs)
	return {
		key = key, name = zoneData.name, width = zoneData.width, height = zoneData.height,
		stops = stops, skipped = skipped, herbs = herbs,
	}
end

-- Size of every zone any herb grows in (yards), for spawns learned in zones a herb's
-- data doesn't list. Unknown zones fall back to a typical zone size.
local ZONE_SIZE = {}
for i = 1, table.getn(HERBS) do
	for name, z in pairs(HERBS[i].zones) do ZONE_SIZE[name] = z end
end
local function ZoneInfo(zone)
	local z = ZONE_SIZE[zone]
	if z then return z end
	return { name = zone, width = 4000, height = 2666.67 }
end

-- spawns you've picked that the database didn't have: db.learned[herb][zone] = { {x, y}, ... }
local function Learned(herb, zone)
	local h = db.learned[herb]
	return h and h[zone]
end

local function LearnedCount(herb, zone)
	local l = Learned(herb, zone)
	if l then return table.getn(l) end
	return 0
end

-- does this herb grow in this zone (database or learned)?
local function GrowsIn(herb, zone)
	return herb.zones[zone] or LearnedCount(herb.name, zone) > 0
end

-- herbs from the selection that grow in this zone
local function HerbsIn(zone)
	local list = {}
	local sel = Selected()
	for i = 1, table.getn(sel) do
		if GrowsIn(sel[i], zone) then table.insert(list, sel[i]) end
	end
	return list
end

local function RouteKey(zone, herbs)
	local names = {}
	for i = 1, table.getn(herbs) do names[i] = herbs[i].name end
	return table.concat(names, "+") .. "|" .. zone
end

-- Ignored nodes: db.ignored[node id] = true. The id format matches NodeId below.
local ignoreVersion = 0
local function IgnoreKey(zone, s)
	return s[3] .. "|" .. zone .. "|" .. string.format("%.1f,%.1f", s[1], s[2])
end

-- The full loop for a zone before ignored nodes are taken out
local function BaseRoute(zone)
	if not zone then return nil end
	local herbs = HerbsIn(zone)
	if table.getn(herbs) == 0 then return nil end
	local key = RouteKey(zone, herbs)
	local learned = 0
	for i = 1, table.getn(herbs) do learned = learned + LearnedCount(herbs[i].name, zone) end
	-- the cache entry changes whenever a spawn is learned, so the loop is rebuilt to include it
	local cacheKey = key .. "#" .. learned
	if routeCache[cacheKey] then return routeCache[cacheKey] end

	-- one herb with nothing learned: use the ready-made loop
	if table.getn(herbs) == 1 and learned == 0 then
		local h = herbs[1]
		local z = h.zones[zone]
		local stops, skipped = {}, {}
		for i = 1, table.getn(z.stops) do stops[i] = { z.stops[i][1], z.stops[i][2], h.name } end
		for i = 1, table.getn(z.skipped) do skipped[i] = { z.skipped[i][1], z.skipped[i][2], h.name } end
		routeCache[cacheKey] = MakeRoute(z, key, stops, skipped, { h.name })
		return routeCache[cacheKey]
	end

	-- several herbs, or learned spawns: combine every spawn and solve in the background
	-- (one job at a time; another zone asking meanwhile just waits its turn)
	if not job then
		local pts, names = {}, {}
		local zd = ZoneInfo(zone)
		for i = 1, table.getn(herbs) do
			local h = herbs[i]
			names[i] = h.name
			local z = h.zones[zone]
			if z then
				for k = 1, table.getn(z.stops) do table.insert(pts, { z.stops[k][1], z.stops[k][2], h.name }) end
				for k = 1, table.getn(z.skipped) do table.insert(pts, { z.skipped[k][1], z.skipped[k][2], h.name }) end
			end
			local l = Learned(h.name, zone)
			if l then
				for k = 1, table.getn(l) do table.insert(pts, { l[k][1], l[k][2], h.name }) end
			end
		end
		job = { key = key, zone = zone }
		job.co = coroutine.create(function()
			local order, drop = Solve(pts, zd.width / 100, zd.height / 100)
			local stops, skipped = {}, {}
			for i = 1, table.getn(order) do stops[i] = pts[order[i]] end
			for i = 1, table.getn(drop) do skipped[i] = pts[drop[i]] end
			routeCache[cacheKey] = MakeRoute(zd, key, stops, skipped, names)
		end)
	end
	return nil
end

-- Returns the route for a zone with ignored nodes taken out (the remaining stops keep their
-- order), or nil (nothing picked grows there, or the loop is still being built)
local function Route(zone)
	local base = BaseRoute(zone)
	if not base then return nil end
	local fc = base.filtered
	if fc and fc.ver == ignoreVersion then return fc.route end
	local stops, ignored = {}, {}
	for i = 1, table.getn(base.stops) do
		local s = base.stops[i]
		if db.ignored[IgnoreKey(zone, s)] then table.insert(ignored, s) else table.insert(stops, s) end
	end
	local route = base
	if table.getn(ignored) > 0 then
		route = {}
		for k, v in pairs(base) do route[k] = v end
		route.filtered = nil
		route.stops = stops
	end
	route.ignoredStops = ignored
	base.filtered = { ver = ignoreVersion, route = route }
	return route
end

local function Building(zone)
	return job and job.zone == zone
end

local function StopCount(route)
	return table.getn(route.stops)
end

---------------------------------------------------------------------------
-- Node memory
---------------------------------------------------------------------------

local function NodeId(zone, s)
	return s[3] .. "|" .. zone .. "|" .. string.format("%.1f,%.1f", s[1], s[2])
end

function BR:RespawnMinutes(herb, zone)
	return db.respawnZone[herb .. "|" .. zone] or db.respawn[herb] or db.respawnDefault
end

-- seconds until this node is worth checking again (nil when it's ready)
local function Cooldown(zone, s)
	if not db.memory then return nil end
	local t = db.nodes[NodeId(zone, s)]
	if not t then return nil end
	local left = t + BR:RespawnMinutes(s[3], zone) * 60 - time()
	if left > 0 then return left end
end

local function MarkNode(zone, s)
	if db.memory then db.nodes[NodeId(zone, s)] = time() end
end

local function PruneMemory()
	local now = time()
	for id, t in pairs(db.nodes) do
		if now - t > 24 * 3600 then db.nodes[id] = nil end
	end
end

---------------------------------------------------------------------------
-- Targets
---------------------------------------------------------------------------

local function Wrap(i, n)
	while i < 1 do i = i + n end
	return math.mod(i - 1, n) + 1
end

-- Your place in a loop is saved as both the stop's index and the stop itself, so when a
-- learned spawn rebuilds the loop (and shifts the numbering) you stay on the same stop.
local function SetProgress(zone, route, i)
	db.progress[route.key] = i
	db.progressId[route.key] = i and NodeId(zone, route.stops[i]) or nil
end

local function Target(zone)
	local route = Route(zone)
	if not route then return nil end
	local i = db.progress[route.key]
	local id = db.progressId[route.key]
	local n = StopCount(route)
	if i and i >= 1 and i <= n and (not id or NodeId(zone, route.stops[i]) == id) then return i end
	if id then
		for k = 1, n do
			if NodeId(zone, route.stops[k]) == id then
				db.progress[route.key] = k
				return k
			end
		end
	end
	return nil
end

-- next stop from 'from' going 'dir' that isn't cooling down; falls back to the plain next stop
local function NextReady(zone, route, from, dir)
	local n = StopCount(route)
	for k = 1, n - 1 do
		local i = Wrap(from + dir * k, n)
		if not Cooldown(zone, route.stops[i]) then return i end
	end
	return Wrap(from + dir, n)
end

local function Nearest(zone, x, y, readyOnly)
	local route = Route(zone)
	local best, bestD
	for i = 1, StopCount(route) do
		local s = route.stops[i]
		if not readyOnly or not Cooldown(zone, s) then
			local d = Yards(route, x, y, s[1], s[2])
			if not bestD or d < bestD then best, bestD = i, d end
		end
	end
	if not best and readyOnly then return Nearest(zone, x, y, false) end
	return best
end

local function AllCooling(zone, route)
	local soonest
	for i = 1, StopCount(route) do
		local left = Cooldown(zone, route.stops[i])
		if not left then return nil end
		if not soonest or left < soonest then soonest = left end
	end
	return soonest
end

function BR:Direction(zone)
	local route = Route(zone)
	if route and db.reverse[route.key] then return -1 end
	return 1
end

---------------------------------------------------------------------------
-- World map overlay
---------------------------------------------------------------------------

local function GetDot(i)
	local t = dots[i]
	if not t then
		t = overlay:CreateTexture(nil, "ARTWORK")
		t:SetTexture(MEDIA .. "dot")
		t:SetWidth(6); t:SetHeight(6)
		dots[i] = t
	end
	return t
end

local function FormatMinutes(sec)
	local m = math.ceil(sec / 60)
	if m <= 1 then return "under a minute" end
	return m .. " min"
end

local function PinOnEnter()
	local route = Route(this.zone)
	if not route or not route.stops[this.index] then return end
	local s = route.stops[this.index]
	WorldMapTooltip:SetOwner(this, "ANCHOR_RIGHT")
	WorldMapTooltip:AddLine(s[3] .. " - stop " .. this.index .. " of " .. StopCount(route), 1, 0.54, 0.24)
	WorldMapTooltip:AddLine(string.format("%.1f, %.1f", s[1], s[2]), 1, 1, 1)
	local left = Cooldown(this.zone, s)
	if left then
		WorldMapTooltip:AddLine("Checked recently - ready in about " .. FormatMinutes(left), 0.7, 0.7, 0.7)
	end
	WorldMapTooltip:AddLine("Click to make this the next stop", 0.6, 0.6, 0.6)
	WorldMapTooltip:AddLine("Shift-right-click to ignore this node", 0.6, 0.6, 0.6)
	WorldMapTooltip:Show()
end

local function PinOnLeave() WorldMapTooltip:Hide() end
local function PinOnClick()
	if arg1 == "RightButton" then
		if IsShiftKeyDown() then BR:IgnoreStop(this.zone, this.index) end
	else
		BR:SetTarget(this.zone, this.index)
	end
end

local function GetPin(i)
	local b = pins[i]
	if not b then
		b = CreateFrame("Button", nil, overlay)
		b:SetWidth(12); b:SetHeight(12)
		b:EnableMouse(true)
		b.tex = b:CreateTexture(nil, "ARTWORK")
		b.tex:SetAllPoints(b)
		b.tex:SetTexture(MEDIA .. "dot")
		b.ring = b:CreateTexture(nil, "OVERLAY")
		b.ring:SetWidth(26); b.ring:SetHeight(26)
		b.ring:SetPoint("CENTER", b, "CENTER", 0, 0)
		b.ring:SetTexture(MEDIA .. "ring")
		b.ring:SetVertexColor(0.3, 0.76, 0.54, 1)
		b.label = b:CreateFontString(nil, "OVERLAY")
		b.label:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
		b.label:SetTextColor(1, 1, 1)
		b.label:SetPoint("BOTTOMLEFT", b, "TOPRIGHT", -3, -4)
		b:SetScript("OnEnter", PinOnEnter)
		b:SetScript("OnLeave", PinOnLeave)
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", PinOnClick)
		pins[i] = b
	end
	return b
end

local function GetCross(i)
	local t = crosses[i]
	if not t then
		t = overlay:CreateTexture(nil, "OVERLAY")
		t:SetTexture(MEDIA .. "cross")
		t:SetWidth(14); t:SetHeight(14)
		crosses[i] = t
	end
	return t
end

local function HideAll()
	for i = 1, table.getn(dots) do dots[i]:Hide() end
	for i = 1, table.getn(pins) do pins[i]:Hide() end
	for i = 1, table.getn(crosses) do crosses[i]:Hide() end
end

function BR.MapRef()
	return WorldMapDetailFrame or WorldMapButton
end

function BR:DrawMap()
	if not overlay or not WorldMapFrame:IsVisible() then return end
	HideAll()
	local zone = DisplayedMap()
	if not zone then
		overlay:Show()
		overlay.pending = true
		return
	end
	local route = Route(zone)
	if not db.map or not route then
		overlay.pending = nil
		if not (db.map and Building(zone)) then overlay:Hide() end
		return
	end
	overlay:Show()

	local ref = BR.MapRef()
	local W, H = ref:GetWidth(), ref:GetHeight()
	if not W or W < 10 or not H or H < 10 then
		overlay.pending = true
		return
	end
	overlay.pending = nil
	local n = StopCount(route)
	local target = Target(zone)
	local dotN = 0
	local trail = db.colors.trail

	if n > 1 then
		for i = 1, n do
			local a = route.stops[i]
			local b = route.stops[math.mod(i, n) + 1]
			local ax, ay = a[1] / 100 * W, -a[2] / 100 * H
			local bx, by = b[1] / 100 * W, -b[2] / 100 * H
			local len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
			local steps = math.floor(len / db.dotSpacing)
			for s = 1, steps - 1 do
				local f = s / steps
				dotN = dotN + 1
				local t = GetDot(dotN)
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
		p.zone, p.index = zone, i
		p:ClearAllPoints()
		p:SetPoint("CENTER", overlay, "TOPLEFT", s[1] / 100 * W, -s[2] / 100 * H)
		p.label:SetText(i)
		if i == target then
			local c = db.colors.target
			p.tex:SetVertexColor(c[1], c[2], c[3])
			p.ring:SetVertexColor(c[1], c[2], c[3], 1)
			p.ring:Show()
		else
			local c = StopColor(s[3])
			if Cooldown(zone, s) then c = GRAY end
			p.tex:SetVertexColor(c[1], c[2], c[3])
			p.ring:Hide()
		end
		p:Show()
	end

	-- red: left off the loop as too far out of the way; gray: nodes you ignored
	local nc = 0
	for i = 1, table.getn(route.skipped) do
		local s = route.skipped[i]
		nc = nc + 1
		local c = GetCross(nc)
		c:SetVertexColor(0.9, 0.28, 0.3, 1)
		c:ClearAllPoints()
		c:SetPoint("CENTER", overlay, "TOPLEFT", s[1] / 100 * W, -s[2] / 100 * H)
		c:Show()
	end
	for i = 1, table.getn(route.ignoredStops or {}) do
		local s = route.ignoredStops[i]
		nc = nc + 1
		local c = GetCross(nc)
		c:SetVertexColor(0.55, 0.55, 0.55, 0.9)
		c:ClearAllPoints()
		c:SetPoint("CENTER", overlay, "TOPLEFT", s[1] / 100 * W, -s[2] / 100 * H)
		c:Show()
	end
end

local function UpdateDebugMarker()
	local m = overlay and overlay.me
	if not m then return end
	if not db.debug then m:Hide() return end
	local x, y = GetPlayerMapPosition("player")
	if not x or (x == 0 and y == 0) then m:Hide() return end
	local ref = BR.MapRef()
	m:ClearAllPoints()
	m:SetPoint("CENTER", overlay, "TOPLEFT", x * ref:GetWidth(), -y * ref:GetHeight())
	m:Show()
end

local function CreateOverlay()
	local ref = BR.MapRef()
	overlay = CreateFrame("Frame", "BloomRouteMapOverlay", WorldMapButton)
	overlay:SetAllPoints(ref)
	overlay:SetFrameLevel(WorldMapButton:GetFrameLevel() + 2)

	overlay.me = overlay:CreateTexture(nil, "OVERLAY")
	overlay.me:SetTexture(MEDIA .. "dot")
	overlay.me:SetWidth(14); overlay.me:SetHeight(14)
	overlay.me:SetVertexColor(1, 0.2, 1)
	overlay.me:Hide()

	overlay:SetScript("OnUpdate", function()
		if this.pending then BR:DrawMap() end
		UpdateDebugMarker()
	end)
	overlay:Hide()
end

---------------------------------------------------------------------------
-- Arrow
---------------------------------------------------------------------------

local facingModel
local function FindFacingModel()
	local kids = { Minimap:GetChildren() }
	for i = 1, table.getn(kids) do
		local k = kids[i]
		if k.GetObjectType and k:GetObjectType() == "Model" and k.GetModel then
			local m = k:GetModel()
			if type(m) == "string" and string.find(string.lower(m), "minimaparrow") then
				return k
			end
		end
	end
end

local function PlayerFacing()
	if GetPlayerFacing then
		local f = GetPlayerFacing()
		if f then return f end
	end
	if not facingModel then facingModel = FindFacingModel() end
	if facingModel then return facingModel:GetFacing() end
end

local HALF = 0.5 / math.sqrt(2)
local function RotateTexture(t, deg)
	local r = math.rad(deg)
	local c, s = math.cos(r) * HALF, math.sin(r) * HALF
	local function uv(dx, dy) return 0.5 + dx * c + dy * s, 0.5 - dx * s + dy * c end
	local ulx, uly = uv(-1, -1)
	local llx, lly = uv(-1, 1)
	local urx, ury = uv(1, -1)
	local lrx, lry = uv(1, 1)
	t:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

function BR:UpdateArrow()
	local a = tracker and tracker.arrow
	if not a then return end
	local route = Route(playerZone)
	local i = route and Target(playerZone)
	local facing = PlayerFacing()
	if not i or not lastX or not facing then
		a:Hide()
		return
	end
	local s = route.stops[i]
	local d, dx, dy = Yards(route, lastX * 100, lastY * 100, s[1], s[2])
	local bearing = math.deg(math.atan2(dx, -dy))
	local rel = bearing + math.deg(facing)
	rel = rel - math.floor(rel / 360) * 360
	RotateTexture(a, rel)
	local off = rel; if off > 180 then off = 360 - off end
	local t = off / 180
	a:SetVertexColor(0.3 + 0.6 * t, 0.85 - 0.55 * t, 0.4 - 0.15 * t)
	a:Show()
end

---------------------------------------------------------------------------
-- Herb picker (tick any number of herbs)
---------------------------------------------------------------------------

local PICK_COLS, PICK_W, PICK_H = 2, 180, 20
local PICK_TABS = { { kind = "herb", label = "Herbs", skill = "Herbalism" },
                    { kind = "ore", label = "Ores", skill = "Mining" } }

local function CreatePicker()
	local f = CreateFrame("Frame", "BloomRoutePicker", UIParent)
	-- size the window for the longest tab
	local most = 0
	for t = 1, table.getn(PICK_TABS) do
		local n = 0
		for i = 1, table.getn(HERBS) do
			if HERBS[i].kind == PICK_TABS[t].kind then n = n + 1 end
		end
		if n > most then most = n end
	end
	local rows = math.ceil(most / PICK_COLS)
	f:SetWidth(PICK_COLS * PICK_W + 20); f:SetHeight(rows * PICK_H + 96)
	f:SetFrameStrata("DIALOG")
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0.08, 0.06, 0.05, 0.95)
	f:SetBackdropBorderColor(1, 0.54, 0.24, 0.9)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", f, "TOP", 0, -10)
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)

	-- tabs
	f.tabs = {}
	for t = 1, table.getn(PICK_TABS) do
		local tab = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		tab:SetWidth(80); tab:SetHeight(20)
		tab:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (t - 1) * 84, -30)
		tab:SetText(PICK_TABS[t].label)
		tab.kind = PICK_TABS[t].kind
		tab:SetScript("OnClick", function()
			db.pickerTab = this.kind
			f.Refresh()
		end)
		f.tabs[t] = tab
	end

	-- one row per node type, laid out separately for each tab
	f.rows = {}
	local slot = {}
	for i = 1, table.getn(HERBS) do
		local herb = HERBS[i]
		local k = (slot[herb.kind] or 0) + 1
		slot[herb.kind] = k
		local col = math.floor((k - 1) / rows)
		local row = math.mod(k - 1, rows)
		local b = CreateFrame("Button", nil, f)
		b:SetWidth(PICK_W - 4); b:SetHeight(PICK_H)
		b:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + col * PICK_W, -56 - row * PICK_H)
		b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		b.herb = herb.name
		b.kind = herb.kind

		b.check = CreateFrame("CheckButton", nil, b, "UICheckButtonTemplate")
		b.check:SetWidth(20); b.check:SetHeight(20)
		b.check:SetPoint("LEFT", b, "LEFT", 0, 0)
		b.check:SetScript("OnClick", function() BR:ToggleHerb(this:GetParent().herb) end)

		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", b.check, "RIGHT", 2, 0)
		b.text:SetJustifyH("LEFT")
		b.skill = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		b.skill:SetPoint("RIGHT", b, "RIGHT", -4, 0)
		-- the gem node's skill isn't published, so it shows no number
		if herb.skill > 0 then b.skill:SetText(herb.skill) else b.skill:SetText("") end

		b:SetScript("OnClick", function() BR:ToggleHerb(this.herb) end)
		b:SetScript("OnEnter", function()
			local h = HERB_BY_NAME[this.herb]
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:AddLine(h.name, 1, 0.82, 0)
			if h.gem then
				GameTooltip:AddLine("Gem node - skill needed not listed", 1, 1, 1)
			else
				GameTooltip:AddLine((h.kind == "ore" and "Mining " or "Herbalism ") .. h.skill, 1, 1, 1)
			end
			GameTooltip:AddLine(ZoneList({ h }, 8), 0.75, 0.75, 0.75, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		f.rows[i] = b
	end

	local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clear:SetWidth(80); clear:SetHeight(20)
	clear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
	clear:SetText("Clear all")
	clear:SetScript("OnClick", function()
		db.herbs = {}
		BR:SelectionChanged()
	end)
	local done = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	done:SetWidth(80); done:SetHeight(20)
	done:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
	done:SetText("Done")
	done:SetScript("OnClick", function() picker:Hide() end)

	f.Refresh = function()
		local kind = db.pickerTab or "herb"
		for t = 1, table.getn(f.tabs) do
			local tab = f.tabs[t]
			if tab.kind == kind then tab:LockHighlight() else tab:UnlockHighlight() end
		end
		if kind == "ore" then
			title:SetText("Pick ores  |cffa8968a(skill needed)|r")
		else
			title:SetText("Pick herbs  |cffa8968a(skill needed)|r")
		end
		for i = 1, table.getn(f.rows) do
			local b = f.rows[i]
			if b.kind ~= kind then
				b:Hide()
			else
				b:Show()
				local h = HERB_BY_NAME[b.herb]
				local label = b.herb
				if playerZone and GrowsIn(h, playerZone) then label = label .. " |cff4cc38a*|r" end
				b.text:SetText(label)
				b.check:SetChecked(db.herbs[b.herb])
				if db.herbs[b.herb] then
					local c = HerbColor(b.herb)
					b.text:SetTextColor(c[1], c[2], c[3])
				else
					b.text:SetTextColor(1, 1, 1)
				end
			end
		end
	end
	f:SetScript("OnShow", function() this.Refresh() end)
	f:Hide()
	tinsert(UISpecialFrames, "BloomRoutePicker")
	picker = f
end

-- kind ("herb" or "ore") opens the picker on that tab
function BR:TogglePicker(anchor, kind)
	if kind then db.pickerTab = kind end
	if picker:IsVisible() then
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
		picker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	picker:Show()
end

function BR:ToggleHerb(name)
	if not HERB_BY_NAME[name] then return end
	if db.herbs[name] then db.herbs[name] = nil else db.herbs[name] = true end
	self:SelectionChanged()
end

function BR:SelectionChanged()
	lastX, lastY = nil, nil
	if picker and picker:IsVisible() then picker.Refresh() end
	if options and options:IsVisible() then options.Refresh() end
	self:DrawMap()
	self:UpdatePosition()
	self:UpdateTrackerText()
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------

local function MakeButton(parent, label, width, tip, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetWidth(width); b:SetHeight(20)
	b:SetText(label)
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_TOP")
		GameTooltip:SetText(tip, 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function CreateTracker()
	local f = CreateFrame("Frame", "BloomRouteTracker", UIParent)
	f:SetWidth(324); f:SetHeight(110)
	f:SetPoint("TOP", UIParent, "TOP", 0, -140)
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0.08, 0.06, 0.05, 0.8)
	f:SetBackdropBorderColor(1, 0.54, 0.24, 0.8)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function() this:StartMoving() end)
	f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
	f:SetScript("OnMouseUp", function()
		if arg1 == "RightButton" and Route(playerZone) then
			local d = BR:Direction(playerZone)
			if IsShiftKeyDown() then BR:Step(-d) else BR:Step(d) end
		end
	end)

	f.herbButton = MakeButton(f, "", 196, "Pick which herbs and ores to farm", function() BR:TogglePicker(this) end)
	f.herbButton:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
	f.optionsButton = MakeButton(f, "Options", 64, "BloomRoute options", function() BR:ToggleOptions() end)
	f.optionsButton:SetPoint("LEFT", f.herbButton, "RIGHT", 4, 0)
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetWidth(24); close:SetHeight(24)
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
	close:SetScript("OnClick", function() BR:ToggleWindow(false) end)

	f.arrow = f:CreateTexture(nil, "ARTWORK")
	f.arrow:SetTexture(MEDIA .. "arrow")
	f.arrow:SetWidth(52); f.arrow:SetHeight(52)
	f.arrow:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -30)

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 58, -36)
	f.title:SetJustifyH("LEFT")
	f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.info:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -5)
	f.info:SetWidth(232)
	f.info:SetJustifyH("LEFT")

	f.prev = MakeButton(f, "<", 26, "Previous stop (skips nodes still respawning)", function() BR:Step(-1) end)
	f.prev:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 58, 8)
	f.next = MakeButton(f, ">", 26, "Next stop (skips nodes still respawning)", function() BR:Step(1) end)
	f.next:SetPoint("LEFT", f.prev, "RIGHT", 4, 0)
	f.nearest = MakeButton(f, "Nearest", 64, "Head for the closest stop that's ready", function() BR:GoNearest() end)
	f.nearest:SetPoint("LEFT", f.next, "RIGHT", 8, 0)
	f.reverse = MakeButton(f, "Reverse", 64, "Run the loop in the opposite direction", function() BR:ToggleReverse() end)
	f.reverse:SetPoint("LEFT", f.nearest, "RIGHT", 4, 0)

	-- Tracking buttons: Find Herbs and Find Minerals, each shown when you know the spell
	-- and its tracking is off
	local function TrackButton(name, spell, icon)
		local b = CreateFrame("Button", name, f)
		b:SetWidth(20); b:SetHeight(20)
		b:SetNormalTexture(icon)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b.spell = spell
		b:SetScript("OnClick", function() CastSpellByName(this.spell) end)
		b:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_TOP")
			GameTooltip:SetText("Cast " .. this.spell, 1, 1, 1)
			GameTooltip:AddLine((this.spell == "Find Minerals" and "Mineral" or "Herb") .. " tracking is off", 0.75, 0.75, 0.75)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:Hide()
		return b
	end
	f.findHerbs = TrackButton("BloomRouteFindHerbs", "Find Herbs", "Interface\\Icons\\INV_Misc_Flower_02")
	f.findHerbs:SetPoint("LEFT", f.reverse, "RIGHT", 4, 0)
	f.findMinerals = TrackButton("BloomRouteFindMinerals", "Find Minerals", "Interface\\Icons\\Spell_Nature_Earthquake")
	f.findMinerals:SetPoint("LEFT", f.findHerbs, "RIGHT", 4, 0)

	f.trackElapsed = 0
	f:SetScript("OnUpdate", function()
		BR:UpdateArrow()
		this.trackElapsed = this.trackElapsed + arg1
		if this.trackElapsed >= 0.25 then
			this.trackElapsed = 0
			BR:UpdateFindHerbsButton()
		end
	end)
	f:Hide()
	tracker = f
end

-- Tracking spells you know: [spell name] = its icon. Refreshed when your spells change.
local trackIcons = {}
function BR:FindHerbsSpellChanged()
	trackIcons = {}
	local i = 1
	while true do
		local name = GetSpellName(i, BOOKTYPE_SPELL)
		if not name then break end
		if name == "Find Herbs" or name == "Find Minerals" then
			trackIcons[name] = GetSpellTexture(i, BOOKTYPE_SPELL)
		end
		i = i + 1
	end
end

-- Show each tracking button when you know its spell and that tracking isn't on
function BR:UpdateFindHerbsButton()
	if not tracker then return end
	local current = string.lower(GetTrackingTexture() or "")
	local list = { tracker.findHerbs, tracker.findMinerals }
	for i = 1, 2 do
		local b = list[i]
		local icon = trackIcons[b.spell]
		if icon and string.lower(icon) ~= current then
			b:SetNormalTexture(icon)
			b:Show()
		else
			b:Hide()
		end
	end
end

local function SetNavEnabled(on)
	local list = { tracker.prev, tracker.next, tracker.nearest, tracker.reverse }
	for i = 1, 4 do
		if on then list[i]:Enable() else list[i]:Disable() end
	end
end

function BR:UpdateTrackerText()
	if not tracker then return end
	if not db.tracker then
		tracker:Hide()
		return
	end
	tracker:Show()
	tracker.herbButton:SetText(SelectionLabel())
	local sel = Selected()
	if table.getn(sel) == 0 then
		SetNavEnabled(false)
		tracker.title:SetText("|cffa8968aNothing picked|r")
		tracker.info:SetText("Click the button at the top to tick the herbs or ores you want to farm.")
		return
	end
	local route = Route(playerZone)
	if not route then
		SetNavEnabled(false)
		if Building(playerZone) then
			tracker.title:SetText("Building combined route...")
			tracker.info:SetText("")
		else
			local what = sel[1].name
			if table.getn(sel) > 1 then what = "of your picks" end
			tracker.title:SetText("|cffa8968aNo " .. what .. " in this zone|r")
			tracker.info:SetText("Found in: " .. ZoneList(sel, 4))
		end
		return
	end
	SetNavEnabled(true)
	local i = Target(playerZone)
	if not i then
		tracker.title:SetText(route.name)
		tracker.info:SetText("Finding the nearest stop...")
		return
	end
	local s = route.stops[i]
	local rev = ""
	if db.reverse[route.key] then rev = "  |cffa8968a(reversed)|r" end
	tracker.title:SetText(string.format("%s  |cffffffff%d/%d|r%s", route.name, i, StopCount(route), rev))

	local herbTag = ""
	if table.getn(route.herbs) > 1 then
		local c = HerbColor(s[3])
		herbTag = string.format("|cff%02x%02x%02x%s|r  ", c[1] * 255, c[2] * 255, c[3] * 255, s[3])
	end
	local wait = AllCooling(playerZone, route)
	local note = ""
	if wait then note = "\n|cffa8968aAll nodes checked - next ready in about " .. FormatMinutes(wait) .. "|r" end
	if lastX then
		local d, dx, dy = Yards(route, lastX * 100, lastY * 100, s[1], s[2])
		local dir = ""
		if not PlayerFacing() then dir = " " .. Compass(dx, dy) end
		tracker.info:SetText(string.format("%s|cff4cc38a%d yd%s|r  (%.1f, %.1f)%s", herbTag, math.floor(d + 0.5), dir, s[1], s[2], note))
	else
		tracker.info:SetText(string.format("%s(%.1f, %.1f)%s", herbTag, s[1], s[2], note))
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
-- Options panel
---------------------------------------------------------------------------

local RESPAWN_ROWS = 8

local function SetBox(box, value)
	if value then box:SetText(tostring(value)) else box:SetText("") end
end

local function ReadMinutes(box)
	local v = tonumber(box:GetText())
	if v and v > 0 then return v end
end

local function CreateOptions()
	local f = CreateFrame("Frame", "BloomRouteOptions", UIParent)
	f:SetWidth(330); f:SetHeight(200)
	f:SetFrameStrata("DIALOG")
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0.08, 0.06, 0.05, 0.95)
	f:SetBackdropBorderColor(1, 0.54, 0.24, 0.9)
	f:EnableMouse(true)
	f:SetClampedToScreen(true)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", f, "TOP", 0, -10)
	title:SetText("BloomRoute Options")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)

	local checks = {}
	local function Check(i, label, tip, get, set)
		local c = CreateFrame("CheckButton", "BloomRouteOptionsCheck" .. i, f, "UICheckButtonTemplate")
		c:SetWidth(24); c:SetHeight(24)
		c:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28 - (i - 1) * 24)
		getglobal(c:GetName() .. "Text"):SetText(label)
		c.get, c.set, c.tip = get, set, tip
		c:SetScript("OnClick", function() this.set(this:GetChecked() and true or false) end)
		c:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(this.tip, 1, 1, 1, 1, 1)
			GameTooltip:Show()
		end)
		c:SetScript("OnLeave", function() GameTooltip:Hide() end)
		table.insert(checks, c)
	end

	Check(1, "Show path on world map", "Draw the loop on the world map.",
		function() return db.map end,
		function(v) db.map = v; BR:DrawMap() end)
	Check(2, "Show path on minimap", "Draw the loop and nearby stops on your minimap.",
		function() return db.minimapPath end,
		function(v) db.minimapPath = v; BR:UpdateMinimapPath() end)
	Check(3, "Show minimap button", "Show the BloomRoute button on the minimap edge.",
		function() return not db.minimap.hide end,
		function(v)
			db.minimap.hide = not v
			if v then minimapButton:Show() else minimapButton:Hide() end
		end)
	Check(4, "Remember checked nodes", "Nodes you reach or pick are grayed out and skipped until their respawn time has passed.",
		function() return db.memory end,
		function(v) db.memory = v; BR:DrawMap(); BR:UpdateTrackerText() end)

	-- reach radius slider
	local s = CreateFrame("Slider", "BloomRouteOptionsRadius", f, "OptionsSliderTemplate")
	s:SetWidth(200); s:SetHeight(16)
	s:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -144)
	s:SetMinMaxValues(5, 60)
	s:SetValueStep(5)
	getglobal("BloomRouteOptionsRadiusLow"):SetText("5")
	getglobal("BloomRouteOptionsRadiusHigh"):SetText("60")
	s:SetScript("OnValueChanged", function()
		db.radius = this:GetValue()
		getglobal("BloomRouteOptionsRadiusText"):SetText("Reach radius: " .. db.radius .. " yd")
	end)
	f.radius = s

	-- respawn times
	local head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	head:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -176)
	head:SetText("Respawn times (minutes)")
	local colAll = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	colAll:SetPoint("TOPLEFT", f, "TOPLEFT", 160, -196)
	colAll:SetText("All zones")
	f.colZone = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.colZone:SetPoint("TOPLEFT", f, "TOPLEFT", 236, -196)
	f.colZone:SetWidth(84)
	f.colZone:SetJustifyH("LEFT")

	local boxN = 0
	local function Box(x, y)
		boxN = boxN + 1
		local e = CreateFrame("EditBox", "BloomRouteOptionsBox" .. boxN, f, "InputBoxTemplate")
		e:SetWidth(44); e:SetHeight(18)
		e:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
		e:SetAutoFocus(false)
		e:SetMaxLetters(4)
		e:SetScript("OnEscapePressed", function() this.cancel = true; this:ClearFocus() end)
		e:SetScript("OnEnterPressed", function() this:ClearFocus() end)
		e:SetScript("OnEditFocusLost", function()
			if this.cancel then
				this.cancel = nil
				f.Refresh()
			elseif this.save then
				this.save(ReadMinutes(this))
			end
		end)
		return e
	end

	-- default row
	local defLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	defLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -214)
	defLabel:SetText("Default (any node)")
	f.defBox = Box(164, -210)
	f.defBox.save = function(v)
		if v then db.respawnDefault = v end
		f.Refresh(); BR:DrawMap(); BR:UpdateTrackerText()
	end

	f.rows = {}
	for i = 1, RESPAWN_ROWS do
		local y = -214 - i * 22
		local r = {}
		r.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, y)
		r.label:SetWidth(140); r.label:SetJustifyH("LEFT")
		r.all = Box(164, y + 4)
		r.zone = Box(240, y + 4)
		r.all.save = function(v)
			if r.herb then db.respawn[r.herb] = v end
			f.Refresh(); BR:DrawMap(); BR:UpdateTrackerText()
		end
		r.zone.save = function(v)
			if r.herb and playerZone then db.respawnZone[r.herb .. "|" .. playerZone] = v end
			f.Refresh(); BR:DrawMap(); BR:UpdateTrackerText()
		end
		f.rows[i] = r
	end

	f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.empty:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -238)
	f.empty:SetText("Tick herbs in the picker to set their times.")

	f.clear = MakeButton(f, "Clear node memory", 140, "Forget every checked node so all of them count as ready", function()
		db.nodes = {}
		Print("node memory cleared")
		BR:DrawMap(); BR:UpdateTrackerText()
	end)
	f.help = MakeButton(f, "List chat commands", 140, "Print every /bloom command in your chat window", function()
		BR:ShowHelp()
	end)
	f.help:SetPoint("LEFT", f.clear, "RIGHT", 6, 0)
	f.unignoreZone = MakeButton(f, "Unignore this zone", 140, "Bring back every node you ignored in the zone you're in", function()
		BR:Unignore(playerZone)
	end)
	f.unignoreZone:SetPoint("TOPLEFT", f.clear, "BOTTOMLEFT", 0, -6)
	f.unignoreAll = MakeButton(f, "Unignore all zones", 140, "Bring back every node you ignored, in every zone", function()
		BR:Unignore(nil)
	end)
	f.unignoreAll:SetPoint("LEFT", f.unignoreZone, "RIGHT", 6, 0)

	f.Refresh = function()
		for i = 1, table.getn(checks) do checks[i]:SetChecked(checks[i].get()) end
		f.radius:SetValue(db.radius)
		getglobal("BloomRouteOptionsRadiusText"):SetText("Reach radius: " .. db.radius .. " yd")
		SetBox(f.defBox, db.respawnDefault)

		local zoneName
		local sel = Selected()
		for k = 1, table.getn(sel) do
			if playerZone and GrowsIn(sel[k], playerZone) then zoneName = playerZone end
		end
		if zoneName then f.colZone:SetText(zoneName .. " only") else f.colZone:SetText("This zone only") end

		local shown = math.min(table.getn(sel), RESPAWN_ROWS)
		for i = 1, RESPAWN_ROWS do
			local r = f.rows[i]
			local h = sel[i]
			if i <= shown then
				r.herb = h.name
				local c = HerbColor(h.name)
				r.label:SetText(h.name)
				r.label:SetTextColor(c[1], c[2], c[3])
				r.label:Show(); r.all:Show()
				SetBox(r.all, db.respawn[h.name])
				if playerZone and GrowsIn(h, playerZone) then
					r.zone:Show()
					SetBox(r.zone, db.respawnZone[h.name .. "|" .. playerZone])
				else
					r.zone:Hide()
				end
			else
				r.herb = nil
				r.label:Hide(); r.all:Hide(); r.zone:Hide()
			end
		end
		if shown == 0 then f.empty:Show() else f.empty:Hide() end
		local bottom = -214 - math.max(shown, 1) * 22 - 30
		f.clear:ClearAllPoints()
		f.clear:SetPoint("TOPLEFT", f, "TOPLEFT", 14, bottom)
		f:SetHeight(-bottom + 58)
	end

	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 8)
	hint:SetText("Blank = use the time to the left.")

	-- Tabs: everything built above is the General tab
	local general = {}
	local kids = { f:GetChildren() }
	for i = 1, table.getn(kids) do
		if kids[i] ~= close then table.insert(general, kids[i]) end
	end
	local regs = { f:GetRegions() }
	for i = 1, table.getn(regs) do
		if regs[i] ~= title then table.insert(general, regs[i]) end
	end
	local GeneralRefresh = f.Refresh

	-- Visuals tab
	local v = CreateFrame("Frame", nil, f)
	v:SetAllPoints(f)
	v:Hide()

	local colorsHead = v:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	colorsHead:SetPoint("TOPLEFT", v, "TOPLEFT", 14, -30)
	colorsHead:SetText("Colors")

	local function Apply()
		v.Refresh()
		BR:DrawMap()
	end

	-- opens the game's color picker for one of db.colors
	local function PickColor(key)
		local c = db.colors[key]
		ColorPickerFrame.hasOpacity = nil
		ColorPickerFrame.opacityFunc = nil
		ColorPickerFrame.previousValues = { c[1], c[2], c[3] }
		ColorPickerFrame.func = function()
			local r, g, b = ColorPickerFrame:GetColorRGB()
			db.colors[key] = { r, g, b }
			Apply()
		end
		ColorPickerFrame.cancelFunc = function(prev)
			if prev then db.colors[key] = { prev[1], prev[2], prev[3] } end
			Apply()
		end
		ColorPickerFrame:SetColorRGB(c[1], c[2], c[3])
		ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
		ShowUIPanel(ColorPickerFrame)
	end

	v.swatches = {}
	local function Swatch(i, label, key, tip)
		local b = CreateFrame("Button", nil, v)
		b:SetWidth(20); b:SetHeight(20)
		b:SetPoint("TOPLEFT", v, "TOPLEFT", 16, -52 - (i - 1) * 26)
		local edge = b:CreateTexture(nil, "BACKGROUND")
		edge:SetAllPoints(b)
		edge:SetTexture(0, 0, 0, 1)
		b.color = b:CreateTexture(nil, "ARTWORK")
		b.color:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
		b.color:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
		b.color:SetTexture(1, 1, 1, 1)
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		local text = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetPoint("LEFT", b, "RIGHT", 8, 0)
		text:SetText(label)
		b.key, b.tip = key, tip
		b:SetScript("OnClick", function() PickColor(this.key) end)
		b:SetScript("OnEnter", function()
			GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
			GameTooltip:SetText(this.tip, 1, 1, 1, 1, 1)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		table.insert(v.swatches, b)
	end
	Swatch(1, "Trail between nodes", "trail", "Color of the dotted path on the world map and minimap.")
	Swatch(2, "Node rings", "ring", "Color of the node rings on the minimap and the pins on the world map.")
	Swatch(3, "Next stop", "target", "Color of the ring and pin for your next stop.")

	local byType = CreateFrame("CheckButton", "BloomRouteOptionsByType", v, "UICheckButtonTemplate")
	byType:SetWidth(24); byType:SetHeight(24)
	byType:SetPoint("TOPLEFT", v, "TOPLEFT", 14, -130)
	getglobal("BloomRouteOptionsByTypeText"):SetText("Color rings by type when several are picked")
	byType:SetScript("OnClick", function()
		db.ringsByType = this:GetChecked() and true or false
		BR:DrawMap()
	end)
	byType:SetScript("OnEnter", function()
		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:SetText("With more than one herb or ore picked, give each type its own ring color (the colors shown in the picker) instead of the Node rings color.", 1, 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	byType:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local reset = MakeButton(v, "Reset colors", 120, "Go back to the original colors", function()
		db.colors = {}
		for k, c in pairs(DEFAULT_COLORS) do db.colors[k] = { c[1], c[2], c[3] } end
		db.ringsByType = true
		Apply()
	end)
	reset:SetPoint("TOPLEFT", v, "TOPLEFT", 14, -162)

	v.Refresh = function()
		for i = 1, table.getn(v.swatches) do
			local b = v.swatches[i]
			local c = db.colors[b.key]
			b.color:SetVertexColor(c[1], c[2], c[3])
		end
		byType:SetChecked(db.ringsByType)
	end

	-- tab buttons sit on top of the panel
	local TABS = { { id = "general", label = "General" }, { id = "visuals", label = "Visuals" } }
	f.tabs = {}
	for i = 1, table.getn(TABS) do
		local tab = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		tab:SetWidth(80); tab:SetHeight(20)
		tab:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 6 + (i - 1) * 84, -2)
		tab:SetText(TABS[i].label)
		tab.id = TABS[i].id
		tab:SetScript("OnClick", function()
			db.optionsTab = this.id
			f.Refresh()
		end)
		f.tabs[i] = tab
	end

	f.Refresh = function()
		local tab = db.optionsTab or "general"
		for i = 1, table.getn(f.tabs) do
			if f.tabs[i].id == tab then f.tabs[i]:LockHighlight() else f.tabs[i]:UnlockHighlight() end
		end
		if tab == "visuals" then
			for i = 1, table.getn(general) do general[i]:Hide() end
			v:Show()
			v.Refresh()
			f:SetHeight(200)
		else
			v:Hide()
			for i = 1, table.getn(general) do general[i]:Show() end
			GeneralRefresh()
		end
	end

	f:SetScript("OnShow", function() this.Refresh() end)
	f:Hide()
	tinsert(UISpecialFrames, "BloomRouteOptions")
	options = f
end

function BR:ToggleOptions()
	if options:IsVisible() then options:Hide() return end
	if picker then picker:Hide() end
	options:ClearAllPoints()
	if tracker:GetTop() and tracker:GetTop() < GetScreenHeight() / 2 then
		options:SetPoint("BOTTOMRIGHT", tracker, "TOPRIGHT", 0, 4)
	else
		options:SetPoint("TOPRIGHT", tracker, "BOTTOMRIGHT", 0, -4)
	end
	options:Show()
end

---------------------------------------------------------------------------
-- Minimap path
---------------------------------------------------------------------------

local MINIMAP_RADIUS = { [0] = 233.33, 200, 166.67, 133.33, 100, 66.67 }
local mmFrame
local mmDots, mmPins = {}, {}

-- path dots are small solid dots; stops are hollow rings so the herb blip shows through
local function MMTexture(pool, i, size, texture)
	local t = pool[i]
	if not t then
		t = mmFrame:CreateTexture(nil, "OVERLAY")
		t:SetTexture(MEDIA .. (texture or "dot"))
		pool[i] = t
	end
	t:SetWidth(size); t:SetHeight(size)
	return t
end

local function CreateMinimapPath()
	mmFrame = CreateFrame("Frame", "BloomRouteMinimapPath", Minimap)
	mmFrame:SetAllPoints(Minimap)
	mmFrame:SetFrameLevel(Minimap:GetFrameLevel() + 1)
	mmFrame.elapsed = 0
	mmFrame:SetScript("OnUpdate", function()
		this.elapsed = this.elapsed + arg1
		if this.elapsed < 0.05 then return end
		this.elapsed = 0
		BR:UpdateMinimapPath()
	end)
end

function BR:UpdateMinimapPath()
	if not mmFrame then return end
	local nDots, nPins = 0, 0
	local route = db.minimapPath and Route(playerZone)
	local x, y
	if route then
		if not WorldMapFrame:IsVisible() or DisplayedMap() == playerZone then
			x, y = GetPlayerMapPosition("player")
		end
		if not x or (x == 0 and y == 0) then x, y = lastX, lastY end
	end
	if route and x and not (x == 0 and y == 0) then
		local px, py = x * 100, y * 100
		local half = Minimap:GetWidth() / 2
		local R = MINIMAP_RADIUS[Minimap:GetZoom()] or 233.33
		local scale = half / R
		local square = GetMinimapShape and GetMinimapShape() == "SQUARE"
		local lim = half - 4
		local function Inside(ox, oy)
			if square then return math.abs(ox) <= lim and math.abs(oy) <= lim end
			return ox * ox + oy * oy <= lim * lim
		end
		local function Offset(s)
			return (s[1] - px) / 100 * route.width * scale, -(s[2] - py) / 100 * route.height * scale
		end
		local n = StopCount(route)
		local target = Target(playerZone)

		if n > 1 then
			local reach = half + 20
			for i = 1, n do
				local ax, ay = Offset(route.stops[i])
				local bx, by = Offset(route.stops[math.mod(i, n) + 1])
				if not ((ax > reach and bx > reach) or (ax < -reach and bx < -reach)
					or (ay > reach and by > reach) or (ay < -reach and by < -reach)) then
					local len = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
					local steps = math.floor(len / 7)
					for k = 1, steps - 1 do
						local f = k / steps
						local ox, oy = ax + (bx - ax) * f, ay + (by - ay) * f
						if Inside(ox, oy) and nDots < 400 then
							nDots = nDots + 1
							local t = MMTexture(mmDots, nDots, 4)
							local tc = db.colors.trail
							t:SetVertexColor(tc[1], tc[2], tc[3], 0.9)
							t:ClearAllPoints()
							t:SetPoint("CENTER", mmFrame, "CENTER", ox, oy)
							t:Show()
						end
					end
				end
			end
		end

		-- each ring's outer edge is the reach radius, so walking inside it clears the stop
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
				if isTarget then
					local c = db.colors.target
					t:SetVertexColor(c[1], c[2], c[3])
				else
					local c = StopColor(s[3])
					if Cooldown(playerZone, s) then c = GRAY end
					t:SetVertexColor(c[1], c[2], c[3])
				end
				t:ClearAllPoints()
				t:SetPoint("CENTER", mmFrame, "CENTER", ox, oy)
				t:Show()
			end
		end
	end
	for i = nDots + 1, table.getn(mmDots) do mmDots[i]:Hide() end
	for i = nPins + 1, table.getn(mmPins) do mmPins[i]:Hide() end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

local function PlaceMinimapButton()
	local a = math.rad(db.minimap.angle)
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
end

local function CreateMinimapButton()
	local b = CreateFrame("Button", "BloomRouteMinimapButton", Minimap)
	b:SetWidth(31); b:SetHeight(31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Herb_19")
	icon:SetWidth(20); icon:SetHeight(20)
	icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -5)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetWidth(53); border:SetHeight(53)
	border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

	b:SetScript("OnClick", function()
		if arg1 == "RightButton" then
			if not db.tracker then BR:ToggleWindow(true) end
			BR:TogglePicker(tracker.herbButton)
		else
			BR:ToggleWindow()
		end
	end)
	b:SetScript("OnDragStart", function()
		this:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local s = Minimap:GetEffectiveScale()
			db.minimap.angle = math.deg(math.atan2(cy / s - my, cx / s - mx))
			PlaceMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function() this:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function()
		local sel = Selected()
		local names = {}
		for i = 1, table.getn(sel) do names[i] = sel[i].name end
		GameTooltip:SetOwner(this, "ANCHOR_LEFT")
		GameTooltip:AddLine("BloomRoute", 1, 0.54, 0.24)
		if table.getn(names) > 0 then
			GameTooltip:AddLine("Farming: " .. table.concat(names, ", "), 1, 1, 1, 1)
		else
			GameTooltip:AddLine("Nothing picked", 1, 1, 1)
		end
		GameTooltip:AddLine("Left-click: show/hide window", 0.75, 0.75, 0.75)
		GameTooltip:AddLine("Right-click: pick herbs or ores", 0.75, 0.75, 0.75)
		GameTooltip:AddLine("Drag: move this button", 0.75, 0.75, 0.75)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	minimapButton = b
	PlaceMinimapButton()
	if db.minimap.hide then b:Hide() end
end

---------------------------------------------------------------------------
-- Position tracking and harvesting
---------------------------------------------------------------------------

local needRecenter = true
function BR:FlagRecenter() needRecenter = true end

-- mark the current target checked and move to the next stop that's ready
local function Advance(zone, route, i)
	MarkNode(zone, route.stops[i])
	SetProgress(zone, route, NextReady(zone, route, i, BR:Direction(zone)))
	BR:DrawMap()
end

function BR:UpdatePosition()
	local zone, x, y
	if WorldMapFrame:IsVisible() then
		zone = DisplayedMap()
		if zone ~= playerZone then return end
		x, y = GetPlayerMapPosition("player")
	else
		zone = DisplayedMap()
		x, y = GetPlayerMapPosition("player")
		if needRecenter or not zone or GetCurrentMapZone() == 0 or (x == 0 and y == 0) then
			if DropDownList1 and DropDownList1:IsVisible() then return end
			SetMapToCurrentZone()
			needRecenter = false
			zone = DisplayedMap()
			x, y = GetPlayerMapPosition("player")
		end
	end

	local changed = zone ~= playerZone
	playerZone = zone
	if changed and options and options:IsVisible() then options.Refresh() end
	-- your position in any zone (used to learn new spawns, even where there's no route)
	if x and not (x == 0 and y == 0) then curX, curY = x, y else curX, curY = nil, nil end
	local route = Route(zone)
	if not route then
		lastX, lastY = nil, nil
		if changed or Building(zone) then self:UpdateTrackerText() end
		return
	end
	if x == 0 and y == 0 then return end
	lastX, lastY = x, y

	local i = Target(zone)
	if not i then
		i = Nearest(zone, x * 100, y * 100, true)
		SetProgress(zone, route, i)
		self:DrawMap()
	end
	-- Clearing any ready stop by walking up to it (not just the target) moves your place
	-- in the loop to that stop, so the next stop is the one after it.
	if StopCount(route) > 1 then
		local px, py = x * 100, y * 100
		local hit, hd
		for k = 1, StopCount(route) do
			local s = route.stops[k]
			if k == i or not Cooldown(zone, s) then
				local d = Yards(route, px, py, s[1], s[2])
				if d <= db.radius and (not hd or d < hd) then hit, hd = k, d end
			end
		end
		if hit then Advance(zone, route, hit) end
	end
	self:UpdateTrackerText()
end

-- After a loop is rebuilt with a spawn you just learned, move your place to that stop.
function BR:ApplyPendingPick()
	local p = self.pendingPick
	if not p then return end
	local route = Route(p.zone)
	if not route then
		-- still waiting on a rebuild for that zone (or the herb isn't picked); try again later
		if not Building(p.zone) then self.pendingPick = nil end
		return
	end
	self.pendingPick = nil
	for k = 1, StopCount(route) do
		if NodeId(p.zone, route.stops[k]) == p.id then
			Advance(p.zone, route, k)
			return
		end
	end
end

-- How close (yards) a known spawn of the same herb must be for a pick to count as that spawn.
-- Picks farther than this from every known spawn are learned as new spawns.
local LEARN_DISTANCE = 30

-- If the herb you picked has no known spawn (database or learned) near you, remember this
-- spot as a new spawn. Returns its coordinates when a spawn was added.
local function LearnSpawn(herbName, zone, x, y)
	local herb = HERB_BY_NAME[herbName]
	if not herb or not zone then return false end
	local size = ZoneInfo(zone)
	local function Near(list)
		if not list then return false end
		for k = 1, table.getn(list) do
			local p = list[k]
			if Yards(size, x, y, p[1], p[2]) <= LEARN_DISTANCE then return true end
		end
		return false
	end
	local z = herb.zones[zone]
	if z and (Near(z.stops) or Near(z.skipped)) then return false end
	if Near(Learned(herbName, zone)) then return false end

	db.learned[herbName] = db.learned[herbName] or {}
	db.learned[herbName][zone] = db.learned[herbName][zone] or {}
	local px = math.floor(x * 10 + 0.5) / 10
	local py = math.floor(y * 10 + 0.5) / 10
	table.insert(db.learned[herbName][zone], { px, py })
	Print(string.format("learned a new %s spawn in %s (%.1f, %.1f)", herbName, zone, px, py))
	return px, py
end

-- You looted a herb: learn the spawn if it's new, then clear the stop you picked and move
-- your place in the loop to it, exactly like reaching it (picking stop 3 makes 4 next).
local gatherStarted = 0
-- any cast at all: the gem node isn't opened with Mining or Herb Gathering, so a loot window
-- that follows any cast and contains its signature gem counts as picking it
local anyCastStarted = 0
function BR:OnHarvest(gemsOnly)
	-- which node types the loot came from; the first match is the node's own type (a node
	-- can also drop a bonus herb, like Black Lotus from Dreamfoil, or gems from a vein)
	local looted, primary = {}, nil
	for slot = 1, GetNumLootItems() do
		local _, name = GetLootSlotInfo(slot)
		local node = name and BY_LOOT[name]
		if node and gemsOnly and not node.gem then node = nil end
		if node then
			looted[node.name] = true
			if not primary then primary = node.name end
		end
	end

	if primary and curX then
		local nx, ny = LearnSpawn(primary, playerZone, curX * 100, curY * 100)
		if nx then
			-- you just picked it, so it starts out checked; once the loop has been rebuilt
			-- with the new stop, your place moves to it like any other pick
			local node = { nx, ny, primary }
			MarkNode(playerZone, node)
			BR.pendingPick = { zone = playerZone, id = NodeId(playerZone, node) }
			self:DrawMap()
			self:UpdateTrackerText()
			return
		end
	end

	local route = Route(playerZone)
	if not route or not lastX then return end
	local px, py = lastX * 100, lastY * 100
	local best, bd
	for i = 1, StopCount(route) do
		local s = route.stops[i]
		if not next(looted) or looted[s[3]] then
			local d = Yards(route, px, py, s[1], s[2])
			if not bd or d < bd then best, bd = i, d end
		end
	end
	if not best or bd > 40 then return end
	Advance(playerZone, route, best)
	self:UpdateTrackerText()
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- Leave a node out of the loop (shift-right-click its pin on the world map)
function BR:IgnoreStop(zone, i)
	local route = Route(zone)
	if not route or not route.stops[i] then return end
	local s = route.stops[i]
	db.ignored[IgnoreKey(zone, s)] = true
	ignoreVersion = ignoreVersion + 1
	Print(string.format("ignored the %s node at %.1f, %.1f in %s (Options > Unignore to bring it back)", s[3], s[1], s[2], zone))
	self:DrawMap()
	self:UpdateTrackerText()
end

-- Bring back ignored nodes in one zone, or in every zone when zone is nil
function BR:Unignore(zone)
	local n = 0
	for key in pairs(db.ignored) do
		local _, _, z = string.find(key, "^.-|(.-)|")
		if not zone or z == zone then
			db.ignored[key] = nil
			n = n + 1
		end
	end
	ignoreVersion = ignoreVersion + 1
	if zone then
		Print(n .. " ignored node" .. (n == 1 and "" or "s") .. " brought back in " .. zone)
	else
		Print(n .. " ignored node" .. (n == 1 and "" or "s") .. " brought back in all zones")
	end
	self:DrawMap()
	self:UpdateTrackerText()
end

function BR:SetTarget(zone, i)
	local route = Route(zone)
	if not route then return end
	SetProgress(zone, route, Wrap(i, StopCount(route)))
	self:DrawMap()
	self:UpdateTrackerText()
end

local function NotHere()
	Print("None of your picked herbs have a route in this zone.")
end

function BR:GoNearest()
	if Route(playerZone) and lastX then
		self:SetTarget(playerZone, Nearest(playerZone, lastX * 100, lastY * 100, true))
	else
		NotHere()
	end
end

function BR:ToggleReverse()
	local route = Route(playerZone)
	if not route then NotHere() return end
	db.reverse[route.key] = not db.reverse[route.key] or nil
	Print(route.name .. " loop now runs " .. (db.reverse[route.key] and "in reverse" or "in list order"))
	self:UpdateTrackerText()
end

function BR:Step(delta)
	local route = Route(playerZone)
	if not route then NotHere() return end
	local i = Target(playerZone) or 1
	local dir = 1
	if delta < 0 then dir = -1 end
	for k = 1, math.abs(delta) do i = NextReady(playerZone, route, i, dir) end
	self:SetTarget(playerZone, i)
end

-- find a herb or ore by (part of) its name; kind ("herb" or "ore") limits the search
local function FindHerb(text, kind)
	text = string.lower(text)
	for i = 1, table.getn(HERBS) do
		local n = HERBS[i]
		if (not kind or n.kind == kind) and string.lower(n.name) == text then return n.name end
	end
	for i = 1, table.getn(HERBS) do
		local n = HERBS[i]
		if (not kind or n.kind == kind) and string.find(string.lower(n.name), text, 1, true) then return n.name end
	end
end

-- /bloom respawn <minutes> <herb> [here]
local function RespawnCommand(rest)
	local _, _, mins, name = string.find(rest, "^(%d+)%s+(.+)$")
	local here = false
	if name then
		local _, _, n2 = string.find(name, "^(.-)%s+here$")
		if n2 then name, here = n2, true end
	end
	local herb = name and FindHerb(name)
	if not mins or not herb then
		Print("usage: /bloom respawn <minutes> <herb or ore> [here]  e.g. /bloom respawn 10 sungrass here")
		return
	end
	mins = tonumber(mins)
	if here then
		if not playerZone or not GrowsIn(HERB_BY_NAME[herb], playerZone) then
			Print(herb .. " isn't found in this zone.")
			return
		end
		db.respawnZone[herb .. "|" .. playerZone] = mins
		Print(herb .. " respawn in " .. playerZone .. " set to " .. mins .. " min")
	else
		db.respawn[herb] = mins
		Print(herb .. " respawn set to " .. mins .. " min in all zones")
	end
	if options and options:IsVisible() then options.Refresh() end
	BR:DrawMap(); BR:UpdateTrackerText()
end

local function Help()
	Print("commands:")
	Print("  /bloom show - show or hide the window (or click the minimap button)")
	Print("  /bloom herb [name] - tick or untick a herb (no name opens the picker)")
	Print("  /bloom ore [name] - tick or untick an ore, e.g. /bloom ore thorium")
	Print("  /bloom herbs | ores - list every herb or ore and where it's found")
	Print("  /bloom options - open the options panel")
	Print("  /bloom map | mmpath - toggle the path on the world map | minimap")
	Print("  /bloom next | prev | nearest | reverse - move around the loop")
	Print("  /bloom goto <n> - make stop n the next stop")
	Print("  /bloom radius <yards> - how close counts as reaching a stop (now " .. db.radius .. ")")
	Print("  /bloom respawn <minutes> <herb or ore> [here] - set a respawn time, all zones or this zone")
	Print("  /bloom forget - clear node memory")
	Print("  /bloom unignore [all] - bring back ignored nodes in this zone, or everywhere")
	Print("  /bloom learned - list spawns you picked that the database didn't have")
	Print("  /bloom forgetlearned - clear every learned spawn")
	Print("  /bloom minimap - show or hide the minimap button")
	Print("  /bloom where | debug - position help")
end

function BR:ShowHelp() Help() end

SLASH_BLOOMROUTE1 = "/bloom"
SLASH_BLOOMROUTE2 = "/bloomroute"
SlashCmdList["BLOOMROUTE"] = function(msg)
	msg = msg or ""
	local _, _, cmd, rest = string.find(msg, "^%s*(%S*)%s*(.-)%s*$")
	cmd = string.lower(cmd or "")
	if cmd == "show" or cmd == "tracker" then
		BR:ToggleWindow()
	elseif cmd == "herb" or cmd == "ore" then
		if rest == "" then
			BR:ToggleWindow(true)
			BR:TogglePicker(tracker.herbButton, cmd)
		else
			local name = FindHerb(rest, cmd)
			if name then
				BR:ToggleHerb(name)
				Print(name .. (db.herbs[name] and " added" or " removed"))
			else
				Print("nothing matches \"" .. rest .. "\". Try /bloom herbs or /bloom ores")
			end
		end
	elseif cmd == "herbs" or cmd == "ores" then
		local kind = (cmd == "ores") and "ore" or "herb"
		for i = 1, table.getn(HERBS) do
			if HERBS[i].kind == kind then
				Print(string.format("  %s (%d): %s", HERBS[i].name, HERBS[i].skill, ZoneList({ HERBS[i] }, 4)))
			end
		end
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
		BR:UpdateMinimapPath()
	elseif cmd == "next" then
		BR:Step(1)
	elseif cmd == "prev" then
		BR:Step(-1)
	elseif cmd == "nearest" then
		BR:GoNearest()
	elseif cmd == "reverse" then
		BR:ToggleReverse()
	elseif cmd == "goto" then
		local n = tonumber(rest)
		if n and Route(playerZone) then BR:SetTarget(playerZone, math.floor(n)) else Print("usage: /bloom goto <stop number>") end
	elseif cmd == "radius" then
		local n = tonumber(rest)
		if n and n > 0 then db.radius = n; Print("reach radius set to " .. n .. " yards") else Print("usage: /bloom radius <yards>") end
	elseif cmd == "respawn" then
		RespawnCommand(rest)
	elseif cmd == "learned" then
		local total = 0
		for herb, zones in pairs(db.learned) do
			for zone, list in pairs(zones) do
				local n = table.getn(list)
				if n > 0 then
					total = total + n
					Print(string.format("  %s in %s: %d", herb, zone, n))
				end
			end
		end
		if total == 0 then Print("no learned spawns yet") else Print(total .. " learned spawns in all") end
	elseif cmd == "forgetlearned" then
		db.learned = {}
		routeCache = {}
		Print("learned spawns cleared")
		BR:DrawMap(); BR:UpdateTrackerText()
	elseif cmd == "unignore" then
		if string.lower(rest) == "all" then
			BR:Unignore(nil)
		elseif playerZone then
			BR:Unignore(playerZone)
		else
			Print("usage: /bloom unignore [all]")
		end
	elseif cmd == "forget" then
		db.nodes = {}
		Print("node memory cleared")
		BR:DrawMap(); BR:UpdateTrackerText()
	elseif cmd == "minimap" then
		db.minimap.hide = not db.minimap.hide
		if db.minimap.hide then minimapButton:Hide() else minimapButton:Show() end
		Print("minimap button " .. (db.minimap.hide and "hidden (/bloom minimap to bring it back)" or "shown"))
	elseif cmd == "debug" then
		db.debug = not db.debug
		Print("debug marker " .. (db.debug and "on: a magenta dot shows where the addon places you on the world map" or "off"))
	elseif cmd == "where" then
		if not WorldMapFrame:IsVisible() then SetMapToCurrentZone() end
		local x, y = GetPlayerMapPosition("player")
		local zone = DisplayedMap() or "?"
		Print(string.format("map %s, you are at %.1f, %.1f", zone, x * 100, y * 100))
		local route = Route(zone)
		if route and not (x == 0 and y == 0) then
			local i = Nearest(zone, x * 100, y * 100)
			local s = route.stops[i]
			Print(string.format("nearest stop #%d (%s) at %.1f, %.1f (%d yd away)", i, s[3], s[1], s[2],
				math.floor(Yards(route, x * 100, y * 100, s[1], s[2]) + 0.5)))
		end
		local ref = BR.MapRef()
		Print(string.format("map frame %s is %d x %d", ref:GetName() or "?", ref:GetWidth(), ref:GetHeight()))
	else
		Help()
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("VARIABLES_LOADED")
events:RegisterEvent("WORLD_MAP_UPDATE")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("SPELLCAST_START")
events:RegisterEvent("LOOT_OPENED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("LEARNED_SPELL_IN_TAB")
events:SetScript("OnEvent", function()
	if event == "VARIABLES_LOADED" then
		if type(BloomRouteDB) ~= "table" then BloomRouteDB = {} end
		db = BloomRouteDB
		if not db.version or db.version < 3 then
			-- 2.0/2.1 kept one selected herb and progress keyed by herb only
			local old = db.herb
			db.progress, db.reverse, db.herbs = {}, {}, {}
			if type(old) == "string" and HERB_BY_NAME[old] then db.herbs[old] = true end
			db.herb = nil
			db.version = 3
		end
		if db.version < 4 then
			-- 2.3.0 keys zones by name (so Turtle's custom zones work) and uses pfQuest-turtle's
			-- spawn points. Old loop positions and node memory don't match the new stops, so
			-- they start fresh; per-zone respawn times carry over under the zone's name.
			local FILE_TO_NAME = {
				DunMorogh = "Dun Morogh", Badlands = "Badlands", BlastedLands = "Blasted Lands",
				SwampsofSorrow = "Swamp of Sorrows", Duskwood = "Duskwood", Wetlands = "Wetlands",
				Durotar = "Durotar", Dustwallow = "Dustwallow Marsh", Aszhara = "Azshara",
				Barrens = "The Barrens", WesternPlaguelands = "Western Plaguelands",
				Stranglethorn = "Stranglethorn Vale", Alterac = "Alterac Mountains", LochModan = "Loch Modan",
				Westfall = "Westfall", Redridge = "Redridge Mountains", BurningSteppes = "Burning Steppes",
				Hinterlands = "The Hinterlands", SearingGorge = "Searing Gorge", Tirisfal = "Tirisfal Glades",
				Silverpine = "Silverpine Forest", EasternPlaguelands = "Eastern Plaguelands",
				Teldrassil = "Teldrassil", Darkshore = "Darkshore", Mulgore = "Mulgore",
				Hilsbrad = "Hillsbrad Foothills", Feralas = "Feralas", Felwood = "Felwood",
				ThousandNeedles = "Thousand Needles", Desolace = "Desolace",
				StonetalonMountains = "Stonetalon Mountains", Tanaris = "Tanaris",
				UngoroCrater = "Un'Goro Crater", Winterspring = "Winterspring", Elwynn = "Elwynn Forest",
				Silithus = "Silithus", Ashenvale = "Ashenvale", Arathi = "Arathi Highlands",
				AlteracValley = "Alterac Valley",
			}
			local moved = {}
			for key, mins in pairs(db.respawnZone or {}) do
				local _, _, herb, file = string.find(key, "^(.*)|(.-)$")
				if herb and FILE_TO_NAME[file] then moved[herb .. "|" .. FILE_TO_NAME[file]] = mins end
			end
			db.respawnZone = moved
			db.progress, db.reverse, db.nodes = {}, {}, {}
			db.version = 4
		end
		CopyDefaults(DEFAULTS, db)
		if not next(db.herbs) then db.herbs["Firebloom"] = true end
		PruneMemory()
		CreateOverlay()
		CreateTracker()
		CreatePicker()
		CreateMinimapButton()
		CreateOptions()
		CreateMinimapPath()
		BR:FindHerbsSpellChanged()
		BR:UpdateTrackerText()
		events.elapsed = 0
		events:SetScript("OnUpdate", function()
			-- finish any combined route a slice at a time
			-- (4 slices per frame: a few ms, so even a 6-herb Barrens loop takes only seconds)
			for slice = 1, 4 do
				if not job then break end
				local ok, err = coroutine.resume(job.co)
				if not ok then
					Print("couldn't build the combined route: " .. tostring(err))
					job = nil
				elseif coroutine.status(job.co) == "dead" then
					job = nil
					BR:ApplyPendingPick()
					BR:DrawMap()
					BR:UpdatePosition()
					BR:UpdateTrackerText()
				end
			end
			this.elapsed = this.elapsed + arg1
			if this.elapsed < 0.2 then return end
			this.elapsed = 0
			BR:UpdatePosition()
		end)
		WorldMapFrame:SetScript("OnShow", (function(orig)
			return function()
				if orig then orig() end
				BR:DrawMap()
			end
		end)(WorldMapFrame:GetScript("OnShow")))
		WorldMapFrame:SetScript("OnHide", (function(orig)
			return function()
				if orig then orig() end
				BR:FlagRecenter()
			end
		end)(WorldMapFrame:GetScript("OnHide")))
	elseif not db then
		return
	elseif event == "WORLD_MAP_UPDATE" then
		BR:DrawMap()
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		BR:FlagRecenter()
		BR:UpdatePosition()
	elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
		BR:FindHerbsSpellChanged()
	elseif event == "SPELLCAST_START" then
		if GATHER_SPELLS[arg1] then gatherStarted = GetTime() end
		anyCastStarted = GetTime()
	elseif event == "LOOT_OPENED" then
		if GetTime() - gatherStarted < 8 then
			gatherStarted = 0
			BR:OnHarvest()
		elseif GetTime() - anyCastStarted < 8 then
			anyCastStarted = 0
			BR:OnHarvest(true)
		end
	end
end)
