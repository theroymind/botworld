-- The end-of-phase-2 FORK: the plant/animal choice screen and its ascension
-- placeholder, factored out of complexcell.lua to keep the orchestrator's economy
-- wiring legible. This is the phase-2 sibling of nothing in phase 1 -- where the
-- cell layer's endosymbiosis finale white-outs into a fresh lineage, the complex
-- cell's finale white-outs into a CHOICE: light-fed plant vs. eating-fed animal,
-- the defining fork that (per docs/PHASE_2.md) slams the fuel mix to one pole and
-- shapes the phase-3 ascension. Phase 3 isn't built, so the chosen path lands on a
-- graceful "to be continued" placeholder for now.
--
-- The pure parts (mode constants, the choice-recording mutation) are love-free and
-- headless-testable; the draw functions touch love.* ONLY (called from
-- complexcell.draw) and build declarative node trees through the canonical UI kit,
-- reusing primitives.container for the modal backing and the cards -- the same
-- retained-mode pipeline the panel uses (resolve -> renderer.draw -> hit_test).
local ui = require("lib.love-ui")
local layout = ui.layout
local renderer = ui.renderer
local primitives = ui.primitives
-- Colors come through the game facade (NOT ui.colors): requiring it applies the
-- botworld token overrides before any value below is captured at load time.
local colors = require("lib.engine.colors")
local theme = ui.theme
local interaction = ui.interaction
local rect = ui.primitives.rect
local text = ui.primitives.text
local button = ui.primitives.button

local fork = {}

-- The two kingdoms. Each carries its display copy and its one-line phase-3 bias --
-- pulled straight from docs/PHASE_2.md's fork section.
fork.CHOICES = {
  {
    id = "plant",
    label = "PLANT",
    tagline = "feeds on light · self-reliant · steady builder",
    bias = "phase 3 leans calm and idle-friendly — root down and grow",
    accent = colors.secondary, -- green: the interior fills green
  },
  {
    id = "animal",
    label = "ANIMAL",
    tagline = "eats to grow · fast · always on the move",
    bias = "phase 3 leans active and hands-on — move, hunt, sense",
    accent = colors.tertiary, -- warm sand: active intake
  },
}

-- Card geometry for the centered modal (screen-space, computed each draw).
local CARD_W = 300
local CARD_H = 260
local CARD_GAP = 32

-- PURE: record the player's pick onto the sim-layer state. Sets fork_choice to the
-- chosen kingdom id ("plant"|"animal"); validated against CHOICES so a stray id is
-- ignored. Returns the recorded id, or nil if the id was unknown. Love-free and
-- headless-testable -- the orchestrator wraps this with persistence + the mode flip.
function fork.record_choice(state, id)
  for _, c in ipairs(fork.CHOICES) do
    if c.id == id then
      state.fork_choice = id
      return id
    end
  end
  return nil
end

-- The display copy for a recorded choice (the ascension placeholder reads this).
function fork.choice_def(id)
  for _, c in ipairs(fork.CHOICES) do
    if c.id == id then
      return c
    end
  end
  return nil
end

-- ============================================================================
-- Draw (love.* lives only below this line). Both screens dim the interior behind
-- them, then build + resolve + render a declarative node tree, returning the click
-- map so the orchestrator's mousepressed can hit-test it (one-frame lag, standard).
-- ============================================================================

-- A full-screen dark wash so the modal reads over the (frozen) interior swarm.
local function draw_scrim(alpha)
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(0, 0, 0, alpha)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- One option card: a themed content container with the kingdom name (in its accent),
-- a tagline, and the phase-3 bias line, the whole rect a clickable button zone. Built
-- as a custom draw_fn node so the card backing + accent text + hover lighten compose
-- exactly like the panel's action buttons.
local function card_node(choice, on_click)
  return {
    type = "node",
    w = CARD_W,
    h = CARD_H,
    draw_fn = function(r)
      -- Backing + hover-lit border via the button decoration (registers the zone).
      primitives.container(r, "scene_panel")
      button.draw(r, "", { id = "fork_" .. choice.id, opacity = 0.0 })
      text(rect(r.x, r.y + 36, r.w, 30), choice.label, {
        font = "hud_lg",
        color = choice.accent,
        align = "center",
      })
      text(rect(r.x + 16, r.y + 96, r.w - 32, 18), choice.tagline, {
        font = "hud",
        color = colors.ui.text,
        align = "center",
      })
      text(rect(r.x + 16, r.y + 150, r.w - 32, 60), choice.bias, {
        font = "hud_small",
        color = colors.ui.text_muted,
        align = "center",
      })
      text(rect(r.x, r.y + r.h - 36, r.w, 16), "choose", {
        font = "hud_small",
        color = colors.with_alpha(choice.accent, 0.7),
        align = "center",
      })
    end,
    on_click = on_click,
    resolved_rect = nil,
  }
end

-- The choice modal: a centered title + note over two large side-by-side cards. The
-- reveal alpha (0..1, eased up as the white-out fades) scrims the interior and is
-- the orchestrator's hook for the white-out -> choice handoff. on_choose(id) fires
-- when a card is clicked. Returns the click map for hit-testing.
function fork.draw_choice(reveal, on_choose)
  local w, h = love.graphics.getDimensions()
  draw_scrim(0.72 * reveal)

  -- Heading + the "shapes phase 3" note as direct centered overlays (the vstack
  -- doesn't center fixed-width children, so the title rides as plain centered text,
  -- exactly like the panel's help/toast lines and the transition's title block).
  local total_w = CARD_W * 2 + CARD_GAP
  local rx = math.floor((w - total_w) / 2)
  local ry = math.floor(h * 0.5 - CARD_H / 2)
  text(rect(0, ry - 88, w, 28), "Choose your kingdom", {
    font = "hud_lg",
    color = colors.ui.text,
    align = "center",
  })
  text(rect(0, ry - 52, w, 18), "this choice shapes the ascension into phase 3", {
    font = "hud",
    color = colors.ui.text_muted,
    align = "center",
  })

  -- The two cards as an hstack resolved into a rect sized to EXACTLY the cards +
  -- their gap, so they sit centered (the hstack fills the region it's given).
  local cards = layout.hstack({
    card_node(fork.CHOICES[1], function() on_choose(fork.CHOICES[1].id) end),
    card_node(fork.CHOICES[2], function() on_choose(fork.CHOICES[2].id) end),
  }, { gap = CARD_GAP })
  layout.resolve(cards, rect(rx, ry, total_w, CARD_H))

  local click_map = renderer.draw(cards, nil)
  return click_map
end

-- The ascension placeholder: the terminal screen once a path is chosen. A clean,
-- full-screen on-theme message in the chosen kingdom's accent -- phase 3 isn't built,
-- so this is where the draft lands. No click targets.
function fork.draw_ascension(id)
  local w, h = love.graphics.getDimensions()
  draw_scrim(0.88)
  local def = fork.choice_def(id) or fork.CHOICES[1]

  local tree = layout.vstack({
    layout.text(def.label .. " path chosen", {
      size = "lg",
      color = def.accent,
      align = "center",
    }),
    layout.text(def.tagline, { color = colors.ui.text, align = "center" }),
    layout.text("Phase 3 awaits", { color = colors.ui.text_dim, align = "center" }),
    layout.text("— to be continued —", {
      color = colors.with_alpha(colors.ui.text_faint, 0.7),
      align = "center",
    }),
  }, { gap = theme.spacing.md, align = "center" })

  local region_w = 480
  local region_h = 160
  local rx = math.floor((w - region_w) / 2)
  local ry = math.floor((h - region_h) / 2)
  layout.resolve(tree, rect(rx, ry, region_w, region_h))
  renderer.draw(tree, nil)
end

-- Convenience for the orchestrator: begin a UI-kit frame, draw the active fork
-- screen, and commit interaction. `mode` is "choice" or "ascension". Returns the
-- click map (nil for ascension). reveal is the choice fade-in (ignored in ascension).
function fork.draw(mode, opts)
  interaction.begin_frame()
  local click_map = nil
  if mode == "ascension" then
    fork.draw_ascension(opts.choice)
  else
    click_map = fork.draw_choice(opts.reveal or 1, opts.on_choose)
  end
  local mx, my = love.mouse.getPosition()
  interaction.commit_frame(mx, my, love.mouse.isDown(1))
  return click_map
end

return fork
