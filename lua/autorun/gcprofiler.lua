-- measures how much lua garbage each target produces. client only, admins only.
-- point it at hooks, net receivers, timers, metatables, or any table of functions.
--
-- gcprof                    toggle the window
-- gcprof_start / _stop [n]  console only
-- gcprof_save [name]        writes data/gcprof/<name>.json
--
-- table controls: click a header to sort, drag the line between two headers to
-- resize (drag to nothing to collapse), double click a header to reset widths,
-- shift + wheel to scroll sideways. with sections on, click a section bar to fold
-- it, right click one to fold every section at once.
--
-- to profile your own addon, add a line to the source list further down:
--   addTable("myaddon", MyAddon, "MyAddon.", true)
--
-- idle cost is one timer tick four times a second. nothing else of ours runs
-- until you start a recording.

--==============================================================================
-- raw library refs
--
-- grabbed at load, before any source can swap them out. if the profiler called
-- string.lower through the table while the string source was active it'd hit its
-- own wrapper, which calls newEntry, which calls string.lower... stack overflow.
-- these also skip a table lookup per call, which the hot path cares about.
--==============================================================================

if SERVER then return end -- don't let server load it

local cg       = collectgarbage
local getinfo  = debug.getinfo
local lower, format, find, gsub, ssub = string.lower, string.format, string.find, string.gsub, string.sub
local sort     = table.sort
local floor, ceil, min, max, abs, huge = math.floor, math.ceil, math.min, math.max, math.abs, math.huge
local ToJSON, FromJSON = util.TableToJSON, util.JSONToTable
local fWrite, fRead, fFind, fDir, fDel = file.Write, file.Read, file.Find, file.CreateDir, file.Delete
local IsKeyDown = input.IsKeyDown

-- draw.SimpleText looks surface.* up through the table on every call, so it would
-- still route through wrappers. we go straight to the raw functions instead.
local SetDrawColor, DrawRect = surface.SetDrawColor, surface.DrawRect
local SetFont, SetTextColor, SetTextPos, DrawText, GetTextSize =
	surface.SetFont, surface.SetTextColor, surface.SetTextPos, surface.DrawText, surface.GetTextSize
local Scissor = render.SetScissorRect

--==============================================================================
-- state
--
-- nothing in this file is global. the console commands below are the only way in,
-- and they all check IsAdmin first.
--==============================================================================

local stop, refresh -- forward declared, guard and the panels need them early

local entries, sources = {}, {}
local restore  = {}
local active, elapsed, startedAt, drops = false, 0, 0, 0
local child    = 0     -- kb allocated by nested wrapped calls
local memStart, runPeak, livePeak = 0, 0, 0
local inside   = false -- true while we're resolving an entry, see wrapSite
local baseline, frame, list

local UI = { sort = "kb", desc = true, filter = "", minkb = 1, group = false,
	diff = false, live = false, folded = {} }

local cvSoft = CreateClientConVar("gcprof_gc_at", "128", true, false,
	"let the collector work once the heap has grown this many MB past the start")
local cvLimit = CreateClientConVar("gcprof_limit", "1024", true, false,
	"give up and stop recording if growth ever passes this many MB")

--==============================================================================
-- measurement
--==============================================================================

local function newEntry(group, name, src)
	src = src or "?"
	local e = {
		group = group, name = name, src = src,
		find = lower(group .. " " .. name .. " " .. src), -- baked so filtering doesn't allocate
		kb = 0, calls = 0, peak = 0,
	}
	entries[#entries + 1] = e
	return e
end

-- runs after the target returns and passes its results straight through, so we
-- don't care how many values it hands back.
-- over = garbage we made ourselves resolving the entry. it lands inside our
-- caller's window, so it goes on the child pile and gets billed to nobody.
local function post(e, before, outer, over, ...)
	local delta = cg("count") - before
	if delta < 0 then -- a collection landed mid-window, the sample is junk
		drops = drops + 1
		child = outer
		return ...
	end
	local own = delta - child
	e.kb = e.kb + own
	e.calls = e.calls + 1
	if own > e.peak then e.peak = own end
	child = outer + delta + over
	return ...
end

local function wrapInto(e, fn)
	return function(...)
		local before = cg("count")
		local outer = child
		child = 0
		return post(e, before, outer, 0, fn(...))
	end
end

-- one entry for the whole function
local function wrap(group, name, fn)
	local i = getinfo(fn, "S")
	return wrapInto(newEntry(group, name, i and (i.short_src .. ":" .. i.linedefined)), fn)
end

-- one entry per call site. much heavier (getinfo on every call) but it's the only
-- way to find out who keeps calling ent:GetPos() 40k times a frame.
local function wrapSite(group, name, fn)
	local cache = {}
	return function(...)
		-- if we're already inside entry resolution then something we use is itself
		-- wrapped. call through untouched rather than recursing forver.
		if inside then return fn(...) end
		inside = true

		local pre = cg("count")
		local i = getinfo(2, "Sl")
		local f, line = i and i.short_src or "?", i and i.currentline or 0
		local byline = cache[f]
		if not byline then byline = {} cache[f] = byline end
		local e = byline[line]
		if not e then
			e = newEntry(group, name, f .. ":" .. line)
			byline[line] = e
		end
		local before = cg("count")

		local outer = child
		child = 0
		inside = false
		return post(e, before, outer, before - pre, fn(...))
	end
end

local function onStop(fn) restore[#restore + 1] = fn end

-- swaps every function in a table for a measured copy, remembers how to undo it
local function wrapTable(tbl, group, prefix, site, skip)
	prefix = prefix or ""
	for k, fn in pairs(tbl) do
		if isstring(k) and isfunction(fn) and ssub(k, 1, 2) ~= "__" and not (skip and skip[k]) then
			local w = site and wrapSite(group, prefix .. k, fn) or wrap(group, prefix .. k, fn)
			tbl[k] = w
			onStop(function() if tbl[k] == w then tbl[k] = fn end end)
		end
	end
end

--==============================================================================
-- sources -- add your own to the bottom of this section
--==============================================================================

local function addSource(name, desc, attach, on)
	sources[#sources + 1] = { name = name, desc = desc, attach = attach, on = on == true }
end

local function addTable(name, tbl, prefix, site, on)
	if not istable(tbl) then return end
	addSource(name, "table " .. name, function() wrapTable(tbl, name, prefix, site) end, on)
end

local function addMeta(meta, on)
	local m = FindMetaTable(meta)
	if not m then return end
	addSource(meta, meta .. " methods, call-site attributed, heavy", function()
		wrapTable(m, meta, meta .. ":", true)
	end, on)
end

addSource("hooks", "every registered hook", function()
	for event, hlist in pairs(hook.GetTable()) do
		for id, fn in pairs(hlist) do
			if isfunction(fn) and not (isstring(id) and ssub(id, 1, 6) == "gcprof") then
				local w = wrap("hooks", event .. " - " .. tostring(id), fn)
				hook.Add(event, id, w)
				onStop(function()
					-- only put it back if it's still ours, something may have removed it since
					local cur = hook.GetTable()[event]
					if cur and cur[id] == w then hook.Add(event, id, fn) end
				end)
			end
		end
	end
end, true)

addSource("nets", "net.Receive handlers", function()
	wrapTable(net.Receivers, "nets", "", false)
	local recv = net.Receive
	net.Receive = function(name, fn) -- catch ones registered after we started
		if isfunction(fn) then fn = wrap("nets", lower(name), fn) end
		return recv(name, fn)
	end
	onStop(function() net.Receive = recv end)
end, true)

addSource("concommands", "console commands", function()
	wrapTable(concommand.GetTable(), "concommands", "", false)
end, true)

-- timers get caught as they're created, so anything already running is missed
addSource("timers", "timers created while recording", function()
	local create, simple, cache = timer.Create, timer.Simple, {}
	local function grab(name)
		local e = cache[name]
		if not e then e = newEntry("timers", name, name) cache[name] = e end
		return e
	end
	timer.Create = function(id, delay, reps, fn, ...)
		if isfunction(fn) then fn = wrapInto(grab("Create - " .. tostring(id)), fn) end
		return create(id, delay, reps, fn, ...)
	end
	timer.Simple = function(delay, fn, ...)
		if isfunction(fn) then
			local i = getinfo(2, "Sl")
			fn = wrapInto(grab("Simple @ " .. (i and (i.short_src .. ":" .. i.currentline) or "?")), fn)
		end
		return simple(delay, fn, ...)
	end
	onStop(function() timer.Create, timer.Simple = create, simple end)
end, true)

for _, lib in ipairs({ "util", "string", "table", "math", "draw", "surface", "render", "ents", "input", "sound", "net" }) do
	addTable(lib, _G[lib], lib .. ".", true, false)
end

for _, m in ipairs({ "Entity", "Player", "Weapon", "Vehicle", "NPC", "Vector", "Angle", "Panel", "CUserCmd", "IMaterial", "ConVar" }) do
	addMeta(m, false)
end

--==============================================================================
-- run control
--
-- the collector stays off during the frame so nothing can free memory in the
-- middle of a measurement window. this Think hook is the one place we know no
-- wrapper is mid-flight, so that's where the collector gets to catch up.
--==============================================================================

local function guard()
	child = 0 -- an errored target leaves this stale, don't let it poison the next frame

	local mem = cg("count")
	if mem > runPeak then runPeak = mem end

	local grow = mem - memStart
	if grow > cvSoft:GetFloat() * 1024 then
		for _ = 1, 8 do -- bounded so we spread the work instead of stalling a frame
			if cg("step", 512) then break end
		end
		cg("stop") -- "step" moves the threshold, put it back out of reach
		grow = cg("count") - memStart
	end

	if grow > cvLimit:GetFloat() * 1024 then
		stop()
		notification.AddLegacy("[gcprof] heap limit hit, recording stopped", NOTIFY_ERROR, 6)
	end
end

local function reset()
	for i = #entries, 1, -1 do entries[i] = nil end
	child, elapsed, drops, runPeak = 0, 0, 0, 0
end

local function start()
	if active then return end
	reset()
	for _, s in ipairs(sources) do
		if s.on then
			local ok, err = pcall(s.attach)
			if not ok then ErrorNoHalt("[gcprof] source '" .. s.name .. "' failed: " .. tostring(err) .. "\n") end
		end
	end
	active, startedAt = true, SysTime()
	cg("collect")
	memStart = cg("count")
	runPeak = memStart
	cg("stop")
	hook.Add("Think", "gcprof_guard", guard)
	MsgC(Color(150, 255, 150), "[gcprof] recording " .. #entries .. " targets\n")
end

function stop()
	if not active then return end
	active = false
	elapsed = SysTime() - startedAt
	hook.Remove("Think", "gcprof_guard")
	for i = #restore, 1, -1 do
		local ok, err = pcall(restore[i])
		if not ok then ErrorNoHalt("[gcprof] restore failed: " .. tostring(err) .. "\n") end
		restore[i] = nil
	end
	inside = false
	cg("restart")
	cg("collect")
end

local function duration()
	return active and SysTime() - startedAt or elapsed
end

-- always-on high water mark for normal play.
-- a Think hook would run this a few hundred times a second for a number nobody
-- reads more than four times a second, so it's a timer instead. two ops a tick.
-- it sits out while recording: the guard already samples every frame then, and a
-- deferred collector would make this number meaningless anyway.
timer.Create("gcprof_peak", 0.25, 0, function()
	if active then return end
	local mem = cg("count")
	if mem > livePeak then livePeak = mem end
end)

--==============================================================================
-- saved runs
--==============================================================================

local DIR = "gcprof"

local function unkey(k)
	local a = find(k, "\1", 1, true)
	local b = find(k, "\1", a + 1, true)
	return ssub(k, 1, a - 1), ssub(k, a + 1, b - 1), ssub(k, b + 1)
end

local function saveRun(name)
	name = gsub(name or os.date("%d-%m-%y_%H-%M"), "[^%w%-_]", "_")
	fDir(DIR)
	local out = { name = name, time = os.time(), dur = duration(), list = {} }
	for _, e in ipairs(entries) do
		if e.calls > 0 then
			out.list[#out.list + 1] = {
				e.group, e.name, e.src,
				floor(e.kb * 100 + 0.5) / 100, e.calls, floor(e.peak * 100 + 0.5) / 100,
			}
		end
	end
	fWrite(DIR .. "/" .. name .. ".json", ToJSON(out))
	return name
end

local function listRuns()
	local out = {}
	for _, n in ipairs(fFind(DIR .. "/*.json", "DATA") or {}) do
		if n ~= "ui.json" then out[#out + 1] = n end
	end
	return out
end

local function setBaseline(fname)
	baseline = nil
	if not fname then return end
	local raw = fRead(DIR .. "/" .. fname, "DATA")
	local run = raw and FromJSON(raw)
	if not run or not run.list then return end
	local map = {}
	for _, r in ipairs(run.list) do
		map[r[1] .. "\1" .. r[2] .. "\1" .. r[3]] = { kb = r[4], calls = r[5], peak = r[6] or 0 }
	end
	baseline = { name = run.name or fname, file = fname, dur = run.dur or 0, map = map }
end

local function deleteRun(fname)
	fDel(DIR .. "/" .. fname)
	if baseline and baseline.file == fname then baseline = nil end
end

--==============================================================================
-- view building -- opts: filter, minkb, group, folded, sort, desc, diff
--
-- rate and b/call and peak don't care how long a run lasted, which is what makes
-- two runs comparable at all. diff mode swaps every number for its change since
-- the baseline rather than scaling anything.
--==============================================================================

local function view(o)
	o = o or {}
	local f = lower(o.filter or "")
	local minkb = o.minkb or -huge
	local diff = (o.diff and baseline) and true or false
	local dur, bdur = duration(), baseline and baseline.dur or 0

	local out, seen = {}, diff and {} or nil
	for _, e in ipairs(entries) do
		if e.calls > 0 and (f == "" or find(e.find, f, 1, true)) then
			local kb, calls, peak = e.kb, e.calls, e.peak
			local rate = dur > 0 and kb / dur or 0
			local per = kb * 1024 / calls

			if diff then
				local k = e.key
				if not k then -- only ever built if you actually compare
					k = e.group .. "\1" .. e.name .. "\1" .. e.src
					e.key = k
				end
				seen[k] = true
				local b = baseline.map[k]
				if b then
					kb, calls, peak = kb - b.kb, calls - b.calls, peak - b.peak
					rate = rate - (bdur > 0 and b.kb / bdur or 0)
					per = per - (b.calls > 0 and b.kb * 1024 / b.calls or 0)
				end
			end

			if (diff and abs(kb) or kb) >= minkb then
				out[#out + 1] = { group = e.group, name = e.name, src = e.src, diff = diff,
					kb = kb, calls = calls, peak = peak, rate = rate, per = per }
			end
		end
	end

	-- things the baseline had that this run doesn't. all negative, so they read as
	-- "this stopped allocating", which is usually the point of comparing at all.
	if diff then
		for k, b in pairs(baseline.map) do
			if not seen[k] and b.kb >= minkb then
				local g, n, s = unkey(k)
				if f == "" or find(lower(g .. " " .. n .. " " .. s), f, 1, true) then
					out[#out + 1] = { group = g, name = n, src = s, diff = true, gone = true,
						kb = -b.kb, calls = -b.calls, peak = -b.peak,
						rate = -(bdur > 0 and b.kb / bdur or 0),
						per = -(b.calls > 0 and b.kb * 1024 / b.calls or 0) }
				end
			end
		end
	end

	local field, desc = o.sort or "kb", o.desc ~= false
	sort(out, function(a, b)
		if o.group and a.group ~= b.group then return a.group < b.group end
		local x, y = a[field], b[field]
		if x == nil then x = -huge end
		if y == nil then y = -huge end
		if desc then return x > y end
		return x < y
	end)

	if not o.group then return out end

	-- subtotals are summed over every row in the section, folded or not
	local folded = o.folded or {}
	local rows, cur, head, hit = {}, nil, nil, {}
	for _, r in ipairs(out) do
		if r.group ~= cur then
			cur = r.group
			hit[cur] = true
			head = { header = true, group = cur, kb = 0, calls = 0, n = 0, fold = folded[cur] }
			rows[#rows + 1] = head
		end
		head.kb, head.calls, head.n = head.kb + r.kb, head.calls + r.calls, head.n + 1
		if not head.fold then rows[#rows + 1] = r end
	end

	-- a source that was recording but never fired still gets a line, otherwise it
	-- looks like you forgot to tick it
	for _, s in ipairs(sources) do
		if s.on and not hit[s.name] then
			rows[#rows + 1] = { header = true, group = s.name, kb = 0, calls = 0, n = 0, empty = true }
		end
	end
	return rows
end

--==============================================================================
-- ui: shared bits
--==============================================================================

surface.CreateFont("gcprof_row", { font = "Consolas", size = 14, weight = 400 })
surface.CreateFont("gcprof_head", { font = "Consolas", size = 14, weight = 700 })

local C_BG   = Color(18, 18, 22)
local C_ALT  = Color(26, 26, 32)
local C_SEL  = Color(44, 62, 88)
local C_SEC  = Color(38, 42, 54)
local C_TXT  = Color(225, 225, 230)
local C_DIM  = Color(140, 140, 152)
local C_UP   = Color(235, 110, 110)
local C_DOWN = Color(120, 220, 140)
local C_ON   = Color(255, 190, 90)

local ROW  = 18
local VBAR = 14 -- width the vertical scrollbar takes off the list
local CHW  = 0  -- width of one character, filled in on first paint
local hoff = 0  -- horizontal scroll in pixels

-- order has to match row.c built in SetRows
local COLS = {
	{ id = "group", label = "Group",  w = 85,  clip = true, dim = true },
	{ id = "name",  label = "Target", w = 240, clip = true },
	{ id = "src",   label = "Source", w = 210, clip = true, tail = true, dim = true },
	{ id = "kb",    label = "Total",  w = 85,  right = true },
	{ id = "rate",  label = "Rate",   w = 90,  right = true },
	{ id = "calls", label = "Calls",  w = 65,  right = true, dim = true },
	{ id = "per",   label = "B/call", w = 75,  right = true },
	{ id = "peak",  label = "Peak",   w = 75,  right = true, dim = true },
}
for _, c in ipairs(COLS) do c.dw = c.w end

local function fmtKB(kb)
	if kb >= 1024 or kb <= -1024 then return format("%.2f MB", kb / 1024) end
	return format("%.1f KB", kb)
end

local function fmtB(b)
	if b >= 1048576 or b <= -1048576 then return format("%.1f MB", b / 1048576) end
	if b >= 1024 or b <= -1024 then return format("%.1f KB", b / 1024) end
	return format("%.0f B", b)
end

-- ours rather than string.Comma, which goes through the string table
local function comma(n)
	local s, k = format("%d", n), 0
	repeat s, k = gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

local function signed(s, v) return v >= 0 and "+" .. s or s end

local function dcol(v)
	if v > 0 then return C_UP end
	if v < 0 then return C_DOWN end
	return C_DIM
end

local function text(s, x, y, col)
	SetTextColor(col) SetTextPos(x, y) DrawText(s)
end

-- column x positions, independent of scroll. rebuilt only when a width changes.
local cols
local function layout()
	if cols then return cols end
	local x = 4
	cols = {}
	for i, c in ipairs(COLS) do
		cols[i] = x
		x = x + c.w
	end
	cols.total = x + 4
	return cols
end

local function relayout() cols = nil end

local function clampH(vw)
	hoff = min(max(hoff, 0), max(0, layout().total - vw))
end

--==============================================================================
-- ui: remembered layout -- window rect and column widths
--==============================================================================

local UIFILE = DIR .. "/ui.json"

local function saveUI()
	local w = {}
	for i, c in ipairs(COLS) do w[i] = c.w end
	fDir(DIR)
	fWrite(UIFILE, ToJSON({ rect = UI.rect, maxed = UI.maxed, cols = w }))
end

do -- scoped so the raw json doesn't sit in an upvalue for the rest of the session
	local raw = fRead(UIFILE, "DATA")
	local saved = raw and FromJSON(raw)
	if saved then
		UI.rect, UI.maxed = saved.rect, saved.maxed
		if saved.cols then
			for i, v in ipairs(saved.cols) do if COLS[i] then COLS[i].w = v end end
			relayout()
		end
	end
end

-- drag anything: calls onDrag(dx, dy) while the mouse is held
local function dragger(pnl, onDrag)
	pnl:SetMouseInputEnabled(true)
	pnl.OnMousePressed = function(s) s.mx, s.my = gui.MouseX(), gui.MouseY() s:MouseCapture(true) end
	pnl.OnMouseReleased = function(s) s.mx = nil s:MouseCapture(false) end
	pnl.Think = function(s)
		if not s.mx then return end
		local x, y = gui.MouseX(), gui.MouseY()
		if x ~= s.mx or y ~= s.my then
			onDrag(x - s.mx, y - s.my)
			s.mx, s.my = x, y
		end
	end
end

--==============================================================================
-- ui: the table
--==============================================================================

local LIST = {}

function LIST:Init()
	self.rows = {}
	self:SetMouseInputEnabled(true)
	self.bar = vgui.Create("DVScrollBar", self)
	self.bar:SetHideButtons(true)
end

-- every display string is baked here so Paint never allocates
function LIST:SetRows(rows)
	for _, r in ipairs(rows) do
		if r.header then
			if r.empty then
				r.txt = "  " .. r.group .. "     nothing recorded"
			else
				r.txt = (r.fold and "+ " or "- ") .. r.group .. "     " .. fmtKB(r.kb)
					.. "     " .. comma(r.calls) .. " calls     " .. comma(r.n) .. " rows"
			end
		else
			local kb, rate = fmtKB(r.kb), fmtKB(r.rate) .. "/s"
			local calls, per, peak = comma(r.calls), fmtB(r.per), fmtB(r.peak * 1024)
			if r.diff then
				kb, rate = signed(kb, r.kb), signed(rate, r.rate)
				calls, per, peak = signed(calls, r.calls), signed(per, r.per), signed(peak, r.peak)
				r.cc = { [4] = dcol(r.kb), [5] = dcol(r.rate), [6] = dcol(r.calls),
					[7] = dcol(r.per), [8] = dcol(r.peak) }
			else
				r.cc = nil
			end
			r.c = { r.group, r.gone and "(gone) " .. r.name or r.name, r.src, kb, rate, calls, per, peak }
		end
	end
	self.rows, self.sel = rows, nil
	self:InvalidateLayout()
end

function LIST:PerformLayout(w, h)
	self.bar:SetPos(w - VBAR, 0)
	self.bar:SetSize(VBAR, h)
	self.bar:SetUp(h, #self.rows * ROW)
end

function LIST:OnMouseWheeled(d)
	if IsKeyDown(KEY_LSHIFT) or IsKeyDown(KEY_RSHIFT) then
		hoff = hoff - d * 40
		clampH(self:GetWide() - VBAR)
	else
		self.bar:OnMouseWheeled(d)
	end
	return true
end

function LIST:OnMousePressed(code)
	local _, my = self:CursorPos()
	local r = self.rows[floor((my + self.bar:GetScroll()) / ROW) + 1]
	if not r then return end

	if r.header then
		if r.empty then return end
		if code == MOUSE_RIGHT then
			-- fold the lot, or open them all again if any are still open
			local anyOpen = false
			for _, row in ipairs(self.rows) do
				if row.header and not row.empty and not row.fold then anyOpen = true break end
			end
			for _, row in ipairs(self.rows) do
				if row.header and not row.empty then UI.folded[row.group] = anyOpen or nil end
			end
		else
			UI.folded[r.group] = not UI.folded[r.group] or nil
		end
		refresh()
		return
	end

	self.sel = r
	if code == MOUSE_RIGHT then SetClipboardText(r.name .. "  " .. r.src) end
end

function LIST:Paint(w, h)
	local vw = w - VBAR
	SetDrawColor(C_BG)
	DrawRect(0, 0, w, h)

	SetFont("gcprof_row")
	if CHW == 0 then CHW = GetTextSize("0") end

	clampH(vw)
	local L = layout()
	local scroll = self.bar:GetScroll()
	local top = scroll % ROW
	local first = floor(scroll / ROW)
	local nvis = ceil(h / ROW)
	local sx, sy = self:LocalToScreen(0, 0)

	-- row backgrounds
	for i = 0, nvis do
		local r = self.rows[first + i + 1]
		if not r then break end
		local y = i * ROW - top
		if r.header then
			SetDrawColor(C_SEC) DrawRect(0, y, vw, ROW)
		elseif r == self.sel then
			SetDrawColor(C_SEL) DrawRect(0, y, vw, ROW)
		elseif (first + i + 1) % 2 == 0 then
			SetDrawColor(C_ALT) DrawRect(0, y, vw, ROW)
		end
	end

	-- section titles span everything, so they get their own pass
	Scissor(sx, sy, sx + vw, sy + h, true)
	SetFont("gcprof_head")
	for i = 0, nvis do
		local r = self.rows[first + i + 1]
		if not r then break end
		if r.header then text(r.txt, 6, i * ROW - top + 2, r.empty and C_DIM or C_TXT) end
	end
	Scissor(0, 0, 0, 0, false)

	-- one pass per column so the scissor gets set eight times a frame rather than
	-- once per cell, and nothing can spill into its neighbour
	SetFont("gcprof_row")
	for ci, c in ipairs(COLS) do
		local cx, cw = L[ci] - hoff, c.w
		if cw >= 4 and cx < vw and cx + cw > 0 then
			local l, r2 = max(sx + cx, sx), min(sx + cx + cw - 5, sx + vw)
			if r2 > l then
				Scissor(l, sy, r2, sy + h, true)
				for i = 0, nvis do
					local row = self.rows[first + i + 1]
					if not row then break end
					if not row.header then
						local s = row.c[ci]
						local y = i * ROW - top + 2
						local col = (row.cc and row.cc[ci]) or (c.dim and C_DIM or C_TXT)
						if c.right then
							text(s, cx + cw - 8 - GetTextSize(s), y, col)
						elseif c.tail then
							-- monospace, so #s is close enough to shift long paths left
							local over = #s * CHW - (cw - 8)
							text(s, over > 0 and cx - over or cx, y, col)
						else
							text(s, cx, y, col)
						end
					end
				end
				Scissor(0, 0, 0, 0, false)
			end
		end
	end
end

vgui.Register("GCProfList", LIST, "DPanel")

--==============================================================================
-- ui: column headers -- click to sort, drag an edge to resize, double click to reset
--==============================================================================

local HEAD = {}

function HEAD:Init() self:SetMouseInputEnabled(true) end

function HEAD:EdgeAt(x)
	local L = layout()
	x = x + hoff
	for i, c in ipairs(COLS) do
		if abs(x - (L[i] + c.w)) <= 4 then return i end
	end
end

function HEAD:OnCursorMoved(x)
	self:SetCursor(self:EdgeAt(x) and "sizewe" or "arrow")
end

function HEAD:OnMousePressed()
	local x = self:CursorPos()

	local edge = self:EdgeAt(x)
	if edge then
		self.rz, self.mx = edge, gui.MouseX()
		self:MouseCapture(true)
		return
	end

	local L = layout()
	x = x + hoff
	for i, c in ipairs(COLS) do
		if x >= L[i] and x < L[i] + c.w then
			if UI.sort == c.id then UI.desc = not UI.desc else UI.sort, UI.desc = c.id, true end
			refresh()
			return
		end
	end
end

function HEAD:Think()
	if not self.rz then return end
	local mx = gui.MouseX()
	if mx == self.mx then return end
	COLS[self.rz].w = max(0, COLS[self.rz].w + mx - self.mx) -- drag to nothing to collapse
	self.mx = mx
	relayout()
end

function HEAD:OnMouseReleased()
	self.rz = nil
	self:MouseCapture(false)
end

function HEAD:DoDoubleClick()
	for _, c in ipairs(COLS) do c.w = c.dw end
	hoff = 0
	relayout()
end

function HEAD:Paint(w, h)
	SetDrawColor(34, 34, 42)
	DrawRect(0, 0, w, h)

	SetFont("gcprof_head")
	local L = layout()
	local y = h * 0.5 - 8
	local sx, sy = self:LocalToScreen(0, 0)

	for i, c in ipairs(COLS) do
		local cx = L[i] - hoff
		if c.w >= 4 and cx < w and cx + c.w > 0 then
			local l, r2 = max(sx + cx, sx), min(sx + cx + c.w - 5, sx + w)
			if r2 > l then
				local s = c.disp or c.label
				Scissor(l, sy, r2, sy + h, true)
				text(s, c.right and cx + c.w - 8 - GetTextSize(s) or cx, y, C_TXT)
				Scissor(0, 0, 0, 0, false)
			end
			SetDrawColor(C_SEC)
			DrawRect(cx + c.w - 1, 3, 1, h - 6)
		end
	end
end

vgui.Register("GCProfHead", HEAD, "DPanel")

--==============================================================================
-- ui: horizontal scrollbar
--==============================================================================

local HBAR = {}

function HBAR:Init() self:SetMouseInputEnabled(true) end

function HBAR:Thumb(w)
	local total = layout().total
	if total <= w then return end
	local tw = max(30, w * w / total)
	return tw, (w - tw) * (hoff / (total - w))
end

function HBAR:Paint(w, h)
	local tw, tx = self:Thumb(w)
	if not tw then return end
	SetDrawColor(C_BG) DrawRect(0, 0, w, h)
	SetDrawColor(C_DIM) DrawRect(tx, 2, tw, h - 4)
end

function HBAR:OnMousePressed()
	local w = self:GetWide()
	local tw, tx = self:Thumb(w)
	if not tw then return end
	local x = self:CursorPos()
	self.grab = (x >= tx and x <= tx + tw) and x - tx or tw * 0.5
	self:MouseCapture(true)
end

function HBAR:Think()
	if not self.grab then return end
	local w = self:GetWide()
	local tw = self:Thumb(w)
	if not tw then return end
	local span = w - tw
	if span > 0 then
		hoff = (self:CursorPos() - self.grab) / span * (layout().total - w)
		clampH(w)
	end
end

function HBAR:OnMouseReleased()
	self.grab = nil
	self:MouseCapture(false)
end

vgui.Register("GCProfHBar", HBAR, "DPanel")

--==============================================================================
-- ui: frame
--==============================================================================

function refresh()
	for _, c in ipairs(COLS) do
		c.disp = c.label .. (UI.sort == c.id and (UI.desc and " v" or " ^") or "")
	end
	if IsValid(list) then list:SetRows(view(UI)) end
end

local function styleBtn(b)
	b:SetTextColor(C_TXT)
	b.Paint = function(s, w, h)
		local v = s:IsHovered() and 58 or 42
		SetDrawColor(v, v + 3, v + 12)
		DrawRect(0, 0, w, h)
	end
	return b
end

local function openUI()
	if IsValid(frame) then frame:MakePopup() return end

	local f = vgui.Create("DFrame")
	frame = f
	f:SetTitle("")
	f:SetSizable(true)
	f:SetMinWidth(760)
	f:SetMinHeight(340)
	-- bottom padding keeps docked children clear of DFrame's own resize corner
	f:DockPadding(6, 28, 6, 20)

	local r = UI.rect
	if r then -- clamped, the screen may not be the size it was last time
		f:SetSize(max(760, min(r[3], ScrW())), max(340, min(r[4], ScrH())))
		f:SetPos(min(max(r[1], 0), ScrW() - 120), min(max(r[2], 0), ScrH() - 40))
	else
		f:SetSize(min(1180, ScrW() - 60), min(720, ScrH() - 60))
		f:Center()
	end
	f:MakePopup()

	f.Paint = function(s, w, h)
		SetDrawColor(14, 14, 18) DrawRect(0, 0, w, h)
		SetDrawColor(30, 30, 38) DrawRect(0, 0, w, 24)
		SetFont("gcprof_head")
		text("GC Profiler", 8, 5, C_TXT)
		SetDrawColor(C_DIM) -- resize corner
		for i = 0, 2 do DrawRect(w - 6 - i * 4, h - 14 + i * 4, 3, 3) end
	end

	-- f.rest holds the pre-maximise rect, and doubles as the "are we maximised" flag
	local function maximise()
		local x, y = f:GetPos()
		f.rest = { x, y, f:GetWide(), f:GetTall() }
		f:SetPos(0, 0)
		f:SetSize(ScrW(), ScrH())
	end

	local function unmaximise()
		f:SetPos(f.rest[1], f.rest[2])
		f:SetSize(f.rest[3], f.rest[4])
		f.rest = nil
	end

	f.OnRemove = function()
		-- remember the normal size, not the maximised one, plus whether we were maximised
		local rect = f.rest
		if not rect then
			local x, y = f:GetPos()
			rect = { x, y, f:GetWide(), f:GetTall() }
		end
		UI.rect, UI.maxed = rect, f.rest ~= nil
		saveUI()
		frame, list = nil, nil
	end

	-- DFrame ships minimise and maximise as disabled stubs with empty DoClick
	if IsValid(f.btnMinim) then f.btnMinim:SetVisible(false) end
	if IsValid(f.btnMaxim) then
		f.btnMaxim:SetDisabled(false)
		f.btnMaxim.DoClick = function()
			if f.rest then unmaximise() else maximise() end
		end
	end

	-- our title bar is painted, not a real child, so give it a strip to grab
	local title = vgui.Create("DPanel", f)
	title:SetPos(0, 0)
	title:SetSize(f:GetWide() - 70, 24) -- stop short of maximise and close
	title.Paint = function() end
	dragger(title, function(dx, dy)
		if f.rest then return end -- don't drag a maximised window off screen
		local x, y = f:GetPos()
		f:SetPos(x + dx, y + dy)
	end)
	f.OnSizeChanged = function(s, w) title:SetSize(w - 70, 24) end
	title:SetZPos(50)

	-- left side: what to record
	local side = vgui.Create("DPanel", f)
	side:Dock(LEFT) side:SetWide(210) side:DockMargin(0, 0, 6, 0)
	side.Paint = function(s, w, h) SetDrawColor(24, 24, 30) DrawRect(0, 0, w, h) end

	local run = styleBtn(vgui.Create("DButton", side))
	run:Dock(TOP) run:SetTall(32) run:DockMargin(6, 6, 6, 6) run:SetText("start")
	run.Think = function(s) -- only touch the label when it actually changed
		local want = active and "stop" or "start"
		if s.cur ~= want then s.cur = want s:SetText(want) end
	end
	run.DoClick = function()
		if active then stop() else start() end
		refresh()
	end

	local stat = vgui.Create("DPanel", side)
	stat:Dock(BOTTOM) stat:SetTall(92) stat:DockMargin(6, 0, 6, 6)
	stat:SetTooltip("peak is the highest lua memory seen during normal play. while recording it switches to the peak for the run, since the collector is deferred then")
	stat.lines = {}
	stat.Think = function(s)
		-- the live rebuild lives here, not on the frame. DFrame:Think is what drives
		-- dragging and resizing, so overriding it breaks both.
		local t = RealTime()
		if UI.live and active and (s.rx or 0) < t then
			s.rx = t + 0.5
			refresh()
		end
		if (s.nx or 0) > t then return end
		s.nx = t + 0.25
		s.lines = {
			active and "recording" or "idle",
			#entries .. " targets" .. (drops > 0 and ", " .. drops .. " dropped" or ""),
			format("%.1fs", duration()),
			format("mem %.0f MB", cg("count") / 1024),
			active and format("run peak %.0f MB", runPeak / 1024)
				or format("peak %.0f MB", livePeak / 1024),
			baseline and format("base: %s (%.0fs)", baseline.name, baseline.dur) or "no baseline",
		}
	end
	stat.Paint = function(s, w, h)
		SetDrawColor(20, 20, 26) DrawRect(0, 0, w, h)
		SetFont("gcprof_row")
		for i, l in ipairs(s.lines) do
			text(l, 6, 3 + (i - 1) * 15, i == 1 and (active and C_ON or C_DIM) or C_DIM)
		end
	end

	local srcs = vgui.Create("DScrollPanel", side)
	srcs:Dock(FILL) srcs:DockMargin(6, 0, 6, 6)
	for _, s in ipairs(sources) do
		local cb = srcs:Add("DCheckBoxLabel")
		cb:Dock(TOP) cb:DockMargin(0, 0, 0, 4)
		cb:SetText(s.name)
		cb:SetTextColor(C_TXT)
		cb:SetChecked(s.on)
		cb:SetTooltip(s.desc)
		cb.OnChange = function(_, v) s.on = v end
	end

	-- right side
	local main = vgui.Create("DPanel", f)
	main:Dock(FILL)
	main.Paint = function() end

	local bar = vgui.Create("DPanel", main)
	bar:Dock(TOP) bar:SetTall(28) bar:DockMargin(0, 0, 0, 4)
	bar.Paint = function(s, w, h) SetDrawColor(24, 24, 30) DrawRect(0, 0, w, h) end

	local filter = vgui.Create("DTextEntry", bar)
	filter:Dock(LEFT) filter:SetWide(210) filter:DockMargin(4, 3, 8, 3)
	filter:SetPlaceholderText("filter by target, group or file")
	filter:SetValue(UI.filter)
	filter.OnChange = function(s) UI.filter = s:GetValue() refresh() end

	local function tick(txt, field, tip)
		local cb = vgui.Create("DCheckBoxLabel", bar)
		cb:Dock(LEFT) cb:DockMargin(0, 6, 10, 6)
		cb:SetText(txt) cb:SetTextColor(C_TXT) cb:SetTooltip(tip)
		cb:SetChecked(field == "minkb" and UI.minkb > 0 or UI[field] == true)
		cb:SizeToContents()
		cb.OnChange = function(_, v)
			if field == "minkb" then UI.minkb = v and 1 or -huge else UI[field] = v end
			refresh()
		end
	end
	tick("sections", "group", "one section per recording source. click a section bar to fold it, right click to fold every section")
	tick("hide <1KB", "minkb", "hide anything that moved less than 1 KB")
	tick("diff", "diff", "show the change from the loaded baseline in every column instead of this run's own numbers. needs a baseline")
	tick("live", "live", "rebuild the table twice a second while recording")

	-- docked RIGHT stacks right to left, so this order puts base, del, save
	local save = styleBtn(vgui.Create("DButton", bar))
	save:Dock(RIGHT) save:SetWide(80) save:DockMargin(6, 3, 4, 3) save:SetText("save run")

	local del = styleBtn(vgui.Create("DButton", bar))
	del:Dock(RIGHT) del:SetWide(60) del:DockMargin(4, 3, 0, 3) del:SetText("delete")

	local base = vgui.Create("DComboBox", bar)
	base:Dock(RIGHT) base:SetWide(190) base:DockMargin(4, 3, 0, 3)
	base:SetValue("compare with...")

	local function fillRuns()
		base:Clear()
		base:AddChoice("(none)")
		for _, name in ipairs(listRuns()) do base:AddChoice(name) end
	end
	fillRuns()

	base.OnSelect = function(_, _, v)
		setBaseline(v ~= "(none)" and v or nil)
		refresh()
	end

	save.DoClick = function()
		Derma_StringRequest("save run", "name for this run", os.date("%d-%m_%H-%M"), function(n)
			local name = saveRun(n)
			fillRuns()
			notification.AddLegacy("saved " .. name .. ".json", NOTIFY_GENERIC, 4)
		end)
	end

	del.DoClick = function()
		local sel = base:GetValue()
		if not sel or sel == "(none)" or sel == "compare with..." then
			notification.AddLegacy("pick a run first", NOTIFY_ERROR, 3)
			return
		end
		Derma_Query("delete " .. sel .. " ?", "gcprof", "delete", function()
			deleteRun(sel)
			base:SetValue("compare with...")
			fillRuns()
			refresh()
		end, "cancel", function() end)
	end

	-- head and hbar sit inside the list's usable width, ie minus its scrollbar
	local head = vgui.Create("GCProfHead", main)
	head:Dock(TOP) head:SetTall(20) head:DockMargin(0, 0, VBAR, 0)

	local hbar = vgui.Create("GCProfHBar", main)
	hbar:Dock(BOTTOM) hbar:SetTall(12) hbar:DockMargin(0, 2, VBAR, 0)

	list = vgui.Create("GCProfList", main)
	list:Dock(FILL)

	if UI.maxed then maximise() end
	refresh()
end

--==============================================================================
-- console commands -- the only entry points, all gated
--
-- worth being clear eyed about this: the profiler runs entirely in the player's
-- own lua state and only ever touches their own client. the gate keeps the tool
-- out of normal players' hands, it is not a security boundary, and nothing here
-- gives anyone a capability they didn't already have.
--==============================================================================

local function allowed()
	local ply = LocalPlayer()
	if IsValid(ply) and ply:IsAdmin() then return true end
	MsgC(C_UP, "[gcprof] admins only\n")
	return false
end

concommand.Add("gcprof", function()
	if not allowed() then return end
	if IsValid(frame) then frame:Remove() else openUI() end
end)

concommand.Add("gcprof_start", function()
	if not allowed() then return end
	start()
end)

concommand.Add("gcprof_save", function(_, _, args)
	if not allowed() then return end
	print("[gcprof] saved " .. saveRun(args[1]))
end)

concommand.Add("gcprof_stop", function(_, _, args)
	if not allowed() then return end
	stop()
	local rows = view({ sort = "kb", desc = true, minkb = 1 })
	MsgC(C_TXT, "\n=========== LUA ALLOCATION ===========\n")
	for i = 1, min(#rows, tonumber(args[1]) or 30) do
		local r = rows[i]
		MsgC(C_UP, format("#%02d ", i),
			C_TXT, format("%8.2f MB ", r.kb / 1024),
			C_DOWN, format("(%7.1f B/call x%d) ", r.per, r.calls),
			C_DIM, r.group .. "  " .. r.name .. "  " .. r.src .. "\n")
	end
	if drops > 0 then MsgC(C_UP, drops .. " samples dropped to collections\n") end
	MsgC(C_TXT, format("run peak %.0f MB, idle peak %.0f MB\n", runPeak / 1024, livePeak / 1024))
	MsgC(C_TXT, "======================================\n\n")
end)
