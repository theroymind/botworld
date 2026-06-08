local fonts = require("lib.engine.ui.fonts")
local colors = require("lib.engine.ui.colors")
local rect = require("lib.engine.ui.primitives.rect")
local text = require("lib.engine.ui.primitives.text")

local OVERLAY_COLOR = { 0, 0, 0, 0.6 }
local SLOT_RADIUS = 3
local ARC_SEGMENTS = 64
local ARC_RADIUS_FRACTION = 0.7

local cooldown_overlay = {}

function cooldown_overlay.draw(slot_rect, remaining, total)
  if not remaining or not total or total <= 0 then
    return
  end

  local fraction = math.max(0, math.min(1, remaining / total))
  if fraction <= 0 then
    return
  end

  local center_x = slot_rect.x + slot_rect.w / 2
  local center_y = slot_rect.y + slot_rect.w / 2
  local arc_radius = slot_rect.w * ARC_RADIUS_FRACTION

  local angle_start = -math.pi / 2
  local angle_end = angle_start + fraction * math.pi * 2

  love.graphics.stencil(
    function()
      love.graphics.rectangle(
        "fill",
        slot_rect.x,
        slot_rect.y,
        slot_rect.w,
        slot_rect.w,
        SLOT_RADIUS,
        SLOT_RADIUS
      )
    end,
    "replace",
    1
  )
  love.graphics.setStencilTest("greater", 0)

  love.graphics.setColor(OVERLAY_COLOR[1], OVERLAY_COLOR[2], OVERLAY_COLOR[3], OVERLAY_COLOR[4])
  love.graphics.arc(
    "fill",
    "pie",
    center_x,
    center_y,
    arc_radius,
    angle_start,
    angle_end,
    ARC_SEGMENTS
  )

  love.graphics.setStencilTest()

  local font = fonts.get("hud_small")
  local cooldown_text = string.format("%.1fs", remaining)
  local text_height = font:getHeight()
  text(
    rect(slot_rect.x, slot_rect.y + (slot_rect.w - text_height) / 2, slot_rect.w, 0),
    cooldown_text,
    {
      font = "hud_small",
      color = colors.ui.accent,
      align = "center",
    }
  )
end

return setmetatable(cooldown_overlay, {
  __call = function(_, slot_rect, remaining, total)
    cooldown_overlay.draw(slot_rect, remaining, total)
  end,
})
