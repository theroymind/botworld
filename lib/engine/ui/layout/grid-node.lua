local theme = require("lib.engine.ui.theme")

local grid = {}

function grid.columns(available_w, slot_size, gap)
  slot_size = slot_size or theme.sizing.slot_size
  gap = gap or theme.sizing.slot_gap
  return math.max(1, math.floor((available_w + gap) / (slot_size + gap)))
end

function grid.layout(index, cols, slot_size, gap)
  local col = (index - 1) % cols
  local row = math.floor((index - 1) / cols)
  return col * (slot_size + gap), row * (slot_size + gap)
end

function grid.node(children, config)
  local cfg = config or {}
  local slot_size = cfg.slot_size or theme.sizing.slot_size
  local gap = cfg.gap or theme.sizing.slot_gap
  local fixed_cols = cfg.cols

  local w = "fill"
  if fixed_cols then
    w = fixed_cols * (slot_size + gap) - gap
  end

  return {
    type = "grid",
    w = w,
    h = function(available_w)
      local cols = fixed_cols or grid.columns(available_w, slot_size, gap)
      local rows = math.max(1, math.ceil(#children / cols))
      return rows * (slot_size + gap) - gap
    end,
    slot_size = slot_size,
    gap = gap,
    cols = fixed_cols,
    align = cfg.align,
    children = children,
    resolved_rect = nil,
  }
end

return grid
