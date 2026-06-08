local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")
local interaction_state = require("lib.engine.ui.interaction-state")
local math_utils = require("lib.engine.ui.util.math-utils")

local grip = {}

function grip.draw(r, config)
  local cfg = config or {}
  local id = cfg.id
  local idle_color = cfg.color or colors.foreground_faint
  local active_color = cfg.active_color or colors.foreground_dim

  local lighten = id and interaction_state.get_lighten(id) or 0
  local color = math_utils.lerp_color(idle_color, active_color, lighten)

  local dot_count = theme.grip.dot_count
  local dot_h = theme.grip.dot_height
  local gap = theme.grip.dot_gap

  local total_h = dot_count * dot_h + (dot_count - 1) * gap
  local start_y = r.y + math.floor((r.h - total_h) / 2)
  local dot_w = math.max(2, r.w - 2)
  local dot_x = r.x + math.floor((r.w - dot_w) / 2)

  love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  for i = 0, dot_count - 1 do
    love.graphics.rectangle("fill", dot_x, start_y + i * (dot_h + gap), dot_w, dot_h, 1, 1)
  end
end

return setmetatable(grip, {
  __call = function(_, r, config) grip.draw(r, config) end,
})
