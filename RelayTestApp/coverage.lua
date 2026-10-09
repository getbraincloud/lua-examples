-- Canvas coverage % + win ranking: a port of the C++ coverage.cpp / Coverage.cs / Coverage.gd.
-- Same constants and paint-order-wins rasterization so scores match across clients in a lobby.

local Coverage = {}

local CANVAS_W, CANVAS_H = 800, 600
local SPLOTCH_RADIUS = 32 -- 64px display diameter
local CELL = 2
local GRID_W, GRID_H = CANVAS_W / CELL, CANVAS_H / CELL

local grid = {}

--- splotches: {x, y (0-1), c, cx}; members: {cxId, colorIndex}.
--- Returns {cxId, colorIndex, coveragePct, visible, rank, beaten} sorted by rank.
function Coverage.compute(splotches, members)
	local result, byCx = {}, {}
	for i, m in ipairs(members) do
		result[i] = { cxId = m.cxId, colorIndex = m.colorIndex or 0, visible = 0, coveragePct = 0, rank = 1, beaten = 0 }
		byCx[m.cxId] = i
	end

	if #splotches > 0 then
		for i = 0, GRID_W * GRID_H - 1 do
			grid[i] = -1
		end
		local cellRadius = math.ceil(SPLOTCH_RADIUS / CELL)
		local r2 = SPLOTCH_RADIUS * SPLOTCH_RADIUS
		for _, s in ipairs(splotches) do
			local px, py = s.x * CANVAS_W, s.y * CANVAS_H
			-- attribute by sender first so two players sharing a colour aren't merged
			local idx = s.cx and byCx[s.cx] or nil
			if not idx then
				idx = -1
				for k, e in ipairs(result) do
					if e.colorIndex == s.c then
						idx = k
						break
					end
				end
			end
			local gcx, gcy = math.floor(px / CELL), math.floor(py / CELL)
			for dy = -cellRadius, cellRadius do
				local gy = gcy + dy
				if gy >= 0 and gy < GRID_H then
					local ddy = (gy + 0.5) * CELL - py
					local base = gy * GRID_W
					for dx = -cellRadius, cellRadius do
						local gx = gcx + dx
						if gx >= 0 and gx < GRID_W then
							local ddx = (gx + 0.5) * CELL - px
							if ddx * ddx + ddy * ddy <= r2 then
								grid[base + gx] = idx -- -1 still overwrites, crediting no one
							end
						end
					end
				end
			end
		end
		for i = 0, GRID_W * GRID_H - 1 do
			local idx = grid[i]
			if idx > 0 then
				result[idx].visible = result[idx].visible + 1
			end
		end
	end

	local cellArea, canvasArea = CELL * CELL, CANVAS_W * CANVAS_H
	for _, e in ipairs(result) do
		e.coveragePct = math.min(100, e.visible * cellArea / canvasArea * 100)
	end
	table.sort(result, function(a, b)
		if a.coveragePct ~= b.coveragePct then
			return a.coveragePct > b.coveragePct
		end
		if a.visible ~= b.visible then
			return a.visible > b.visible
		end
		return a.cxId < b.cxId
	end)
	for i, e in ipairs(result) do
		local prev = result[i - 1]
		if prev and prev.coveragePct == e.coveragePct and prev.visible == e.visible then
			e.rank = prev.rank
		else
			e.rank = i
		end
	end
	for _, e in ipairs(result) do
		local beaten = 0
		for _, o in ipairs(result) do
			if o.rank > e.rank then
				beaten = beaten + 1
			end
		end
		e.beaten = beaten
	end
	return result
end

return Coverage
