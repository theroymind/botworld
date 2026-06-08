local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")

local shadow = {}

function shadow.draw(r, config)
  local cfg = config or {}
  local elevation = cfg.elevation or "md"
  local radius = cfg.radius or theme.gradient.panel_radius
  local profile = theme.shadow[elevation] or theme.shadow.md

  local offsets = profile.offsets
  local alphas = profile.alphas

  for i = #offsets, 1, -1 do
    local o = offsets[i]
    local a = alphas[i]
    local sc = colors.with_alpha(colors.shadow, a)
    love.graphics.setColor(sc[1], sc[2], sc[3], sc[4])
    love.graphics.rectangle("fill", r.x + o, r.y + o, r.w, r.h, radius, radius)
  end
end

return setmetatable(shadow, {
  __call = function(_, r, config) shadow.draw(r, config) end,
})
