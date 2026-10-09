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
	if love._os == "iOS" or love._os == "Android" then
		-- fullscreen landscape (resizable would follow the sensor on Android); view.lua scales the desktop layout down
		t.window.highdpi = true
		t.window.resizable = false
		t.window.fullscreen = true
		t.window.minwidth, t.window.minheight = 1, 1
	end
	t.modules.joystick = false
	t.modules.physics = false
end
