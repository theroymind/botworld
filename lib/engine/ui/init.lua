-- botworld's canonical UI kit, vendored from botlands' game-agnostic UI core.
-- One require exposes the whole kit: PixelOperator fonts, theme tokens + color
-- palette, the immediate-mode draw primitives, the interaction/tween layer, and
-- the retained-mode layout tree + renderer. No immediate-mode bridge -- callers
-- build a node tree and drive it through `renderer`.
--
--   local ui = require("lib.engine.ui")
--   local tree = ui.layout.vstack({ ui.layout.text("hello") })
--   ui.layout.resolve(tree, ui.primitives.rect(16, 16, 320, 200))
--   local click_map = ui.renderer.draw(tree, nil)
return {
  fonts = require("lib.engine.ui.fonts"),
  theme = require("lib.engine.ui.theme"),
  colors = require("lib.engine.ui.colors"),
  highlight_modes = require("lib.engine.ui.highlight-modes"),
  interaction = require("lib.engine.ui.interaction-state"),
  tween = require("lib.engine.ui.tween"),
  toast = require("lib.engine.ui.toast"),
  primitives = {
    rect = require("lib.engine.ui.primitives.rect"),
    text = require("lib.engine.ui.primitives.text"),
    button = require("lib.engine.ui.primitives.button"),
    bar = require("lib.engine.ui.primitives.bar"),
    badge = require("lib.engine.ui.primitives.badge"),
    border = require("lib.engine.ui.primitives.border"),
    container = require("lib.engine.ui.primitives.container"),
    separator = require("lib.engine.ui.primitives.separator"),
    gradient = require("lib.engine.ui.primitives.gradient"),
    grid = require("lib.engine.ui.primitives.grid"),
    grip = require("lib.engine.ui.primitives.grip"),
    highlight = require("lib.engine.ui.primitives.highlight"),
    shadow = require("lib.engine.ui.primitives.shadow"),
    slot = require("lib.engine.ui.primitives.slot"),
    text_input = require("lib.engine.ui.primitives.text-input"),
    cooldown_overlay = require("lib.engine.ui.primitives.cooldown-overlay"),
  },
  layout = require("lib.engine.ui.layout"),
  renderer = require("lib.engine.ui.layout-renderer"),
}
