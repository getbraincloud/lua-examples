local ui = require("ui")
local state = require("state")
local app = require("app")
local prefs = require("prefs")
local chat = require("chat")

local screen = {}
local serverStatus = ""
local enteredAt = 0
local pickerOpen = false
local starting = false

local function sendReady(ready)
	state.bc.lobby:updateReady(state.lobbyId, ready, state.myExtra())
end

-- Guests auto-ready once on first arrival so the host can start without waiting on them;
-- after that "Not Ready" sticks.
local function applyRole()
	if state.lobbyArrived or state.lobbyOwnerCxId == "" then
		return
	end
	state.lobbyArrived = true
	if not state.isHost() and not state.userIsReady then
		state.userIsReady = true
		sendReady(true)
	end
end

function screen.enter()
	serverStatus = ""
	enteredAt = love.timer.getTime()
	pickerOpen = false
	starting = false
	chat.tab = "lobby"
	applyRole()
end

-- BC_AUTOSTART=1 (unattended multi-instance runs): the host starts once someone else is in.
function screen.update()
	if state.autoStart and not starting and state.isHost() and #state.lobbyMembers >= 2
		and love.timer.getTime() - enteredAt > 3 then
		starting = true
		state.userIsReady = true
		sendReady(true)
	end
end

function screen.setStatus(text)
	serverStatus = text
end

function screen.onLobbyEvent(op, data)
	if op == "MEMBER_JOIN" or op == "ROOM_UPDATE" then
		applyRole()
	elseif op == "STARTING" then
		serverStatus = "Server is starting up..."
		starting = true
	elseif op == "ROOM_ASSIGNED" then
		serverStatus = "Server assigned - waiting for relay..."
		starting = true
	elseif op == "ROOM_PROGRESS" then
		serverStatus = string.format("%d/%d: %s", data.curStep or 0, data.ofStep or 0, tostring(data.msg or ""))
	elseif op == "ROOM_READY" then
		serverStatus = "Connecting to server..."
	end
end

local function regionColumns()
	local seen, list = {}, {}
	local function add(pings)
		for r in pairs(pings or {}) do
			if not seen[r] then
				seen[r] = true
				list[#list + 1] = r
			end
		end
	end
	for _, m in ipairs(state.lobbyMembers) do
		add(m.extra and m.extra.pings)
	end
	add(state.pingData)
	table.sort(list)
	return list
end

local function fmtPing(ms)
	if not ms or ms < 0 then
		return "-"
	end
	return ms >= 999 and "T/O" or (ms .. "ms")
end

local function drawPicker(x, y)
	local cols, size, gap = 10, 22, 4
	local n = #state.palette
	local rows = math.ceil(n / cols)
	ui.box(x, y, cols * (size + gap) + gap, rows * (size + gap) + gap)
	for i = 1, n do
		local cx = x + gap + ((i - 1) % cols) * (size + gap)
		local cy = y + gap + math.floor((i - 1) / cols) * (size + gap)
		ui.rect(cx, cy, size, size, state.palette[i], 3)
		if i - 1 == state.myColorIndex then
			love.graphics.setColor(1, 1, 1)
			love.graphics.rectangle("line", cx - 1, cy - 1, size + 2, size + 2, 3, 3)
		end
		if ui.clicked(cx, cy, size, size) then
			state.myColorIndex = i - 1
			prefs.data.colorIndex = state.myColorIndex
			prefs.save()
			pickerOpen = false
			sendReady(state.userIsReady)
		end
	end
end

function screen.draw(w, h)
	local x, y = 40, 50
	local listW = w - 460
	local region = state.lobbyRegion ~= "" and state.lobbyRegion or "-"
	ui.label("Lobby  " .. state.selectedLobbyType, x, y, ui.colors.text, "title")
	local t = math.floor(love.timer.getTime() - enteredAt)
	ui.label(string.format("Region %s   |   %s   |   Time in lobby %02d:%02d", region, state.selectedProtocol, math.floor(t / 60), t % 60), x, y + 34, ui.colors.dim, "small")

	local regions = regionColumns()
	local tableY = y + 60
	ui.box(x, tableY, listW, 34 + math.max(1, #state.lobbyMembers) * 30)
	ui.label("Player", x + 44, tableY + 8, ui.colors.dim, "small")
	ui.label("Ready", x + 260, tableY + 8, ui.colors.dim, "small")
	for i, r in ipairs(regions) do
		ui.label(r, x + 320 + (i - 1) * 90, tableY + 8, ui.colors.dim, "small")
	end

	local pickerAt
	for i, m in ipairs(state.lobbyMembers) do
		local ry = tableY + 30 + (i - 1) * 30
		local isMe = m.cxId == state.userCxId
		local extra = m.extra or {}
		local swatchX = x + 12
		ui.rect(swatchX, ry + 4, 22, 18, state.color(isMe and state.myColorIndex or extra.colorIndex), 3)
		if isMe and ui.clicked(swatchX, ry + 4, 22, 18) then
			pickerOpen = not pickerOpen
		end
		if isMe then
			pickerAt = { swatchX, ry + 26 }
		end
		local name = (m.name and m.name ~= "" and m.name or "Player")
			.. (m.cxId == state.lobbyOwnerCxId and " [H]" or "") .. (isMe and " (you)" or "")
		ui.label(name, x + 44, ry + 5, isMe and ui.colors.good or ui.colors.text)
		local ready = m.isReady
		if isMe then
			ready = state.userIsReady
		end
		ui.label(ready and "Ready" or "-", x + 260, ry + 5, ready and ui.colors.good or ui.colors.dim)
		local pings = extra.pings
		if (not pings or next(pings) == nil) and isMe then
			pings = state.pingData
		end
		for j, r in ipairs(regions) do
			ui.label(fmtPing(pings and pings[r]), x + 320 + (j - 1) * 90, ry + 5, ui.colors.text, "small")
		end
	end

	local by = tableY + 50 + math.max(1, #state.lobbyMembers) * 30
	local label
	if state.isHost() then
		label = starting and "Starting..." or "Start"
	else
		label = state.userIsReady and "Not Ready" or "Ready"
	end
	if ui.button(label, x, by, 160, 36, { disabled = starting }) then
		if state.isHost() then
			starting = true
			state.userIsReady = true
			sendReady(true)
		else
			state.userIsReady = not state.userIsReady
			sendReady(state.userIsReady)
		end
	end
	if ui.button("Leave", x + 170, by, 120, 36, { color = ui.colors.panel2, hover = ui.colors.border }) then
		app.leaveLobby()
	end
	ui.label(serverStatus, x + 306, by + 9, ui.colors.warn)
	ui.label("Click your colour swatch to change it.", x, by + 46, ui.colors.dim, "small")

	chat.draw(w - 400, 50, 360, h - 100, true)

	if pickerOpen and pickerAt then
		drawPicker(pickerAt[1], pickerAt[2])
	end
end

return screen
