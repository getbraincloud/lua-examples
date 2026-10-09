-- Match Summary (port of the C++ matchSummary.cpp): winner banner, one card per player with
-- points and leaderboard movement, and the rematch queue.

local ui = require("ui")
local state = require("state")
local app = require("app")

local screen = {}

local AUTO_QUEUE = 45 -- C++ MATCH_SUMMARY_REMATCH_MS
local LEADERBOARD_TIMEOUT = 8 -- C++ LEADERBOARD_RESULT_TIMEOUT_MS
local PANEL_W, PANEL_H = 940, 640

local COLOR_ME = { 0.35, 1, 0.45 }
local COLOR_GOOD = { 0.45, 0.95, 0.55 }
local COLOR_BEST = { 1, 0.84, 0.3 }
local COLOR_DIM = { 0.55, 0.58, 0.65 }
local RANK_COLORS = { { 1, 0.84, 0.25 }, { 0.92, 0.92, 0.92 }, { 0.9, 0.55, 0.25 } }
local WINDOW_BG = { 0.1, 0.1, 0.15 }

local autoQueued = false

function screen.enter()
	autoQueued = false
end

local function elapsed()
	return love.timer.getTime() - state.summaryArrivedAt
end

function screen.update()
	if not autoQueued and not state.userIsReady and elapsed() >= AUTO_QUEUE then
		autoQueued = true
		app.setRematchReady(true)
	end
end

local function memberFor(cx)
	return state.memberFor(cx) or {}
end

local function periodsText(lifetime, quarterly)
	local parts = {}
	if lifetime and lifetime.improved then
		parts[#parts + 1] = string.format("Lifetime #%d->#%d", lifetime.before, lifetime.after)
	end
	if quarterly and quarterly.improved then
		parts[#parts + 1] = string.format("Quarterly #%d->#%d", quarterly.before, quarterly.after)
	end
	return table.concat(parts, "  |  ")
end

-- Rounded pill; returns its width so pills/text can follow on the same line.
local function pill(text, x, y, bg, fg)
	local font = ui.font("small")
	local w = font:getWidth(text) + 16
	ui.rect(x, y, w, font:getHeight() + 8, bg, 6)
	ui.label(text, x + 8, y + 4, fg, "small")
	return w
end

local function cardLines(e)
	local lines = 1
	if not e.lb then
		return lines + 1
	end
	local pointsUp = e.lb.pointsLifetime.improved or e.lb.pointsQuarterly.improved
	local coverageBest = e.lb.coverageLifetime.improved or e.lb.coverageQuarterly.improved
	lines = lines + (pointsUp and 1 or 0) + (coverageBest and 1 or 0)
	if not pointsUp and not coverageBest then
		lines = lines + 1
	end
	return lines
end

local LINE_H = 22

local function drawCard(e, x, y, w)
	local m = memberFor(e.cxId)
	local isMe = e.cxId == state.userCxId
	local h = LINE_H * (2 + cardLines(e)) + 16
	ui.box(x, y, w, h, { 0.12, 0.13, 0.18 })
	if isMe then
		love.graphics.setColor(COLOR_ME)
		love.graphics.setLineWidth(1.5)
		love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 6, 6)
		love.graphics.setLineWidth(1)
	end

	local px, py = x + 14, y + 10
	ui.label("#" .. e.rank, px, py, RANK_COLORS[e.rank] or ui.colors.text, "small")
	love.graphics.setColor(state.color((m.extra and m.extra.colorIndex) or 0))
	love.graphics.circle("fill", px + 30, py + 7, 4)
	local name = (m.name and m.name ~= "") and m.name or "?"
	ui.label(name, px + 40, py, isMe and COLOR_ME or ui.colors.text, "small")
	if isMe then
		ui.label("(YOU)", px + 46 + ui.font("small"):getWidth(name), py, COLOR_DIM, "small")
	end
	ui.label(string.format("%.0f%%", e.coveragePct), x, py, isMe and COLOR_ME or ui.colors.text, "small", w - 20, "right")
	ui.label("COVERAGE", x, py + LINE_H - 4, COLOR_DIM, "small", w - 20, "right")

	py = py + LINE_H * 2
	local pw = pill(string.format("+%d pts", e.beaten + 1), px, py, { 0.2, 0.24, 0.34 }, { 0.75, 0.82, 1 })
	ui.label(string.format("%d beaten + 1 for playing", e.beaten), px + pw + 6, py + 4, COLOR_DIM, "small")
	py = py + LINE_H

	if not e.lb then
		ui.label(elapsed() >= LEADERBOARD_TIMEOUT and "Leaderboard unavailable" or "Updating leaderboards...", px, py + 4, COLOR_DIM, "small")
		return h
	end
	local lb = e.lb
	local pointsUp = lb.pointsLifetime.improved or lb.pointsQuarterly.improved
	local coverageBest = lb.coverageLifetime.improved or lb.coverageQuarterly.improved
	if pointsUp then
		pill("^ Rank up - Opponents Beaten  " .. periodsText(lb.pointsLifetime, lb.pointsQuarterly), px, py, { 0.16, 0.32, 0.2 }, COLOR_GOOD)
		py = py + LINE_H
	end
	if coverageBest then
		pill("* Personal best - Coverage %  " .. periodsText(lb.coverageLifetime, lb.coverageQuarterly), px, py, { 0.34, 0.28, 0.1 }, COLOR_BEST)
		py = py + LINE_H
	end
	if not pointsUp and not coverageBest then
		pill("No leaderboard rank change this round", px, py, { 0.2, 0.2, 0.24 }, COLOR_DIM)
	end
	return h
end

function screen.draw(w, h)
	local margin, bar = 24, 22
	local pw = math.min(PANEL_W, math.max(480, w - margin * 2))
	local ph = math.min(PANEL_H, math.max(360, h - bar - margin * 2))
	local x, y = (w - pw) / 2, bar + (h - bar - ph) / 2
	ui.box(x, y, pw, ph, WINDOW_BG)

	local cx, cy, cw = x + 14, y + 14, pw - 28
	ui.label("Match Summary", cx, cy, ui.colors.text, "h2")
	ui.label(string.format("Lobby %s - %d Players", state.lobbyId, #state.lobbyMembers), cx, cy + 26, COLOR_DIM, "small")
	cy = cy + 50

	local entries = state.matchResultEntries
	local winner = entries[1]
	if winner then
		local m = memberFor(winner.cxId)
		ui.rect(cx, cy, cw, 40, { 0.3, 0.24, 0.08 }, 6)
		love.graphics.setColor(COLOR_BEST)
		love.graphics.setLineWidth(1.5)
		love.graphics.rectangle("line", cx + 0.5, cy + 0.5, cw - 1, 39, 6, 6)
		love.graphics.setLineWidth(1)
		ui.label(string.format("%s wins the round, covering %.0f%% of the board.", (m.name and m.name ~= "") and m.name or "?", winner.coveragePct),
			cx + 14, cy + 12, COLOR_BEST, "small")
		cy = cy + 52
	else
		ui.label("Waiting for results...", cx, cy, COLOR_DIM, "small")
		cy = cy + 24
	end

	ui.label("RANK / PLAYER", cx, cy, COLOR_DIM, "small")
	ui.label("LEADERBOARD RESULT", x + pw - 200, cy, COLOR_DIM, "small")
	cy = cy + 18
	love.graphics.setColor(ui.colors.border)
	love.graphics.line(cx, cy, cx + cw, cy)
	cy = cy + 8

	local listBottom = y + ph - 90
	love.graphics.setScissor(cx, cy, cw, math.max(0, listBottom - cy))
	for _, e in ipairs(entries) do
		cy = cy + drawCard(e, cx, cy, cw - 4) + 8
	end
	love.graphics.setScissor()

	-- footer: next-round countdown + rematch queue
	local fy = y + ph - 82
	love.graphics.setColor(ui.colors.border)
	love.graphics.line(cx, fy, cx + cw, fy)
	local left = 0
	if state.isCursorPartyLobby() then
		left = math.max(0, math.ceil(AUTO_QUEUE - elapsed()))
	end
	ui.label(string.format("Next Round: %d:%02d", math.floor(left / 60), left % 60), cx, fy + 8, COLOR_DIM, "small")

	local ready = 0
	for _, m in ipairs(state.lobbyMembers) do
		local r = m.isReady
		if m.cxId == state.userCxId then
			r = state.userIsReady
		end
		if r then
			ready = ready + 1
		end
	end
	local label = string.format("%s  %d/%d", state.userIsReady and "Queued for Rematch" or "Queue for Rematch", ready, #state.lobbyMembers)
	local bw = pw * 0.6
	local queued = state.userIsReady
	if ui.button(label, cx, fy + 30, bw, 36, { color = queued and { 0.2, 0.55, 0.3 } or { 0.18, 0.2, 0.27 }, hover = queued and { 0.25, 0.62, 0.35 } or ui.colors.border }) then
		app.setRematchReady(not queued)
	end
	if ui.button("Main Menu", cx + bw + 8, fy + 30, cw - bw - 8, 36, { color = { 0.18, 0.2, 0.27 }, hover = ui.colors.border }) then
		app.leaveLobby()
	end
end

return screen
