local ui = require("ui")
local state = require("state")
local app = require("app")
local prefs = require("prefs")

local screen = {}
local form = { username = "", password = "" }
local remember = false
local busy = false
local status = ""

local PROPERTIES = {
	"Colours", "Colors", "AllLobbyTypes", "SplotchDuration",
	"PointsLeaderboardId", "PointsLeaderboardIdQuarterly", "CoverageLeaderboardId", "CoverageLeaderboardIdQuarterly",
}

-- Global properties every CursorParty client reads; any of them may be undefined.
local function loadGlobalProperties(done)
	app.showLoading("Loading lobby types...")
	state.bc.globalApp:readSelectedProperties(PROPERTIES, function(ok, r)
		local data = ok and r.data or {}
		local function value(name)
			local p = data[name]
			return type(p) == "table" and p.value or nil
		end
		local json = state.bc.json

		-- C++ reads "Colours" (CSV); "Colors" (JSON array) is the fallback
		local palette = state.parsePalette(value("Colours"), json)
		if #palette == 0 then
			palette = state.parsePalette(value("Colors"), json)
		end
		if #palette > 0 then
			state.palette = palette
		end

		state.lobbyTypes = {}
		local okTypes, types = pcall(json.decode, value("AllLobbyTypes") or "")
		if okTypes and type(types) == "table" then
			local keys = {}
			for k in pairs(types) do
				keys[#keys + 1] = k
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for _, k in ipairs(keys) do
				local entry = types[k]
				local name = type(entry) == "table" and entry.lobby or (type(entry) == "string" and entry)
				if name then
					state.lobbyTypes[#state.lobbyTypes + 1] = name
				end
			end
		end
		if #state.lobbyTypes == 0 then
			state.lobbyTypes = { "CursorPartyV2" }
		end

		state.splotchDuration = tonumber(value("SplotchDuration") or "") or -1
		for _, key in ipairs({ "pointsLeaderboardId", "pointsLeaderboardIdQuarterly", "coverageLeaderboardId", "coverageLeaderboardIdQuarterly" }) do
			local v = value(key:sub(1, 1):upper() .. key:sub(2))
			if v and v ~= "" then
				state[key] = v
			end
		end
		done()
	end)
end

-- The lobby member name comes from the profile's playerName: push the username if unset.
local function syncPlayerName(done)
	state.bc.playerState:readUserState(function(ok, r)
		local name = ok and r.data and r.data.playerName or ""
		if name ~= "" then
			state.username = name
			done()
		else
			state.bc.playerState:updateUserName(state.username, function()
				done()
			end)
		end
	end)
end

-- Worldwide coverage rank, shared with lobby-mates in extra.rank.
local function fetchRank()
	state.bc.leaderboard:getGlobalLeaderboardView(state.coverageLeaderboardId, "HIGH_TO_LOW", 0, 0, function(ok, r)
		local board = ok and r.data and r.data.leaderboard
		state.worldwideRank = (board and board[1] and board[1].rank) or -1
	end)
end

local function onAuthenticated()
	syncPlayerName(function()
		loadGlobalProperties(function()
			fetchRank()
			busy = false
			status = ""
			app.hideLoading()
			app.onAuthenticated()
		end)
	end)
end

local function login()
	local username = form.username:match("^%s*(.-)%s*$")
	if username == "" or form.password == "" then
		status = "Enter username and password."
		return
	end
	busy = true
	status = ""
	app.showLoading("Logging in ...")
	state.bc:authenticateUniversal(username, form.password, true, function(ok, r)
		if ok then
			state.username = username
			prefs.data.remember = remember
			prefs.data.username = remember and username or nil
			prefs.data.password = remember and form.password or nil
			prefs.save()
			onAuthenticated()
		else
			busy = false
			app.hideLoading()
			status = "Login failed: " .. tostring(r and r.status_message or "unknown error")
		end
	end)
end

function screen.enter(autoLogin)
	remember = prefs.data.remember == true
	form.username = prefs.data.username or ""
	form.password = prefs.data.password or ""
	busy = false
	status = ""
	if state.multiInstance and form.username == "" then
		-- generic per-instance user, like the C++ client's smrj_N
		form.username = "lua_" .. (state.instanceIndex + 1)
		form.password = form.username
		remember = true
	end
	if autoLogin and remember and form.username ~= "" and form.password ~= "" then
		login()
	end
end

function screen.draw(w, h)
	local bw, bh = 380, 300
	local x, y = (w - bw) / 2, (h - bh) / 2 - 20
	ui.box(x, y, bw, bh)
	ui.label("CursorParty", x, y + 20, ui.colors.text, "title", bw, "center")
	ui.label("brainCloud Relay Test App - LÖVE", x, y + 54, ui.colors.dim, "small", bw, "center")
	ui.label("Username", x + 30, y + 86, ui.colors.dim, "small")
	local enter = ui.textfield(form, "username", x + 30, y + 102, bw - 60, 30, { nextField = "password" })
	ui.label("Password", x + 30, y + 140, ui.colors.dim, "small")
	enter = ui.textfield(form, "password", x + 30, y + 156, bw - 60, 30, { password = true }) or enter
	remember = ui.checkbox("Remember me", remember, x + 30, y + 198)
	if (ui.button(busy and "..." or "Log in", x + 30, y + 228, bw - 60, 34, { disabled = busy }) or enter) and not busy then
		login()
	end
	ui.label(status, x, y + bh + 12, ui.colors.warn, "body", bw, "center")
end

return screen
