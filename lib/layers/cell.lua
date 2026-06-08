-- Cell layer: the first playable scale -- a living micro-world. Drift a colony of
-- cells through a nutrient medium, level concrete traits, click nutrient blooms to
-- feed the reserve, and grow the colony toward its carrying capacity. This file is
-- the ORCHESTRATOR: it owns only the wiring. It folds the pure economy core
-- (metabolism + traits + organelles) into an INTAKE table -- the photosynthesis
-- light, the per-cell foraging and its finite-food saturation, the per-cell
-- upkeep, and the overall multiplier -- which sim.tick/sim.offline run the shared
-- economy step on, so idle/offline math never depends on the live agents. The live
-- world (world.lua) is a cosmetic skin over that baseline, driven only in update()
-- (never backgrounded, so offline stays pure), with exactly THREE real couplings
-- back to the economy: a nutrient-bloom click -> sim.feed_burst, a predator kill
-- -> sim.kill, and a rare prey engulf -> keep an organelle (organelles.acquire +
-- the intake fold). The pure modules know nothing of each other or of love.*; they
-- meet only here. Economy runs at a fixed sweet-spot base rate (no dial).
local save = require("lib.engine.save")
local fx = require("lib.engine.fx")
local sound = require("lib.engine.sound")
local format = require("lib.engine.format")
local metabolism = require("lib.layers.cell.metabolism")
local traits = require("lib.layers.cell.traits")
local sim = require("lib.layers.cell.sim")
local organelles = require("lib.layers.cell.organelles")
local world = require("lib.layers.cell.world")
local view = require("lib.layers.cell.view")
local transition = require("lib.layers.cell.transition")
-- Phase-2 seam: the endosymbiosis finale no longer restarts phase 1 -- it zooms
-- INTO the cell and hands off to the complex-cell layer (see begin_lineage_transition).
local layers = require("lib.engine.layers")
local complexcell = require("lib.layers.complexcell")

-- Canonical UI kit (lib/engine/ui): retained-mode layout tree + renderer, themed
-- primitives, fonts, interaction. The panel below is a declarative node tree.
local ui = require("lib.engine.ui")
local layout = ui.layout
local renderer = ui.renderer
local primitives = ui.primitives
local colors = ui.colors
local theme = ui.theme
local interaction = ui.interaction
local tween = ui.tween
local rect = ui.primitives.rect
local text = ui.primitives.text
local button = ui.primitives.button

local cell = {}

local SAVE_NAME = "cell"
local SAVE_INTERVAL = 5 -- seconds between autosaves (active layer only)
local OFFLINE_CAP = 8 * 3600 -- credit at most 8h of time away
-- DEV: ignore any existing save on boot, so every launch starts a fresh lineage
-- (a single founder cell) -- resume + offline catch-up kept getting in the way
-- while tuning. Autosaves still write during play (harmlessly unread). Flip to
-- false to restore the real idle behaviour: resume the saved colony and credit
-- up to OFFLINE_CAP of away-time growth.
local DEV_FRESH_START = true
local TOAST_SECONDS = 4

-- Economy intake tuning (folded into sim's intake table). The colony forages
-- ambient motes per cell, but the food supply SATURATES past FORAGE_CAP cells --
-- the finite carrying capacity that makes a colony outgrow its food and starve.
-- Photosynthesis (unlocked at colony 5) opens a flat light income; predation and
-- the organelles lift the cap further.
local FORAGE_CAP = 5 -- foraging income saturates past this many cells (carrying cap)
local UPKEEP_SCALE = 1.3 -- per-cell upkeep multiplier (lowers K, slows growth, sharpens deficit)
local PHOTO_LIGHT = 30 -- flat light income once photosynthesis is unlocked (x photo_mult)
-- OPEN-ENDED COMPOUNDING growth. Each cell adds a tiny per-cell income that does
-- NOT saturate, so income scales with the colony and population climbs
-- exponentially WITHOUT BOUND -- no carrying-capacity wall and no hard population
-- cap. GROWTH_RATE is the net compounding surplus per cell (x the
-- income mult) -- the master pacing knob: higher = a steeper climb, sooner to the
-- millions. It's added ON TOP of foraging exactly covering upkeep, so the colony
-- never starves under it. Phase 1 is a ~5-minute sprint: at 0.1 the colony rockets
-- past a million cells in well under 5 min. Validate with `lua tools/sim_lab.lua growth`.
local GROWTH_RATE = 0.1

-- Endosymbiosis (phase 1's climax) is an RNG event possible at ANY colony size, but
-- the per-engulf chance starts vanishingly small and only begins to RAMP once the
-- colony crosses ENDO_RAMP_START cells, then climbs by ENDO_RAMP_PER_STEP for every
-- further ENDO_STEP cells -- so an early keep is *possible* but statistically very
-- rare, and the run almost always resolves once the colony is well into the millions.
-- ENDO_BASE_CHANCE is the floor below the ramp start (tiny, never zero); clamped to 1.
-- Tuned harder than the first pass (a smaller floor + gentler ramp) so the proc no
-- longer lands too soon; the ramp deliberately starts at the first 100k milestone.
local ENDO_RAMP_START = 100000 -- no ramp below this colony size -- just the floor
local ENDO_STEP = 100000 -- past the start, the chance ramps once per this many cells
local ENDO_BASE_CHANCE = 0.000004 -- per-engulf floor before the ramp (possible but very rare)
local ENDO_RAMP_PER_STEP = 0.0006 -- added to the chance per ENDO_STEP cells past the ramp start
local FEED_ENERGY = 40 -- nutrient reserve a bloom feed credits

-- The metabolism dial has been removed; the economy runs at the sweet-spot base
-- rate baked in here so offline / online math never diverges.
local FIXED_TEMPO = metabolism.optimum()

local PANEL_MARGIN = 16 -- gap from the window edge (panel x is computed each frame)
local PANEL_Y = 16
local PANEL_W = 320
local PANEL_H = 502
local PAD = 16
local BTN_W = 96 -- fixed-width trait button, pinned right by the fill label column
local TRAIT_BTN_H = 40
local BAR_COLOR = colors.secondary -- energy bar rides the global nourishment token

cell.state = nil

local world_state
local view_state
local save_accum = 0
local toast_text
local toast_timer = 0
-- The end-of-phase-1 transition cinematic (armed by the endosymbiosis proc).
-- While active the orchestrator FREEZES the live sim and hands the frame to it.
local transition_state = transition.new()
-- Once the endosymbiosis finale hands off into phase 2, phase 1 is RETIRED: its
-- final metrics are snapshotted into the carry and its sim is frozen, so the colony
-- you left behind becomes a fixed statistic instead of quietly ticking on in the
-- background. Reset on a fresh load ([r] / boot) so a new lineage runs normally.
local retired = false

-- The INTAKE fold: the one place the pure modules meet. Assemble the table the
-- sim's shared economy step runs on -- the photosynthesis light (opened by the
-- unlock, lifted by the trait and the chloroplast), the per-cell foraging and its
-- finite-food saturation, the per-cell upkeep (shrunk by evasion), and the
-- overall multiplier (yield x unlocked income channels x the organelle boost).
-- Recomputed wherever the economy is run; never depends on the live swarm.
local function intake_for(state)
  local stats = traits.stats(state.traits)
  local set = state.sim.organelles
  local photo = 0
  if traits.is_unlocked(state.traits, "photosynthesis") then
    photo = PHOTO_LIGHT * stats.photo_mult
  end
  photo = photo + organelles.photo_bonus(set)
  local upkeep = metabolism.loss(FIXED_TEMPO) * stats.upkeep_mult * UPKEEP_SCALE
  local mult = traits.income_mult(state.traits) * organelles.intake_mult(set)
  -- Compounding income per cell: enough to cover its own upkeep (upkeep/mult) plus
  -- the GROWTH_RATE surplus, so the net per-cell contribution is GROWTH_RATE x mult
  -- -- a small positive that compounds the colony exponentially. Scaling the
  -- surplus by mult means unlocks/organelles also steepen the climb.
  local growth_per_cell = upkeep / mult + GROWTH_RATE
  return {
    photo = photo,
    forage_per_cell = metabolism.gain(FIXED_TEMPO) * stats.forage_mult,
    forage_cap = FORAGE_CAP * stats.forage_cap_mult, -- reach synergy lifts the saturation cap
    upkeep_per_cell = upkeep,
    growth_per_cell = growth_per_cell, -- the open-ended compounding channel (-> millions)
    mult = mult,
    div_mult = stats.div_mult, -- digestion: < 1 cheapens every division
  }
end

-- The drawn swarm is a logarithmic SAMPLE of the (now millions-scale) colony, so
-- the dish keeps visibly filling without ever becoming an unreadable blur. The
-- mapping + its tuning knobs live in world.sample_count.
local function target_population(state) return world.sample_count(state.sim.population) end

-- The panel hugs its content and rides the RIGHT edge: cell.draw stamps the
-- resolved tree height and the frame's computed left x here so the hit-test region
-- matches the themed backing exactly (PANEL_H / right-edge x are the pre-draw
-- fallbacks for a mousepressed that lands before the first draw).
cell._panel_h = PANEL_H
cell._panel_x = PANEL_MARGIN

local function in_panel(x, y)
  return x >= cell._panel_x
    and x < cell._panel_x + PANEL_W
    and y >= PANEL_Y
    and y < PANEL_Y + cell._panel_h
end

local function set_toast(message)
  toast_text = message
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

-- Feed a nutrient bloom: credit the energy reserve -- the burst the colony spends
-- on divisions -- scatter motes for the cells to chase, and play a GENTLE feedback
-- beat (a brief flash, a small shake, a ripple at the bloom) composed from
-- reusable fx effect entities spawned onto the view.
local function feed_bloom(b)
  -- Pentatonic pitch set (root, 2nd, 3rd, 5th, 6th): every variation stays
  -- consonant with the Cmaj BGM, where free jitter would read as detuned.
  sound.play("bloom", { volume = 0.9, pitches = { 1.0, 9 / 8, 5 / 4, 3 / 2, 5 / 3 } })
  sim.feed_burst(cell.state.sim, FEED_ENERGY)
  world.add_food_burst(world_state, b.x, b.y)
  view.spawn(view_state, fx.pulse({ x = b.x, y = b.y }))
  view.spawn(view_state, fx.flash({ color = colors.secondary_bright, alpha = 0.18, life = 0.2 }))
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

-- Arm the end-of-phase-1 transition cinematic on the cell at (cx, cy) -- the one
-- whose engulf triggered endosymbiosis, the culminating beat of the cell layer.
-- The timeline owns the clock and the overlay; we bind its three side effects
-- here: the camera push-in onto the cell, the build-up/detonation shakes, and -- at
-- the white peak -- the HAND-OFF INTO PHASE 2. Instead of restarting phase 1, the
-- reset punches through the white-out into the cytoplasm: the engulfed bacterium
-- becomes the first mitochondrion, the colony carries forward as a single statistic,
-- and we switch to the complex-cell layer. The colony population is captured NOW
-- (before the reset fires) so it survives the cinematic. base_zoom is captured NOW
-- so the focus pushes in relative to the camera's current settled fit.
local function begin_lineage_transition(cx, cy)
  local base_zoom = view_state.camera.zoom
  -- Snapshot phase 1's final metrics NOW (before the reset) -- the figures the
  -- colony "becomes" as a single statistic carried into phase 2.
  local stats = {
    colony = cell.state.sim.population,
    divisions = cell.state.sim.total_divisions,
    biomass = cell.state.sim.biomass,
    organelles = #organelles.acquired_list(cell.state.sim.organelles),
  }
  transition.begin(transition_state, {
    x = cx,
    y = cy,
    -- Phase-2 seam text: the zoom-into-the-cell, not a fresh soup.
    title = "A CELL WITHIN A CELL",
    kicker = "endosymbiosis",
    subtitle = "zoom in",
    on_focus = function(x, y, mult) view.focus(view_state, x, y, base_zoom * mult) end,
    on_shake = function(mag, life, seed)
      view.spawn(view_state, fx.shake({ mag = mag, life = life, seed = seed }))
    end,
    on_reset = function()
      -- Cross the seam into phase 2: initialize a fresh complex cell (the engulfed
      -- bacterium is its first mitochondrion), carrying phase 1's snapshotted metrics
      -- as its statistic, then switch layers behind the white-out. RETIRE phase 1 so
      -- its sim freezes at the snapshot rather than ticking on in the background.
      retired = true
      complexcell.enter_from_seam({ stats = stats })
      layers.switch("complexcell")
    end,
  })
end

-- The per-engulf endosymbiosis chance at the current colony size: the tiny
-- ENDO_BASE_CHANCE floor until the colony reaches ENDO_RAMP_START, then a slight
-- ramp for every further ENDO_STEP cells (clamped to 1). Nonzero from the first
-- cell -- so a keep is possible at any size -- but held at the floor below the
-- ramp start and only climbing once the swarm crosses 100k, so it almost always
-- lands once the swarm is into the millions rather than too soon.
local function endo_chance(population)
  local steps = math.floor(math.max(0, population - ENDO_RAMP_START) / ENDO_STEP)
  local chance = ENDO_BASE_CHANCE + ENDO_RAMP_PER_STEP * steps
  if chance > 1 then
    return 1
  end
  return chance
end

-- Phase 1's CLIMAX. Each completed prey engulf has the ramped endo_chance() to KEEP
-- the partner as an organelle and resolve the run into a new lineage via the
-- end-of-phase-1 cinematic -- possible at any colony size, but vanishingly rare
-- until the swarm is huge. Gated on predation being unlocked (prey -- the partners
-- -- exist) and an organelle still being available. At most one keep per frame; the
-- transition then freezes the sim so it can't re-enter. engulf_points centres the
-- cinematic on the cell that actually triggered. Live-only (prey are live-only), so
-- it never fires offline -- a moment to witness.
local function roll_endosymbiosis(engulfs, engulf_points, predation)
  if transition.active(transition_state) then
    return
  end
  local s = cell.state.sim
  local chance = endo_chance(s.population)
  for i = 1, engulfs do
    local def = organelles.next_eligible(s.organelles, s.total_divisions, predation)
    if def and love.math.random() < chance then
      organelles.acquire(s.organelles, def.id)
      set_toast(string.format("Endosymbiosis! %s kept — %s", def.label, def.boon))
      local p = engulf_points and engulf_points[i]
      local cx, cy = world.swarm_center(world_state)
      if p then
        cx, cy = p.x, p.y
      end
      sound.play("endosymbiosis")
      view.endosymbiosis_beat(view_state, { x = cx, y = cy })
      begin_lineage_transition(cx, cy)
      persist()
      return
    end
  end
end

function cell.load()
  retired = false -- a fresh lineage runs live again (clears any prior phase-2 hand-off)
  sound.load("pop", "assets/sounds/pop.ogg")
  sound.load("bloom", "assets/sounds/bloom.ogg")
  sound.load("endosymbiosis", "assets/sounds/endosymbiosis.ogg")
  local data = DEV_FRESH_START and {} or (save.read(SAVE_NAME) or {})
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
    rng = function() return love.math.random() end,
    aspect = width / height,
  })

  -- Offline catch-up from a wall-clock stamp (closed-form rate only -- no
  -- predators, no agent dependency). Swallow the division pulses; the live
  -- swarm rebuilds from population and fills in smoothly on its own.
  if type(data.stamp) == "number" then
    local seconds = math.min(os.time() - data.stamp, OFFLINE_CAP)
    if seconds > 0 then
      sim.offline(cell.state.sim, seconds, intake_for(cell.state))
      sim.take_divisions(cell.state.sim)
    end
  end
end

-- Fixed sim tick (runs even while backgrounded). Pure sim: no love.*, no world.
-- FROZEN while the end-of-phase-1 cinematic is mid-build (up to its reset): the
-- economy must not mint/starve under the freeze frame. Once the reset has fired
-- the fresh colony ticks normally beneath the fading white-out.
function cell.tick(tick_dt)
  if not cell.state then
    return
  end
  if retired then
    return -- phase 1 handed off to phase 2: frozen at its snapshot, no longer ticking
  end
  if transition.active(transition_state) and not transition_state.reset_done then
    return
  end
  sim.tick(cell.state.sim, tick_dt, intake_for(cell.state))
end

function cell.update(dt)
  -- The end-of-phase-1 transition takes over the frame. Until its reset fires the live
  -- sim is FROZEN (freeze frame -> camera push-in -> charge -> white-out): advance
  -- only the cinematic and the view (so the camera glides + the fx play), then
  -- bail before world.update so cells hold still under the lingering camera. After
  -- the reset we fall through to the normal update so the fresh founder emerges as
  -- the white fades.
  if transition.active(transition_state) and not transition_state.reset_done then
    transition.update(transition_state, dt)
    view.update(view_state, dt)
    if toast_timer > 0 then
      toast_timer = toast_timer - dt
    end
    return
  end
  if transition.active(transition_state) then
    transition.update(transition_state, dt) -- post-reset: tick the white-out fade to its end
  end

  tween.update(dt) -- advance the UI kit's hover/press lighten transitions
  local width, height = love.graphics.getDimensions()
  local aspect = width / height

  -- SAFE ZONE for the nutrient bloom: the bloom is the world's only click
  -- target and the panel eats any click landing on it, so a bloom that spawns
  -- behind the panel is unclickable. Project the panel's screen rect into world
  -- space -- padded by the bloom's drawn extent (glow reaches ~1.7r, the timer
  -- bar hangs below) -- and hand it to the world as a no-spawn rect. Skipped
  -- before the camera's first-draw snap (init=false), when screen_to_world has
  -- no meaningful basis yet; no bloom can spawn that early anyway.
  local bloom_exclude
  if view_state.camera.init then
    local panel_x = width - PANEL_W - PANEL_MARGIN
    local x1, y1 = view.screen_to_world(view_state, panel_x, PANEL_Y)
    local x2, y2 = view.screen_to_world(view_state, panel_x + PANEL_W, PANEL_Y + cell._panel_h)
    local pad = view.bloom_radius(view_state) * 1.8
    bloom_exclude = { x = x1 - pad, y = y1 - pad, w = (x2 - x1) + pad * 2, h = (y2 - y1) + pad * 2 }
  end

  local predation = traits.is_unlocked(cell.state.traits, "predation")
  local killed, engulfs, deaths, kill_points, engulf_points = world.update(world_state, dt, {
    stats = traits.stats(cell.state.traits),
    dial_tempo = FIXED_TEMPO,
    aspect = aspect,
    target_population = target_population(cell.state),
    unlocked = traits.unlocked_set(cell.state.traits),
    threats_enabled = predation,
    bloom_exclude = bloom_exclude,
  })
  -- A live predator kill removes cells from the colony (a population setback the
  -- energy economy regrows; biomass -- the banked currency -- is untouched).
  if killed > 0 then
    sim.kill(cell.state.sim, killed)
  end
  -- Starvation deaths cover both reconcile's economy cull and the world's
  -- low-cadence starvation turnover; each bursts into recycled food in the world,
  -- so echo it with a view death-fx -- the cell exploding into its OWN color,
  -- recycled bits of itself -- at the reported position.
  if deaths then
    for i = 1, #deaths do
      local p = deaths[i]
      view.spawn(
        view_state,
        fx.burst({ x = p.x, y = p.y, color = colors.primary, seed = p.x + p.y })
      )
    end
  end
  -- A predator KILL bursts the victim into RED particles -- a violent death,
  -- visually distinct from the cell-colored starvation burst above.
  if kill_points then
    for i = 1, #kill_points do
      local p = kill_points[i]
      view.spawn(
        view_state,
        fx.burst({ x = p.x, y = p.y, color = colors.quaternary, seed = p.x + p.y })
      )
    end
  end
  -- Any cell death this frame -- starvation or kill -- gets ONE pop (not one per
  -- death, so a simultaneous cull doesn't stack into a blast), pitch-jittered.
  local death_count = (deaths and #deaths or 0) + (kill_points and #kill_points or 0)
  if death_count > 0 then
    sound.play("pop", { volume = 0.8, pitch_spread = 0.12 })
  end
  -- A completed PREY engulf plays a REVERSE burst -- prey-colored particles
  -- converging INTO the feeding cell (the death burst backwards: matter drawn in,
  -- not scattered); the cell itself swells via the entity-level fed pulse the
  -- view draws.
  if engulf_points then
    for i = 1, #engulf_points do
      local p = engulf_points[i]
      view.spawn(
        view_state,
        fx.implode({ x = p.x, y = p.y, color = colors.tertiary, seed = p.x + p.y })
      )
    end
  end
  -- Phase 1's climax: a prey engulf may keep the partner (endo_chance ramps with
  -- colony size), ending the run into a new lineage -- rare early, near-certain huge.
  if engulfs and engulfs > 0 then
    roll_endosymbiosis(engulfs, engulf_points, predation)
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

local TRAIT_IDS = { "photosynthesis", "motility", "sensing", "digestion", "evasion" }

-- Colony size that auto-unlocks a still-locked trait, for its "colony N" notice.
local function locked_need(def)
  for _, u in ipairs(traits.unlocks()) do
    if u.id == def.locked_until then
      return u.pop
    end
  end
  return nil
end

-- A themed action button carrying a dim cost/flavor sublabel and an affordability
-- gate -- the copied button-node has neither, so we compose the decoration
-- (primitives.button) with two stacked text lines in a custom draw_fn node, and
-- only register the hover zone + on_click when enabled.
local function action_button_node(opts)
  local enabled = opts.enabled
  return {
    type = "node",
    w = opts.w,
    h = opts.h,
    draw_fn = function(r)
      local tcol = enabled and colors.ui.white or colors.with_alpha(colors.ui.text, 0.35)
      button.draw(r, "", {
        font = "hud_small",
        id = enabled and opts.id or nil,
        opacity = enabled and nil or 0.18,
      })
      local label_y = r.y + math.max(2, math.floor((r.h - 28) / 2))
      text(
        rect(r.x, label_y, r.w, 14),
        opts.label,
        { font = "hud", color = tcol, align = "center" }
      )
      if opts.sublabel then
        text(rect(r.x, r.y + r.h - 16, r.w, 12), opts.sublabel, {
          font = "hud_small",
          color = colors.with_alpha(tcol, 0.6),
          align = "center",
        })
      end
    end,
    on_click = enabled and opts.on_click or nil,
    resolved_rect = nil,
  }
end

-- One trait row: a fill-width label column (name + level over a concrete hint)
-- and a right-pinned level-up button, or a dim "colony N" notice while locked.
local function trait_row(state, id)
  local def = traits.def(id)
  local level = state.traits.levels[id]
  local available = traits.is_available(state.traits, id)

  local label_color = available and colors.ui.text or colors.with_alpha(colors.ui.text, 0.4)
  local hint_color = available and colors.ui.text_faint
    or colors.with_alpha(colors.ui.text_faint, 0.6)

  local label_col = layout.vstack({
    layout.text(string.format("%s   Lv %d", def.label, level), { color = label_color }),
    layout.text(traits.hint(id), { color = hint_color }),
  }, { gap = 2 })

  local right
  if available then
    local cost = traits.cost(state.traits, id)
    local affordable = sim.can_spend(state.sim, cost)
    right = action_button_node({
      label = "level up",
      sublabel = format.number(cost) .. " bm",
      enabled = affordable,
      w = BTN_W,
      h = TRAIT_BTN_H,
      id = "trait_" .. id,
      on_click = function()
        if sim.spend(state.sim, cost) then
          traits.level(state.traits, id)
          persist()
        end
      end,
    })
  else
    right = layout.text(string.format("colony %d", locked_need(def) or 0), {
      color = colors.with_alpha(colors.ui.text_muted, 0.6),
      align = "center",
      w = BTN_W,
    })
  end

  return layout.hstack({ label_col, right }, { gap = theme.spacing.sm })
end

-- The organelles section: the acquired organelles (label + boon, with the lore as
-- a faint line) and, once predation is unlocked but not everything is held, a dim
-- hint that an engulfed microbe may rarely become one. Empty before predation, so
-- the section only appears once the rare event is reachable.
local function organelle_children(state)
  local held = organelles.acquired_list(state.sim.organelles)
  local predation = traits.is_unlocked(state.traits, "predation")
  if #held == 0 and not predation then
    return nil
  end
  local children = { layout.text("organelles", { color = colors.ui.text_dim }) }
  for _, def in ipairs(held) do
    table.insert(
      children,
      layout.vstack({
        layout.text(string.format("%s — %s", def.label, def.boon), { color = colors.ui.text }),
        layout.text(def.lore, { color = colors.with_alpha(colors.ui.text_faint, 0.7) }),
      }, { gap = 2 })
    )
  end
  if predation and organelles.next_eligible(state.sim.organelles, math.huge, true) then
    table.insert(
      children,
      layout.text("rare: an engulfed microbe may become an organelle", {
        color = colors.with_alpha(colors.ui.text_muted, 0.6),
      })
    )
  end
  return children
end

-- The whole panel as a declarative node tree, rebuilt each frame so dynamic values
-- and the on_click closures capture the current state. Stacked groups (header /
-- traits / organelles / footer) inside a PAD-padded vstack.
local function build_panel(state)
  local intake = intake_for(state)
  local pop = state.sim.population
  local div_cost = sim.div_cost(pop, intake.div_mult)
  local energy_ratio = math.max(0, math.min(state.sim.energy / div_cost, 1))

  local header = {}
  table.insert(
    header,
    layout.text(
      "biomass  " .. format.number(state.sim.biomass),
      { size = "lg", color = colors.ui.text }
    )
  )
  table.insert(
    header,
    layout.text(string.format("colony  %d", pop), { color = colors.ui.text_dim })
  )
  table.insert(
    header,
    layout.text(
      -- Measured throughput (EMA of actual mints in sim.step), not the
      -- instantaneous theoretical rate -- which whipsaws near carrying capacity
      -- as the integer population wobbles with each division/death/kill.
      string.format("division  %s /min", format.number(state.sim.div_rate * 60)),
      { color = colors.ui.text_muted }
    )
  )
  -- The energy reserve filling toward the next division (banks biomass on cross).
  table.insert(
    header,
    layout.bar(energy_ratio, {
      h = 10,
      color = BAR_COLOR,
      bg_color = colors.with_alpha(colors.ui.white, 0.12),
    })
  )

  -- Trait list: concrete, direct levels. No slots, no splicing.
  local trait_children = { layout.text("traits", { color = colors.ui.text_dim }) }
  for _, id in ipairs(TRAIT_IDS) do
    table.insert(trait_children, trait_row(state, id))
  end

  local groups = {
    layout.vstack(header, { gap = theme.spacing.xs }),
    layout.vstack(trait_children, { gap = theme.spacing.sm }),
  }

  local organelle_group = organelle_children(state)
  if organelle_group then
    table.insert(groups, layout.vstack(organelle_group, { gap = theme.spacing.xs }))
  end

  local nxt = traits.next_unlock(state.traits)
  local footer_text = nxt and string.format("next: %s at colony %d", nxt.label, nxt.pop)
    or "all capabilities evolved"
  table.insert(groups, layout.text(footer_text, { color = colors.ui.text_muted }))

  return layout.vstack(groups, { padding = PAD, gap = theme.spacing.md })
end

-- Centered footer help line, a direct text overlay (not part of the panel tree).
local function draw_help(width)
  text(
    rect(0, love.graphics.getHeight() - 44, width, 16),
    "click a nutrient bloom to feed   ·   level traits (biomass)   ·   grow the colony   ·   [r] new lineage",
    { color = colors.with_alpha(colors.ui.text_faint, 0.7), align = "center" }
  )
end

local function draw_toast(width)
  if toast_timer <= 0 or not toast_text then
    return
  end
  local alpha = math.min(toast_timer, 1)
  text(rect(0, 40, width, 22), toast_text, {
    font = "hud_lg",
    color = colors.with_alpha(colors.ui.accent, alpha),
    align = "center",
  })
end

function cell.draw()
  local state = cell.state
  local width = love.graphics.getWidth()

  view.draw_world(view_state, world.snapshot(world_state), {
    mito = organelles.has(state.sim.organelles, "mitochondrion"),
  })

  -- During the end-of-phase-1 cinematic the world is drawn (frozen) beneath the
  -- overlay, but the panel / help / toast are suppressed -- the screen belongs to
  -- the transition. The triggering cell is projected each frame so the core + text
  -- ride it as the camera pushes in.
  if transition.active(transition_state) then
    local sx, sy = view.world_to_screen(view_state, transition_state.x, transition_state.y)
    transition.draw(transition_state, sx, sy)
    return
  end

  -- The panel rides the RIGHT edge: its left x is computed from the window width
  -- each frame (the panel hugs its content height, so only x moves with resize).
  local panel_x = width - PANEL_W - PANEL_MARGIN
  cell._panel_x = panel_x

  -- Build + resolve the panel tree into the right-edge panel rect, draw its themed
  -- backing, then render it -- keeping this frame's click map on the module so
  -- mousepressed can hit-test it (one-frame lag is standard and harmless).
  interaction.begin_frame()
  local tree = build_panel(state)
  layout.resolve(tree, rect(panel_x, PANEL_Y, PANEL_W, PANEL_H))
  cell._panel_h = tree.resolved_rect.h
  primitives.container(rect(panel_x, PANEL_Y, PANEL_W, cell._panel_h), "content")
  cell._click_map = renderer.draw(tree, nil)
  local mx, my = love.mouse.getPosition()
  interaction.commit_frame(mx, my, love.mouse.isDown(1))

  draw_help(width)
  draw_toast(width)
end

function cell.keypressed(key)
  -- The cinematic owns the screen: swallow gameplay input until it finishes.
  if transition.active(transition_state) then
    return
  end
  if key == "space" then
    local b = world.any_bloom(world_state)
    if b then
      world.hit_bloom(world_state, b.x, b.y, view.bloom_radius(view_state))
      feed_bloom(b)
    end
  elseif key == "m" then
    -- DEV: force the end-of-phase-1 transition (endosymbiosis is ~0.1%/engulf, so
    -- the real proc is rare to witness). Centres on the live swarm.
    local cx, cy = world.swarm_center(world_state)
    sound.play("endosymbiosis")
    view.endosymbiosis_beat(view_state, { x = cx, y = cy })
    begin_lineage_transition(cx, cy)
  elseif key == "r" then
    -- New lineage: wipe the save and reload a fresh single founder. The escape
    -- hatch from a stale grown colony restored off an old save -- instant fresh
    -- start, the true ~20-30s solo-cell open.
    save.remove(SAVE_NAME)
    cell.load()
  end
end

function cell.mousepressed(x, y, button_index)
  if button_index ~= 1 then
    return
  end
  -- The cinematic owns the screen: ignore clicks until it finishes.
  if transition.active(transition_state) then
    return
  end
  -- A widget hit fires its on_click closure; anything else outside the panel
  -- feeds a nutrient bloom if it landed on one (the blooms are the only other
  -- clickable). in_panel is screen space; the bloom hit-test is world space.
  local cb = cell._click_map and renderer.hit_test(cell._click_map, x, y)
  if cb then
    cb()
    return
  end
  if not in_panel(x, y) then
    local wx, wy = view.screen_to_world(view_state, x, y)
    local b = world.hit_bloom(world_state, wx, wy, view.bloom_radius(view_state))
    if b then
      feed_bloom(b)
    end
  end
end

return cell
