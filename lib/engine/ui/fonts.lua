local colors = require("lib.engine.ui.colors")

local BODY_FONT_PATH = "assets/fonts/PixelOperator.ttf"
local BOLD_FONT_PATH = "assets/fonts/PixelOperator-Bold.ttf"
local FALLBACK_FONT_PATH = "assets/fonts/DepartureMono-Regular.otf"

local FONT_SOURCES = {
  hud = { path = BODY_FONT_PATH, size = 16 },
  hud_small = { path = BODY_FONT_PATH, size = 16 },
  hud_bold = { path = BOLD_FONT_PATH, size = 16 },
  hud_lg = { path = BOLD_FONT_PATH, size = 22 },
  world = { path = BODY_FONT_PATH, size = 32 },
}

local ICON_FONT_PATH = "assets/fonts/lucide.ttf"
local ICON_SIZES = {
  hud = 16,
  hud_small = 8,
}

local WORLD_TEXT_HEIGHT = 8
local WORLD_SCALE = WORLD_TEXT_HEIGHT / FONT_SOURCES.world.size

local LEADING = 4

local fonts = {}
local icon_fonts = {}
local initialized = false

local function init()
  if initialized then
    return
  end
  local fallback_cache = {}
  local function fallback_for(size)
    if not fallback_cache[size] then
      local fb = love.graphics.newFont(FALLBACK_FONT_PATH, size)
      fb:setFilter("nearest", "nearest")
      fallback_cache[size] = fb
    end
    return fallback_cache[size]
  end
  for name, source in pairs(FONT_SOURCES) do
    local font = love.graphics.newFont(source.path, source.size)
    font:setFilter("nearest", "nearest")
    if font.setFallbacks then
      font:setFallbacks(fallback_for(source.size))
    end
    if font.setLineHeight then
      font:setLineHeight((font:getHeight() + LEADING) / font:getHeight())
    end
    fonts[name] = font
  end
  for name, size in pairs(ICON_SIZES) do
    local font = love.graphics.newFont(ICON_FONT_PATH, size)
    font:setFilter("nearest", "nearest")
    icon_fonts[name] = font
  end
  initialized = true
end

local function get(name)
  init()
  return fonts[name]
end

local function get_icon_font(name)
  init()
  return icon_fonts[name or "hud"]
end

local function line_height(name)
  init()
  return fonts[name]:getHeight() + LEADING
end

local function draw_world_text(text, x, y, config)
  init()
  config = config or {}
  local font = fonts.world
  local color = config.color or { 1, 1, 1, 0.9 }
  local shadow = config.shadow ~= false
  local align = config.align or "center"
  local anchor_x = config.anchor_x or 0

  love.graphics.setFont(font)

  local text_w = font:getWidth(text) * WORLD_SCALE
  local draw_x = x
  if align == "center" then
    draw_x = anchor_x - text_w / 2
  end

  if shadow then
    love.graphics.setColor(colors.ui.shadow)
    love.graphics.print(text, draw_x + 0.5, y + 0.5, 0, WORLD_SCALE, WORLD_SCALE)
  end

  love.graphics.setColor(color[1], color[2], color[3], color[4])
  love.graphics.print(text, draw_x, y, 0, WORLD_SCALE, WORLD_SCALE)
end

return {
  get = get,
  get_icon_font = get_icon_font,
  line_height = line_height,
  draw_world_text = draw_world_text,
  WORLD_TEXT_HEIGHT = WORLD_TEXT_HEIGHT,
  WORLD_SCALE = WORLD_SCALE,
  _reset = function()
    fonts = {}
    icon_fonts = {}
    initialized = false
  end,
}
