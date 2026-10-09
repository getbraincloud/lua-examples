# CursorParty (RelayTestApp)

brainCloud's cross-client real-time demo for the
[brainCloud Lua SDK](https://github.com/getbraincloud/braincloud-lua), built with
[LÖVE](https://love2d.org) 11.4+. Players join a lobby, the room server launches, and everyone's
cursors, shockwaves and paint splotches are synced over brainCloud Relay. It plays in the same
lobby as the C++, C#, Java, JavaScript and Godot CursorParty clients.

What it uses:

- **REST**: universal login, player name, global properties (`Colours`, `AllLobbyTypes`,
  `SplotchDuration`), the `PostMatchResults` cloud script and leaderboards.
- **RTT**: lobby events, lobby chat (signals) and global chat.
- **Lobbies + Room Server**: find-or-create with optional region ping data, ready/start,
  `ROOM_READY` → relay.
- **Relay**: WebSocket, secure WebSocket, TCP or UDP; reliable/ordered/channel settings;
  live relay ping.

Behaviour follows the C++ CursorParty reference: shockwaves always go to every other player
(no per-player mask, so everyone scores the same canvas), the 90-second match / results /
leaderboard flow only runs for `CursorParty*` lobby types, `game_start` carries the host's
round number, and the host starts the next round when everyone has queued (or after 45s).

## 1. Get the pieces

1. Install [LÖVE](https://love2d.org) 11.4 or newer. On macOS, put `love.app` in
   `/Applications` (or `~/Applications`); on Windows, use the installer.
2. Clone this repo. This folder ships everything else:
   - `braincloud/` — the brainCloud Lua SDK 6.1.0, including its native pack (third-party
     licenses in `THIRD_PARTY_NOTICES.md`).
   - `.braincloud/braincloud-setup.love` — the brainCloud Setup plugin (see step 3). The
     folder starts with a dot, so it's hidden in Finder (⌘⇧. shows it) and `ls` (use `ls -a`).
     It isn't part of your game build.

To move to another SDK version, replace `braincloud/` (and `.braincloud/` from the release's
`tools/`) with the ones from that
[SDK release](https://github.com/getbraincloud/braincloud-lua/releases).

## 2. Open the project

LÖVE is only a runtime — there's no LÖVE editor or project file. A LÖVE game is a folder
with a `main.lua`, and you work on it in a code editor.

- **VS Code (recommended):** open `RelayTestApp.code-workspace` in this folder (File → Open
  Workspace from File…). It comes with tasks for running the game and the brainCloud setup
  plugin. When VS Code offers the recommended **Lua** extension, install it for LÖVE and
  brainCloud autocomplete.
- **Any other editor:** open this folder.

## 3. Connect it to your brainCloud app (the setup plugin)

The brainCloud Setup plugin signs you in to brainCloud, lets you pick (or create) an app, and
writes `braincloud_config.lua` into this folder. You never copy an app secret by hand.

1. Start the plugin, either way:
   - **VS Code:** Terminal → Run Task… → **brainCloud: Setup**
   - **Terminal**, from this folder: `love .braincloud/braincloud-setup.love .`
2. The setup panel opens in your browser (no extra window). If it doesn't, open the address
   printed in the terminal.
3. In the browser panel, click **Log in with brainCloud** and sign in.
4. Pick your **team**, then pick an **app** from the list (or **-- Create New App --**). The
   panel shows which app is configured and confirms `braincloud_config.lua` was written.
   Optionally open **APP CREDENTIALS** to set the server URL or app version, then **Save**.
5. Click **Done**. The plugin exits on its own.

To play against our own CursorParty clients, pick the brainCloud RelayTestApp app — the game
needs the CursorParty setup (lobby types, relay room servers, global properties).

`braincloud_config.lua` is added to `.gitignore` automatically; run the plugin again to switch
apps. **brainCloud: Refresh config** (or `luajit .braincloud/setup/cli.lua . --refresh`)
re-fetches it from your saved login without the browser — in CI, set `BRAINCLOUD_APP_ID`,
`BRAINCLOUD_BUILDER_EMAIL`, `BRAINCLOUD_BUILDER_API_KEY` and `BRAINCLOUD_TEAM_ID`.

## 4. How the game uses it (init)

`main.lua` reads that config with a single call — no app id or secret in your code:

```lua
local BrainCloud = require("braincloud")
local bc = BrainCloud.new("cursorparty")

function love.load()
	if not bc:init() then -- reads braincloud_config.lua
		print("Run the brainCloud setup plugin first")
	end
end

function love.update()
	bc:update() -- pumps networking; callbacks fire from here
end
```

`bc:init()` returns `false` (and the game shows a message) when there's no config yet. To
skip the plugin, call `bc:initialize(appId, appSecret, appVersion, serverUrl)` instead.

## 5. Run it

- **VS Code:** Terminal → Run Build Task (⌘⇧B / Ctrl+Shift+B) → **Run CursorParty**.
- **Terminal**, from this folder: `love .`
- **Finder / Explorer:** drag this folder onto LÖVE.

Start two or more copies to play together; log in with any username and password.

## Run it in a browser

The same game builds for the web with [love.js](https://github.com/Davidobot/love.js) (relay
uses secure WebSocket there). Package this folder as a `.love` without `braincloud/native/`,
run `npx love.js -c -t CursorParty CursorParty.love web`, copy
`braincloud/web/braincloud-web.js` into `web/`, and add it to `web/index.html` (see the SDK
README). Serve `web/` over http(s) — opening `index.html` from disk won't work.

## For brainCloud developers (bccm)

From the client-master repo, `node bccm syncsdk lua_relaytestapp` copies the local SDK and
the setup plugin in, `generate` writes the config for `data/relaytestapp_ids_<env>.h`,
`run -i 2` starts two clients, and `deploy` publishes a fused build to the Builds page.
`-p web` does the browser version: `build -p web` (love.js + bridge), `run -p web` (serves it at
localhost:8071 — open more tabs for more players), `deploy -p web` (apps.braincloudservers.com
`cursorparty-lua-<env>` + a Builds card).

## How it's put together

| File | What it does |
|---|---|
| `main.lua` | LÖVE entry: `bc:init()`, `bc:update()` every frame, version overlay |
| `app.lua` | The flow: login → RTT → lobby → relay → match → summary, and every brainCloud callback |
| `screens/login.lua` | Universal login, player name, global properties |
| `screens/menu.lua` | Lobby type + relay protocol, region ping option |
| `screens/lobby.lua` | Members, per-region pings, colour picker, ready/start, room status |
| `screens/game.lua` | The relay match: cursors, shockwaves, splotches, relay settings, coverage |
| `screens/summary.lua` | Results, leaderboard movement, rematch |
| `coverage.lua` | Coverage scoring, identical to the other clients |

## Wire protocol

Relay messages are JSON `{op, data}`: `move {x, y}` (0–1 board coordinates), `shockwave
{x, y, angle}`, `splotch_sync {first, splotches: [{x, y, c, a, t, o}]}`, `clear_splotches`,
`relay_ping {ping}`, `game_start {startTime, round}` and `match_result {round, first, last, e}`.
The board is 800×600 logical units; splotches are 64 units across.
