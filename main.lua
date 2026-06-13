-- Thin entry point: a fixed-timestep clock ticks every registered layer (so
-- backgrounded scales keep producing) while only the active layer gets
-- per-frame updates, drawing, and input. Tab cycles layers, esc quits.
local clock = require("lib.engine.clock")
-- Color facade FIRST among UI-touching requires: requiring it runs colors.apply()
-- on the love-ui theme, so every botworld override (colors.game, the teal/green
-- ordinal tokens, ...) is in place before any layer or library module captures a
-- token or draws a frame.
local colors = require("lib.engine.colors")
assert(colors.game, "color facade must expose the game namespace")
local layers = require("lib.engine.layers")
local touch = require("lib.engine.touch")
local music = require("lib.engine.music")
local cell = require("lib.layers.cell")
local complexcell = require("lib.layers.complexcell")
local solar = require("lib.layers.solar")
-- Debug + automation stack: the shared love-ui debug toolkit (console/overlay/panel/
-- state-store), botworld's screenshot + build-hash modules, the opt-in JSON-over-TCP
-- agent connector, and the registration module that loads botworld's OWN debug content
-- into the toolkit. json is the codec the state-store + connector speak.
local json = require("lib.engine.json")
local screenshot = require("lib.engine.screenshot")
local build_hash = require("lib.engine.build_hash")
local registration = require("lib.engine.debug.registration")
local controller_factory = require("tools.automation.controller")
local ui = require("lib.love-ui")
local console = ui.debug.console
local overlay = ui.debug.overlay
local panel = ui.debug.panel
local registry = ui.debug.registry
local registry_kinds = ui.debug.registry_kinds
local state_store = ui.debug.state_store

-- The boot/phase-1 BGM volume. Named here (not buried in the track) because the
-- phase-2 stems match it -- see lib/engine/music.lua + complexcell's layered intro.
local BGM_VOLUME = 0.75

-- The opt-in agent connector instance (nil unless `--automation` is on the command
-- line). Every connector call site no-ops when this is nil, so the flag is the only
-- thing that turns the JSON-over-TCP server on.
local automation = nil

-- Bottom-right inset for the build-hash stamp: wide enough to clear the longest form
-- ("<md5-8>-<gitsha>", ~17 chars at the HUD font) so the stamp never runs off-screen.
local BUILD_HASH_MARGIN = 150
-- The build-hash stamp's distance up from the window bottom (matches the HUD line).
local BUILD_HASH_BOTTOM = 22
-- The debug economy overlay's panel width (love-ui overlay PANEL_WIDTH is 180); we
-- inset it from the right edge by this so the corner HUD sits flush top-right.
local OVERLAY_PANEL_W = 180
-- Right-edge gap for the overlay. The kit insets its content a few px inside the
-- (x, y) we pass, so without this margin the panel's right edge runs off-screen.
local OVERLAY_MARGIN = 8
-- Top-left inset for the optional FPS readout (clears the HUD/edge, stays unobtrusive).
local FPS_INSET = 10

-- Pick the layer to boot into from the command line, so `love . phase2` (or a
-- literal layer name like `love . complexcell`) jumps straight there for debugging.
-- `phaseN` maps to the Nth REGISTERED layer (1-based), so it tracks registration
-- order as phases are added -- no hardcoded phase->name table to keep in sync.
-- Defaults to the first layer (phase 1) when no/unknown arg is given.
local function resolve_start_layer(args)
  local names = layers.names()
  for _, tok in ipairs(args or {}) do
    tok = tostring(tok):lower()
    local n = tok:match("^phase(%d+)$")
    if n and names[tonumber(n)] then
      return names[tonumber(n)]
    end
    for _, name in ipairs(names) do
      if name:lower() == tok then
        return name
      end
    end
  end
  return names[1]
end

-- True when `--automation` is present in the command-line args. The connector binds a
-- localhost port only when this flag is on; absent, the whole automation path no-ops.
local function wants_automation(args)
  for _, tok in ipairs(args or {}) do
    if tostring(tok) == "--automation" then
      return true
    end
  end
  return false
end

function love.load(arg)
  love.graphics.setBackgroundColor(0, 0, 0)
  -- Per-launch source fingerprint, computed once: stamps screenshots + the HUD so a
  -- shot traces back to the exact source (even with uncommitted edits). Must run before
  -- any screenshot can be requested.
  build_hash.compute()
  -- Phase-1 BGM, loaded but NOT yet played: which track sounds depends on the start
  -- layer (the phase-2 stems are loaded by complexcell.load below).
  music.load("bgm", "assets/music/botworld.ogg")
  layers.register("cell", cell)
  layers.register("complexcell", complexcell)
  layers.register("solar", solar)
  -- Load ONLY the phase we boot into. A phase you haven't reached must never load or
  -- tick (else it produces -- and leaks toasts -- in the background behind the active
  -- phase); each later phase loads when it is first entered (the seam loads phase 2).
  local start = resolve_start_layer(arg)
  layers.load(start)
  layers.switch(start)
  -- Score the boot layer. Booting STRAIGHT into phase 2 for debugging (`love . phase2`)
  -- skips the endosymbiosis seam that normally hands off the music, so the phase-1 BGM
  -- must never start (otherwise it blips before any pause) -- bring up the complex-cell
  -- layers directly. Any other start layer plays the phase-1 BGM.
  if start == "complexcell" and complexcell.start_layered_music then
    complexcell.start_layered_music()
  else
    music.play("bgm", BGM_VOLUME)
  end
  -- Debug toolkit wiring (after layers are up so collectors can read live state):
  -- hand the state-store botworld's JSON codec, load any persisted toggle values,
  -- register botworld's debug content, then replay the saved toggles onto it.
  state_store.configure({ codec = { encode = json.encode, decode = json.decode } })
  state_store.load()
  registration.register_all()
  state_store.apply_to_registry(registry, registry_kinds)
  -- Opt-in agent connector: bind localhost only under `--automation` and hand it the
  -- game context (layers, the two seam modules, screenshot, the live console so
  -- console_exec works, and the clock). nil otherwise -> every connector call no-ops.
  if wants_automation(arg) then
    automation = controller_factory()
    local port = automation:start()
    print("automation: 127.0.0.1:" .. port)
    automation:set_game_context({
      layers = layers,
      modules = { cell = cell, complexcell = complexcell },
      screenshot = screenshot,
      console = console,
      clock = clock,
    })
  end
  -- Pinch-to-zoom on touch screens; taps/drags arrive via mouse emulation.
  touch.init(function(dy) layers.wheelmoved(0, dy) end)
end

function love.update(dt)
  -- Gate the authoritative sim on the freeze_tick toggle: when frozen, the economy
  -- stops advancing but the active layer still gets layers.update so its live world
  -- keeps animating (the freeze is a sim pause, not a render pause).
  if not registration.is_tick_frozen() then
    clock.update(dt, layers.tick_all)
  end
  layers.update(dt)
  music.update(dt)
  -- Drives the state-store debounce flush (panel.update calls state_store.update
  -- internally -- do NOT also call state_store.update, that double-counts the timer).
  panel.update(dt)
  if automation then
    automation:update(dt)
  end
end

function love.draw()
  -- Game world + game HUD first (the screenshot below captures exactly this).
  layers.draw()
  love.graphics.setColor(1, 1, 1, 0.7)
  local hud = string.format("layer  %s   [tab] switch layer   [esc] quit", layers.active_name())
  love.graphics.print(hud, 10, love.graphics.getHeight() - 22)
  -- Build-hash stamp, bottom-right. The module owns the string; we own color + spot.
  love.graphics.setColor(1, 1, 1, 0.7)
  build_hash.draw(
    love.graphics.getWidth() - BUILD_HASH_MARGIN,
    love.graphics.getHeight() - BUILD_HASH_BOTTOM
  )
  love.graphics.setColor(1, 1, 1, 1)
  -- Optional FPS readout (perf toggle), top-left and unobtrusive.
  if registration.is_fps_visible() then
    love.graphics.setColor(1, 1, 1, 0.7)
    love.graphics.print("fps " .. love.timer.getFPS(), FPS_INSET, FPS_INSET)
    love.graphics.setColor(1, 1, 1, 1)
  end
  -- Fire the deferred screenshot HERE -- after the game world + game HUD + build-hash
  -- stamp, but BEFORE the debug overlay/panel/console -- so a capture is a CLEAN frame
  -- with no debug UI in the shot. (The connector drains via screenshot.is_pending(),
  -- so this single call also serves automation; no separate automation:post_draw.)
  screenshot.post_draw()
  -- Debug layer LAST, on top of everything and out of the screenshot. Full window
  -- height as the viewport so the overlay uses the whole right column before scrolling.
  overlay.draw(
    love.graphics.getWidth() - OVERLAY_PANEL_W - OVERLAY_MARGIN,
    0,
    love.graphics.getHeight()
  )
  panel.draw()
  console.draw()
end

-- The layer after the active one in registration order, wrapping.
local function next_layer_name()
  local names = layers.names()
  for i = 1, #names do
    if names[i] == layers.active_name() then
      return names[i % #names + 1]
    end
  end
  return names[1]
end

-- The debug-console toggle key (backtick / grave). Named so the gate carries no inline
-- key literal; it is swallowed by console.textinput so it never types into the input.
local CONSOLE_KEY = "`"
-- Debug toolkit keybinds: F3 corner economy overlay, F4 the debug panel, F12 a clean
-- screenshot. Named off the inline-literal list (these are dispatch keys, not display).
local OVERLAY_KEY = "f3"
local PANEL_KEY = "f4"
local SCREENSHOT_KEY = "f12"

function love.keypressed(key)
  -- Debug UI gets first crack, in a fixed order: the toggle keys flip a tool, then an
  -- OPEN console / VISIBLE panel swallows the rest of the keystrokes, then the game.
  if key == CONSOLE_KEY then
    console.toggle()
    return
  end
  if key == OVERLAY_KEY then
    overlay.toggle()
    return
  end
  if key == PANEL_KEY then
    panel.toggle()
    return
  end
  if key == SCREENSHOT_KEY then
    screenshot.request(nil, build_hash.get())
    return
  end
  if console.open then
    console.keypressed(key)
    return
  end
  if panel.is_visible() and panel.keypressed(key) then
    return
  end
  if key == "tab" then
    -- Debug cycler: bring the target phase up on first visit (idempotent), since phases
    -- are no longer all loaded at boot -- otherwise tabbing to an unentered phase would
    -- draw an unloaded layer.
    local nxt = next_layer_name()
    layers.load(nxt)
    layers.switch(nxt)
  elseif key == "escape" then
    love.event.quit()
  else
    layers.keypressed(key)
  end
end

-- Text entry routes to the open console / visible panel search field; the game has no
-- text input of its own, so when neither debug tool wants it the event is dropped.
function love.textinput(text)
  if console.open then
    console.textinput(text)
    return
  end
  if panel.is_visible() and panel.textinput(text) then
    return
  end
end

function love.mousepressed(x, y, button)
  if panel.is_visible() and panel.mousepressed(x, y, button) then
    return
  end
  layers.mousepressed(x, y, button)
end

function love.mousemoved(x, y, dx, dy) layers.mousemoved(x, y, dx, dy) end

function love.wheelmoved(dx, dy)
  if console.open then
    console.wheelmoved(dy)
    return
  end
  if panel.is_visible() and panel.wheelmoved(dy) then
    return
  end
  -- The overlay self-gates on the cursor (returns false unless the pointer is over
  -- the HUD), so a miss falls through to the layer's zoom unchanged.
  if overlay.visible and overlay.wheelmoved(dy) then
    return
  end
  layers.wheelmoved(dx, dy)
end

function love.touchpressed(id, x, y) touch.pressed(id, x, y) end

function love.touchmoved(id, x, y) touch.moved(id, x, y) end

function love.touchreleased(id) touch.released(id) end
