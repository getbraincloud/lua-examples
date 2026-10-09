function love.conf(t)
	t.identity = "braincloud-cursorparty"
	t.version = "11.4"
	t.window.title = "Cursor Party"
	t.window.icon = "assets/icon.png" -- the CursorParty icon shared with the C++ / C# clients
	t.window.width = 1280
	t.window.height = 760
	t.window.resizable = true
	t.window.minwidth = 1000
	t.window.minheight = 640
	t.modules.joystick = false
	t.modules.physics = false
end
