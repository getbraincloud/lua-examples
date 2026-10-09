-- The match: 800x600 normalized board shared with every other CursorParty client.

local ui = require("ui")
local state = require("state")
local app = require("app")
local Coverage = require("coverage")

local screen = {}

local GAME_W, GAME_H = 800, 600
local MATCH_DURATION = tonumber(os.getenv("BC_MATCH_SECONDS") or "") or 90 -- BC_MATCH_SECONDS shortens rounds for test runs
local MOVE_INTERVAL = 1 / 60
local PING_INTERVAL = 2.0
local AUTO_PAINT_INTERVAL = 0.15
local COVERAGE_INTERVAL = 0.25
local RESULT_GRACE = 3.0
local CHUNK_MAX_BYTES = 900
local SPLOTCH_SIZE = 64
local SHOCKWAVE_RADIUS = 64
local SHOCKWAVE_LIFE = 1.0
local FADE_SECS = 3.0

local splatImage
local cursors, splotches, shockwaves = {}, {}, {}
local cxToNet, netToCx = {}, {}
local pings = {} -- cxId → ms
local timers = {}
local phase = "running"
local resultsSentAt = 0
local roundNumber = 0
local pendingResult = {}
local scoreboard = {}
local hud = { reliable = false, ordered = true, channel = 1 }
local board = { x = 0, y = 0, s = 1 }

local function relay()
	return state.bc.relay
end

local function json()
	return state.bc.json
end

local function elapsedSec()
	if state.gameStartTimeMs <= 0 then
		return 0
	end
	return (state.nowMs() - state.gameStartTimeMs) / 1000
end

-- SENDING

local function sendAll(msg, reliable, ordered, channel)
	relay():sendToAll(json().encode(msg), reliable, ordered, channel)
end

-- SPLOTCHES

local function addSplotch(nx, ny, colorIndex, angle, createdMs, cx)
	splotches[#splotches + 1] = { x = nx, y = ny, c = colorIndex, a = angle, t = createdMs, cx = cx }
end

local function shockwave(nx, ny, colorIndex, broadcast, angle, cx)
	angle = angle or love.math.random() * math.pi * 2
	shockwaves[#shockwaves + 1] = { x = nx, y = ny, c = colorIndex, start = love.timer.getTime() }
	addSplotch(nx, ny, colorIndex, angle, state.nowMs(), cx)
	if broadcast then
		-- everyone but us, reliable/unordered on the picked channel (C++: no per-player mask —
		-- unchecking a peer would desync their canvas and score)
		sendAll({ op = "shockwave", data = { x = nx, y = ny, angle = angle } }, true, false, hud.channel - 1)
	end
end

local function clearSplotches()
	splotches = {}
end

-- Host → join-in-progress member: replay the canvas, chunked under the 1024-byte relay limit.
-- Sized per entry (not by re-encoding the batch) so a full canvas stays cheap.
local SYNC_OVERHEAD = #'{"data":{"first":false,"splotches":[]},"op":"splotch_sync"}'
local function sendSplotchSync(netId)
	local first, i, n = true, 1, #splotches
	repeat
		local parts, size = {}, SYNC_OVERHEAD
		while i <= n do
			local s = splotches[i]
			local entry = json().encode({ x = s.x, y = s.y, c = s.c, a = s.a, t = s.t, o = s.cx and cxToNet[s.cx] or nil })
			if #parts > 0 and size + #entry + 1 > CHUNK_MAX_BYTES then
				break
			end
			parts[#parts + 1] = entry
			size = size + #entry + 1
			i = i + 1
		end
		local packet = '{"data":{"first":' .. tostring(first) .. ',"splotches":[' .. table.concat(parts, ",") .. ']},"op":"splotch_sync"}'
		relay():send(packet, netId, true, true, relay().CHANNEL_HIGH_PRIORITY_2)
		first = false
	until i > n
end

local function onSplotchSync(data)
	if data.first then
		clearSplotches()
	end
	for _, e in ipairs(data.splotches or {}) do
		local owner = e.o and netToCx[e.o] or nil
		addSplotch(e.x or 0, e.y or 0, e.c or 0, e.a or love.math.random() * math.pi * 2, e.t or state.nowMs(), owner)
	end
end

-- COVERAGE / MATCH RESULT

local function coverageMembers()
	local list = {}
	for _, m in ipairs(state.lobbyMembers) do
		list[#list + 1] = { cxId = m.cxId, colorIndex = (m.extra and m.extra.colorIndex) or 0 }
	end
	return list
end

local function toEntries(cov)
	local out = {}
	for _, c in ipairs(cov) do
		out[#out + 1] = { cxId = c.cxId, rank = c.rank, coveragePct = c.coveragePct, beaten = c.beaten }
	end
	return out
end

local function applyMatchResult(round, entries)
	if state.matchResultRound == round then
		return
	end
	state.matchResultRound = round
	state.matchResultEntries = entries
	if state.isHost() then
		app.hostPostMatchResults(round, entries)
	end
end

local function sendMatchResult(round, cov)
	if #cov == 0 then
		return
	end
	local entries = {}
	for _, c in ipairs(cov) do
		entries[#entries + 1] = { cx = c.cxId, r = c.rank, c = math.floor(c.coveragePct * 100 + 0.5), b = c.beaten }
	end
	local batches, batch = {}, {}
	for _, e in ipairs(entries) do
		batch[#batch + 1] = e
		local candidate = json().encode({ op = "match_result", data = { round = round, first = #batches == 0, last = true, e = json().array(batch) } })
		if #candidate > CHUNK_MAX_BYTES and #batch > 1 then
			batch[#batch] = nil
			batches[#batches + 1] = batch
			batch = { e }
		end
	end
	batches[#batches + 1] = batch
	for k, b in ipairs(batches) do
		sendAll({ op = "match_result", data = { round = round, first = k == 1, last = k == #batches, e = json().array(b) } },
			true, true, relay().CHANNEL_HIGH_PRIORITY_1)
	end
end

local function onMatchResult(data)
	local round = data.round or 0
	if state.matchResultRound == round then
		return
	end
	if data.first then
		pendingResult = {}
	end
	for _, e in ipairs(data.e or {}) do
		pendingResult[#pendingResult + 1] = { cxId = e.cx, rank = e.r or 0, coveragePct = (e.c or 0) / 100, beaten = e.b or 0 }
	end
	if data.last then
		applyMatchResult(round, pendingResult)
		pendingResult = {}
	end
end

function screen.applyFallbackIfMissing()
	if state.matchResultRound ~= roundNumber then
		applyMatchResult(roundNumber, toEntries(Coverage.compute(splotches, coverageMembers())))
	end
end

local function tickMatch(elapsed)
	local fresh = Coverage.compute(splotches, coverageMembers())
	scoreboard = fresh
	if not state.isCursorPartyLobby() then
		return -- auto-end / results / leaderboards are CursorParty-only
	end
	local host = state.isHost()
	if phase == "running" and elapsed >= MATCH_DURATION and host then
		if state.matchResultRound ~= roundNumber then
			applyMatchResult(roundNumber, toEntries(fresh))
			sendMatchResult(roundNumber, fresh)
		end
		phase = "results"
		resultsSentAt = elapsed
	elseif phase == "results" and host and elapsed - resultsSentAt >= RESULT_GRACE then
		app.hostEndMatch()
		phase = "ended"
	end
	-- watchdog: no authoritative result well past the deadline
	if state.matchResultRound ~= roundNumber and elapsed >= MATCH_DURATION + RESULT_GRACE + 3 then
		applyMatchResult(roundNumber, toEntries(fresh))
		if host and phase ~= "ended" then
			sendMatchResult(roundNumber, fresh)
			phase = "results"
			resultsSentAt = elapsed
		end
	end
end

-- RELAY EVENTS (from app.lua)

function screen.onRelayMessage(netId, msg)
	local data = msg.data or {}
	local op = msg.op
	if op == "game_start" then
		-- the host's start time and round are authoritative (round keys the results entity)
		if (data.startTime or 0) > 0 then
			state.gameStartTimeMs = data.startTime
		end
		if data.round then
			state.roundNumber = data.round
			roundNumber = data.round
		end
	elseif op == "move" then
		if netId ~= state.myNetId then
			local c = cursors[netId] or {}
			c.tx, c.ty = data.x or 0, data.y or 0
			c.x, c.y = c.x or c.tx, c.y or c.ty
			cursors[netId] = c
		end
	elseif op == "shockwave" then
		if netId ~= state.myNetId then
			local cx = netToCx[netId]
			local m = cx and state.memberFor(cx)
			shockwave(data.x or 0, data.y or 0, (m and m.extra and m.extra.colorIndex) or 0, false, data.angle, cx)
		end
	elseif op == "relay_ping" then
		local cx = netToCx[netId]
		if cx then
			pings[cx] = data.ping or msg.ping
		end
	elseif op == "clear_splotches" then
		clearSplotches()
	elseif op == "splotch_sync" then
		onSplotchSync(data)
	elseif op == "match_result" then
		onMatchResult(data)
	end
end

function screen.onRelaySystem(msg)
	local op = msg.op
	if op == "CONNECT" or op == "NET_ID" then
		local cx, nid = msg.cxId, msg.netId
		if cx and nid then
			cxToNet[cx], netToCx[nid] = nid, cx
			-- relay can beat the lobby's MEMBER_JOIN; seed a placeholder so coverage sees them
			if not state.memberFor(cx) then
				state.lobbyMembers[#state.lobbyMembers + 1] = { cxId = cx, extra = {} }
			end
			if op == "CONNECT" and state.isHost() and cx ~= state.userCxId then
				-- a late connector missed the original game_start broadcast
				if state.gameStartTimeMs > 0 then
					relay():send(json().encode({ op = "game_start", data = { startTime = state.gameStartTimeMs, round = state.roundNumber } }), nid, true, false, relay().CHANNEL_HIGH_PRIORITY_1)
				end
				sendSplotchSync(nid)
			end
		end
	elseif op == "DISCONNECT" then
		local nid = msg.cxId and cxToNet[msg.cxId]
		if nid then
			cursors[nid] = nil
			netToCx[nid] = nil
			cxToNet[msg.cxId] = nil
		end
	end
end

-- LIFECYCLE

function screen.enter()
	splatImage = splatImage or love.graphics.newImage("assets/PaintSplatter1.png")
	cursors, splotches, shockwaves, pings = {}, {}, {}, {}
	cxToNet, netToCx = {}, {}
	timers = { move = 0, ping = 0, paint = 0, coverage = 0 }
	phase = "running"
	pendingResult, scoreboard = {}, {}
	roundNumber = state.roundNumber -- bumped on relay connect, overwritten by the host's game_start
	state.matchResultRound = -1
	state.matchResultEntries = {}

	local r = relay()
	for _, m in ipairs(state.lobbyMembers) do
		local nid = r:getNetIdForCxId(m.cxId)
		if nid < 40 then
			cxToNet[m.cxId], netToCx[nid] = nid, m.cxId
		end
	end
	if state.myNetId >= 0 then
		cxToNet[state.userCxId], netToCx[state.myNetId] = state.myNetId, state.userCxId
	end
end

local function boardMouse()
	local mx, my = love.mouse.getPosition()
	local nx = (mx - board.x) / (GAME_W * board.s)
	local ny = (my - board.y) / (GAME_H * board.s)
	return nx, ny, nx >= 0 and nx <= 1 and ny >= 0 and ny <= 1
end

function screen.update(dt)
	local nx, ny, inBoard = boardMouse()
	local cnx, cny = math.max(0, math.min(1, nx)), math.max(0, math.min(1, ny))

	timers.move = timers.move + dt
	if timers.move >= MOVE_INTERVAL then
		timers.move = 0
		sendAll({ op = "move", data = { x = cnx, y = cny } }, hud.reliable, hud.ordered, hud.channel - 1)
	end

	-- hold to paint (the press itself paints immediately in mousepressed)
	if love.mouse.isDown(1) and inBoard then
		timers.paint = timers.paint + dt
		if timers.paint >= AUTO_PAINT_INTERVAL then
			timers.paint = 0
			shockwave(nx, ny, state.myColorIndex, true, nil, state.userCxId)
		end
	else
		timers.paint = 0
	end

	for _, c in pairs(cursors) do
		local k = math.min(1, dt * 15)
		c.x = c.x + (c.tx - c.x) * k
		c.y = c.y + (c.ty - c.y) * k
	end

	local now = love.timer.getTime()
	for i = #shockwaves, 1, -1 do
		if now - shockwaves[i].start >= SHOCKWAVE_LIFE then
			table.remove(shockwaves, i)
		end
	end
	if state.splotchDuration >= 0 then
		local nowMs = state.nowMs()
		for i = #splotches, 1, -1 do
			if (nowMs - splotches[i].t) / 1000 >= state.splotchDuration then
				table.remove(splotches, i)
			end
		end
	end

	if state.gameStartTimeMs <= 0 then
		return
	end
	timers.ping = timers.ping + dt
	if timers.ping >= PING_INTERVAL then
		timers.ping = 0
		local ms = relay():getPing()
		pings[state.userCxId] = ms
		sendAll({ op = "relay_ping", data = { ping = ms } }, false, false, relay().CHANNEL_LOW_PRIORITY)
	end
	timers.coverage = timers.coverage + dt
	if timers.coverage >= COVERAGE_INTERVAL then
		timers.coverage = 0
		tickMatch(elapsedSec())
	end
end

function screen.mousepressed(_, _, button)
	if button ~= 1 then
		return
	end
	local nx, ny, inBoard = boardMouse()
	if inBoard then
		timers.paint = 0
		shockwave(nx, ny, state.myColorIndex, true, nil, state.userCxId)
	end
end

-- DRAWING

-- Spring overshoot 0 → ~1.4 → 1, same curve as the other clients.
local function splatSize(t)
	if t <= 0 then
		return 0
	end
	if t >= 1 then
		return 1
	end
	local a, b = 0.6, 0.4
	return math.max(0, math.min(math.min((1 + b) * t / a, -(((1 + b) * t) - ((2 + b) * a)) / a), 1 + b))
end

local function fmtPing(ms)
	if not ms or ms < 0 then
		return "..."
	end
	return ms >= 999 and "T/O" or (ms .. " ms")
end

local function memberName(cx)
	local m = cx and state.memberFor(cx)
	return (m and m.name and m.name ~= "" and m.name) or "Player"
end

local SIDEBAR_W = 220 -- C++ SIDEBAR_WIDTH
local BAR_H = 22 -- top menu bar (main.lua)
local HEADER_H = 56
local PAD = 14
local RANK_COLORS = { { 1, 0.84, 0.25 }, { 0.92, 0.92, 0.92 }, { 0.9, 0.55, 0.25 } }
local WINDOW_BG = { 0.1, 0.1, 0.15 } -- C++ ImGuiCol_WindowBg
local BOARD_BG = { 0.137, 0.145, 0.188 } -- C++ play-area frame
local ROW_ME = { 0.18, 0.2, 0.27 }

local function pingColor(ms)
	if not ms or ms < 0 then
		return ui.colors.dim
	elseif ms < 100 then
		return { 0.4, 0.9, 0.5 }
	elseif ms < 200 then
		return { 0.95, 0.8, 0.3 }
	end
	return { 1, 0.4, 0.4 }
end

local function coverageFor(cx)
	for _, c in ipairs(scoreboard) do
		if c.cxId == cx then
			return c.coveragePct
		end
	end
	return 0
end

-- C++ cursors are labelled with that player's live coverage %, in their colour.
local function drawCursorPct(x, y, color, pct)
	love.graphics.setColor(color)
	love.graphics.polygon("fill", x, y, x, y + 14, x + 4, y + 11, x + 7, y + 17, x + 9, y + 16, x + 6, y + 10, x + 11, y + 10)
	ui.label(string.format("%.0f%%", pct), x + 10, y - 8, color, "small")
end

-- Full-height RANK / PLAYER | COVERAGE sidebar (left, like the C++ client): one line per player.
local function drawSidebar(h)
	ui.rect(0, BAR_H, SIDEBAR_W, h - BAR_H, WINDOW_BG, 0)
	love.graphics.setColor(ui.colors.border)
	love.graphics.line(SIDEBAR_W - 0.5, BAR_H, SIDEBAR_W - 0.5, h)
	ui.rect(8, BAR_H + 10, SIDEBAR_W - 16, 18, { 0.16, 0.17, 0.23 }, 0)
	ui.label("RANK / PLAYER", 14, BAR_H + 12, ui.colors.text, "small")
	ui.label("COVERAGE", SIDEBAR_W - 76, BAR_H + 12, ui.colors.text, "small")
	local rows = scoreboard
	if #rows == 0 then
		rows = {}
		for i, m in ipairs(state.lobbyMembers) do
			rows[i] = { cxId = m.cxId, colorIndex = (m.extra and m.extra.colorIndex) or 0, rank = i, coveragePct = 0 }
		end
	end
	local font = ui.font("small")
	local y = BAR_H + 30
	for _, c in ipairs(rows) do
		local isMe = c.cxId == state.userCxId
		if isMe then
			ui.rect(8, y - 1, SIDEBAR_W - 16, 17, ROW_ME, 0)
		end
		local textColor = isMe and ui.colors.good or ui.colors.text
		ui.label("#" .. c.rank, 14, y, RANK_COLORS[c.rank] or ui.colors.text, "small")
		love.graphics.setColor(state.color(c.colorIndex))
		love.graphics.circle("fill", 44, y + 7, 4)
		local name = memberName(c.cxId)
		local maxW = SIDEBAR_W - 76 - 54 - (isMe and 34 or 6)
		while #name > 1 and font:getWidth(name) > maxW do
			name = name:sub(1, -2)
		end
		ui.label(name, 54, y, textColor, "small")
		if isMe then
			local bx = 54 + font:getWidth(name) + 6
			ui.rect(bx, y - 1, 30, 16, { 0.25, 0.27, 0.35 }, 3)
			ui.label("YOU", bx + 3, y, ui.colors.text, "small")
		end
		ui.label(string.format("%.0f%%", c.coveragePct), SIDEBAR_W - 76, y, textColor, "small")
		y = y + 18
	end
end

-- Relay settings + round/lobby: the C++ "Debug" panel, kept at the foot of the sidebar so it never
-- covers the board.
local function drawDebugPanel(h)
	local pw, ph = SIDEBAR_W - 16, 200
	local x, y = 8, h - ph - 70
	ui.box(x, y, pw, ph, { 0.12, 0.13, 0.18 })
	local yy = y + 8
	if state.lobbyRegion ~= "" then
		ui.label("Region: " .. state.lobbyRegion, x + 10, yy, ui.colors.dim, "small")
		yy = yy + 16
	end
	ui.label("Reliable options", x + 10, yy, ui.colors.text, "small")
	ui.label("Only affect position", x + 10, yy + 14, ui.colors.dim, "small")
	ui.label("Channel", x + 10, yy + 34, ui.colors.text, "small")
	for i = 0, 3 do
		local cx = x + 70 + (i % 2) * 56
		local cy = yy + 34 + math.floor(i / 2) * 20
		love.graphics.setColor(ui.colors.border)
		love.graphics.circle("line", cx + 6, cy + 7, 6)
		if hud.channel - 1 == i then
			love.graphics.setColor(ui.colors.accent)
			love.graphics.circle("fill", cx + 6, cy + 7, 3.5)
		end
		ui.label(tostring(i), cx + 16, cy, ui.colors.text, "small")
		if ui.clicked(cx, cy, 40, 16) then
			hud.channel = i + 1
		end
	end
	hud.reliable = ui.checkbox("Reliable", hud.reliable, x + 10, yy + 76)
	hud.ordered = ui.checkbox("Ordered", hud.ordered, x + 10, yy + 98)
	ui.label("Round: " .. state.roundNumber, x + 10, yy + 124, ui.colors.dim, "small")
	ui.label("Lobby:", x + 10, yy + 140, ui.colors.dim, "small")
	ui.label(state.lobbyId, x + 10, yy + 154, ui.colors.dim, "small", pw - 20)
end

function screen.draw(w, h)
	drawSidebar(h)
	drawDebugPanel(h)

	-- the board fills the area right of the sidebar, capped at 1x like the C++ client
	local areaW = w - SIDEBAR_W
	local availW, availH = areaW - 2 * PAD - 48, h - BAR_H - 2 * PAD - HEADER_H - 48
	board.s = math.min(1, availW / GAME_W, availH / GAME_H)
	local s = board.s
	local gw, gh = GAME_W * s, GAME_H * s
	board.x = SIDEBAR_W + (areaW - gw) / 2
	board.y = BAR_H + (h - BAR_H - gh) / 2 + HEADER_H / 2

	-- the C++ "Game" window: a framed panel holding the header and the play area
	local hy = board.y - HEADER_H
	ui.box(board.x - PAD, hy - PAD, gw + 2 * PAD, gh + HEADER_H + 2 * PAD, WINDOW_BG)
	local cursorParty = state.isCursorPartyLobby()
	local remaining = math.max(0, MATCH_DURATION - elapsedSec())
	if cursorParty then
		local tc = remaining <= 10 and { 1, 0.3, 0.3 } or (remaining <= 30 and { 1, 0.75, 0.2 } or ui.colors.text)
		local secs = math.ceil(remaining)
		ui.label(string.format("%d:%02d", math.floor(secs / 60), secs % 60), board.x, hy, tc, "body")
	end
	if ui.button("Exit Match", board.x + gw - 92, hy - 2, 92, 22, { color = { 0.18, 0.2, 0.27 }, hover = ui.colors.border, font = "small" }) then
		app.leaveGame()
	end
	local myPing = relay():getPing()
	love.graphics.setColor(pingColor(myPing))
	love.graphics.circle("fill", board.x + 4, hy + 31, 4)
	ui.label("Ping: " .. fmtPing(myPing), board.x + 14, hy + 24, ui.colors.dim, "small")

	-- play area
	ui.rect(board.x, board.y, gw, gh, BOARD_BG, 4)
	love.graphics.setScissor(board.x, board.y, gw, gh)

	local nowMs = state.nowMs()
	local iw, ih = splatImage:getDimensions()
	for _, sp in ipairs(splotches) do
		local age = (nowMs - sp.t) / 1000
		local alpha = 1
		if state.splotchDuration >= 0 then
			alpha = math.max(0, math.min(1, (state.splotchDuration - age) / FADE_SECS))
		end
		local c = state.color(sp.c)
		love.graphics.setColor(c[1], c[2], c[3], alpha)
		local scale = SPLOTCH_SIZE / iw * splatSize(age / state.appearDuration) * s
		love.graphics.draw(splatImage, board.x + sp.x * GAME_W * s, board.y + sp.y * GAME_H * s, sp.a, scale, scale, iw / 2, ih / 2)
	end

	local now = love.timer.getTime()
	for _, sw in ipairs(shockwaves) do
		local t = (now - sw.start) / SHOCKWAVE_LIFE
		local ease = 1 - (1 - t) * (1 - t)
		local c = state.color(sw.c)
		love.graphics.setColor(c[1], c[2], c[3], 0.35 * (1 - t))
		love.graphics.circle("fill", board.x + sw.x * GAME_W * s, board.y + sw.y * GAME_H * s, SHOCKWAVE_RADIUS * ease * s)
	end

	for nid, c in pairs(cursors) do
		local cx = netToCx[nid]
		local m = cx and state.memberFor(cx)
		local color = state.color((m and m.extra and m.extra.colorIndex) or nid % #state.palette)
		drawCursorPct(board.x + c.x * GAME_W * s, board.y + c.y * GAME_H * s, color, coverageFor(cx))
	end
	local mx, my = love.mouse.getPosition()
	drawCursorPct(mx, my, state.color(state.myColorIndex), coverageFor(state.userCxId))
	love.graphics.setScissor()
end

return screen
