local text_node = require("lib.engine.ui.layout.text-node")

local function title_node(label, config)
  local cfg = config or {}
  return text_node(label, {
    size = cfg.size or "md",
    align = cfg.align or "center",
    color = cfg.color,
    visible = cfg.visible,
  })
end

return title_node
