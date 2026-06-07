-- Cell layer: the first playable scale -- a living micro-world. Drift a colony of
-- cells through a nutrient medium, level concrete traits, click nutrient blooms
-- to feed, and grow the colony until it can evolve. This file is the
-- ORCHESTRATOR: it owns only the wiring. It folds the pure economy core
-- (metabolism + traits + sim) into a CLOSED-FORM net growth rate -- the one
-- authoritative number that sim.tick/sim.offline run on, so idle/offline math
-- never depends on the live agents. The live world (world.lua) is a cosmetic
-- skin over that baseline, driven only in update() (never backgrounded, so
-- offline stays pure), with exactly two real couplings back to the economy:
-- a nutrient-bloom click -> sim.feed_burst, and a predator kill -> sim.threat_loss.
-- The pure modules know nothing of each other or of love.*; they meet only here.
-- Economy runs at a fixed sweet-spot base rate (no dial in the player's hands).
local save = require("lib.engine.save")
local ui = require("lib.engine.ui")
local fx = require("lib.engine.fx")
local format = require("lib.engine.format")
local metabolism = require("lib.layers.cell.metabolism")
local traits = require("lib.layers.cell.traits")
local sim = require("lib.layers.cell.sim")
local world = require("lib.layers.cell.world")
local view = require("lib.layers.cell.view")

local cell = {}

local SAVE_NAME = "cell"
local SAVE_INTERVAL = 5 -- seconds between autosaves (active layer only)
local OFFLINE_CAP = 8 * 3600 -- credit at most 8h of time away
local TOAST_SECONDS = 4

-- Closed-form economy tuning. Net rate = per-cell yield * colony factor, where
-- the colony factor scales with population but SATURATES at INCOME_POP_CAP so
-- the always-recomputed online rate can never run away (and the load-time rate
-- used offline stays a finite lump).
local ECON_POP_GAIN = 0.04 -- per-cell income contribution of each colony member
local INCOME_POP_CAP = 300 -- closed-form income saturates here

local BLOOM_SECONDS = 3 -- a fed bloom credits ~this many seconds of growth
local BLOOM_FLOOR = 8 -- ...but always at least this, so early feeds feel good

-- The metabolism dial has been removed; the economy runs at the sweet-spot base
-- rate baked in here so offline / online math never diverges.
local FIXED_TEMPO = metabolism.optimum()

local PANEL_X = 16
local PANEL_Y = 16
local PANEL_W = 320
local PANEL_H = 502
local PAD = 16
local ROW_H = 44
local BTN_W = 96
local BAR_COLOR = { 0.46, 0.92, 0.42 }

cell.state = nil

local world_state
local view_state
local save_accum = 0
local toast_text
local toast_timer = 0

-- Net biomass/sec: the authoritative closed form. Fold the fixed sweet-spot
-- tempo through metabolism, the trait stats, and the unlocked income channels
-- into a per-cell yield, then scale by the (saturating) colony size and the
-- carried evolve multiplier. The one place the modules meet.
local function net_growth(state)
  local stats = traits.stats(state.traits)
  local income = traits.income_mult(state.traits)
  local gain = metabolism.gain(FIXED_TEMPO) * stats.photo_mult * stats.forage_mult * income
  local loss = metabolism.loss(FIXED_TEMPO) * stats.upkeep_mult
  local per_cell = (gain - loss) * stats.yield_mult
  local pop = math.min(state.sim.population, INCOME_POP_CAP)
  local colony = 1 + ECON_POP_GAIN * pop
  return per_cell * colony * state.sim.evolve_mult
end

local function target_population(state)
  return math.min(state.sim.population, world.MAX_AGENTS)
end

local function in_panel(x, y)
  return x >= PANEL_X and x < PANEL_X + PANEL_W and y >= PANEL_Y and y < PANEL_Y + PANEL_H
end

local function set_toast(text)
  toast_text = text
  toast_timer = TOAST_SECONDS
end

local function persist()
  save.write(SAVE_NAME, {
    traits = traits.serialize(cell.state.traits),
    sim = sim.serialize(cell.state.sim),
    stamp = os.time(),
    -- legacy `genome` and `dial` keys (old systems) are intentionally not written.
  })
end

-- Feed a nutrient bloom: credit a biomass burst (scaled by digestion + a few
-- seconds of the live net rate), scatter motes for the cells to chase, and play
-- a GENTLE feedback beat -- a brief flash, a small shake, and a ripple at the
-- bloom -- composed from reusable fx effect entities spawned onto the view.
local function feed_bloom(b)
  local stats = traits.stats(cell.state.traits)
  local amount = math.max(net_growth(cell.state) * BLOOM_SECONDS, BLOOM_FLOOR) * stats.feed_rate
  sim.feed_burst(cell.state.sim, amount)
  world.add_food_burst(world_state, b.x, b.y)
  view.spawn(view_state, fx.pulse({ x = b.x, y = b.y }))
  view.spawn(view_state, fx.flash({ color = { 0.6, 1.0, 0.7 }, alpha = 0.18, life = 0.2 }))
  view.spawn(view_state, fx.shake({ mag = 4, life = 0.26, seed = b.x + b.y }))
end

-- Fire any colony milestones the population has reached (auto-unlocks). Each
-- opens a closed-form income channel and tells the world to add its contents.
local function check_unlocks()
  local pop = cell.state.sim.population
  for _, def in ipairs(traits.unlocks()) do
    if pop >= def.pop and not traits.is_unlocked(cell.state.traits, def.id) then
      local fired = traits.unlock(cell.state.traits, def.id)
      if fired then
        set_toast(string.format("Unlocked %s — %s", fired.label, fired.tell))
        persist()
      end
    end
  end
end

local function evolve()
  local snapshot = world.snapshot(world_state)
  local mult = sim.evolve(cell.state.sim)
  if not mult then
    return
  end
  -- Prestige reset: a fresh lineage carrying only the net multiplier; the swarm
  -- fuses to one body (the multicellular beat) and refills from scratch.
  cell.state.traits = traits.new()
  -- Fuse to the center of the NEW founder field (in world coords, not screen
  -- coords), so the fusion beat lands where the camera re-zooms after evolve.
  local win_w, win_h = love.graphics.getDimensions()
  local aspect = win_w / math.max(win_h, 1)
  local cx = world.BASE_FIELD / 2
  local cy = (world.BASE_FIELD / aspect) / 2
  view.fuse(view_state, snapshot, cx, cy)
  set_toast(string.format("Evolved! net x%.2f carried into a fresh lineage", mult))
  persist()
end

function cell.load()
  local data = save.read(SAVE_NAME) or {}
  cell.state = {
    traits = traits.load(data.traits),
    sim = sim.load(data.sim),
  }
  view_state = view.new()
  local width, height = 1280, 720
  if love and love.graphics then
    width, height = love.graphics.getDimensions()
  end
  world_state = world.new({
    rng = function()
      return love.math.random()
    end,
    aspect = width / height,
  })

  -- Offline catch-up from a wall-clock stamp (closed-form rate only -- no
  -- predators, no agent dependency). Swallow the division pulses; the live
  -- swarm rebuilds from population and fills in smoothly on its own.
  if type(data.stamp) == "number" then
    local seconds = math.min(os.time() - data.stamp, OFFLINE_CAP)
    if seconds > 0 then
      sim.offline(cell.state.sim, seconds, net_growth(cell.state))
      sim.take_divisions(cell.state.sim)
    end
  end
end

-- Fixed sim tick (runs even while backgrounded). Pure sim: no love.*, no world.
function cell.tick(tick_dt)
  if not cell.state then
    return
  end
  sim.tick(cell.state.sim, tick_dt, net_growth(cell.state))
end

function cell.update(dt)
  local width, height = love.graphics.getDimensions()
  local aspect = width / height

  local predation = traits.is_unlocked(cell.state.traits, "predation")
  local killed = world.update(world_state, dt, {
    stats = traits.stats(cell.state.traits),
    dial_tempo = FIXED_TEMPO,
    aspect = aspect,
    target_population = target_population(cell.state),
    unlocked = traits.unlocked_set(cell.state.traits),
    threats_enabled = predation,
  })
  -- A live kill debits one cell's worth of biomass (scare, not a setback: the
  -- always-positive baseline heals it and the colony regrows the lost cell).
  if killed > 0 then
    local s = cell.state.sim
    local per_cell = s.biomass / math.max(s.population, 1)
    sim.threat_loss(s, per_cell * killed)
  end

  check_unlocks()
  sim.take_divisions(cell.state.sim) -- drain; the swarm reconciles off population
  view.update(view_state, dt)

  if toast_timer > 0 then
    toast_timer = toast_timer - dt
  end

  save_accum = save_accum + dt
  if save_accum >= SAVE_INTERVAL then
    save_accum = 0
    persist()
  end
end

local function draw_bar(x, y, w, h, fraction)
  love.graphics.setColor(1, 1, 1, 0.12)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3], 0.85)
  love.graphics.rectangle("fill", x, y, w * fraction, h)
  love.graphics.setColor(1, 1, 1, 0.3)
  love.graphics.rectangle("line", x, y, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- One trait row: label + concrete hint + level on the left, a level-up button
-- (or a locked notice) on the right. Returns the next y.
local function draw_trait_row(state, id, x, y, inner_w)
  local def = traits.def(id)
  local level = state.traits.levels[id]
  local available = traits.is_available(state.traits, id)
  ui.label(x, y + 3, string.format("%s   Lv %d", def.label, level), { alpha = available and 0.95 or 0.4 })
  ui.label(x, y + 22, traits.hint(id), { alpha = available and 0.5 or 0.3 })

  local bx = x + inner_w - BTN_W
  if available then
    local cost = traits.cost(state.traits, id)
    local affordable = sim.can_spend(state.sim, cost)
    if ui.button(bx, y, BTN_W, 38, "level up", { sublabel = format.number(cost), enabled = affordable }) then
      if sim.spend(state.sim, cost) then
        traits.level(state.traits, id)
        persist()
      end
    end
  else
    local need = nil
    for _, u in ipairs(traits.unlocks()) do
      if u.id == def.locked_until then
        need = u.pop
      end
    end
    ui.label(bx, y + 10, string.format("colony %d", need or 0), { width = BTN_W, align = "center", alpha = 0.35 })
  end
  return y + ROW_H
end

local function draw_panel(state, width)
  local x = PANEL_X + PAD
  local inner_w = PANEL_W - 2 * PAD
  local y = PANEL_Y + PAD
  ui.panel(PANEL_X, PANEL_Y, PANEL_W, PANEL_H)

  local net = net_growth(state)
  ui.label(x, y, "biomass  " .. format.number(state.sim.biomass), { scale = 1.4 })
  y = y + 30
  ui.label(x, y, string.format("net  %s /s", format.number(net)), { alpha = 0.85 })
  y = y + 20

  ui.label(
    x,
    y,
    string.format("colony  %d / %d", state.sim.population, sim.maturity_pop_target()),
    { alpha = 0.85 }
  )
  y = y + 18
  ui.label(
    x,
    y,
    string.format("division  %s /min", format.number(sim.division_rate(net, state.sim.population) * 60)),
    { alpha = 0.6 }
  )
  y = y + 18
  if state.sim.generation > 0 then
    ui.label(
      x,
      y,
      string.format("generation %d   net x%.2f", state.sim.generation, state.sim.evolve_mult),
      { alpha = 0.6 }
    )
  end
  y = y + 26

  -- Trait list: concrete, direct levels. No slots, no splicing.
  ui.label(x, y, "traits", { alpha = 0.7 })
  y = y + 20
  for _, id in ipairs({ "photosynthesis", "motility", "sensing", "digestion", "membrane" }) do
    y = draw_trait_row(state, id, x, y, inner_w)
  end
  y = y + 4

  -- Next milestone (auto-unlocks on its own as the colony grows).
  local nxt = traits.next_unlock(state.traits)
  if nxt then
    ui.label(x, y, string.format("next: %s at colony %d", nxt.label, nxt.pop), { alpha = 0.6 })
  else
    ui.label(x, y, "all capabilities evolved", { alpha = 0.45 })
  end
  y = y + 24

  -- Maturity gate -> evolve.
  ui.label(x, y, string.format("maturity  %d%%", math.floor(state.sim.maturity * 100 + 0.5)), { alpha = 0.85 })
  y = y + 18
  draw_bar(x, y, inner_w, 14, state.sim.maturity)
  y = y + 24
  local evolve_opts = { enabled = sim.can_evolve(state.sim), sublabel = "fuse · carry net x1.5" }
  if ui.button(x, y, inner_w, 44, "evolve", evolve_opts) then
    evolve()
  end

  ui.label(
    0,
    love.graphics.getHeight() - 44,
    "click a nutrient bloom to feed   ·   level traits   ·   grow the colony to evolve   ·   [r] new lineage",
    { width = width, align = "center", alpha = 0.4 }
  )
end

local function draw_toast(width)
  if toast_timer <= 0 or not toast_text then
    return
  end
  local alpha = math.min(toast_timer, 1)
  ui.label(0, 40, toast_text, { width = width, align = "center", alpha = alpha })
end

function cell.draw()
  local state = cell.state
  local width = love.graphics.getWidth()
  ui.begin_frame()

  view.draw_world(view_state, world.snapshot(world_state))

  draw_panel(state, width)

  -- A click the widgets didn't take, outside the panel, feeds a nutrient bloom
  -- if it landed on one (the blooms are the feed -- nothing else is clickable).
  -- in_panel is kept in screen space; the bloom hit-test is in world space.
  local cx, cy = ui.consume_click()
  if cx and not in_panel(cx, cy) then
    local wx, wy = view.screen_to_world(view_state, cx, cy)
    local b = world.hit_bloom(world_state, wx, wy)
    if b then
      feed_bloom(b)
    end
  end

  draw_toast(width)
  ui.end_frame()
end

function cell.keypressed(key)
  if key == "e" then
    evolve()
  elseif key == "space" then
    local b = world.any_bloom(world_state)
    if b then
      world.hit_bloom(world_state, b.x, b.y)
      feed_bloom(b)
    end
  elseif key == "r" then
    -- New lineage: wipe the save and reload a fresh single founder. The escape
    -- hatch from a stale grown colony restored off an old save -- instant fresh
    -- start, the true ~20-30s solo-cell open.
    save.remove(SAVE_NAME)
    cell.load()
  end
end

function cell.mousepressed(x, y, button)
  ui.mousepressed(x, y, button)
end

return cell
