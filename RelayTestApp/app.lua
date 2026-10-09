-- Flow controller (port of the GDScript RelayTestApp's Main.gd): auth → RTT → lobby → relay →
-- match → summary/rematch. Screens call into this; it owns every brainCloud callback.

local state = require("state")

local app = {
	screen = nil,
	screens = {},
	loading = nil, -- full-screen overlay text, or nil
	cancelable = false,
}

local LOBBY_NOT_FOUND = 40613
local RESULTS_POLL_INTERVAL = 1.0
local REMATCH_WAIT = 45 -- host starts the next round anyway after this (C++ MATCH_SUMMARY_REMATCH_MS)

function app.show(name, ...)
	local screen = app.screens[name]
	app.screen = screen
	app.screenName = name
	if screen.enter then
		screen.enter(...)
	end
end

function app.call(method, ...)
	local s = app.screen
	if s and s[method] then
		s[method](...)
	end
end

-- C++-style loading dialog in place of the screen: text, then (when cancelable) elapsed time,
-- lobby id and a live status line.
function app.showLoading(text, cancelable)
	if app.loading ~= text then
		app.loadingStart = love.timer.getTime()
		app.loadingStatus = ""
	end
	app.loading = text
	app.cancelable = cancelable or false
end

function app.setLoadingStatus(text)
	app.loadingStatus = text or ""
end

function app.hideLoading()
	app.loading = nil
	app.cancelable = false
	app.loadingStatus = ""
end

local function bc()
	return state.bc
end

-- AUTH

function app.onAuthenticated()
	app.show("menu")
	app.connectGlobalChat()
end

-- RTT stays up for the whole session (login → logout); only relay/lobby are torn down per match.
local rttWaiters
function app.ensureRtt(done)
	local rtt = bc().rttService
	if rtt:isRTTEnabled() then
		done(true)
		return
	end
	if rttWaiters then
		rttWaiters[#rttWaiters + 1] = done
		return
	end
	rttWaiters = { done }
	local function finish(ok, err)
		local waiters = rttWaiters
		rttWaiters = nil
		if ok then
			state.userCxId = rtt:getRTTConnectionId()
			rtt:registerRTTLobbyCallback(app.onLobbyEvent)
		end
		for _, w in ipairs(waiters) do
			w(ok, err)
		end
	end
	rtt:enableRTT(function()
		finish(true)
	end, function(err)
		if rttWaiters then
			finish(false, err)
		else
			print("RTT disconnected: " .. tostring(err))
		end
	end)
end

-- GLOBAL CHAT ("gl" channel over the Chat service + RTT push)

function app.connectGlobalChat()
	app.ensureRtt(function(ok)
		if not ok or state.globalChatChannelId ~= "" then
			return
		end
		bc().chat:getChannelId("gl", "gl", function(s, r)
			if not s then
				return
			end
			local channelId = r.data.channelId
			bc().chat:channelConnect(channelId, 30, function(s2, r2)
				if not s2 then
					return
				end
				state.globalChatChannelId = channelId
				state.globalChat = {}
				for _, m in ipairs(r2.data.messages or {}) do
					state.globalChat[#state.globalChat + 1] = {
						msgId = m.msgId,
						from = (m.from and m.from.name) or "Player",
						text = (m.content and m.content.text) or "",
					}
				end
				bc().rttService:registerRTTChatCallback(app.onChatEvent)
			end)
		end)
	end)
end

function app.onChatEvent(msg)
	local d = msg.data or {}
	if msg.operation == "INCOMING" then
		state.globalChat[#state.globalChat + 1] = {
			msgId = d.msgId,
			from = (d.from and d.from.name) or "Player",
			text = (d.content and d.content.text) or "",
		}
	elseif msg.operation == "UPDATE" then
		for _, e in ipairs(state.globalChat) do
			if e.msgId == d.msgId then
				e.text = (d.content and d.content.text) or e.text
			end
		end
	elseif msg.operation == "DELETE" then
		for i = #state.globalChat, 1, -1 do
			if state.globalChat[i].msgId == d.msgId then
				table.remove(state.globalChat, i)
				break
			end
		end
	end
end

function app.sendGlobalChat(text)
	if text == "" or state.globalChatChannelId == "" then
		return
	end
	bc().chat:postChatMessageSimple(state.globalChatChannelId, text, true)
end

-- LOBBY CHAT (Lobby service signals)

function app.sendLobbyChat(text)
	if text == "" or state.lobbyId == "" then
		return
	end
	bc().lobby:sendSignal(state.lobbyId, { text = text })
	state.lobbyChat[#state.lobbyChat + 1] = { from = state.username, text = text, isMe = true }
end

-- MATCHMAKING

local searchCancelled = false

function app.matchmake(lobbyType, protocol, usePing)
	state.selectedLobbyType = lobbyType
	state.selectedProtocol = protocol
	state.usePingData = usePing
	searchCancelled = false
	app.joiningLobby = true
	app.showLoading("Joining lobby ...", true)
	app.ensureRtt(function(ok, err)
		if not ok then
			app.joiningLobby = false
			app.hideLoading()
			app.call("setError", "Could not enable RTT: " .. tostring(err))
			return
		end
		if usePing then
			app.pingRegions(lobbyType, function()
				if not searchCancelled then
					app.findLobby(lobbyType, usePing)
				end
			end)
		else
			app.findLobby(lobbyType, false)
		end
	end)
end

function app.pingRegions(lobbyType, done)
	state.pingData = {}
	app.setLoadingStatus("Getting regions...")
	bc().lobby:getRegionsForLobbies({ lobbyType }, function(ok)
		if not ok or searchCancelled then
			return done()
		end
		app.setLoadingStatus("Pinging regions...")
		bc().lobby:pingRegions(function(s, r)
			if s and r and r.data then
				state.pingData = r.data
			end
			done()
		end)
	end)
end

function app.findLobby(lobbyType, usePing)
	app.setLoadingStatus("Finding lobby...")
	local algo = { strategy = "ranged-absolute", alignment = "center", ranges = { 1000 } }
	-- "Team*" lobby types join the picked team (alpha/beta), everything else "all"
	local team = lobbyType:sub(1, 4) == "Team" and state.team or "all"
	local extra = state.myExtra()
	-- the Lobby screen opens on the first lobby event (like the C++ client), not on this reply
	local function onResult(ok, r)
		if ok and r.data then
			state.lobbyId = r.data.lobbyId or r.data.id or state.lobbyId
		end
		if searchCancelled or ok then
			return
		end
		app.joiningLobby = false
		app.hideLoading()
		print("findOrCreateLobby failed: " .. tostring(r and r.status_message))
		state.clearLobby()
		app.show("menu")
		app.call("setError", "Matchmaking failed: " .. tostring(r and r.status_message))
	end
	if usePing and next(state.pingData) then
		bc().lobby:findOrCreateLobbyWithPingData(lobbyType, 0, 1, algo, {}, nil, {}, false, extra, team, onResult)
	else
		bc().lobby:findOrCreateLobby(lobbyType, 0, 1, algo, {}, nil, {}, false, extra, team, onResult)
	end
end

function app.cancelSearch()
	searchCancelled = true
	app.joiningLobby = false
	if state.lobbyId ~= "" then
		bc().lobby:leaveLobby(state.lobbyId)
	end
	state.clearLobby()
	app.hideLoading()
	app.show("menu")
end

-- LOBBY EVENTS (RTT)

function app.onLobbyEvent(msg)
	local data = msg.data or {}
	local op = msg.operation
	local lobby = data.lobby
	if lobby and lobby.ownerCxId and lobby.ownerCxId ~= "" then
		state.lobbyOwnerCxId = lobby.ownerCxId
	end

	if op == "MEMBER_JOIN" or op == "ROOM_UPDATE" then
		if lobby and lobby.members and #lobby.members > 0 then
			state.lobbyMembers = {}
			for _, m in ipairs(lobby.members) do
				state.lobbyMembers[#state.lobbyMembers + 1] = m
			end
		elseif data.member and not state.memberFor(data.member.cxId) then
			state.lobbyMembers[#state.lobbyMembers + 1] = data.member
		end
		if state.lobbyId == "" then
			state.lobbyId = data.lobbyId or ""
		end
	elseif op == "MEMBER_LEFT" then
		local cx = data.member and data.member.cxId
		for i = #state.lobbyMembers, 1, -1 do
			if state.lobbyMembers[i].cxId == cx then
				table.remove(state.lobbyMembers, i)
			end
		end
	elseif op == "MEMBER_UPDATE" then
		local m = data.member or {}
		for i, existing in ipairs(state.lobbyMembers) do
			if existing.cxId == m.cxId then
				state.lobbyMembers[i] = m
			end
		end
	elseif op == "MATCHMAKING_IN_PROGRESS" then
		app.setLoadingStatus("Searching...")
		return
	elseif op == "SIGNAL" then
		local from = data.from or {}
		local text = data.signalData and data.signalData.text
		if text and text ~= "" and from.cxId ~= state.userCxId then
			state.lobbyChat[#state.lobbyChat + 1] = { from = from.name or "Player", text = text, isMe = false }
		end
		return
	elseif op == "DISBANDED" then
		local code = data.reason and data.reason.code
		if code ~= bc().client.reasonCodes.RTT_ROOM_READY then
			app.hideLoading()
			app.teardownRelay()
			state.clearLobby()
			app.show("menu")
		end
		return
	end

	if op == "MEMBER_JOIN" then
		local name = data.member and data.member.name
		app.setLoadingStatus("Joined: " .. ((name and name ~= "") and name or "unknown"))
	elseif op == "MEMBER_LEFT" then
		app.setLoadingStatus("Player left")
	end
	if app.joiningLobby and lobby then
		app.joiningLobby = false
		app.hideLoading()
		app.show("lobby")
	end
	if op == "ROOM_ASSIGNED" and data.region then
		state.lobbyRegion = data.region
	end
	app.call("onLobbyEvent", op, data)
	if op == "ROOM_READY" then
		app.connectRelay(data)
	end
end

-- RELAY

function app.connectRelay(room)
	app.call("setStatus", "Connecting to relay server...")
	local cd = room.connectData or {}
	local ports = cd.ports or {}
	state.lobbyId = room.lobbyId or state.lobbyId

	local proto = state.selectedProtocol:lower()
	local host = cd.address
	local port
	local ssl = proto == "wss"
	-- GameLift/i3D expose a single port and are forced to WEBSOCKET
	if ports.gamelift then
		port, proto, ssl = ports.gamelift, "ws", false
	elseif ports.i3d then
		port, proto, ssl = ports.i3d, "ws", false
	elseif ports[proto] then
		port = ports[proto]
	else
		port, proto, ssl = ports.ws, "ws", false
	end
	-- a browser can only open wss, so use the server's secure port whatever was picked
	if state.isWeb and ports.wss then
		port, proto, ssl = ports.wss, "wss", true
	end
	if proto == "wss" then
		host = cd.secureAddress or host -- the TLS endpoint is SNI-routed
	end
	local connectionType = (proto == "ws" or proto == "wss") and "ws" or proto

	local relay = bc().relay
	relay:registerSystemCallback(app.onRelaySystem)
	relay:registerRelayCallback(app.onRelayData)
	relay:connect(connectionType, {
		host = host,
		port = port,
		ssl = ssl,
		passcode = room.passcode,
		lobbyId = state.lobbyId,
	}, function()
		state.myNetId = relay:getNetIdForCxId(state.userCxId)
		-- the host's game_start round overwrites this for everyone else
		state.roundNumber = state.roundNumber + 1
		if state.isHost() then
			state.gameStartTimeMs = state.nowMs()
			relay:sendToAll(bc().json.encode({ op = "game_start", data = { startTime = state.gameStartTimeMs, round = state.roundNumber } }),
				true, false, relay.CHANNEL_HIGH_PRIORITY_1)
		end
		app.show("game")
	end, function(err)
		if app.screenName == "game" then
			-- a mid-match socket loss ends the match for us
			app.onMatchEnded()
		else
			app.teardownRelay()
			if state.lobbyId ~= "" then
				bc().lobby:leaveLobby(state.lobbyId)
			end
			state.clearLobby()
			app.show("menu")
			app.call("setError", "Relay connect failed: " .. tostring(err))
		end
	end)
end

function app.onRelaySystem(msg)
	if msg.op == "END_MATCH" then
		app.onMatchEnded()
		return
	end
	if msg.op == "MIGRATE_OWNER" and msg.cxId then
		state.lobbyOwnerCxId = msg.cxId
	end
	app.call("onRelaySystem", msg)
end

function app.onRelayData(netId, data)
	local ok, msg = pcall(bc().json.decode, data)
	if ok and type(msg) == "table" then
		app.call("onRelayMessage", netId, msg)
	end
end

function app.teardownRelay()
	local relay = bc().relay
	relay:deregisterRelayCallback()
	relay:deregisterSystemCallback()
	relay:disconnect()
end

function app.hostEndMatch()
	if state.isHost() then
		bc().relay:endMatch({ cxId = state.userCxId, lobbyId = state.lobbyId, op = "END_MATCH" })
	end
end

function app.leaveGame()
	app.teardownRelay()
	state.gameStartTimeMs = 0
	if state.lobbyId ~= "" then
		bc().lobby:leaveLobby(state.lobbyId)
	end
	state.clearLobby()
	app.show("menu")
end

local function recoverIfLobbyGone(ok, r)
	if ok or not r or r.reason_code ~= LOBBY_NOT_FOUND then
		return false
	end
	state.clearLobby()
	app.show("menu")
	return true
end

function app.onMatchEnded()
	if app.screenName ~= "game" then
		return
	end
	app.teardownRelay()
	state.gameStartTimeMs = 0
	if not state.isCursorPartyLobby() then
		-- non-CursorParty types skip the summary: straight back to the lobby, guests re-ready
		state.userIsReady = not state.isHost()
		app.show("lobby")
		if state.userIsReady then
			bc().lobby:updateReady(state.lobbyId, true, state.myExtra(), recoverIfLobbyGone)
		end
		return
	end
	app.call("applyFallbackIfMissing")
	state.userIsReady = false
	state.awaitingRematch = true
	state.summaryArrivedAt = love.timer.getTime()
	app.show("summary")
	if state.lobbyId ~= "" then
		bc().lobby:updateReady(state.lobbyId, false, state.myExtra(), recoverIfLobbyGone)
	end
end

--- Queue (or un-queue) for the next round from the Match Summary.
function app.setRematchReady(ready)
	state.userIsReady = ready
	if ready then
		app.show("lobby")
	end
	bc().lobby:updateReady(state.lobbyId, ready, state.myExtra(), recoverIfLobbyGone)
end

-- Host starts the next round once everyone queued, or after REMATCH_WAIT regardless.
local function tickRematchGate()
	if not state.awaitingRematch or not state.isHost() then
		return
	end
	local allReady = #state.lobbyMembers > 0
	for _, m in ipairs(state.lobbyMembers) do
		local ready
		if m.cxId == state.userCxId then
			ready = state.userIsReady -- not "and/or": false would fall through to the stale server value
		else
			ready = m.isReady
		end
		if not ready then
			allReady = false
			break
		end
	end
	if allReady or love.timer.getTime() - state.summaryArrivedAt >= REMATCH_WAIT then
		state.awaitingRematch = false
		state.userIsReady = true
		bc().lobby:updateReady(state.lobbyId, true, state.myExtra(), recoverIfLobbyGone)
	end
end

function app.logout()
	if state.globalChatChannelId ~= "" then
		bc().rttService:deregisterAllRTTCallbacks()
	end
	bc().rttService:disableRTT()
	state.globalChatChannelId = ""
	state.globalChat = {}
	state.clearLobby()
	bc():logout(true, function()
		app.show("login")
	end)
end

function app.leaveLobby()
	if state.lobbyId ~= "" then
		bc().lobby:leaveLobby(state.lobbyId)
	end
	state.clearLobby()
	app.show("menu")
end

-- MATCH RESULTS → leaderboards (host posts via the PostMatchResults script; others poll the
-- "matchResults" GlobalEntity it writes, indexed "<lobbyId>:<round>")

local function readPeriod(j)
	j = j or {}
	return { improved = j.improved == true, before = j.before or -1, after = j.after or -1 }
end

function app.applyLeaderboardResults(round, results)
	if state.matchResultRound ~= round or not results or #results == 0 then
		return
	end
	local profileToCx = {}
	for _, m in ipairs(state.lobbyMembers) do
		if m.profileId then
			profileToCx[m.profileId] = m.cxId
		end
	end
	for _, r in ipairs(results) do
		local cx = profileToCx[r.profileId]
		for _, e in ipairs(state.matchResultEntries) do
			if cx and e.cxId == cx then
				e.lb = {
					pointsLifetime = readPeriod(r.pointsLifetime),
					pointsQuarterly = readPeriod(r.pointsQuarterly),
					coverageLifetime = readPeriod(r.coverageLifetime),
					coverageQuarterly = readPeriod(r.coverageQuarterly),
				}
			end
		end
	end
end

function app.hostPostMatchResults(round, entries)
	local list = {}
	for _, e in ipairs(entries) do
		local m = state.memberFor(e.cxId)
		if m and m.profileId then
			list[#list + 1] = {
				profileId = m.profileId,
				name = m.name or "?",
				points = e.beaten + 1,
				coverageBasisPoints = math.floor(e.coveragePct * 100 + 0.5),
			}
		end
	end
	bc().script:runScript("PostMatchResults", {
		round = round,
		lobbyId = state.lobbyId,
		pointsLeaderboardId = state.pointsLeaderboardId,
		pointsLeaderboardIdQuarterly = state.pointsLeaderboardIdQuarterly,
		coverageLeaderboardId = state.coverageLeaderboardId,
		coverageLeaderboardIdQuarterly = state.coverageLeaderboardIdQuarterly,
		entries = bc().json.array(list),
	}, function(ok, r)
		if ok then
			local response = r.data and r.data.response or {}
			app.applyLeaderboardResults(round, response.results)
		else
			print("PostMatchResults failed: " .. tostring(r and r.status_message))
		end
	end)
end

local pollAccum, pollInFlight, pollRound = 0, false, -1
function app.update(dt)
	tickRematchGate()

	-- non-host: poll for the host's posted leaderboard results
	if state.matchResultRound < 0 or #state.matchResultEntries == 0 or state.isHost() then
		return
	end
	for _, e in ipairs(state.matchResultEntries) do
		if e.lb then
			return
		end
	end
	if pollRound ~= state.matchResultRound then
		pollRound, pollAccum, pollInFlight = state.matchResultRound, RESULTS_POLL_INTERVAL, false
	end
	if pollInFlight then
		return
	end
	pollAccum = pollAccum + dt
	if pollAccum < RESULTS_POLL_INTERVAL then
		return
	end
	pollAccum, pollInFlight = 0, true
	local round = state.matchResultRound
	bc().globalEntity:getListByIndexedId(state.lobbyId .. ":" .. round, 1, function(ok, r)
		pollInFlight = false
		local list = ok and r.data and r.data.entityList
		if list and list[1] and list[1].data then
			app.applyLeaderboardResults(round, list[1].data.results)
		end
	end)
end

return app
