-- Minimal immediate-mode UI, drawn in screen space from inside love.draw.
-- No retained widget tree, no ids, no layout: callers position everything each frame.
--
-- Usage:
--   local ui = require("lib.engine.ui")
--   function love.mousepressed(x, y, button)
--     ui.mousepressed(x, y, button)
--   end
--   function love.draw()
--     ui.begin_frame()
--     ui.panel(10, 10, 220, 120)
--     ui.label(20, 20, "biomass  1234", { alpha = 0.8 })
--     if ui.button(20, 44, 200, 44, "grow", { sublabel = "cost 10", enabled = can_afford }) then
--       -- clicked this frame (click consumed by at most one button)
--     end
--     ui.end_frame()
--   end
local ui = {}

local BORDER_ALPHA = 0.6
local FILL_ALPHA = 0.08
local HOVER_FILL_ALPHA = 0.18
local DISABLED_ALPHA = 0.25
local PANEL_FILL_ALPHA = 0.04
local PANEL_BORDER_ALPHA = 0.2
local SUBLABEL_FONT_SIZE = 10
local SUBLABEL_ALPHA = 0.6

local SLIDER_TRACK_ALPHA = 0.18
local SLIDER_FILL_ALPHA = 0.5
local SLIDER_HANDLE_ALPHA = 0.9
local SLIDER_MARKER_ALPHA = 0.7

local mouse_x, mouse_y = 0, 0
local pending_click_x, pending_click_y -- recorded by mousepressed, latched by begin_frame
local click_x, click_y -- this frame's unconsumed click, nil once a button takes it
local slider_drag -- x of the slider being dragged this gesture, or nil
local sublabel_font -- lazily created, cached for the lifetime of the module

local function point_in_rect(px, py, x, y, w, h)
  return px ~= nil and px >= x and px < x + w and py >= y and py < y + h
end

local function clamp01(value)
  if value < 0 then
    return 0
  elseif value > 1 then
    return 1
  end
  return value
end

-- Host forwards LÖVE's mousepressed here; only button 1 registers.
function ui.mousepressed(x, y, button)
  if button == 1 then
    pending_click_x, pending_click_y = x, y
  end
end

-- Call at the top of the frame's UI pass.
function ui.begin_frame()
  click_x, click_y = pending_click_x, pending_click_y
  pending_click_x, pending_click_y = nil, nil
  mouse_x, mouse_y = love.mouse.getPosition()
end

-- Call after all widgets; drops any click no button consumed.
function ui.end_frame()
  click_x, click_y = nil, nil
end

-- Returns true if this frame's click landed inside and the button is enabled.
-- opts: enabled (default true), sublabel (smaller dim second line, e.g. cost).
function ui.button(x, y, w, h, label, opts)
  opts = opts or {}
  local enabled = opts.enabled ~= false
  local hover = enabled and point_in_rect(mouse_x, mouse_y, x, y, w, h)
  local clicked = enabled and point_in_rect(click_x, click_y, x, y, w, h)
  if clicked then
    click_x, click_y = nil, nil
  end

  local text_alpha = enabled and 1 or DISABLED_ALPHA
  local border_alpha = enabled and BORDER_ALPHA or DISABLED_ALPHA
  local fill_alpha = enabled and (hover and HOVER_FILL_ALPHA or FILL_ALPHA)
    or FILL_ALPHA * DISABLED_ALPHA
  love.graphics.setColor(1, 1, 1, fill_alpha)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(1, 1, 1, border_alpha)
  love.graphics.rectangle("line", x, y, w, h)

  local font = love.graphics.getFont()
  local label_h = font:getHeight()
  if opts.sublabel then
    sublabel_font = sublabel_font or love.graphics.newFont(SUBLABEL_FONT_SIZE)
    local top = math.floor(y + (h - label_h - sublabel_font:getHeight()) / 2)
    love.graphics.setColor(1, 1, 1, text_alpha)
    love.graphics.printf(label, x, top, w, "center")
    love.graphics.setFont(sublabel_font)
    love.graphics.setColor(1, 1, 1, text_alpha * SUBLABEL_ALPHA)
    love.graphics.printf(opts.sublabel, x, top + label_h, w, "center")
    love.graphics.setFont(font)
  else
    love.graphics.setColor(1, 1, 1, text_alpha)
    love.graphics.printf(label, x, math.floor(y + (h - label_h) / 2), w, "center")
  end
  love.graphics.setColor(1, 1, 1, 1)
  return clicked
end

-- opts: align ("left"/"center"/"right"; needs width when not left), width, alpha, scale.
function ui.label(x, y, text, opts)
  opts = opts or {}
  local alpha = opts.alpha or 1
  local scale = opts.scale or 1
  local align = opts.align or "left"
  love.graphics.setColor(1, 1, 1, alpha)
  if align == "left" and not opts.width then
    love.graphics.print(text, x, y, 0, scale, scale)
  else
    -- printf's wrap limit is pre-scale, so divide to keep the visual width.
    love.graphics.printf(text, x, y, (opts.width or 0) / scale, align, 0, scale, scale)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- Subtle background rect + border for grouping.
function ui.panel(x, y, w, h)
  love.graphics.setColor(1, 1, 1, PANEL_FILL_ALPHA)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(1, 1, 1, PANEL_BORDER_ALPHA)
  love.graphics.rectangle("line", x, y, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- Horizontal drag dial in [0, 1]. Grab anywhere on the track and drag; the
-- gesture sticks until the mouse releases, even if it strays off the track.
-- Returns the (possibly updated) value. opts.marker draws a tick at a value in
-- [0, 1] (e.g. the metabolism optimum). Consumes a click that starts a drag so
-- the background tap-to-feed never fights the dial.
function ui.slider(x, y, w, h, value, opts)
  opts = opts or {}
  if point_in_rect(click_x, click_y, x, y, w, h) then
    slider_drag = x
    click_x, click_y = nil, nil
  end
  if not love.mouse.isDown(1) then
    slider_drag = nil
  end
  if slider_drag == x then
    value = clamp01((mouse_x - x) / w)
  else
    value = clamp01(value)
  end

  local mid = math.floor(y + h / 2)
  love.graphics.setColor(1, 1, 1, SLIDER_TRACK_ALPHA)
  love.graphics.rectangle("fill", x, mid - 2, w, 4)
  love.graphics.setColor(1, 1, 1, SLIDER_FILL_ALPHA)
  love.graphics.rectangle("fill", x, mid - 2, w * value, 4)
  if opts.marker then
    local mx = x + w * clamp01(opts.marker)
    love.graphics.setColor(1, 1, 1, SLIDER_MARKER_ALPHA)
    love.graphics.rectangle("fill", mx - 1, y, 2, h)
  end
  love.graphics.setColor(1, 1, 1, SLIDER_HANDLE_ALPHA)
  love.graphics.rectangle("fill", x + w * value - 4, y, 8, h)
  love.graphics.setColor(1, 1, 1, 1)
  return value
end

-- Returns this frame's click position if no widget has consumed it yet, and
-- clears it. For click-anywhere-background actions (e.g. tap to feed). Call
-- after every widget, before end_frame.
function ui.consume_click()
  if click_x then
    local x, y = click_x, click_y
    click_x, click_y = nil, nil
    return x, y
  end
  return nil
end

return ui
