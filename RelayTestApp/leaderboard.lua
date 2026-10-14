-- Leaderboard panel for the menu: top 5 + your row, Most Opponents Beaten / Highest Coverage %
-- and Lifetime / Quarterly toggles. Mirrors the React and C++ panels.

local ui = require("ui")
local state = require("state")

local leaderboard = { board = "points", period = "lifetime" }
local results = {} -- "<board>:<period>" -> { top = {...}, self = row or nil }
local pending = {}

local function boardId()
	if leaderboard.board == "points" then
		return leaderboard.period == "lifetime" and state.pointsLeaderboardId or state.pointsLeaderboardIdQuarterly
	end
	return leaderboard.period == "lifetime" and state.coverageLeaderboardId or state.coverageLeaderboardIdQuarterly
end

-- Gold, silver, bronze, then white.
local function rankColor(rank)
	if rank == 1 then return { 1, 0.84, 0 } end
	if rank == 2 then return { 0.75, 0.75, 0.75 } end
	if rank == 3 then return { 0.8, 0.53, 0.2 } end
	return ui.colors.text
end

-- Coverage scores are stored as basis points.
local function formatScore(score, board)
	if board == "coverage" then
		return string.format("%.1f%%", (score or 0) / 100)
	end
	local s = tostring(math.floor(score or 0))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function parse(entry)
	local name = (entry.data and entry.data.name) or entry.playerName or entry.name
	return { rank = entry.rank, score = entry.score, name = (name and name ~= "") and name or "Player" }
end

local function fetch(key)
	if results[key] or pending[key] or not state.bc then
		return
	end
	pending[key] = true
	local id = boardId()
	local entry = { top = {}, self = nil }
	local remaining = 2
	local function done()
		remaining = remaining - 1
		if remaining == 0 then
			results[key] = entry
			pending[key] = nil
		end
	end
	state.bc.leaderboard:getGlobalLeaderboardPage(id, "HIGH_TO_LOW", 0, 4, function(ok, r)
		local list = ok and r.data and r.data.leaderboard or {}
		for _, e in ipairs(list) do
			entry.top[#entry.top + 1] = parse(e)
		end
		done()
	end)
	-- beforeCount/afterCount 0 returns just your own entry.
	state.bc.leaderboard:getGlobalLeaderboardView(id, "HIGH_TO_LOW", 0, 0, function(ok, r)
		local list = ok and r.data and r.data.leaderboard
		entry.self = (list and list[1]) and parse(list[1]) or nil
		done()
	end)
end

-- Drop cached pages so the next draw re-reads them (e.g. after a match).
function leaderboard.refresh()
	results = {}
end

local function toggle(label, active, x, y, w)
	return ui.button(label, x, y, w, 26, { color = active and ui.colors.accent or ui.colors.panel2, font = "small" })
end

function leaderboard.draw(x, y, w, h)
	local half = (w - 4) / 2
	if toggle("Most Opponents Beaten", leaderboard.board == "points", x, y, half) then
		leaderboard.board = "points"
	end
	if toggle("Highest Coverage %", leaderboard.board == "coverage", x + half + 4, y, half) then
		leaderboard.board = "coverage"
	end
	if toggle("Lifetime", leaderboard.period == "lifetime", x, y + 30, half) then
		leaderboard.period = "lifetime"
	end
	if toggle("Quarterly", leaderboard.period == "quarterly", x + half + 4, y + 30, half) then
		leaderboard.period = "quarterly"
	end
	ui.rect(x, y + 64, w, 1, ui.colors.border, 0)

	local key = leaderboard.board .. ":" .. leaderboard.period
	fetch(key)
	local data = results[key]
	local rowY = y + 74
	if not data then
		ui.label("Loading...", x, rowY, ui.colors.dim, "small")
		return
	end

	local function row(r, suffix, ry)
		ui.label("#" .. tostring(r.rank), x, ry, rankColor(r.rank), "body")
		ui.label(r.name .. (suffix or ""), x + 48, ry, ui.colors.text, "body", w - 48 - 90)
		ui.label(formatScore(r.score, leaderboard.board), x + w - 90, ry, ui.colors.text, "body", 90, "right")
	end

	if #data.top == 0 then
		ui.label("No scores yet - be the first!", x, rowY, ui.colors.dim, "small")
		rowY = rowY + 24
	end
	local shown = false
	for _, r in ipairs(data.top) do
		row(r, nil, rowY)
		rowY = rowY + 26
		if data.self and r.rank == data.self.rank then
			shown = true
		end
	end
	if data.self and not shown then
		if #data.top > 0 then
			ui.label("...", x, rowY, ui.colors.dim, "small")
			rowY = rowY + 20
		end
		row(data.self, " (You)", rowY)
	end
end

return leaderboard
