local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local container = {}

local BLACK = { 0, 0, 0 }

local VARIANTS = {
  default = { color = BLACK, opacity = 0.5, radius = 4 },
  message = { color = BLACK, opacity = 0.7, radius = 4 },
  overlay = { color = BLACK, opacity = 0.75, radius = 6 },
  scene_panel = {
    color = colors.ui.bg_dark,
    opacity = 0.92,
    radius = 6,
    border = colors.ui.border,
  },
  content = {
    color = colors.ui.bg_panel,
    opacity = 1,
    radius = 4,
    border = colors.ui.border_dim,
  },
  content_borderless = {
    color = colors.ui.bg_panel,
    opacity = 0.35,
    radius = 4,
  },
  row = {
    color = colors.ui.bg_dark,
    opacity = 0.5,
    radius = theme.sizing.row_radius,
    border = colors.ui.border_dim,
  },
  input = {
    color = BLACK,
    opacity = 0.6,
    radius = theme.sizing.text_input_radius,
    border = colors.scene.accent,
  },
  inspector = { color = BLACK, opacity = 0.85, radius = 2 },
  editor_panel = {
    color = colors.surface,
    opacity = 0.92,
    radius = 4,
    border = colors.border,
  },
}

local function draw_border(r, border_color, radius)
  if not border_color then
    return
  end
  local alpha = border_color[4] or 1
  love.graphics.setColor(border_color[1], border_color[2], border_color[3], alpha)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, radius, radius)
end

function container.draw(r, variant_name)
  local v = VARIANTS[variant_name or "default"]
  assert(v, "unknown container variant: " .. tostring(variant_name))

  local color = v.color
  love.graphics.setColor(color[1], color[2], color[3], v.opacity)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, v.radius, v.radius)

  draw_border(r, v.border, v.radius)
end

function container.get_variant(name)
  local v = VARIANTS[name]
  assert(v, "unknown container variant: " .. tostring(name))
  return v
end

return setmetatable(container, {
  __call = function(_, r, variant_name) container.draw(r, variant_name) end,
})
