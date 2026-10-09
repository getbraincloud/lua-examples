-- CursorParty (RelayTestApp) for LÖVE: brainCloud's cross-client REST + RTT + Relay demo.
-- Interoperates in one lobby with the C++, C#, Java, JS and Godot CursorParty clients.

local BrainCloud = require("braincloud")
local ui = require("ui")
local state = require("state")
local app = require("app")
local prefs = require("prefs")
local view = require("view")

local configError
local serverVersion = ""

-- `love . <index> <count>`: tile the windows and log each instance in as its own user.
local function applyInstanceArgs(args)
	local index, count = tonumber(args[#args - 1] or ""), tonumber(args[#args] or "")
	if not (index and count) then
		return
	end
	state.multiInstance = true
	state.instanceIndex = index
	state.autoJoin = count > 1
	state.autoStart = os.getenv("BC_AUTOSTART") == "1"
	prefs.setInstance(index)
	local cols = math.ceil(math.sqrt(count))
	local rows = math.ceil(count / cols)
	local _, _, flags = love.window.getMode()
	local dw, dh = love.window.getDesktopDimensions(flags.display)
	local w, h = math.min(1280, math.floor(dw / cols)), math.min(760, math.floor(dh / rows))
	love.window.setMode(w, h, { resizable = true, minwidth = 800, minheight = 560 })
	love.window.setPosition((index % cols) * w, math.floor(index / cols) * h, flags.display)
	love.window.setTitle(string.format("Cursor Party [%d]", index + 1))
end

function love.load(args)
	view.load()
	ui.load()
	applyInstanceArgs(args or {})
	prefs.load()
	state.myColorIndex = prefs.data.colorIndex or 0
	if state.multiInstance then
		state.myColorIndex = state.instanceIndex % #state.palette
	end

	app.screens.login = require("screens.login")
	app.screens.menu = require("screens.menu")
	app.screens.lobby = require("screens.lobby")
	app.screens.game = require("screens.game")
	app.screens.summary = require("screens.summary")

	state.bc = BrainCloud.new(state.multiInstance and ("cursorparty_" .. state.instanceIndex) or "cursorparty")
	-- braincloud_config.lua comes from the brainCloud setup tool (or `bccm generate`)
	if not state.bc:init() then
		configError = "No braincloud_config.lua found.\n\nRun the brainCloud setup tool from this folder:\n  love <braincloud-lua>/tools/braincloud-setup.love ."
		return
	end
	state.appVersion = state.bc:getBCClient():getAppVersion()
	state.bc:getBCClient():setDebugEnabled(os.getenv("BC_DEBUG") == "1")
	state.bc.authentication:getServerVersion(function(ok, r)
		if ok and r.data then
			serverVersion = tostring(r.data.serverVersion or "")
		end
	end)
	app.show("login", true)
end

function love.update(dt)
	ui.beginFrame()
	if state.bc then
		state.bc:update()
	end
	if configError then
		return
	end
	app.update(dt)
	if app.screen and app.screen.update then
		app.screen.update(dt)
	end
end

-- Persistent version overlay, bottom-left on every screen (same spot and lines as the C++ client).
local function drawVersion(_, h)
	local lines = { "App:    " .. state.appVersion }
	if state.bc and not configError then
		lines[#lines + 1] = "Client: " .. BrainCloud.VERSION
		lines[#lines + 1] = "Server: " .. serverVersion
	end
	local font = ui.font("small")
	local lh = font:getHeight() + 2
	local bw = 0
	for _, l in ipairs(lines) do
		bw = math.max(bw, font:getWidth(l))
	end
	local bh = #lines * lh + 10
	ui.rect(8, h - 8 - bh, bw + 16, bh, { 0.05, 0.07, 0.1, 0.45 }, 4)
	for i, l in ipairs(lines) do
		ui.label(l, 16, h - 8 - bh + 5 + (i - 1) * lh, ui.colors.dim, "small")
	end
end

-- The C++ loading dialog (280x155, centred), shown instead of the screen.
local function drawLoading(w, h)
	local dw, dh = 280, 155
	local x, y = (w - dw) / 2, (h - dh) / 2
	ui.box(x, y, dw, dh, { 0.1, 0.1, 0.15 })
	local yy = y + 14
	ui.label(app.loading, x, yy, ui.colors.text, "body", dw, "center")
	if app.cancelable then
		local secs = math.floor(love.timer.getTime() - (app.loadingStart or love.timer.getTime()))
		yy = yy + 20
		ui.label(string.format("%d:%02d", math.floor(secs / 60), secs % 60), x, yy, ui.colors.dim, "body", dw, "center")
		if state.lobbyId ~= "" then
			yy = yy + 22
			ui.label(state.lobbyId, x, yy, ui.colors.dim, "small", dw, "center")
		end
		if (app.loadingStatus or "") ~= "" then
			yy = yy + 20
			ui.label(app.loadingStatus, x, yy, ui.colors.dim, "small", dw, "center")
		end
		if ui.button("Cancel", x + (dw - 120) / 2, y + dh - 34, 120, 24, { color = { 0.18, 0.2, 0.27 }, hover = ui.colors.border }) then
			app.cancelSearch()
		end
	end
end

-- Top menu bar on every screen, like the C++ client: SDK version left, you (in your colour) right.
local function drawMenuBar(w)
	ui.rect(0, 0, w, 22, { 0.1, 0.1, 0.15 }, 0)
	love.graphics.setColor(ui.colors.border)
	love.graphics.line(0, 21.5, w, 21.5)
	ui.label("brainCloud " .. BrainCloud.VERSION, 12, 4, ui.colors.text, "small")
	if state.username ~= "" and app.screenName ~= "login" then
		local label = state.multiInstance and string.format("[%d] %s", state.instanceIndex + 1, state.username) or state.username
		ui.label(label, 0, 4, state.color(state.myColorIndex), "small", w - 12, "right")
	end
end

function love.draw()
	local w, h = view.begin()
	love.graphics.clear(ui.colors.bg)
	if configError then
		ui.label(configError, 40, 60, ui.colors.warn, "body", w - 80)
	elseif app.loading then
		drawLoading(w, h)
	elseif app.screen then
		app.screen.draw(w, h)
	end
	drawMenuBar(w)
	drawVersion(w, h)
	ui.endFrame()
	view.finish(ui.focusBottom)
end

function love.mousepressed(x, y, b)
	x, y = view.toView(x, y)
	ui.mousepressed(x, y, b)
	if not app.loading and app.screen and app.screen.mousepressed then
		app.screen.mousepressed(x, y, b)
	end
end

function love.mousereleased(x, y, b)
	x, y = view.toView(x, y)
	ui.mousereleased(x, y, b)
end

function love.wheelmoved(x, y)
	ui.wheelmoved(x, y)
end

function love.textinput(t)
	ui.textinput(t)
end

function love.keypressed(k)
	ui.keypressed(k)
end

function love.quit()
	if state.bc then
		state.bc:getBCClient():shutdown()
	end
end
