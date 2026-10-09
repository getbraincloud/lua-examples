-- Chat panel shared by the menu and lobby screens: Global (Chat service "gl") and Lobby
-- (Lobby service signals) tabs.

local ui = require("ui")
local state = require("state")
local app = require("app")

local chat = { tab = "global" }
local input = { text = "" }
local scroll = { global = {}, lobby = {} }

function chat.draw(x, y, w, h, allowLobby)
	if not allowLobby then
		chat.tab = "global"
	end
	local tabW = allowLobby and (w / 2) or w
	if ui.button("Global", x, y, tabW - 2, 24, { color = chat.tab == "global" and ui.colors.accent or ui.colors.panel2 }) then
		chat.tab = "global"
	end
	if allowLobby and ui.button("Lobby", x + tabW + 2, y, tabW - 2, 24, { color = chat.tab == "lobby" and ui.colors.accent or ui.colors.panel2 }) then
		chat.tab = "lobby"
	end

	local listY = y + 30
	local listH = h - 30 - 36
	if chat.tab == "global" then
		ui.list(scroll.global, state.globalChat, x, listY, w, listH, function(m, lx, ly, lw)
			ui.label(m.from .. ": " .. m.text, lx, ly, ui.colors.text, "small", lw)
		end)
	else
		ui.list(scroll.lobby, state.lobbyChat, x, listY, w, listH, function(m, lx, ly, lw)
			ui.label(m.from .. ": " .. m.text, lx, ly, m.isMe and ui.colors.good or ui.colors.text, "small", lw)
		end)
	end

	local sendY = y + h - 30
	local entered = ui.textfield(input, "text", x, sendY, w - 66, 30, { placeholder = chat.tab == "global" and "Message everyone..." or "Message this lobby..." })
	if (ui.button("Send", x + w - 60, sendY, 60, 30) or entered) and input.text ~= "" then
		if chat.tab == "global" then
			app.sendGlobalChat(input.text)
		else
			app.sendLobbyChat(input.text)
		end
		input.text = ""
	end
	if chat.tab == "global" and state.globalChatChannelId == "" then
		ui.label("connecting to chat...", x + 8, listY + 8, ui.colors.dim, "small")
	end
end

return chat
