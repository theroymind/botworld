local slot = require("lib.engine.ui.primitives.slot")
local colors = require("lib.engine.ui.colors")
local highlight_modes = require("lib.engine.ui.highlight-modes")
local theme = require("lib.engine.ui.theme")

local M = {}

function M.resolve_border_color(config)
  if config.category == "equipment" then
    return colors.game.equip_border
  end
  return colors.game.item_border
end

local function slot_node(config)
  local cfg = config or {}
  local border_color = M.resolve_border_color(cfg)
  local slot_highlight = cfg.selected and highlight_modes.SELECTED or nil
  local size = cfg.size or theme.sizing.slot_size

  return {
    type = "node",
    w = size,
    h = size,
    draw_fn = function(r) slot.draw(r, { border_color = border_color, highlight = slot_highlight }) end,
    on_click = cfg.on_click,
    on_right_click = cfg.on_right_click,
    on_hover = cfg.on_hover,
    resolved_rect = nil,
  }
end

return setmetatable(M, {
  __call = function(_, config) return slot_node(config) end,
})
