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
local TOAST_SECONDS = 4

local PANEL_MARGIN = 16 -- gap from the window edge (panel x is computed each frame)
local PANEL_Y = 16
local PANEL_W = 320
local PANEL_H = 540
local PAD = 16
local BTN_W = 96 -- fixed-width action button, pinned right by the fill label column
local BTN_H = 40
local BAR_COLOR = colors.secondary -- the ATP buffer bar rides the global nourishment token

complexcell.state = nil

local view_state
local save_accum = 0
local toast_text
local toast_timer = 0
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

local function set_toast(message)
  toast_text = message
  toast_timer = TOAST_SECONDS
end

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
  sound.load("endosymbiosis", "assets/sounds/endosymbiosis.ogg")
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
      catalog.apply_gates(complexcell.state.sim)
    end
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
  local newly = catalog.apply_gates(s)
  for _, id in ipairs(newly) do
    local def = catalog.STAGE_DEFS[id]
    set_toast(string.format("Unlocked %s — %s", def.label, def.flavor))
    persist()
  end
end

function complexcell.update(dt)
  if not complexcell.state then
    return
  end
  tween.update(dt) -- advance the UI kit's hover/press lighten transitions
  view.update(view_state, dt) -- the interior keeps animating beneath the overlay

  -- Advance the victory cinematic whenever it's armed. The view/tween still update
  -- (so the fx beats play + the white-out fades), but the economy is frozen by
  -- tick's guard, and we bail before the autosave/arming so the terminal beat is
  -- clean. The choice modal is revealed by on_reset at the white peak.
  if transition.active(transition_state) then
    transition.update(transition_state, dt)
    if toast_timer > 0 then
      toast_timer = toast_timer - dt
    end
    return
  end

  if toast_timer > 0 then
    toast_timer = toast_timer - dt
  end

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
local function build_snapshot(s)
  return {
    built = s.built,
    energy = s.energy,
    buffer_max = catalog.BUFFER_MAX,
    output = s.output,
    throughput = catalog.fold(s).throughput,
    brownout = s.brownout,
    mito = s.mito,
    fuel_factor = catalog.FUEL_FACTOR,
    bottleneck_id = catalog.bottleneck_id(s),
    stages = catalog.stage_snapshot(s),
  }
end

-- A themed action button carrying a dim cost/flavor sublabel and an affordability
-- gate -- the same composition cell.lua uses: primitives.button decoration plus two
-- stacked text lines in a custom draw_fn node, registering the hover zone + on_click
-- only when enabled.
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

-- One pipeline-stage row: a fill-width label column (name + level over its flavor)
-- and a right-pinned level-up button gated on the ATP buffer. Built only for
-- UNLOCKED stages (locked beats are teased by the self-revealing footer instead).
local function stage_row(s, row)
  local label_col = layout.vstack({
    layout.text(
      string.format("%s   Lv %d", row.label, row.level),
      { color = row.is_bottleneck and colors.ui.accent or colors.ui.text }
    ),
    layout.text(row.flavor, { color = colors.ui.text_faint }),
  }, { gap = 2 })

  local cost = catalog.stage_cost(row.level)
  local affordable = s.energy >= cost
  local right = action_button_node({
    label = "level up",
    sublabel = format.number(cost) .. " atp",
    enabled = affordable,
    w = BTN_W,
    h = BTN_H,
    id = "stage_" .. row.id,
    on_click = function() buy_stage(s, row.id) end,
  })

  return layout.hstack({ label_col, right }, { gap = theme.spacing.sm })
end

-- The whole panel as a declarative node tree, rebuilt each frame so dynamic values
-- and the on_click closures capture the current state. Stacked groups (header /
-- power / stages / footer) inside a PAD-padded vstack. Mirrors cell.lua's build_panel.
local function build_panel(s)
  local rates = catalog.fold(s)
  local buffer_ratio = math.max(0, math.min(s.energy / catalog.BUFFER_MAX, 1))

  -- HEADER: the headline built total, the ATP buffer bar, the live output/throughput
  -- readouts, and the brownout tell only when the line is power-starved.
  local header = {}
  table.insert(
    header,
    layout.text("built  " .. format.number(s.built), { size = "lg", color = colors.ui.text })
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
    layout.text(string.format("ATP  %s", format.number(s.energy)), { color = colors.ui.text_dim })
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
        "output  %s /s   ·   throughput  %s",
        format.number(s.output),
        format.number(rates.throughput)
      ),
      { color = colors.ui.text_muted }
    )
  )
  if s.brownout then
    table.insert(
      header,
      layout.text("BROWNOUT — power deficit, line dimmed", { color = colors.ui.accent })
    )
  end

  -- POWER: the mitochondria count + a build-mitochondrion button (ATP).
  local mito_cost = catalog.mito_cost(s.mito)
  local power_group = {
    layout.text("power", { color = colors.ui.text_dim }),
    layout.hstack({
      layout.vstack({
        layout.text(string.format("Mitochondria   x%d", s.mito), { color = colors.ui.text }),
        layout.text("the power plants -- gross ATP/sec", { color = colors.ui.text_faint }),
      }, { gap = 2 }),
      action_button_node({
        label = "build",
        sublabel = format.number(mito_cost) .. " atp",
        enabled = s.energy >= mito_cost,
        w = BTN_W,
        h = BTN_H,
        id = "build_mito",
        on_click = function() buy_mito(s) end,
      }),
    }, { gap = theme.spacing.sm }),
  }

  -- STAGES: one row per UNLOCKED stage (the others are teased in the footer).
  local stage_children = { layout.text("assembly line", { color = colors.ui.text_dim }) }
  for _, row in ipairs(catalog.stage_snapshot(s)) do
    if row.unlocked then
      table.insert(stage_children, stage_row(s, row))
    end
  end

  local groups = {
    layout.vstack(header, { gap = theme.spacing.xs }),
    layout.vstack(power_group, { gap = theme.spacing.xs }),
    layout.vstack(stage_children, { gap = theme.spacing.sm }),
  }

  -- FOOTER: the self-revealing next beat, or the FORK line once it's reached. At
  -- the FORK the victory cinematic takes over the whole screen (the panel is
  -- suppressed), so this line is only briefly visible as `built` crosses FORK_AT
  -- on the frame before the cinematic arms.
  local footer_text
  if catalog.reached_fork(s) then
    footer_text = "FORK reached — a choice of kingdoms"
  else
    local nxt = catalog.next_gate(s)
    if nxt then
      local reveal = catalog.reveal(s, nxt.at)
      if reveal == "ready" then
        footer_text = string.format("next: %s — ready at built %d", nxt.label, nxt.at)
      elseif reveal == "named" then
        footer_text = string.format("next: %s forming at built %d", nxt.label, nxt.at)
      elseif reveal == "silhouette" then
        footer_text = "next: something is forming…"
      else
        footer_text = "next: …"
      end
    else
      footer_text = "the assembly line is complete"
    end
  end
  table.insert(groups, layout.text(footer_text, { color = colors.ui.text_muted }))

  return layout.vstack(groups, { padding = PAD, gap = theme.spacing.md })
end

-- Centered footer help line, a direct text overlay (not part of the panel tree).
local function draw_help(width)
  text(
    rect(0, love.graphics.getHeight() - 44, width, 16),
    "build mitochondria for power   ·   level the bottleneck stage   ·   grow `built` to the fork   ·   [r] fresh cell",
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

function complexcell.draw()
  local s = complexcell.state.sim
  local width = love.graphics.getWidth()

  -- The interior swarm first (the other agent's view, drawn against the snapshot
  -- contract), THEN the panel over it -- mirroring cell.draw's world-then-panel pipe.
  view.draw(view_state, build_snapshot(s))

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
  complexcell._click_map = renderer.draw(tree, nil)
  local mx, my = love.mouse.getPosition()
  interaction.commit_frame(mx, my, love.mouse.isDown(1))

  draw_help(width)
  draw_toast(width)
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
      complexcell.state.sim.built = catalog.FORK_AT
      catalog.apply_gates(complexcell.state.sim)
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
  -- A widget hit fires its on_click closure; clicks outside the panel fall through
  -- to the interior, which has no click targets in this first draft (the panel is
  -- the only interaction surface -- interior click targets land in a later pass).
  local cb = complexcell._click_map and renderer.hit_test(complexcell._click_map, x, y)
  if cb then
    cb()
  end
end

return complexcell
