-- Saved login + picker choices (save directory, settings.json).

local json = require("braincloud.lib.json")

local prefs = { data = {} }
local FILE = "settings.json"

-- multi-instance runs keep separate prefs (settings_<index>.json), like the C++ configs_N.txt
function prefs.setInstance(index)
	FILE = "settings_" .. index .. ".json"
end

function prefs.load()
	if love.filesystem.getInfo(FILE) then
		local ok, t = pcall(json.decode, love.filesystem.read(FILE))
		if ok and type(t) == "table" then
			prefs.data = t
		end
	end
end

function prefs.save()
	love.filesystem.write(FILE, json.encode(prefs.data))
end

return prefs
