-- Cell layer, M0 stub: a bare counter that grows passively each sim tick and
-- jumps on space/click. Placeholder visuals only — a later milestone replaces
-- this file's internals; the layer interface is the contract.
local cell = {}

local PASSIVE_PER_SECOND = 1
local PRESS_AMOUNT = 10
local COUNTER_SCALE = 6 -- default font scaled up; no font assets per the art pillar
local HINT = "[space] or click  +10   passive +1/sec"
local HINT_Y_OFFSET = 60 -- below center, clear of the scaled counter digits

cell.state = { counter = 0 }

function cell.tick(tick_dt)
  cell.state.counter = cell.state.counter + PASSIVE_PER_SECOND * tick_dt
end

function cell.keypressed(key)
  if key == "space" then
    cell.state.counter = cell.state.counter + PRESS_AMOUNT
  end
end

function cell.mousepressed()
  cell.state.counter = cell.state.counter + PRESS_AMOUNT
end

function cell.draw()
  local width, height = love.graphics.getDimensions()
  local font = love.graphics.getFont()
  local text = string.format("%d", math.floor(cell.state.counter))
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(
    text,
    width / 2,
    height / 2,
    0,
    COUNTER_SCALE,
    COUNTER_SCALE,
    font:getWidth(text) / 2,
    font:getHeight() / 2
  )
  love.graphics.setColor(1, 1, 1, 0.6)
  love.graphics.printf(HINT, 0, height / 2 + HINT_Y_OFFSET, width, "center")
end

return cell
