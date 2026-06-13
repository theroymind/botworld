-- Reincarnate confirm modal: the manual prestige cash-out gate. Where the
-- endosymbiosis finale (transition.lua) ENDS phase 1 into phase 2, reincarnation is
-- the VOLUNTARY within-phase loop -- bank the colony's banked endospore peak, collapse
-- this generation, and regrow faster off the spent tree. This module is the confirm
-- card the player taps before that collapse fires: it states what will be banked and
-- the beat ("collapse this generation -- regrow faster"), then routes the choice back
-- out through on_confirm / on_cancel callbacks (the orchestrator owns the cinematic +
-- the actual collapse). Mirrors complexcell/fork.lua exactly: love.* lives ONLY in the
-- draw fns, the card is a declarative UI-kit node tree resolved -> renderer.draw -> the
-- returned click map the orchestrator's mousepressed hit-tests (one-frame lag, standard).
local ui = require("lib.love-ui")
local layout = ui.layout
local renderer = ui.renderer
local primitives = ui.primitives
-- Colors come through the game facade (NOT ui.colors): requiring it applies the
-- botworld token overrides before any value below is captured at load time.
local colors = require("lib.engine.colors")
local format = require("lib.engine.format")
local interaction = ui.interaction
local rect = ui.primitives.rect
local text = ui.primitives.text
local button = ui.primitives.button

local reincarnate = {}

-- Card geometry for the centered modal (screen-space, computed each draw).
local CARD_W = 360
local CARD_H = 220
local BTN_H = 44 -- the confirm/cancel button row height
local BTN_GAP = 16 -- gap between the two side-by-side buttons

-- ============================================================================
-- Draw (love.* lives only below this line). Dims the interior behind the card,
-- then builds + resolves + renders a declarative node tree, returning the click map
-- so the orchestrator's mousepressed can hit-test it (one-frame lag, standard).
-- ============================================================================

-- A full-screen dark wash so the card reads over the (frozen) dish.
local function draw_scrim(alpha)
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(0, 0, 0, alpha)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- One button zone: the themed button decoration (registers the hover/click zone via
-- its id) under a centered label, composed in a custom draw_fn node exactly like the
-- panel's action buttons. accent tints the label so confirm reads "go" and cancel "stay".
local function button_node(id, label, accent, on_click)
  return {
    type = "node",
    w = "fill",
    h = BTN_H,
    draw_fn = function(r)
      button.draw(r, "", { id = id, opacity = 0.0 })
      primitives.container(r, "scene_panel")
      button.draw(r, "", { id = id, opacity = 0.0 })
      text(rect(r.x, r.y + math.floor((r.h - 16) / 2), r.w, 16), label, {
        font = "hud",
        color = accent,
        align = "center",
      })
    end,
    on_click = on_click,
    resolved_rect = nil,
  }
end

-- The confirm card: a centered title, the banked-endospores line, the trade-off beat, and
-- the confirm/cancel button row. `reveal` (0..1) scrims the dish and is the fade hook
-- (1 = fully up). Returns the click map for hit-testing.
function reincarnate.draw_card(opts)
  local w, h = love.graphics.getDimensions()
  local reveal = opts.reveal or 1
  draw_scrim(0.72 * reveal)

  local rx = math.floor((w - CARD_W) / 2)
  local ry = math.floor(h * 0.5 - CARD_H / 2)

  -- The card backing as a content container; the copy + buttons stack inside its pad.
  primitives.container(rect(rx, ry, CARD_W, CARD_H), "scene_panel")

  text(rect(rx, ry + 24, CARD_W, 28), "Reincarnate?", {
    font = "hud_lg",
    color = colors.secondary,
    align = "center",
  })
  text(rect(rx, ry + 72, CARD_W, 20), "bank " .. format.number(opts.amount) .. " endospores", {
    font = "hud",
    color = colors.ui.text,
    align = "center",
  })
  text(rect(rx + 16, ry + 100, CARD_W - 32, 18), "collapse this generation — regrow faster", {
    font = "hud_small",
    color = colors.ui.text_muted,
    align = "center",
  })

  -- The two buttons as an hstack resolved into a rect inside the card's lower pad.
  local row = layout.hstack({
    button_node("reincarnate_cancel", "keep growing", colors.ui.text, opts.on_cancel),
    button_node("reincarnate_confirm", "reincarnate", colors.secondary, opts.on_confirm),
  }, { gap = BTN_GAP })
  local row_x = rx + 24
  local row_y = ry + CARD_H - BTN_H - 24
  layout.resolve(row, rect(row_x, row_y, CARD_W - 48, BTN_H))

  return renderer.draw(row, nil)
end

-- Convenience for the orchestrator: begin a UI-kit frame, draw the card, and commit
-- interaction. opts = { amount, reveal, on_confirm, on_cancel }. Returns the click map.
function reincarnate.draw(opts)
  interaction.begin_frame()
  local click_map = reincarnate.draw_card(opts)
  local mx, my = love.mouse.getPosition()
  interaction.commit_frame(mx, my, love.mouse.isDown(1))
  return click_map
end

return reincarnate
