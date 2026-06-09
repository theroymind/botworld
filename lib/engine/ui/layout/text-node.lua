local fonts = require("lib.engine.ui.fonts")
local text = require("lib.engine.ui.primitives.text")
local theme = require("lib.engine.ui.theme")

-- A text leaf for the layout tree. By default it ADAPTS to the width it resolves to:
-- the string wraps to the column the layout hands it (resolve.lua gives a "fill" child
-- the available inner width), and the node's height is a FUNCTION of that width -- the
-- wrapped line count -- so the parent vstack reserves the right vertical space and rows
-- below it stack correctly. This is why a long flavor line in a narrow column wraps to
-- a second line instead of running off the panel. Pass `wrap = false` (or an explicit
-- numeric `h`) to force the old single-line behaviour for labels that must never break.
local function text_node(str, config)
  local cfg = config or {}
  local font_name = theme.font[cfg.size or "sm"]
  local is_dynamic = type(str) == "function"
  local wrap = cfg.wrap ~= false -- wrap to the resolved width unless explicitly disabled

  -- Dynamic strings are re-read each frame; resolve and draw both pull the current value.
  local function current_label() return is_dynamic and str() or str end

  -- Natural single-line width: drives auto-width measurement in hstacks. A node placed
  -- at its natural width resolves to one line (getWrap finds no break), so auto layouts
  -- are unaffected; wrapping only engages when a column constrains the node narrower.
  local measure_w = is_dynamic and 0 or fonts.get(font_name):getWidth(str)

  -- Wrapped height for a resolved width `w`. printf advances one fonts.line_height per
  -- extra line (the font carries that leading via setLineHeight), so n lines occupy
  -- getHeight + (n-1)*line_height -- a single line stays exactly getHeight() tall.
  local function wrapped_height(w)
    local font = fonts.get(font_name)
    if not w or w <= 0 then
      return font:getHeight()
    end
    local _, lines = font:getWrap(current_label(), w)
    local line_count = math.max(1, #lines)
    return font:getHeight() + (line_count - 1) * fonts.line_height(font_name)
  end

  local height
  if cfg.h then
    height = cfg.h -- caller pinned an explicit height; honour it verbatim
  elseif wrap then
    height = wrapped_height -- resolve.lua evaluates this with the resolved width
  else
    height = fonts.get(font_name):getHeight()
  end

  return {
    type = "node",
    h = height,
    w = cfg.w or "fill",
    measure_w = measure_w,
    visible = cfg.visible,
    draw_fn = function(r)
      text(r, current_label(), {
        font = font_name,
        color = cfg.color,
        align = cfg.align,
        wrap = wrap and r.w or nil,
      })
    end,
    on_click = cfg.on_click,
    resolved_rect = nil,
  }
end

return text_node
