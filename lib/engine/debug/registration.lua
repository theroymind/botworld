-- Botworld's OWN debug content, registered once into the shared love-ui debug
-- toolkit (console commands, registry toggles, overlay collectors). main.lua calls
-- register_all() once from love.load (after the start layer is loaded and the
-- state-store is configured) and then consults the small accessor getters below
-- (is_fps_visible / is_tick_frozen) each frame.
--
-- Everything game-specific lives here so main.lua stays a thin wiring layer and the
-- love-ui kit stays content-free. Handlers route through the per-layer debug seams
-- (cell.debug_* / complexcell.debug_*) and NEVER poke layer state directly, so a
-- console mutation goes through the same clamp+persist path the connector uses.
-- Pure module-scope named functions (project rule: no functions-in-functions) keep
-- register_all() from closing over a forest of nested closures and tripping the
-- 60-upvalue cap.
local layers = require("lib.engine.layers")
local cell = require("lib.layers.cell")
local complexcell = require("lib.layers.complexcell")
local screenshot = require("lib.engine.screenshot")
local build_hash = require("lib.engine.build_hash")
local format = require("lib.engine.format")
local ui = require("lib.love-ui")

local console = ui.debug.console
local registry = ui.debug.registry
local overlay = ui.debug.overlay
local registry_kinds = ui.debug.registry_kinds
local registry_scopes = ui.debug.registry_scopes

local registration = {}

-- The layer-name -> debug-seam module map. active_module() looks the active layer
-- up here; a layer with no seam (e.g. solar) returns nil so commands degrade to a
-- friendly error instead of crashing.
local modules = { cell = cell, complexcell = complexcell }

-- Registry category ids (kept off the inline-literal list so the toggle definitions
-- carry named categories). These reuse the love-ui DEFAULT_CATEGORY_ORDER set
-- (perf / visualizer / world) so no registry.configure call is needed.
local CATEGORY_PERF = "perf" -- frame-time / FPS readouts
local CATEGORY_VISUALIZER = "visualizer" -- on-screen overlays/HUDs
local CATEGORY_WORLD = "world" -- sim-world behavior toggles

-- Console line colors (named so the dispatch carries no inline RGB). Errors read in
-- the threat hue family; ok confirmations in a calm neutral. RGBA literals are data,
-- not logic -- fine to inline inside these tables.
local CONSOLE_OK = { 0.7, 0.85, 0.7, 1 } -- soft green: a command landed
local CONSOLE_ERR = { 1, 0.45, 0.45, 1 } -- soft red: a command failed/was rejected

-- Module-local toggle flags the registry TOGGLE entries read/write. main.lua reads
-- show_fps + freeze_tick via the accessors below each frame; show_economy_overlay
-- is mirrored straight onto overlay.visible (no flag of its own) so the panel toggle
-- and the F3 keybind drive the exact same corner HUD.
local flags = {
  show_fps = false, -- draw love.timer.getFPS() in main.lua's draw
  freeze_tick = false, -- main.lua skips the sim tick (the live layer still animates)
}

-- ---------------------------------------------------------------------------
-- Console command helpers (module-scope named functions; small closures only).
-- ---------------------------------------------------------------------------

-- The debug-seam module for the active layer, or nil when the active layer has no
-- seam (or none is active yet). Commands guard on this and print a friendly error.
local function active_module() return modules[layers.active_name() or ""] end

-- Print a "this layer has no debug seam" error for the named command.
local function print_no_seam(command_name)
  console.print(
    command_name .. ": active layer '" .. tostring(layers.active_name()) .. "' has no debug seam",
    CONSOLE_ERR
  )
end

-- console `phase <n>`: jump to the Nth REGISTERED layer (1-based), loading it first
-- (idempotent) so an unentered phase comes up before we switch to it.
local function command_phase(args)
  local index = tonumber(args[1])
  local name = index and layers.names()[index]
  if not name then
    console.print("phase: no layer at index " .. tostring(args[1]), CONSOLE_ERR)
    return
  end
  layers.load(name)
  layers.switch(name)
  console.print("phase: switched to " .. name, CONSOLE_OK)
end

-- console `give <resource> <n>`: add n to a sim resource (biomass/energy) on the
-- active layer by reading the current value through the seam and setting current+n.
-- Only fields the active layer's seam recognises succeed; others report the error.
local function command_give(args)
  local mod = active_module()
  if not mod then
    print_no_seam("give")
    return
  end
  local resource = args[1]
  local amount = tonumber(args[2])
  if not resource or not amount then
    console.print("give: usage: give <resource> <amount>", CONSOLE_ERR)
    return
  end
  local current = mod.debug_get(resource)
  if current == nil then
    console.print("give: '" .. resource .. "' is not a field on this layer", CONSOLE_ERR)
    return
  end
  local ok, err = mod.debug_set(resource, current + amount)
  if ok then
    console.print("give: " .. resource .. " = " .. tostring(mod.debug_get(resource)), CONSOLE_OK)
  else
    console.print("give: " .. tostring(err), CONSOLE_ERR)
  end
end

-- The `trait` subcommand that lists every phase's traits instead of setting one. Named
-- so the dispatch below carries no inline literal (and so `trait list` reads as one
-- word, not a trait id that happens to be "list").
local TRAIT_LIST_SUBCOMMAND = "list"

-- console `trait list`: print every registered phase's leveled traits/stages with their
-- CURRENT levels, in phase order -- a CROSS-LAYER readout (not just the active layer), so
-- the whole progression is visible at a glance. Phases with no trait seam are skipped; a
-- registered-but-unloaded phase prints "(not loaded)" (mirrors the overlay collectors).
local function command_trait_list()
  for _, name in ipairs(layers.names()) do
    local mod = modules[name]
    if mod and mod.debug_traits then
      console.print(name .. ":")
      local rows = mod.debug_traits()
      if rows then
        for _, row in ipairs(rows) do
          console.print(string.format("  %-16s %d", row.id, row.level), CONSOLE_OK)
        end
      else
        console.print("  (not loaded)", CONSOLE_ERR)
      end
    end
  end
end

-- console `trait <id> <level>`: set a leveled trait/stage on the active layer to an
-- absolute level, printing the post-clamp readback (or the seam's error string).
-- `trait list` instead dumps every phase's current trait levels (see above).
local function command_trait(args)
  if args[1] == TRAIT_LIST_SUBCOMMAND then
    command_trait_list()
    return
  end
  local mod = active_module()
  if not mod then
    print_no_seam("trait")
    return
  end
  local id = args[1]
  local level = tonumber(args[2])
  if not id or not level then
    console.print("trait: usage: trait <id> <level>  |  trait list", CONSOLE_ERR)
    return
  end
  local ok, err = mod.debug_set(id, level)
  if ok then
    console.print("trait: " .. id .. " = " .. tostring(mod.debug_get(id)), CONSOLE_OK)
  else
    console.print("trait: " .. tostring(err), CONSOLE_ERR)
  end
end

-- console `unlock <id>`: flip a milestone unlock on the active layer. cell unlocks a
-- trait (photosynthesis/predation); complexcell brings a stage online. The two seams
-- name the op differently, so dispatch on which module is active.
local function command_unlock(args)
  local mod = active_module()
  if not mod then
    print_no_seam("unlock")
    return
  end
  local id = args[1]
  if not id then
    console.print("unlock: usage: unlock <id>", CONSOLE_ERR)
    return
  end
  local ok, err
  if mod == cell then
    ok, err = mod.debug_unlock(id)
  elseif mod == complexcell then
    ok, err = mod.debug_unlock_stage(id)
  end
  if ok then
    console.print("unlock: " .. id, CONSOLE_OK)
  else
    console.print("unlock: " .. tostring(err), CONSOLE_ERR)
  end
end

-- console `screenshot`: queue a deferred capture (fired in post_draw off the clean,
-- pre-debug-UI frame). request() returns false if one is already in flight.
local function command_screenshot()
  local queued = screenshot.request(nil, build_hash.get())
  if not queued then
    console.print("screenshot: one already in flight", CONSOLE_ERR)
    return
  end
  -- last_path() is the PREVIOUS shot until post_draw fires this one; report the
  -- queued intent now and let the print in screenshot.post_draw confirm the path.
  console.print("screenshot: queued", CONSOLE_OK)
end

-- console `save`: force the active layer to persist NOW. The seams persist on every
-- set, so a no-mutation round-trip (read a field, write the SAME value back) trips
-- the persist() write without changing any state. Uses "energy" -- present on both
-- the cell and complexcell seams.
local function command_save()
  local mod = active_module()
  if not mod then
    print_no_seam("save")
    return
  end
  -- Round-trip energy through the seam: debug_set re-applies the clamp and calls
  -- persist(), so setting energy to its current value is a pure persist trigger.
  local current = mod.debug_get("energy")
  if current == nil then
    console.print("save: no persistable field on this layer", CONSOLE_ERR)
    return
  end
  local ok, err = mod.debug_set("energy", current)
  if ok then
    console.print("saved", CONSOLE_OK)
  else
    console.print("save: " .. tostring(err), CONSOLE_ERR)
  end
end

-- ---------------------------------------------------------------------------
-- Registry toggle accessors (module-scope; the get/set closures stay one-liners).
-- ---------------------------------------------------------------------------

local function get_show_fps() return flags.show_fps end
local function set_show_fps(value) flags.show_fps = value end

-- The economy overlay toggle reads/writes overlay.visible directly (no own flag), so
-- the panel checkbox and the F3 keybind agree on the corner HUD's visibility.
local function get_show_overlay() return overlay.visible end
local function set_show_overlay(value) overlay.visible = value end

local function get_freeze_tick() return flags.freeze_tick end
local function set_freeze_tick(value) flags.freeze_tick = value end

-- ---------------------------------------------------------------------------
-- Overlay collectors (cheap, nil-safe; called once per frame while F3 is up).
-- ---------------------------------------------------------------------------

-- A single row meaning "this layer is not currently loaded".
local NOT_LOADED_ROW = { { "—", "not loaded" } }

-- Active-layer collector: one row naming the live layer.
local function collect_active_layer() return { { "active", tostring(layers.active_name()) } } end

-- Cell collector: the headline economy numbers when the cell layer is loaded, else a
-- not-loaded row. Numbers go through format.number for the same abbreviation the HUD
-- uses (1.2M etc.), keeping the overlay readable at any scale.
local function collect_cell()
  local state = cell.debug_state()
  if not state then
    return NOT_LOADED_ROW
  end
  local s = state.sim
  return {
    { "biomass", format.number(s.biomass) },
    { "energy", format.number(s.energy) },
    { "population", format.number(s.population) },
    { "toxicity", format.number(s.toxicity) },
    { "age", format.number(s.age) },
  }
end

-- Complex-cell collector: its headline numbers when loaded, else a not-loaded row.
local function collect_complexcell()
  local state = complexcell.debug_state()
  if not state then
    return NOT_LOADED_ROW
  end
  local s = state.sim
  return {
    { "energy", format.number(s.energy) },
    { "built", format.number(s.built) },
    { "mito", format.number(s.mito) },
    { "stress", format.number(s.stress) },
    { "ros", format.number(s.ros) },
  }
end

-- ---------------------------------------------------------------------------
-- One-time registration of all botworld debug content.
-- ---------------------------------------------------------------------------

-- Register every botworld console command, registry toggle, and overlay collector.
-- Idempotent-by-contract: call exactly once from love.load (the registries assert on
-- duplicate ids, so a second call would error -- that is the intended guard).
function registration.register_all()
  console.register("phase", { desc = "switch to the Nth registered layer", fn = command_phase })
  console.register(
    "give",
    { desc = "give <resource> <amount> to the active layer", fn = command_give }
  )
  console.register(
    "trait",
    {
      desc = "set <id> <level> on the active layer; `trait list` dumps all phases",
      fn = command_trait,
    }
  )
  console.register("unlock", { desc = "unlock <id> on the active layer", fn = command_unlock })
  console.register(
    "screenshot",
    { desc = "capture a clean PNG screenshot", fn = command_screenshot }
  )
  console.register("save", { desc = "force-persist the active layer", fn = command_save })

  registry.register({
    id = "show_fps",
    label = "Show FPS",
    category = CATEGORY_PERF,
    kind = registry_kinds.TOGGLE,
    scope = registry_scopes.CLIENT,
    get = get_show_fps,
    set = set_show_fps,
  })
  registry.register({
    id = "show_economy_overlay",
    label = "Economy Overlay",
    category = CATEGORY_VISUALIZER,
    kind = registry_kinds.TOGGLE,
    scope = registry_scopes.CLIENT,
    get = get_show_overlay,
    set = set_show_overlay,
  })
  registry.register({
    id = "freeze_tick",
    label = "Freeze Tick",
    category = CATEGORY_WORLD,
    kind = registry_kinds.TOGGLE,
    scope = registry_scopes.CLIENT,
    get = get_freeze_tick,
    set = set_freeze_tick,
  })

  overlay.register("active_layer", "Layer", collect_active_layer)
  overlay.register("cell", "Cell", collect_cell)
  overlay.register("complexcell", "Complex Cell", collect_complexcell)
end

-- main.lua accessors: read each frame to gate drawing/ticking on the toggle state.
function registration.is_fps_visible() return flags.show_fps end

function registration.is_tick_frozen() return flags.freeze_tick end

return registration
