-- Shared runtime state for every screen.

local state = {
	bc = nil, -- brainCloud wrapper
	appVersion = "2.0",

	username = "",
	userCxId = "",

	lobbyTypes = {},
	selectedLobbyType = "",
	selectedProtocol = "UDP",
	team = "alpha", -- Team* lobby types only
	worldwideRank = -1,
	lobbyArrived = false, -- auto-ready happens once per lobby
	usePingData = false,
	myColorIndex = 0,
	userIsReady = false,

	-- `love . <index> <count>` (bccm run -i N), same as the C++ client's launch args
	multiInstance = false,
	instanceIndex = 0,
	autoJoin = false, -- count > 1: find a lobby straight after login
	autoStart = false, -- BC_AUTOSTART=1: host starts once another player joins (unattended test runs)

	lobbyId = "",
	lobbyRegion = "", -- from ROOM_ASSIGNED
	lobbyOwnerCxId = "",
	lobbyMembers = {},
	pingData = {}, -- region → ms, measured before joining
	lobbyChat = {}, -- {from, text, isMe}
	globalChatChannelId = "",
	globalChat = {}, -- {msgId, from, text}

	myNetId = -1,
	gameStartTimeMs = 0,
	splotchDuration = -1,
	appearDuration = 0.3,
	awaitingRematch = false,
	summaryArrivedAt = 0,

	roundNumber = 0,
	matchResultRound = -1,
	matchResultEntries = {}, -- {cxId, rank, coveragePct, beaten, lb}

	pointsLeaderboardId = "CursorParty_Points",
	pointsLeaderboardIdQuarterly = "CursorParty_Points_Quarterly",
	coverageLeaderboardId = "CursorParty_HighestCoverage",
	coverageLeaderboardIdQuarterly = "CursorParty_HighestCoverage_Quarterly",
}

-- Default 40-colour palette, matching the other CursorParty clients; replaced by "Colors".
local DEFAULT_HEX = {
	"FF3333", "FF8800", "FFD700", "88FF00", "00EE44", "00DDDD", "00AAFF", "3355FF", "AA00FF", "FF00BB",
	"FF5566", "FFAA00", "AADD00", "00FF88", "00FFCC", "0088FF", "8833FF", "FF44AA", "77FF33", "FF6688",
	"FF9999", "FFCC88", "FFFF88", "AAFFAA", "88FFEE", "AABBFF", "DDBBFF", "FFBBDD", "CCFFDD", "FFEECC",
	"CC1133", "CC5500", "88AA00", "228855", "009999", "3366AA", "7744CC", "AA3366", "AA6633", "7788AA",
}

local function hexColor(h)
	h = h:gsub("^%s*#?", ""):gsub("%s*$", "")
	if not h:match("^%x%x%x%x%x%x$") then
		return nil
	end
	return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end

function state.parsePalette(raw, json)
	local out = {}
	if type(raw) ~= "string" or raw:match("^%s*$") then
		return out
	end
	local tokens = {}
	if raw:match("^%s*%[") then
		local ok, arr = pcall(json.decode, raw)
		if ok and type(arr) == "table" then
			tokens = arr
		end
	else
		for t in raw:gmatch("[^,]+") do
			tokens[#tokens + 1] = t
		end
	end
	for _, t in ipairs(tokens) do
		local c = hexColor(tostring(t))
		if c then
			out[#out + 1] = c
		end
	end
	return out
end

state.palette = {}
for i, h in ipairs(DEFAULT_HEX) do
	state.palette[i] = hexColor(h)
end

--- 0-based colour index (the wire format) → {r,g,b}.
function state.color(index)
	return state.palette[(index or 0) + 1] or { 1, 1, 1 }
end

-- love.js builds: browsers only get secure WebSocket relay
state.isWeb = love.system.getOS() == "Web"

function state.isHost()
	return state.lobbyOwnerCxId ~= "" and state.userCxId == state.lobbyOwnerCxId
end

function state.memberFor(cxId)
	for _, m in ipairs(state.lobbyMembers) do
		if m.cxId == cxId then
			return m
		end
	end
	return nil
end

function state.nowMs()
	local socket = require("socket")
	return math.floor(socket.gettime() * 1000)
end

-- Same shape as the C++ client: {colorIndex, rank, pings?}
function state.myExtra()
	local extra = { colorIndex = state.myColorIndex, rank = state.worldwideRank }
	if next(state.pingData) then
		extra.pings = state.pingData
	end
	return extra
end

-- Only CursorParty lobby types run the 90s match / results / leaderboard flow.
function state.isCursorPartyLobby()
	return state.selectedLobbyType:find("CursorParty", 1, true) == 1
end

function state.clearLobby()
	state.lobbyId = ""
	state.lobbyOwnerCxId = ""
	state.lobbyMembers = {}
	state.lobbyChat = {}
	state.userIsReady = false
	state.lobbyArrived = false
	state.lobbyRegion = ""
	state.awaitingRematch = false
	state.pingData = {}
end

return state
