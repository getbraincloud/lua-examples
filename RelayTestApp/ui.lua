-- Tiny immediate-mode UI: call widgets from draw(); clicks/typing are latched in from LÖVE events.

local ui = {}

local mouse = { x = 0, y = 0, pressed = false, down = false, wheel = 0 }
local typed = {}
local keys = {}
local focus = nil
local fonts = {}

ui.colors = {
	bg = { 0.035, 0.05, 0.075 },
	panel = { 0.11, 0.15, 0.2 },
	panel2 = { 0.15, 0.2, 0.27 },
	border = { 0.25, 0.32, 0.4 },
	text = { 0.9, 0.93, 0.95 },
	dim = { 0.55, 0.62, 0.68 },
	accent = { 0.2, 0.55, 0.95 },
	accentHover = { 0.3, 0.63, 1 },
	good = { 0.35, 0.9, 0.45 },
	bad = { 0.95, 0.4, 0.4 },
	warn = { 1, 0.75, 0.3 },
}
local C = ui.colors
ui.mobile = require("view").active

function ui.load()
	fonts.small = love.graphics.newFont(11)
	fonts.body = love.graphics.newFont(14)
	fonts.h2 = love.graphics.newFont(18)
	fonts.title = love.graphics.newFont(24)
	fonts.big = love.graphics.newFont(48)
	love.keyboard.setKeyRepeat(true)
end

function ui.font(name)
	return fonts[name or "body"]
end

-- LÖVE event hooks (forwarded from main.lua)
function ui.mousepressed(_, _, b)
	if b == 1 then
		mouse.pressed = true
		mouse.down = true
	end
end
function ui.mousereleased(_, _, b)
	if b == 1 then
		mouse.down = false
	end
end
function ui.wheelmoved(_, y)
	mouse.wheel = mouse.wheel + y
end
function ui.textinput(t)
	typed[#typed + 1] = t
end
function ui.keypressed(k)
	keys[k] = true
end

function ui.beginFrame()
	mouse.x, mouse.y = love.mouse.getPosition()
end

--- Call at the end of each frame.
function ui.endFrame()
	-- tapped elsewhere, or the focused field is gone (screen changed): drop focus and the on-screen keyboard
	if focus and ((mouse.pressed and not ui._hitFocus) or not ui._focusDrawn) then
		if ui.mobile then
			love.keyboard.setTextInput(false)
		end
		focus = nil
		ui.focusBottom = nil
	end
	ui._focusDrawn = false
	mouse.pressed, mouse.wheel = false, 0
	typed, keys = {}, {}
	ui._hitFocus = false
end

function ui.mouse()
	return mouse
end

function ui.keyPressed(k)
	return keys[k]
end

local function inside(x, y, w, h)
	return mouse.x >= x and mouse.x < x + w and mouse.y >= y and mouse.y < y + h
end
ui.inside = inside

--- True once per click inside the rect (for custom widgets).
function ui.clicked(x, y, w, h)
	return mouse.pressed and inside(x, y, w, h)
end

function ui.rect(x, y, w, h, color, radius)
	love.graphics.setColor(color or C.panel)
	love.graphics.rectangle("fill", x, y, w, h, radius or 4, radius or 4)
end

function ui.box(x, y, w, h, color)
	ui.rect(x, y, w, h, color or C.panel, 6)
	love.graphics.setColor(C.border)
	love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 6, 6)
end

function ui.label(text, x, y, color, fontName, w, align)
	love.graphics.setFont(fonts[fontName or "body"])
	love.graphics.setColor(color or C.text)
	if w then
		love.graphics.printf(tostring(text), x, y, w, align or "left")
	else
		love.graphics.print(tostring(text), x, y)
	end
end

--- Returns true when clicked.
function ui.button(text, x, y, w, h, opts)
	opts = opts or {}
	local disabled = opts.disabled
	local hover = not disabled and inside(x, y, w, h)
	local color = disabled and C.panel2 or (hover and (opts.hover or C.accentHover) or (opts.color or C.accent))
	ui.rect(x, y, w, h, color, 5)
	local font = fonts[opts.font or "body"]
	love.graphics.setFont(font)
	love.graphics.setColor(disabled and C.dim or C.text)
	love.graphics.printf(text, x, y + (h - font:getHeight()) / 2, w, "center")
	return hover and mouse.pressed
end

--- Returns the new checked state.
function ui.checkbox(label, checked, x, y)
	local size = 16
	local hover = inside(x, y, size + 6 + fonts.body:getWidth(label), size)
	ui.rect(x, y, size, size, hover and C.panel2 or C.panel, 3)
	love.graphics.setColor(C.border)
	love.graphics.rectangle("line", x + 0.5, y + 0.5, size - 1, size - 1, 3, 3)
	if checked then
		love.graphics.setColor(C.accent)
		love.graphics.rectangle("fill", x + 4, y + 4, size - 8, size - 8, 2, 2)
	end
	if label ~= "" then
		ui.label(label, x + size + 6, y)
	end
	if hover and mouse.pressed then
		return not checked
	end
	return checked
end

--- Click the left half to go back, the right half to go forward. Returns the new index.
function ui.cycler(options, index, x, y, w, h)
	local text = options[index] or "-"
	if ui.button("<  " .. text .. "  >", x, y, w, h, { color = C.panel2, hover = C.border }) and #options > 0 then
		index = index + (mouse.x < x + w / 2 and -1 or 1)
		if index < 1 then
			index = #options
		elseif index > #options then
			index = 1
		end
	end
	return index
end

--- Single-line text field bound to state[key]. Returns true on Enter.
function ui.textfield(state, key, x, y, w, h, opts)
	opts = opts or {}
	local id = tostring(state) .. key
	if inside(x, y, w, h) and mouse.pressed then
		focus = id
		ui._hitFocus = true
		love.keyboard.setTextInput(true)
	end
	local focused = focus == id
	if focused then
		ui.focusBottom = y + h
		ui._focusDrawn = true
	end
	ui.rect(x, y, w, h, focused and C.panel2 or C.panel, 4)
	love.graphics.setColor(focused and C.accent or C.border)
	love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1, 4, 4)
	local submitted = false
	if focused then
		for _, t in ipairs(typed) do
			state[key] = (state[key] or "") .. t
		end
		if keys.backspace then
			-- drop one UTF-8 character
			local s = state[key] or ""
			local cut = #s
			while cut > 0 do
				local b = s:byte(cut)
				cut = cut - 1
				if b < 0x80 or b >= 0xC0 then
					break
				end
			end
			state[key] = s:sub(1, cut)
		end
		submitted = keys["return"] or keys.kpenter
		if keys.tab and opts.nextField then
			focus = tostring(state) .. opts.nextField
		end
	end
	local value = state[key] or ""
	local shown = opts.password and string.rep("*", #value) or value
	local fh = fonts.body:getHeight()
	love.graphics.setScissor(x + 4, y, w - 8, h)
	if shown == "" and not focused and opts.placeholder then
		ui.label(opts.placeholder, x + 8, y + (h - fh) / 2, C.dim)
	else
		local caret = (focused and love.timer.getTime() % 1 < 0.5) and "|" or ""
		local ox = math.min(0, (w - 16) - fonts.body:getWidth(shown .. "|"))
		ui.label(shown .. caret, x + 8 + ox, y + (h - fh) / 2)
	end
	love.graphics.setScissor()
	return submitted and true or false
end

function ui.focus(state, key)
	focus = tostring(state) .. key
	love.keyboard.setTextInput(true)
end

--- Scrolling list, newest at the bottom; scroll offset lives in state.scroll.
function ui.list(state, items, x, y, w, h, render)
	ui.box(x, y, w, h)
	local lh = fonts.small:getHeight() + 4
	local visible = math.max(1, math.floor((h - 8) / lh))
	state.scroll = state.scroll or 0
	if inside(x, y, w, h) then
		state.scroll = math.max(0, math.min(math.max(0, #items - visible), state.scroll + mouse.wheel))
	end
	local first = math.max(1, #items - visible + 1 - state.scroll)
	love.graphics.setScissor(x + 2, y + 2, w - 4, h - 4)
	local yy = y + 4
	for i = first, math.min(#items, first + visible - 1) do
		if render then
			render(items[i], x + 6, yy, w - 12)
		else
			ui.label(items[i], x + 6, yy, C.text, "small")
		end
		yy = yy + lh
	end
	love.graphics.setScissor()
end

return ui
