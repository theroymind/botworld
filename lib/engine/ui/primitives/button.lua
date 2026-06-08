local fonts = require("lib.engine.ui.fonts")
local rect = require("lib.engine.ui.primitives.rect")
local text = require("lib.engine.ui.primitives.text")
local interaction_state = require("lib.engine.ui.interaction-state")
local colors = require("lib.engine.ui.colors")
local math_utils = require("lib.engine.ui.util.math-utils")

local button = {}

button.DEFAULT = "default"
button.DESTRUCTIVE = "destructive"

local VARIANT_STYLES = {
  [button.DEFAULT] = {
    border_color = colors.scene.border,
    text_color = colors.ui.white,
    opacity = 0.45,
  },
  [button.DESTRUCTIVE] = {
    border_color = colors.palette.brown_red,
    text_color = colors.palette.brown_red,
    opacity = 0.45,
  },
}

local VALID_VARIANTS = {
  [button.DEFAULT] = true,
  [button.DESTRUCTIVE] = true,
}

function button.validate_variant(value)
  assert(VALID_VARIANTS[value], "invalid button variant: " .. tostring(value))
end

local WHITE = { 1, 1, 1, 1 }

local function lighten_color(c, amount)
  local lit = math_utils.lerp_color(c, WHITE, amount * 0.25)
  lit[4] = c[4] or 1
  return lit
end

local function draw_decoration(r, opacity, border_color, radius)
  love.graphics.setColor(colors.with_alpha(colors.shadow, opacity))
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, radius, radius)

  local alpha = border_color[4] or 1
  love.graphics.setColor(border_color[1], border_color[2], border_color[3], alpha)
  love.graphics.rectangle("line", r.x, r.y, r.w, r.h, radius, radius)
end

function button.draw(r, label, config)
  local cfg = config or {}
  local variant = VARIANT_STYLES[cfg.variant] or VARIANT_STYLES[button.DEFAULT]
  local border_color = cfg.border_color or variant.border_color
  local opacity = cfg.opacity or variant.opacity
  local font = cfg.font or "hud_small"
  local text_color = cfg.text_color or variant.text_color
  local radius = cfg.radius or 4

  local lighten = 0
  if cfg.id then
    interaction_state.register_zone(cfg.id, r)
    lighten = interaction_state.get_lighten(cfg.id)
  end

  local effective_opacity = opacity + lighten * 0.15
  if effective_opacity > 1 then
    effective_opacity = 1
  end

  local effective_border = border_color
  if lighten > 0 then
    effective_border = lighten_color(border_color, lighten)
    effective_border[4] = math.min(1, (border_color[4] or 1) + lighten * 0.2)
  end

  draw_decoration(r, effective_opacity, effective_border, radius)

  local effective_text_color = text_color
  if lighten > 0 and text_color then
    effective_text_color = lighten_color(text_color, lighten * 0.5)
    effective_text_color[4] = text_color[4] or 1
  end

  local fh = fonts.get(font):getHeight()
  text(rect(r.x, r.y + (r.h - fh) / 2, r.w, fh), label, {
    font = font,
    align = "center",
    color = effective_text_color or colors.ui.white,
  })
end

return setmetatable(button, {
  __call = function(_, r, label, config) button.draw(r, label, config) end,
})
