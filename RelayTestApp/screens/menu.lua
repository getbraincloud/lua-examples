local ui = require("ui")
local state = require("state")
local app = require("app")
local prefs = require("prefs")
local chat = require("chat")

local screen = {}
local PROTOCOLS = state.isWeb and { "WSS" } or { "UDP", "TCP", "WS", "WSS" }
local TEAMS = { "alpha", "beta" }
local typeIndex, protoIndex, teamIndex = 1, 1, 1
local usePing = false
local errorText = ""

local function indexOf(list, value)
	for i, v in ipairs(list) do
		if v == value then
			return i
		end
	end
	return 1
end

local DEFAULT_LOBBY_TYPE = "CursorPartyV2" -- C++ DEFAULT_LOBBY_TYPE

function screen.enter()
	if state.autoJoin then
		-- multi-instance: straight into the default lobby type, like the C++ client
		state.autoJoin = false
		app.matchmake(DEFAULT_LOBBY_TYPE, prefs.data.protocol or state.selectedProtocol, false)
		return
	end
	typeIndex = indexOf(state.lobbyTypes, prefs.data.lobbyType or state.selectedLobbyType)
	protoIndex = indexOf(PROTOCOLS, prefs.data.protocol or state.selectedProtocol)
	usePing = prefs.data.usePing == true
	teamIndex = indexOf(TEAMS, prefs.data.team or state.team)
	errorText = ""
end

function screen.setError(text)
	errorText = text
end

function screen.draw(w, h)
	local x, y = 40, 60
	ui.label("Welcome, " .. state.username, x, y, ui.colors.text, "title")
	ui.box(x, y + 50, 420, 300)
	local px = x + 20
	ui.label("Lobby type", px, y + 70, ui.colors.dim, "small")
	typeIndex = ui.cycler(state.lobbyTypes, typeIndex, px, y + 86, 380, 32)
	ui.label("Relay protocol", px, y + 130, ui.colors.dim, "small")
	protoIndex = ui.cycler(PROTOCOLS, protoIndex, px, y + 146, 380, 32)
	usePing = ui.checkbox("Use region ping data", usePing, px, y + 194)
	local lobbyType = state.lobbyTypes[typeIndex] or ""
	if lobbyType:sub(1, 4) == "Team" then
		ui.label("Team", px + 220, y + 196, ui.colors.dim, "small")
		teamIndex = ui.cycler(TEAMS, teamIndex, px + 260, y + 188, 120, 28)
	end

	local swatch = state.color(state.myColorIndex)
	ui.label("Your colour", px, y + 226, ui.colors.dim, "small")
	ui.rect(px, y + 242, 32, 20, swatch, 3)
	ui.label("(change it in the lobby)", px + 42, y + 244, ui.colors.dim, "small")

	if ui.button("Find Lobby", px, y + 280, 380, 40) then
		local lobbyType = state.lobbyTypes[typeIndex]
		prefs.data.lobbyType = lobbyType
		prefs.data.protocol = PROTOCOLS[protoIndex]
		prefs.data.usePing = usePing
		prefs.data.team = TEAMS[teamIndex]
		state.team = TEAMS[teamIndex]
		prefs.save()
		app.matchmake(lobbyType, PROTOCOLS[protoIndex], usePing)
	end
	ui.label(errorText, x, y + 366, ui.colors.bad, "body", 420)
	if ui.button("Log Out", x, y + 400, 120, 32, { color = ui.colors.panel2, hover = ui.colors.border }) then
		prefs.data.remember = false
		prefs.data.password = nil
		prefs.save()
		app.logout()
	end

	chat.draw(w - 380, 60, 340, h - 120, false)
end

return screen
