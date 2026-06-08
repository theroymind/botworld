local highlight = {}

local GOLD = { 1.0, 0.85, 0.3, 1 }
local LINE_WIDTH = 2

local SELECTED_ALPHA = 0.9
local SELECTED_FILL_ALPHA = 0.1

local FOCUSED_ALPHA_MIN = 0.7
local FOCUSED_ALPHA_MAX = 1.0
local FOCUSED_FILL_ALPHA = 0.15
local FOCUSED_PULSE_SPEED = 3.5

local function pulse_alpha()
  local t = love.timer.getTime() * FOCUSED_PULSE_SPEED
  local wave = (math.sin(t) + 1) / 2
  return FOCUSED_ALPHA_MIN + wave * (FOCUSED_ALPHA_MAX - FOCUSED_ALPHA_MIN)
end

function highlight.selected(x, y, w, h)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], SELECTED_FILL_ALPHA)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], SELECTED_ALPHA)
  love.graphics.setLineWidth(LINE_WIDTH)
  love.graphics.rectangle("line", x, y, w, h)
end

function highlight.focused(x, y, w, h)
  local alpha = pulse_alpha()
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], FOCUSED_FILL_ALPHA)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(GOLD[1], GOLD[2], GOLD[3], alpha)
  love.graphics.setLineWidth(LINE_WIDTH)
  love.graphics.rectangle("line", x, y, w, h)
end

return highlight
