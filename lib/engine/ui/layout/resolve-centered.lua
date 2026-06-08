local rect = require("lib.engine.ui.primitives.rect")
local resolve = require("lib.engine.ui.layout.resolve")

local function resolve_centered(tree, w, h)
  resolve(tree, rect(0, 0, w, h))
  local tree_w = tree.resolved_rect.w
  local tree_h = tree.resolved_rect.h
  resolve(tree, rect(math.floor((w - tree_w) / 2), math.floor((h - tree_h) / 2), tree_w, h))
end

return resolve_centered
