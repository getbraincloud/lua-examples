-- Phones/tablets: draw the desktop layout into a canvas scaled to fit the safe area.
local view = {}

local os_ = love.system.getOS()
view.active = os_ == "iOS" or os_ == "Android"

local MIN_W, MIN_H = 1000, 640
local canvas
local scale, ox, oy, vw, vh, lift = 1, 0, 0, 0, 0, 0
local rawGetPosition = love.mouse.getPosition

local function layout()
	local sx, sy, sw, sh = love.window.getSafeArea()
	scale = math.min(sw / MIN_W, sh / MIN_H, 1)
	local w, h = math.floor(sw / scale), math.floor(sh / scale)
	if not canvas or w ~= vw or h ~= vh then
		vw, vh = w, h
		canvas = love.graphics.newCanvas(vw, vh, { dpiscale = love.graphics.getDPIScale() * scale })
	end
	ox, oy = sx, sy
end

-- screen → layout coordinates
function view.toView(x, y)
	if not view.active then
		return x, y
	end
	return (x - ox) / scale, (y - oy - lift) / scale
end

function view.load()
	if not view.active then
		return
	end
	love.mouse.getPosition = function()
		return view.toView(rawGetPosition())
	end
	layout()
end

-- Returns the layout size to draw at.
function view.begin()
	if not view.active then
		return love.graphics.getDimensions()
	end
	layout()
	love.graphics.setCanvas(canvas)
	return vw, vh
end

-- focusBottom: bottom edge of the focused text field (layout coords), so the keyboard doesn't hide it.
function view.finish(focusBottom)
	if not view.active then
		return
	end
	love.graphics.setCanvas()
	lift = 0
	if focusBottom and love.keyboard.hasTextInput() then
		local limit = love.graphics.getHeight() * 0.4
		lift = math.min(0, limit - (oy + focusBottom * scale))
	end
	love.graphics.clear(0, 0, 0)
	love.graphics.setColor(1, 1, 1)
	love.graphics.setBlendMode("alpha", "premultiplied")
	love.graphics.draw(canvas, ox, oy + lift, 0, scale, scale)
	love.graphics.setBlendMode("alpha")
end

return view
