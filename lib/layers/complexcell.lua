-- Complex-cell layer: phase 2, the eukaryotic SEQUEL to the cell colony. You grew a
-- colony in phase 1; at the endosymbiosis finale you zoom INTO a single cell and
-- play on inside it -- one complex cell building out its internal machinery. Growth
-- is no longer "more cells fill the dish" but DETAIL: an assembly line (ribosomes ->
-- nucleus -> ER -> Golgi -> transport -> membrane) powered by MITOCHONDRIA, banking
-- ATP and minting BUILT. This file is the ORCHESTRATOR, the phase-2 sibling of
-- lib/layers/cell.lua: it owns only the wiring. It folds the pure catalog (constants
-- + stage levels + mito count) into the `rates` table the pure sim's shared economy
-- step runs on, so idle/offline math never depends on the live view. The interior
-- swarm (view.lua, written alongside this) is a cosmetic skin over that baseline,
-- driven only in update()/draw(). The pure modules (sim, catalog) know nothing of
-- each other or of love.*; they meet only here.
--
-- The verb is BALANCING power against throughput: output is capped by the slowest
-- unlocked stage and costs ATP to run, so complexity demands mitochondria -- overreach
-- and the line BROWNS OUT. ATP (sim.energy) is the single currency; every upgrade is
-- bought with it directly (NOT phase-1 biomass -- that's sim.spend, a different sim).
local save = require("lib.engine.save")
local fx = require("lib.engine.fx")
local sound = require("lib.engine.sound")
local music = require("lib.engine.music")
local format = require("lib.engine.format")
local sim = require("lib.layers.complexcell.sim")
local catalog = require("lib.layers.complexcell.catalog")
local view = require("lib.layers.complexcell.view")
-- The end-of-phase-2 finale: the shared cinematic timeline (REUSED from phase 1,
-- not forked) plus the plant/animal CHOICE screen + ascension placeholder it
-- resolves into. transition owns the clock + white-out; fork owns the choice modal.
local transition = require("lib.layers.cell.transition")
local fork = require("lib.layers.complexcell.fork")

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
local toast = ui.toast
local rect = ui.primitives.rect
local text = ui.primitives.text
local button = ui.primitives.button

local complexcell = {}

local SAVE_NAME = "complexcell"
local SAVE_INTERVAL = 5 -- seconds between autosaves (active layer only)
local OFFLINE_CAP = 8 * 3600 -- credit at most 8h of time away
-- DEV: ignore any existing save on boot, so every launch starts a fresh complex
-- cell -- mirrors cell.lua's DEV_FRESH_START while the layer is being tuned.
-- Autosaves still write during play (harmlessly unread). Flip to false to restore
-- the real idle behaviour: resume the saved cell + offline catch-up.
local DEV_FRESH_START = true

-- COLLAPSE -- the phase-2 lose state, mirroring cell.lua's extinction beat. When the
-- sim's oxidative stress saturates (state.stress >= catalog.STRESS_FAIL, a power
-- deficit run to its end) the cell LYSES: a short game-over overlay freezes the sim,
-- flashes + shakes, then a FRESH cell seeds (the same wipe+reload as [r]).
local collapsing = false -- true while the lysis overlay plays (freezes the sim)
local collapse_anim = 0 -- remaining seconds of the lysis overlay
local COLLAPSE_ANIM = 2.6 -- length of the lysis beat before the fresh reload (matches cell.lua)
-- Surface the oxidative-stress WARNING (the analogue of the BROWNOUT line) once stress
-- climbs past this fraction -- early enough that the player can still power out of it
-- before STRESS_FAIL (1.0) lyses the cell.
local STRESS_WARN = 0.4

-- MANUAL ATP TAP -- the kickstart click. A left-click in the cytoplasm injects an ATP
-- burst into the buffer. A tap credits a burst on a LONG, RANDOMISED cooldown (phase-1's "click a bloom to
-- feed" cadence), so it's a deliberate kickstart you reach for now and then -- not a
-- spammable per-frame faucet, and not a metronome you can drum on a fixed beat. The
-- burst SCALES with the cell's gross power (a few seconds of ATP production), so it
-- stays a useful nudge the whole phase instead of fading to nothing once costs climb:
-- early (mito 1, power 10) a tap is ~25 ATP (a power plant in one tap); late it grows
-- with your mitochondria. Clamped at the buffer ceiling.
local TAP_POWER_SECONDS = 2.5 -- a tap is worth this many seconds of gross ATP power
local ATP_TAP_COOLDOWN_MIN = 5 -- shortest gap between taps (seconds)
local ATP_TAP_COOLDOWN_MAX = 10 -- longest gap; each tap rolls a fresh cd in [MIN, MAX]
local atp_tap_cooldown = 0 -- remaining lockout, drained in update()
-- A stable 0..1 seed naming WHICH mitochondrion shows the "feed me" pulse this ready-window
-- (the view maps it to a bean index). Re-rolled when the cooldown expires (see update), so the
-- cue hops to a fresh power plant each window. Cosmetic only -- never feeds the sim.
local atp_tap_seed = 0

local PANEL_MARGIN = 16 -- gap from the window edge (panel x is computed each frame)
local PANEL_Y = 16
local PANEL_W = 320
-- The panel hugs its content (draw stamps the resolved height into _panel_h), so
-- PANEL_H is only the resolve budget + the pre-first-draw fallback. We size that budget
-- to the room the panel actually has on screen: from PANEL_Y down to the window bottom.
-- The compact row rhythm below is tuned so even the WORST CASE -- all six assembly-line
-- stages online AND the optional brownout + dying header lines -- resolves to ~700px,
-- which fits this budget on the 720px window without overflow (the old layout ran ~986px
-- and pushed the bottom stages + footer off-screen, the bug this redesign fixes). The
-- panel hugs its content, so shorter states end well above the bottom; only the full
-- pipeline reaches near the window edge, and never past it.
local WINDOW_H_FALLBACK = 720 -- design height before the first draw learns the live window
local PANEL_BOTTOM_MARGIN = 0 -- the full pipeline may reach the window bottom edge (still on-screen)
local PANEL_H = WINDOW_H_FALLBACK - PANEL_Y - PANEL_BOTTOM_MARGIN
local PAD = 12 -- panel inner padding (tighter than phase 1 to claw back vertical room)
-- The read-only VITALS sit boxed at the top of the panel (their own container, lifted
-- above the build levers). Layout nodes carry no background, so complexcell.draw stamps a
-- bordered box behind the vitals vstack's resolved rect, expanded outward by this many px
-- so the border breathes around the gauge column rather than crowding the text.
local VITALS_BOX_PAD = 6
-- A consistent BUY-ROW rhythm across the whole panel: every purchasable line -- power,
-- each unlocked stage's level-up, each discovered stage's integrate -- is a fill-width
-- label column beside a right-pinned action pill. BTN_W fits the widest verb ("integrate")
-- over the widest cost ("180K atp") on the pill's two centred lines.
local BTN_W = 92 -- fixed-width action pill, pinned right by the fill label column
-- COMPACT TWO-LINE PILL: the verb sits over a dim cost line INSIDE the pill (see
-- action_button_node). Folding the cost into the button -- instead of a third label-column
-- line -- lets a stage row be a single label line, so six stage rows stay short. BTN_H is
-- the min height for two snug hud_small lines (~17px each) with a little breathing room.
local BTN_H = 34
-- The pill's verb (top line) and cost (bottom line) split BTN_H. The verb gets the upper
-- portion, the cost the lower; this fraction is the verb's share so the two read as a
-- title-over-subtitle pair rather than two equal lines crowding the pill.
local PILL_VERB_FRACTION = 0.52
local BAR_COLOR = colors.secondary -- the ATP buffer bar rides the global nourishment token
-- A buy row's cost string, rendered as the pill's dim second line. Named so the cost is
-- never inlined ad hoc and reads consistently across power / stage rows.
local COST_SUFFIX = " atp"

-- GAUGES (Pillar 5). The vitals strip reads the catalog's pure derived metrics and
-- surfaces them as biologically-named percentages/labels -- NO "what to upgrade" text;
-- the gauges only show state and the player reasons out the lever. The balance-ratio
-- band classes (catalog.BAND_*) map to a one-word verdict + a color token here, at the
-- view's edge (the catalog never names a color). under -> brownout warning (accent),
-- ideal -> in-band (nourishment green), over -> ROS leak (threat red).
local BAND_LABEL = {} -- catalog band class -> verdict word the gauge prints
local BAND_COLOR = {} -- catalog band class -> color token the gauge tints
BAND_LABEL[catalog.BAND_UNDER] = "under"
BAND_LABEL[catalog.BAND_IDEAL] = "ideal"
BAND_LABEL[catalog.BAND_OVER] = "over"
BAND_COLOR[catalog.BAND_UNDER] = colors.ui.accent
BAND_COLOR[catalog.BAND_IDEAL] = colors.secondary
BAND_COLOR[catalog.BAND_OVER] = colors.quaternary
-- ROS reads as a rising danger: tint the readout toward the threat token once it climbs
-- past this fraction (the same warning band the soft cut is already biting in). Below it
-- the cell is calm, so the metric stays a quiet dim readout.
local ROS_WARN_FRAC = 0.4

complexcell.state = nil

local view_state
local save_accum = 0
-- SEAM INTRO: phase 1's endosymbiosis dive ends on a full-screen teal flood (the cell's
-- own colour, as the camera plunges inside). enter_from_seam arms this brief teal sheet
-- that fades OUT over INTRO_FADE seconds, so phase 2 opens straight out of that same teal
-- -- the hand-off is one continuous teal, no flash and no black gap. Zero in normal play.
local INTRO_FADE = 0.6
local intro_fade = 0
-- ============================================================================
-- LAYERED SCORE (vertical remix). Phase 2's music is three SAME-LENGTH, downbeat-
-- aligned stems (assets/music/complexcell_layer1..3.ogg). All three start TOGETHER
-- at the seam (some silent) so they stay sample-synced for the whole phase; we then
-- ride their volumes up as `built` climbs, so the track THICKENS with the cell's
-- complexity instead of restarting.
--   layer1 -- the bed, in from the seam (built 0).
--   layer2 -- enters at the Endomembrane (ER) gate: the line gains its first organelle.
--   layer3 -- enters at the Cytoskeleton gate: the line becomes a moving network, and
--             the long final climb toward the FORK finale begins (~28% up the climb).
-- Anchored to the catalog's stair-step gates so the score thickens with each named beat
-- (er ~1 min, transport ~5 min into the ~10-min run); both ride `built`, so a fast or
-- slow player still hears the stems arrive on their own organelles, not a wall clock.
local LAYER_VOL = 0.50 -- matches the phase-1 BGM volume (main.BGM_VOLUME)
local LAYER1_VOL = LAYER_VOL * 0.50 -- the bed stem sits 25% under the others (it underpins, not leads)
local LAYER_FADE = 3.0 -- seconds each stem eases in over (musical, not a hard cut)
local LAYER2_AT = 1000 -- == catalog Endomembrane (ER) gate
local LAYER3_AT = 50000 -- == catalog Cytoskeleton/transport gate (~28% up the 180000 climb)
local layer2_in = false -- one-shot: layer2 has been faded in
local layer3_in = false -- one-shot: layer3 has been faded in
-- The end-of-phase-2 transition cinematic (armed when `built` first crosses the
-- FORK gate). While active the orchestrator FREEZES the live sim and hands the
-- frame to it -- exactly as cell.lua does at the endosymbiosis finale.
local transition_state = transition.new()
-- One-shot arming guard: the FORK cinematic fires ONCE when reached_fork first
-- becomes true (reset only on a fresh [r] cell / a load that hasn't reached it).
local fork_armed = false
-- The terminal fork flow this draft lands on. nil = normal play. "choice" = the
-- white-out has resolved into the plant/animal modal (set by the cinematic's
-- on_reset at the white peak). "ascension" = a kingdom is picked; the placeholder
-- screen, where the draft ends.
local fork_mode = nil

-- The panel hugs its content and rides the RIGHT edge: complexcell.draw stamps the
-- resolved tree height and the frame's computed left x here (the renderer click map
-- is the only hit surface in this first draft, so these track the backing for the
-- interior-click pass that lands later).
complexcell._panel_h = PANEL_H
complexcell._panel_x = PANEL_MARGIN

local function persist()
  save.write(SAVE_NAME, {
    sim = sim.serialize(complexcell.state.sim),
    carry = complexcell.state.carry, -- the colony number carried from phase 1
    -- The terminal fork: persist the recorded kingdom so a resumed save returns
    -- straight to the ascension placeholder rather than re-playing the cinematic.
    fork_choice = complexcell.state.fork_choice,
    stamp = os.time(),
  })
end

-- Build the fresh in-memory state: a sim seeded with ribosomes online at level 1
-- (matching the lab's run_policy init, so output > 0 from t=0) plus the carried
-- phase-1 colony number. `data` is a save blob or {} for a fresh cell.
local function build_state(data)
  local s = sim.load(data.sim)
  -- Ribosomes online from t=0 at level 1, so the assembly line produces from the
  -- start -- the lab's init. (sim.load already floors mito at 1, the engulfed
  -- bacterium.) Idempotent: a resumed save that already has them stays as-is.
  s.unlocked.ribosomes = true
  s.stages.ribosomes = math.max(s.stages.ribosomes or 0, 1)
  return {
    sim = s,
    -- The frozen phase-1 snapshot (colony / divisions / biomass / organelles) the
    -- colony "became" -- a fixed statistic, surfaced in the panel. nil on a [r] fresh
    -- cell (no phase-1 lineage to carry).
    carry = type(data.carry) == "table" and data.carry or nil,
    -- The end-of-phase fork pick ("plant"|"animal"), restored from a resumed save so
    -- the placeholder is returned to without re-playing the cinematic. nil until chosen.
    fork_choice = fork.choice_def(data.fork_choice) and data.fork_choice or nil,
  }
end

-- Reset the end-of-phase fork runtime flags from the (re)built state. A resumed
-- save that already recorded a kingdom returns STRAIGHT to the terminal ascension
-- placeholder (the cinematic never re-plays); otherwise the layer opens in normal
-- play and the cinematic arms the first time `built` crosses the FORK gate.
local function reset_fork_runtime()
  -- A freshly (re)built cell runs normally: clear any prior lysis overlay + tap lockout.
  collapsing = false
  collapse_anim = 0
  atp_tap_cooldown = 0
  atp_tap_seed = love.math.random() -- the tap opens off cooldown, so prime a bean for its cue
  transition_state = transition.new()
  if complexcell.state.fork_choice then
    fork_armed = true
    fork_mode = "ascension"
  else
    fork_armed = false
    fork_mode = nil
  end
end

function complexcell.load()
  intro_fade = 0 -- a resumed/loaded cell opens normally (only the seam plays the teal intro)
  sound.load("endosymbiosis", "assets/sounds/endosymbiosis.ogg")
  sound.load("cytoplasm_active", "assets/sounds/cytoplasm_active.ogg") -- the manual ATP-tap beat
  -- The three vertical-remix stems (idempotent loads, paused at volume 0 until armed).
  -- stream = false -> decode fully so the short stems loop sample-accurately (gapless);
  -- a streaming source would drop a few ms at each loop point.
  local loop_stem = { stream = false }
  music.load("complexcell_layer1", "assets/music/complexcell_layer1.ogg", loop_stem)
  music.load("complexcell_layer2", "assets/music/complexcell_layer2.ogg", loop_stem)
  music.load("complexcell_layer3", "assets/music/complexcell_layer3.ogg", loop_stem)
  local data = DEV_FRESH_START and {} or (save.read(SAVE_NAME) or {})
  complexcell.state = build_state(data)
  reset_fork_runtime()
  view_state = view.new()

  -- Offline catch-up from a wall-clock stamp (closed-form rate only -- the same
  -- shared step the live tick runs, folded through catalog.fold). Apply any gates
  -- the offline build crossed so the resumed cell opens its stages.
  if type(data.stamp) == "number" then
    local seconds = math.min(os.time() - data.stamp, OFFLINE_CAP)
    if seconds > 0 then
      sim.offline(complexcell.state.sim, seconds, catalog.fold(complexcell.state.sim))
      -- Reveal (not unlock) any stages the offline build crossed -- they wait in the
      -- panel as "integrate" rows until the player pays the steep ATP cost.
      catalog.discover_gates(complexcell.state.sim)
    end
  end
end

-- Kick off the layered phase-2 score: start ALL THREE stems together (so they stay
-- in phase forever -- see the LAYERED SCORE note), with only layer1 audible. The
-- phase-1 BGM has already been ducked + paused (cell's begin_lineage_transition at
-- the seam, or main at a debug phase-2 boot). layer2/layer3 ride in later from
-- update() as `built` crosses their thresholds. Idempotent: re-arms the one-shots.
function complexcell.start_layered_music()
  layer2_in, layer3_in = false, false
  music.play("complexcell_layer1", 0)
  music.play("complexcell_layer2", 0)
  music.play("complexcell_layer3", 0)
  music.fade_in("complexcell_layer1", LAYER1_VOL, LAYER_FADE)
end

-- Ride the upper stems in as the cell grows. One-shot per layer, keyed on `built`
-- crossing each threshold; the actual crossfade is the music manager's volume
-- envelope (the stems are already playing silently in sync).
local function update_music_layers(built)
  if not layer2_in and built >= LAYER2_AT then
    layer2_in = true
    music.fade_in("complexcell_layer2", LAYER_VOL, LAYER_FADE)
  end
  if not layer3_in and built >= LAYER3_AT then
    layer3_in = true
    music.fade_in("complexcell_layer3", LAYER_VOL, LAYER_FADE)
  end
end

-- Called by the phase-1 seam (cell.lua's endosymbiosis finale): (re)initialize a
-- FRESH complex cell. The just-engulfed bacterium is the first mitochondrion (sim
-- seeds mito = 1); opts.colony is recorded as the carried "becomes a statistic"
-- number -- the collapsed colony carried forward as a single figure. Persisted so
-- the zoom-into-the-cell lands in a real, saved phase 2.
function complexcell.enter_from_seam(opts)
  opts = opts or {}
  complexcell.state = build_state({ carry = opts.stats })
  reset_fork_runtime()
  view_state = view.new()
  intro_fade = INTRO_FADE -- open out of phase 1's teal flood, fading in over INTRO_FADE
  complexcell.start_layered_music() -- phase-2 score fades up out of the teal hand-off
  persist()
end

-- Arm the END-OF-PHASE-2 victory cinematic -- the phase-2 sibling of cell.lua's
-- begin_lineage_transition. REUSES lib/layers/cell/transition.lua verbatim (the
-- same freeze -> focus -> charge -> white-out timeline), with phase-2 text and the
-- three side-effect callbacks bound here. The interior view has no camera (its
-- interface is new/update/draw/spawn), so on_focus/on_shake route to subtle
-- view.spawn beats; on_reset, fired at the WHITE PEAK, flips the layer into CHOICE
-- mode so the modal is revealed as the white-out fades (it does NOT reset or switch
-- layers -- the fork is the terminal beat of this draft). One-shot via fork_armed.
local function arm_fork()
  fork_armed = true
  -- Centre the cinematic on the cell's centre (the view fills the screen). The
  -- transition projects (x, y) itself; we pass screen-centre-ish coords directly
  -- since the interior has no world camera to project through.
  local cx, cy = 0, 0
  if love and love.graphics then
    cx, cy = love.graphics.getWidth() * 0.5, love.graphics.getHeight() * 0.5
  end
  sound.play("endosymbiosis")
  transition.begin(transition_state, {
    x = cx,
    y = cy,
    title = "TWO PATHS",
    kicker = "ascension",
    subtitle = "what will you become",
    on_focus = function()
      -- No camera in the interior view; mark the moment with a gentle flash beat.
      view.spawn(view_state, fx.flash({ color = colors.primary, alpha = 0.12, life = 0.5 }))
    end,
    on_shake = function(mag, life, seed)
      view.spawn(view_state, fx.shake({ mag = mag, life = life, seed = seed }))
    end,
    on_reset = function()
      -- The white-out peaks: reveal the plant/animal CHOICE behind the lifting white.
      -- No layer switch, no economy reset -- the assembly line is simply done.
      fork_mode = "choice"
    end,
  })
end

-- Commit the player's plant/animal pick: record it (via the pure fork helper),
-- persist it in the save blob, and fall through to the terminal ascension
-- placeholder. Wired as the on_choose callback the choice modal's cards fire.
local function choose_kingdom(id)
  if fork.record_choice(complexcell.state, id) then
    fork_mode = "ascension"
    persist()
  end
end

-- The lethal problem in plain words, named by which side of the balance band drove the
-- stress: a power DEFICIT ("low power") or idle OVER-power ("power overload"). Oxidative
-- stress is two-sided now (the ROS pendulum), so the warning + lysis toast must state the
-- ACTUAL cause, not assume a deficit. States the problem only -- no fix hint (the player
-- reads the vitals and picks the lever).
local function lethal_problem(s)
  if catalog.balance_band(s) == catalog.BAND_OVER then
    return "power overload"
  end
  return "low power"
end

-- Begin the LYSIS game-over beat (the phase-2 sibling of cell.lua's begin_collapse):
-- freeze the sim, flash + shake red, toast the cause, play a death sound. The overlay
-- runs for COLLAPSE_ANIM, then update() wipes the save and seeds a fresh cell -- the
-- same reset as [r]. One-shot via the collapsing flag; cleared on every (re)build.
local function begin_collapse()
  collapsing = true
  collapse_anim = COLLAPSE_ANIM
  toast.show(
    string.format("The cell burst — %s. A new cell begins", lethal_problem(complexcell.state.sim))
  )
  sound.play("endosymbiosis")
  view.spawn(view_state, fx.flash({ color = colors.quaternary, alpha = 0.4, life = 0.6 }))
  view.spawn(
    view_state,
    fx.shake({ mag = 10, life = 0.7, seed = math.floor(complexcell.state.sim.built) })
  )
  persist()
end

-- Fixed sim tick (runs even while backgrounded). Pure: fold -> step -> apply gates;
-- no love.*, no view. A freshly-crossed gate toasts and persists (the named-beat
-- unlock -- the phase-2 analogue of cell.lua's check_unlocks). Mirrors cell.tick.
-- FROZEN once the cell reaches the FORK: while the victory cinematic is mid-build
-- (up to its white peak) and through the whole choice/ascension flow, the economy
-- must not mint/starve under the freeze -- the assembly line has stopped. Mirrors
-- cell.tick's transition guard.
function complexcell.tick(tick_dt)
  if not complexcell.state then
    return
  end
  -- The fork is a terminal beat: once the choice/ascension screen is up, freeze.
  if fork_mode then
    return
  end
  -- Freeze while the cinematic builds toward its white peak (before on_reset fires).
  if transition.active(transition_state) and not transition_state.reset_done then
    return
  end
  local s = complexcell.state.sim
  sim.tick(s, tick_dt, catalog.fold(s))
  -- DISCOVERY (not auto-unlock): a freshly-crossed gate only REVEALS its stage as an
  -- "integrate" purchase row; the player pays the steep ATP cost to bring it online.
  local newly = catalog.discover_gates(s)
  for _, id in ipairs(newly) do
    local def = catalog.STAGE_DEFS[id]
    toast.show(string.format("Discovered %s — spend ATP to bring it online", def.label))
    persist()
  end

  -- FAILURE -> LYSIS: the oxidative stress the sim accrues from a sustained power
  -- deficit has saturated. The cell dies; play the game-over beat, then reload fresh.
  -- arm_collapse touches love.*/sound, but tick runs only the pure economy -- so we set
  -- the module flag here and the live overlay/reset is driven from update(), like cell.
  if s.stress >= catalog.STRESS_FAIL and not collapsing then
    begin_collapse()
  end
end

function complexcell.update(dt)
  if not complexcell.state then
    return
  end
  -- Drain the seam intro fade regardless of the cinematic/fork guards below, so the
  -- teal hand-off sheet always lifts (it's pure cosmetics over a freshly-seeded cell).
  if intro_fade > 0 then
    intro_fade = math.max(0, intro_fade - dt)
  end
  -- Drain the manual ATP-tap lockout so the cytoplasm click rearms after the cooldown.
  if atp_tap_cooldown > 0 then
    atp_tap_cooldown = math.max(0, atp_tap_cooldown - dt)
    if atp_tap_cooldown <= 0 then
      -- Rearmed: pick a fresh power plant for the next tap cue (cosmetic; see atp_tap_seed).
      atp_tap_seed = love.math.random()
    end
  end
  tween.update(dt) -- advance the UI kit's hover/press lighten transitions
  view.update(view_state, dt) -- the interior keeps animating beneath the overlay
  update_music_layers(complexcell.state.sim.built) -- thicken the score as `built` climbs

  -- The cell has LYSED: the game-over beat owns the frame. Advance only the view (so the
  -- red flash + shake play) and the overlay clock, then -- when it elapses -- wipe the
  -- save and seed a fresh cell (the same reset as [r], via enter_from_seam). Mirrors
  -- cell.update's collapsing branch.
  if collapsing then
    toast.update(dt)
    collapse_anim = collapse_anim - dt
    if collapse_anim <= 0 then
      save.remove(SAVE_NAME)
      complexcell.enter_from_seam({}) -- fresh cell; reset_fork_runtime clears collapsing
    end
    return
  end

  -- Advance the victory cinematic whenever it's armed. The view/tween still update
  -- (so the fx beats play + the white-out fades), but the economy is frozen by
  -- tick's guard, and we bail before the autosave/arming so the terminal beat is
  -- clean. The choice modal is revealed by on_reset at the white peak.
  if transition.active(transition_state) then
    transition.update(transition_state, dt)
    toast.update(dt)
    return
  end

  toast.update(dt)

  -- Live-only arming (mirrors cell.lua, where the finale arms from update, not the
  -- backgrounded tick): the first frame `built` crosses the FORK gate, play the
  -- victory cinematic. Guarded one-shot via fork_armed; skipped once the fork flow
  -- is up. arm_fork touches love.*/sound, so it lives here, never in tick.
  if not fork_armed and not fork_mode and catalog.reached_fork(complexcell.state.sim) then
    arm_fork()
    return
  end

  -- The terminal fork flow (choice / ascension) is a held screen: no autosave churn.
  if fork_mode then
    return
  end

  save_accum = save_accum + dt
  if save_accum >= SAVE_INTERVAL then
    save_accum = 0
    persist()
  end
end

-- The snapshot the view draws against (THE CONTRACT). Built fresh each draw so the
-- view always sees the current economy: the headline numbers/flags, the power-plant
-- count, the neutral fuel mix, the pinning stage, and the ordered pipeline rows.
local function build_snapshot(s, tap_ready)
  return {
    built = s.built,
    energy = s.energy,
    buffer_max = catalog.buffer_max(s),
    output = s.output,
    throughput = catalog.fold(s).throughput,
    brownout = s.brownout,
    mito = s.mito,
    fuel_factor = catalog.FUEL_FACTOR,
    bottleneck_id = catalog.bottleneck_id(s),
    stages = catalog.stage_snapshot(s),
    efficiency = (catalog.efficiency and catalog.efficiency(s)) or 1,
    -- 0..1 oxidative stress (power deficit). The view may dim/redden the cell as it
    -- climbs toward STRESS_FAIL (the lysis threshold).
    stress = s.stress,
    -- Pillar-5 gauge readouts (pure derived math from the catalog). The view surfaces
    -- these as biologically-named metrics; none feeds back into the economy.
    ros = s.ros or 0,
    balance_ratio = catalog.balance_ratio(s),
    balance_band = catalog.balance_band(s),
    -- Whether the manual ATP tap is off cooldown and usable RIGHT NOW: primes a random
    -- mitochondrion with a pulsing "feed me" halo. Cosmetic; never feeds the sim.
    tap_ready = tap_ready,
    -- Which power plant carries that pulse this window (0..1 -> bean index in the view).
    -- Stable until the tap is spent, then re-rolled on rearm. Cosmetic.
    tap_seed = atp_tap_seed,
  }
end

-- A themed TWO-LINE action pill with an affordability gate: the verb (e.g. "level up")
-- over a dim cost line ("180K atp"), both centred inside one compact BTN_H pill. Folding
-- the cost INTO the pill -- rather than spending a third label-column line on it -- is what
-- lets a stage row collapse to a single label line, so six stage rows stay short and the
-- whole panel fits the window. button.draw paints the decoration + border (and the hover
-- lighten) and registers the hover zone over the full pill; we then stamp the two text
-- lines ourselves so the verb sits in the upper portion and the cost in the lower. The
-- on_click fires only when enabled; a disabled pill dims its border and both lines.
local function action_button_node(opts)
  local enabled = opts.enabled
  return {
    type = "node",
    w = opts.w,
    h = opts.h,
    draw_fn = function(r)
      -- Decoration + border + hover zone over the whole pill, with no label of its own --
      -- we draw the verb/cost lines below so they can split the pill vertically.
      button.draw(r, "", {
        font = "hud_small",
        id = enabled and opts.id or nil,
        opacity = enabled and nil or 0.18,
      })
      local verb_color = enabled and colors.ui.white or colors.with_alpha(colors.ui.text, 0.35)
      local cost_color = enabled and colors.ui.text_muted
        or colors.with_alpha(colors.ui.text_muted, 0.35)
      local verb_h = math.floor(r.h * PILL_VERB_FRACTION)
      text(rect(r.x, r.y, r.w, verb_h), opts.label, {
        font = "hud_small",
        align = "center",
        color = verb_color,
      })
      text(rect(r.x, r.y + verb_h, r.w, r.h - verb_h), format.number(opts.cost) .. COST_SUFFIX, {
        font = "hud_small",
        align = "center",
        color = cost_color,
      })
    end,
    on_click = enabled and opts.on_click or nil,
    resolved_rect = nil,
  }
end

-- The shared BUY ROW -- the one builder EVERY purchasable line routes through (power, each
-- unlocked stage's level-up, each discovered stage's integrate), so the rows share an
-- identical structure, gap rhythm, and pill (the user flagged the old per-builder rows as
-- inconsistent). A fill-width label column -- a bright title over an OPTIONAL faint
-- descriptor -- beside the two-line cost pill. The descriptor (the organelle's short role
-- line, or the power plant's one-liner) rides UNDER the pill's height, so a row carrying it
-- is no taller than one without -- all six stage rows stay the same compact height.
local function buy_row(opts)
  local col_children = { layout.text(opts.title, { color = colors.ui.text }) }
  if opts.descriptor then
    table.insert(col_children, layout.text(opts.descriptor, { color = colors.ui.text_faint }))
  end
  local label_col = layout.vstack(col_children, { gap = 2 })

  local pill = action_button_node({
    label = opts.label,
    cost = opts.cost,
    enabled = opts.enabled,
    w = BTN_W,
    h = BTN_H, -- a fixed compact pill; the hstack tops it against the title line
    id = opts.id,
    on_click = opts.on_click,
  })

  return layout.hstack({ label_col, pill }, { gap = theme.spacing.sm })
end

-- Buy the next mitochondrion (a power plant): deduct its cost from the ATP buffer
-- (sim.energy -- the phase-2 currency) and bump the count. Clamped at affordability.
local function buy_mito(s)
  local cost = catalog.mito_cost(s.mito)
  if s.energy >= cost then
    s.energy = s.energy - cost
    s.mito = s.mito + 1
    persist()
  end
end

-- Buy the next level of an unlocked stage: deduct its geometric cost from the ATP
-- buffer and increment the level. Clamped at affordability.
local function buy_stage(s, id)
  local cost = catalog.stage_cost(s.stages[id] or 0)
  if s.energy >= cost then
    s.energy = s.energy - cost
    s.stages[id] = (s.stages[id] or 0) + 1
    persist()
  end
end

-- INTEGRATE a discovered-but-locked stage: pay its steep one-time ATP cost from the
-- buffer, bring it online (catalog.unlock_stage sets unlocked + level 1), toast the
-- tell, and persist. Guarded on affordability; unlock_stage itself never touches energy,
-- so the deduction is the orchestrator's job. A no-op if unaffordable.
local function integrate_stage(s, id)
  local cost = catalog.stage_unlock_cost(id)
  if s.energy >= cost then
    s.energy = s.energy - cost
    if catalog.unlock_stage(s, id) then
      local def = catalog.STAGE_DEFS[id]
      toast.show(string.format("%s is online", def.label))
      view.spawn(
        view_state,
        fx.flash({ color = colors.secondary_bright, alpha = 0.22, life = 0.4 })
      )
      persist()
    end
  end
end

-- Is the screen point (x, y) inside the panel's right-edge rect? The panel is the only
-- click surface; a tap that misses it lands in the cytoplasm (the ATP-tap zone).
local function is_in_panel(x, y)
  local px = complexcell._panel_x
  return x >= px and x <= px + PANEL_W and y >= PANEL_Y and y <= PANEL_Y + complexcell._panel_h
end

-- The manual ATP TAP: a cytoplasm click injects an ATP burst into the buffer (clamped
-- at the ceiling), on a RANDOM 5-10s cooldown so a held/drummed click can't drain it.
-- The burst scales with gross power (TAP_POWER_SECONDS of production), so it keeps
-- helping as the cell grows. Spawns a pulse + flash + soft beat so the tap reads.
local function tap_atp(s, x, y)
  if atp_tap_cooldown > 0 then
    return
  end
  -- Roll a fresh randomised cooldown each tap so the cadence varies (not a fixed metronome).
  atp_tap_cooldown = ATP_TAP_COOLDOWN_MIN
    + love.math.random() * (ATP_TAP_COOLDOWN_MAX - ATP_TAP_COOLDOWN_MIN)
  -- Burst scales with gross ATP power (mitochondria), so it stays a useful nudge late.
  local burst = catalog.fold(s).power * TAP_POWER_SECONDS
  s.energy = math.min(s.energy + burst, catalog.buffer_max(s))
  view.spawn(view_state, fx.pulse({ x = x, y = y, color = colors.secondary_bright }))
  view.spawn(view_state, fx.flash({ color = colors.secondary_bright, alpha = 0.08, life = 0.15 }))
  sound.play("cytoplasm_active", { volume = 0.8 })
end

-- One DISCOVERED-but-locked stage row: the full organelle name marked "(locked)" over its
-- short role descriptor, beside an "integrate" pill carrying the steep one-time ATP unlock
-- cost, enabled on the buffer. The descriptor sits in the label column UNDER the pill's
-- height, so it costs no row height; it tells the player what the new beat will do before
-- they commit. Once integrated the stage falls through to the normal stage_row level-up
-- path. Routes through the shared buy_row for a uniform rhythm.
local function discovered_row(s, row)
  local cost = catalog.stage_unlock_cost(row.id)
  return buy_row({
    title = string.format("%s   (locked)", row.label),
    descriptor = row.flavor,
    cost = cost,
    label = "integrate",
    enabled = s.energy >= cost,
    id = "integrate_" .. row.id,
    on_click = function() integrate_stage(s, row.id) end,
  })
end

-- One pipeline-stage row: the full organelle name + level over its short role descriptor,
-- beside a right-pinned level-up pill (verb over the next geometric ATP cost), gated on the
-- buffer. The descriptor is a SHORT active-verb line naming the step the stage owns ("fold
-- raw parts into working shape") -- the only guidance the panel gives: it implies which
-- step speeds up when you level it, leaving the player to map a backed-up line to its
-- organelle (no bottleneck highlight, no "this increases X" hand-hold). It rides in the
-- label column under the 34px pill, so all six stage rows stay the same height. Built only
-- for UNLOCKED stages (locked beats are teased by the footer). Shares buy_row.
local function stage_row(s, row)
  local cost = catalog.stage_cost(row.level)
  return buy_row({
    title = string.format("%s   Lv %d", row.label, row.level),
    descriptor = row.flavor,
    cost = cost,
    label = "level up",
    enabled = s.energy >= cost,
    id = "stage_" .. row.id,
    on_click = function() buy_stage(s, row.id) end,
  })
end

-- One vitals GAUGE line: a dim "name" label on the left and a right-aligned "value"
-- string tinted by `color`. A compact two-column row (the name takes the fill, the value
-- hugs the right) so the strip reads like a meter list. Pure presentation -- the caller
-- has already turned the catalog's pure metric into the value string + color token.
local function gauge_row(name, value, color)
  return layout.hstack({
    layout.text(name, { color = colors.ui.text_faint }),
    layout.text(value, { color = color, align = "right" }),
  }, { gap = theme.spacing.sm })
end

-- VITALS (Pillar 5): the biologically-named gauge strip, trimmed to the three read-only
-- metrics the player actually reasons from -- the power balance ratio vs. its safe band
-- (the dial: too little browns out, too much leaks ROS), oxidative stress (ROS, which now
-- climbs whenever power runs hot), and build efficiency (the consequence) -- with NO hint
-- about which lever fixes them. (The old "oxygen use" row was demand/power, a restatement
-- of the balance ratio that barely moved in play, so it was dropped as noise.) Every figure
-- is pure catalog math (folded once via the snapshot's gauge fields); the verdict word +
-- color for the balance ratio come from the BAND_* maps. Values are percentages except the
-- balance ratio (a multiplier vs. the band).
local function vitals_group(snap)
  local children = { layout.text("vitals", { color = colors.ui.text_dim }) }

  -- Oxidative stress (ROS), 0-100%. Climbs whenever power runs hot (over the safe band) and
  -- tints toward the threat token once it crosses the warning fraction, so a leaking cell
  -- reads red on its own -- the fix (ease off mitochondria) is left for the player to reason.
  local ros = snap.ros or 0
  local ros_color = (ros >= ROS_WARN_FRAC) and colors.quaternary or colors.ui.text_muted
  table.insert(
    children,
    gauge_row("cell stress", string.format("%d%%", math.floor(ros * 100 + 0.5)), ros_color)
  )

  -- Balance ratio = power / demand, with its under/ideal/over verdict from the band map.
  -- The number is the ratio (a multiplier), the word + color tell which side of the band.
  local band = snap.balance_band
  local band_word = BAND_LABEL[band] or BAND_LABEL[catalog.BAND_IDEAL]
  local band_color = BAND_COLOR[band] or colors.ui.text_muted
  table.insert(
    children,
    gauge_row(
      "power balance",
      string.format("%.2fx  %s", snap.balance_ratio or 0, band_word),
      band_color
    )
  )

  -- Build efficiency: the Pillar-3 balance scalar as a single percent ("running at N%").
  table.insert(
    children,
    gauge_row(
      "efficiency",
      string.format("%d%%", math.floor((snap.efficiency or 1) * 100 + 0.5)),
      colors.ui.text_muted
    )
  )

  return children
end

-- The whole panel as a declarative node tree, rebuilt each frame so dynamic values
-- and the on_click closures capture the current state. Stacked groups -- header, the
-- boxed read-only vitals, then the build levers (power, assembly line), footer --
-- inside a PAD-padded vstack, on one consistent gap rhythm (xs within a group,
-- sm between groups). Every purchasable line
-- routes through buy_row (label column + two-line cost pill), so the rows are uniform
-- and compact: a stage row is a single label line, so all six stages plus the optional
-- brownout + dying header lines still resolve within the window height (the height story
-- is on the PANEL_H comment). Mirrors cell.lua's build_panel.
local function build_panel(s)
  local rates = catalog.fold(s)
  local buffer_ratio = math.max(0, math.min(s.energy / catalog.buffer_max(s), 1))

  -- HEADER: the headline built total, the ATP buffer bar, the live output/throughput
  -- readouts, and the brownout tell only when the line is power-starved.
  local header = {}
  -- The headline built total, with the live BUILD RATE beside it ("+N /s"). The rate
  -- mirrors the sim's mint exactly (catalog.build_rate), so tuning a stage or trimming
  -- power moves it immediately -- the felt payoff that makes meticulous balancing pay off.
  table.insert(
    header,
    layout.text(
      string.format(
        "built  %s   (+%s /s)",
        format.number(s.built),
        format.number(catalog.build_rate(s))
      ),
      { size = "lg", color = colors.ui.text }
    )
  )
  -- The phase-1 colony, now a frozen statistic carried across the seam.
  local carry = complexcell.state.carry
  if carry then
    local legacy = string.format(
      "from phase 1  ·  colony %s  ·  %s divisions",
      format.number(carry.colony or 0),
      format.number(carry.divisions or 0)
    )
    if (carry.organelles or 0) > 0 then
      legacy = legacy .. string.format("  ·  %d organelles", carry.organelles)
    end
    table.insert(header, layout.text(legacy, { color = colors.ui.text_faint }))
  end
  table.insert(
    header,
    layout.text(
      string.format("ATP energy  %s", format.number(s.energy)),
      { color = colors.ui.text_dim }
    )
  )
  table.insert(
    header,
    layout.bar(buffer_ratio, {
      h = 10,
      color = BAR_COLOR,
      bg_color = colors.with_alpha(colors.ui.white, 0.12),
    })
  )
  table.insert(
    header,
    layout.text(
      string.format(
        "making  %s /s   ·   line speed  %s",
        format.number(s.output),
        format.number(rates.throughput)
      ),
      { color = colors.ui.text_muted }
    )
  )
  if s.brownout then
    -- Kept to one line (the column is the full panel inner width) so the header stays
    -- compact even when this warning and the dying line are both present.
    table.insert(
      header,
      layout.text("BROWNOUT — low power, production slowed", { color = colors.ui.accent })
    )
  end
  -- DYING warning: as stress climbs past STRESS_WARN it creeps toward STRESS_FAIL (lysis).
  -- Stress is two-sided (deficit OR over-power), so we name the actual problem -- "low
  -- power" / "power overload" -- and state it only, no fix hint. Surfaced on the accent
  -- token, like BROWNOUT, so the player can rebalance before it dies.
  if s.stress and s.stress > STRESS_WARN then
    table.insert(
      header,
      layout.text(
        string.format("%s — the cell is dying", lethal_problem(s):upper()),
        { color = colors.ui.accent }
      )
    )
  end

  -- POWER: the mitochondria count + a build-mitochondrion pill, through the shared buy_row
  -- so it reads identically to the stage rows. The one-line descriptor stays short enough
  -- not to wrap (keeping the row two lines tall).
  local mito_cost = catalog.mito_cost(s.mito)
  local power_group = {
    layout.text("power", { color = colors.ui.text_dim }),
    buy_row({
      title = string.format("Mitochondria   x%d", s.mito),
      descriptor = "power plants that make ATP",
      cost = mito_cost,
      label = "build",
      enabled = s.energy >= mito_cost,
      id = "build_mito",
      on_click = function() buy_mito(s) end,
    }),
  }

  -- STAGES: one row per UNLOCKED stage (the others are teased in the footer).
  local stage_children = { layout.text("assembly line", { color = colors.ui.text_dim }) }
  for _, row in ipairs(catalog.stage_snapshot(s)) do
    if row.unlocked then
      -- Online stages keep their level-up row.
      table.insert(stage_children, stage_row(s, row))
    elseif catalog.is_discovered(s, row.id) then
      -- Discovered but not yet integrated: a one-time "integrate" purchase row.
      table.insert(stage_children, discovered_row(s, row))
    end
    -- Undiscovered stages stay hidden here, teased only by the self-revealing footer.
  end

  -- VITALS: the Pillar-5 gauge strip, read from the same snapshot the view draws against
  -- (so the panel numbers and the cell's flow can never disagree). Boxed and lifted to the
  -- TOP of the panel (just below the header) so the read-only health reads as its own
  -- container instead of interleaving with the build levers. The vstack node is stashed on
  -- the module so complexcell.draw can stamp the bordered box behind its resolved rect.
  local vitals_stack = layout.vstack(vitals_group(build_snapshot(s)), { gap = theme.spacing.xs })
  complexcell._vitals_node = vitals_stack

  -- Group order: header, VITALS (boxed), then the build levers (power, then the assembly-
  -- line stages), then the footer. Every group stacks its rows on the same xs intra-group
  -- gap, and the groups stack on the sm gap below -- one consistent rhythm. The tighter
  -- group gap also claws back the height that lets the worst-case full pipeline fit the
  -- window.
  local groups = {
    layout.vstack(header, { gap = theme.spacing.xs }),
    vitals_stack,
    layout.vstack(power_group, { gap = theme.spacing.xs }),
    layout.vstack(stage_children, { gap = theme.spacing.xs }),
  }

  -- FOOTER: the self-revealing next beat, or the FORK line once it's reached. At
  -- the FORK the victory cinematic takes over the whole screen (the panel is
  -- suppressed), so this line is only briefly visible as `built` crosses FORK_AT
  -- on the frame before the cinematic arms.
  local footer_text
  if catalog.reached_fork(s) then
    footer_text = "PATH CHOICE — become a plant or an animal"
  else
    local nxt = catalog.next_gate(s)
    if nxt then
      -- Stair-step: hold the teaser fully hidden until the next beat's predecessor is
      -- integrated, so a stage walled behind an un-integrated one reads "next: …"
      -- rather than teasing its silhouette early.
      local prereq_met = catalog.is_gate_prereq_met(s, nxt)
      local reveal = catalog.reveal(s, nxt.at, prereq_met)
      if reveal == "ready" then
        footer_text = string.format("next: %s — ready to build!", nxt.label)
      elseif reveal == "named" then
        footer_text = string.format("next: %s — almost ready", nxt.label)
      elseif reveal == "silhouette" then
        footer_text = "something is forming…"
      else
        footer_text = "next: …"
      end
    else
      footer_text = "the assembly line is complete"
    end
  end
  table.insert(groups, layout.text(footer_text, { color = colors.ui.text_muted }))

  return layout.vstack(groups, { padding = PAD, gap = theme.spacing.sm })
end

-- Centered footer help line, a direct text overlay (not part of the panel tree). Bare
-- INTERACTION affordances only -- no strategy hints (what to build / which stage to
-- level / how to reach the fork). The player figures out the optimisation themselves.
local function draw_help(width)
  text(
    rect(0, love.graphics.getHeight() - 44, width, 16),
    "click the glowing mitochondrion to inject energy   ·   [r] fresh cell",
    { color = colors.with_alpha(colors.ui.text_faint, 0.7), align = "center" }
  )
end

-- The LYSIS game-over overlay: a dimming sheet + cause line over the frozen interior,
-- held for COLLAPSE_ANIM before the fresh cell reloads. Mirrors cell.lua's draw_collapse
-- (a darkening wash that deepens as the beat runs, the threat token on the headline).
local function draw_collapse(width)
  local height = love.graphics.getHeight()
  local progress = 1 - math.max(0, math.min(collapse_anim / COLLAPSE_ANIM, 1)) -- 0 -> 1
  love.graphics.setColor(0, 0, 0, 0.55 * progress)
  love.graphics.rectangle("fill", 0, 0, width, height)
  love.graphics.setColor(1, 1, 1, 1)
  text(rect(0, height / 2 - 16, width, 30), "THE CELL BURST", {
    font = "hud_lg",
    color = colors.with_alpha(colors.quaternary, math.min(1, progress * 1.5)),
    align = "center",
  })
end

-- The seam intro sheet: a full-screen teal (the cell's own primary token) that fades
-- out over INTRO_FADE, so phase 2 opens straight out of phase 1's teal plunge. Drawn
-- LAST (over the interior + panel) so the whole screen lifts as one. No-op once drained.
local function draw_intro()
  if intro_fade <= 0 then
    return
  end
  local w, h = love.graphics.getDimensions()
  local prim = colors.primary
  love.graphics.setColor(prim[1], prim[2], prim[3], math.min(1, intro_fade / INTRO_FADE))
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

function complexcell.draw()
  local s = complexcell.state.sim
  local width = love.graphics.getWidth()

  -- The centre "feed me" ring shows only when a tap would actually land: off cooldown AND
  -- in normal play (the lysis/cinematic/fork beats below swallow clicks, so the cue must
  -- not invite a tap that does nothing). Cosmetic-only flag, threaded through the snapshot.
  local tap_ready = atp_tap_cooldown <= 0
    and not collapsing
    and not fork_mode
    and not transition.active(transition_state)

  -- The interior swarm first (the other agent's view, drawn against the snapshot
  -- contract), THEN the panel over it -- mirroring cell.draw's world-then-panel pipe.
  view.draw(view_state, build_snapshot(s, tap_ready))

  -- The cell has LYSED: the game-over beat owns the frame (panel/help suppressed). The
  -- overlay + toast play over the frozen interior until update() reloads a fresh cell.
  if collapsing then
    draw_collapse(width)
    toast.draw(width)
    return
  end

  -- The end-of-phase-2 finale OWNS the screen (the panel is suppressed):
  --   * the victory cinematic plays over the frozen interior, its overlay drawn by
  --     the REUSED transition module (centred on screen-centre coords);
  --   * at the white peak on_reset flips fork_mode to "choice" -- the modal is then
  --     revealed beneath the lifting white-out (drawn AFTER transition.draw so the
  --     cards bleed up through the fade), and clicking a card commits the kingdom;
  --   * once chosen, the terminal ascension placeholder holds the screen.
  if fork_mode then
    if fork_mode == "ascension" then
      fork.draw("ascension", { choice = complexcell.state.fork_choice })
      complexcell._fork_click_map = nil
    else
      complexcell._fork_click_map = fork.draw("choice", { on_choose = choose_kingdom })
    end
    -- During the white-out fade the cinematic is still active; draw its overlay ON
    -- TOP of the freshly-revealed modal so the white sheet lifts to expose it.
    if transition.active(transition_state) then
      transition.draw(transition_state, transition_state.x, transition_state.y)
    end
    return
  end

  if transition.active(transition_state) then
    -- Pre-reset cinematic: the build-up + white-out over the frozen interior. The
    -- panel/help/toast are suppressed -- the screen belongs to the transition.
    transition.draw(transition_state, transition_state.x, transition_state.y)
    return
  end

  -- The panel rides the RIGHT edge: its left x is computed from the window width
  -- each frame (it hugs its content height, so only x moves with resize).
  local panel_x = width - PANEL_W - PANEL_MARGIN
  complexcell._panel_x = panel_x

  -- Build + resolve the panel tree into the right-edge panel rect, draw its themed
  -- backing, then render it -- keeping this frame's click map on the module so
  -- mousepressed can hit-test it (one-frame lag is standard and harmless).
  interaction.begin_frame()
  local tree = build_panel(s)
  layout.resolve(tree, rect(panel_x, PANEL_Y, PANEL_W, PANEL_H))
  complexcell._panel_h = tree.resolved_rect.h
  primitives.container(rect(panel_x, PANEL_Y, PANEL_W, complexcell._panel_h), "content")
  -- Box the read-only VITALS: layout nodes carry no background, so stamp a bordered 'row'
  -- container behind the stashed vitals vstack's resolved rect (expanded by VITALS_BOX_PAD
  -- so the border breathes around the gauges) BEFORE the renderer draws the gauge text over
  -- it. build_panel stashes the node every frame, so the rect is current.
  local vitals_node = complexcell._vitals_node
  if vitals_node and vitals_node.resolved_rect then
    local vr = vitals_node.resolved_rect
    primitives.container(
      rect(
        vr.x - VITALS_BOX_PAD,
        vr.y - VITALS_BOX_PAD,
        vr.w + VITALS_BOX_PAD * 2,
        vr.h + VITALS_BOX_PAD * 2
      ),
      "row"
    )
  end
  complexcell._click_map = renderer.draw(tree, nil)
  local mx, my = love.mouse.getPosition()
  interaction.commit_frame(mx, my, love.mouse.isDown(1))

  draw_help(width)
  toast.draw(width)
  draw_intro() -- the teal seam sheet lifts over everything as phase 2 opens
end

function complexcell.keypressed(key)
  if key == "r" then
    -- DEV: a fresh complex cell -- wipe the save and re-enter from the seam with no
    -- carried phase-1 stats, the instant clean-slate start for tuning.
    save.remove(SAVE_NAME)
    complexcell.enter_from_seam({})
  elseif key == "f" then
    -- DEV: force the end-of-phase FORK (the real climb to FORK_AT is a ~10-min
    -- playthrough). Slam `built` to the gate + apply any gates it crosses, so the
    -- next update arms the victory cinematic -- mirrors cell.lua's [m]. No-op once
    -- the fork flow is already up.
    if not fork_mode and not transition.active(transition_state) then
      local s = complexcell.state.sim
      s.built = catalog.FORK_AT
      -- DEV: the real path only DISCOVERS gates (the player integrates them), but the
      -- dev fork shortcut wants every stage live -- so discover AND unlock all of them.
      catalog.discover_gates(s)
      for _, id in ipairs(catalog.STAGES) do
        catalog.unlock_stage(s, id)
      end
    end
  end
end

function complexcell.mousepressed(x, y, button_index)
  if button_index ~= 1 then
    return
  end
  -- The end-of-phase finale owns the screen. During the cinematic, swallow clicks.
  -- In the CHOICE modal, a card hit commits the kingdom; the ascension placeholder
  -- has no click targets.
  if fork_mode then
    if fork_mode == "choice" and not transition.active(transition_state) then
      local cb = complexcell._fork_click_map
        and renderer.hit_test(complexcell._fork_click_map, x, y)
      if cb then
        cb()
      end
    end
    return
  end
  if transition.active(transition_state) then
    return
  end
  -- The lysis beat owns the frame: swallow clicks until the fresh cell reloads.
  if collapsing then
    return
  end
  -- A widget hit fires its on_click closure; a click that misses the panel can feed a manual
  -- ATP burst -- but ONLY if it lands on the glowing (primed) mitochondrion. The view stamps
  -- that power plant's screen position each draw; a miss does nothing, so the player hunts the
  -- lit plant (a fresh one lights when the cooldown resets).
  local cb = complexcell._click_map and renderer.hit_test(complexcell._click_map, x, y)
  if cb then
    cb()
  elseif not is_in_panel(x, y) then
    local tx, ty, tr = view.tap_target(view_state)
    if tx then
      local dx, dy = x - tx, y - ty
      if dx * dx + dy * dy <= tr * tr then
        tap_atp(complexcell.state.sim, x, y)
      end
    end
  end
end

return complexcell
