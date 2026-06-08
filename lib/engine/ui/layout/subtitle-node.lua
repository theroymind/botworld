local colors = require("lib.engine.ui.colors")
local text_node = require("lib.engine.ui.layout.text-node")

local function subtitle_node(label, config)
  local cfg = config or {}
  return text_node(label, {
    size = cfg.size or "sm",
    align = cfg.align or "center",
    color = cfg.color or colors.scene.dim_text,
    visible = cfg.visible,
  })
end

return subtitle_node
