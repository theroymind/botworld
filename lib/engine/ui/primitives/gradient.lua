local theme = require("lib.engine.ui.theme")

local gradient = {}

local SHADER_SOURCE = [[
  extern vec4 top_color;
  extern vec4 bottom_color;
  vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords) {
    return mix(top_color, bottom_color, texture_coords.y) * color;
  }
]]

local vertical_shader = nil

function gradient.load()
  if love.graphics and love.graphics.newShader then
    vertical_shader = love.graphics.newShader(SHADER_SOURCE)
  end
end

function gradient.fill(r, top_color, bottom_color, radius)
  if not vertical_shader then
    gradient.load()
  end

  local rad = radius or theme.gradient.panel_radius

  if vertical_shader and vertical_shader.send then
    vertical_shader:send("top_color", top_color)
    vertical_shader:send("bottom_color", bottom_color)
    love.graphics.setShader(vertical_shader)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, rad, rad)
    love.graphics.setShader()
  else
    love.graphics.setColor(top_color[1], top_color[2], top_color[3], top_color[4] or 1)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h, rad, rad)
  end
end

function gradient.is_loaded() return vertical_shader ~= nil end

return gradient
