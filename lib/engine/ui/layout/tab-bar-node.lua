local fonts = require("lib.engine.ui.fonts")
local text = require("lib.engine.ui.primitives.text")
local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local TAB_GAP = 16

local function tab_bar(labels, config)
  local cfg = config or {}
  local active_index = cfg.active_index or 1
  local on_select = cfg.on_select
  local font_name = theme.font.sm
  local font = fonts.get(font_name)
  local tab_height = font:getHeight() + 6

  local children = {}
  for index, label in ipairs(labels) do
    local is_active = index == active_index
    local tab_width = font:getWidth(label) + 8
    table.insert(children, {
      type = "node",
      w = tab_width,
      h = tab_height,
      draw_fn = function(r)
        local label_color = is_active and colors.ui.accent or colors.ui.text_muted
        text(r, label, { font = font_name, color = label_color, align = "center" })
        if is_active then
          love.graphics.setColor(colors.ui.accent)
          love.graphics.rectangle("fill", r.x, r.y + r.h - 2, r.w, 2)
        end
      end,
      on_click = on_select and function() on_select(index) end or nil,
      resolved_rect = nil,
    })
  end

  return {
    type = "hstack",
    gap = TAB_GAP,
    padding = 0,
    w = "fill",
    h = "content",
    children = children,
    resolved_rect = nil,
  }
end

return tab_bar
