-- Standalone smoke spec for the vendored UI kit (lib/engine/ui). Plain Lua 5.1 /
-- luajit, no busted, no love. Run from the repo root: lua tests/ui_spec.lua
--
-- Covers only the love-free layer: the color palette + ui tokens, theme tokens,
-- the rect geometry spine, tween easing/integration, highlight modes, and the
-- pure layout `resolve` geometry (vstack stacking, hstack fill/fixed and
-- fill/auto splits -- the exact shape the cell trait-row relies on). The
-- love-coupled parts (fonts, primitives, renderer, text/button/bar nodes) are
-- verified by booting the game.
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
-- Two patterns: files (lib/foo.lua) and packages with init.lua (lib/engine/ui).
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local colors = require("lib.engine.ui.colors")
local theme = require("lib.engine.ui.theme")
local tween = require("lib.engine.ui.tween")
local highlight_modes = require("lib.engine.ui.highlight-modes")
local rect = require("lib.engine.ui.primitives.rect")
local is_visible = require("lib.engine.ui.layout.is-visible")
local layout = require("lib.engine.ui.layout")

local checks = 0

local function check(condition, label)
  checks = checks + 1
  if not condition then
    error("FAILED: " .. label, 2)
  end
end

local function approx(a, b) return math.abs(a - b) < 1e-6 end

-- Colors: palette is rgba, ui tokens present, with_alpha + hex parse correct.
check(
  type(colors.palette.tan_light) == "table" and #colors.palette.tan_light == 4,
  "palette is rgba"
)
check(approx(colors.palette.tan_light[1], 0xa6 / 255), "hex parses red channel")
check(approx(colors.palette.tan_light[2], 0x88 / 255), "hex parses green channel")
check(approx(colors.palette.tan_light[3], 0x4a / 255), "hex parses blue channel")
check(colors.ui.text ~= nil and colors.ui.accent ~= nil, "ui tokens text + accent")
check(
  colors.ui.text_dim ~= nil and colors.ui.text_muted ~= nil and colors.ui.text_faint ~= nil,
  "ui dim tokens"
)
local faded = colors.with_alpha(colors.ui.text, 0.5)
check(faded[4] == 0.5 and faded[1] == colors.ui.text[1], "with_alpha sets alpha, keeps rgb")

-- Theme tokens used by the cell panel.
check(
  theme.spacing.xs == 4
    and theme.spacing.sm == 8
    and theme.spacing.md == 12
    and theme.spacing.lg == 16,
  "spacing scale"
)
check(
  theme.font.sm == "hud_small" and theme.font.md == "hud" and theme.font.lg == "hud_lg",
  "font tokens incl lg"
)
check(theme.sizing.bar_height == 8, "sizing bar_height token")

-- Highlight modes (inlined, no define wrapper).
check(
  highlight_modes.SELECTED == "selected" and highlight_modes.FOCUSED == "focused",
  "highlight modes"
)

-- Rect geometry spine.
local r = rect(10, 20, 100, 50)
check(r.x == 10 and r.y == 20 and r.w == 100 and r.h == 50, "rect ctor")
local p = r:pad(5)
check(p.x == 15 and p.y == 25 and p.w == 90 and p.h == 40, "rect pad uniform")
local p2 = r:pad(4, 8)
check(p2.x == 18 and p2.y == 24 and p2.w == 84 and p2.h == 42, "rect pad (v, h)")
local b = r:below(10)
check(b.x == 10 and b.y == 30 and b.w == 100 and b.h == 50, "rect below")
local rr = r:right(10)
check(rr.x == 20 and rr.y == 20 and rr.w == 100, "rect right")
check(r:contains(50, 40) and r:contains(10, 20), "rect contains inside/edge")
check(not r:contains(5, 5) and not r:contains(200, 200), "rect contains outside")

-- Tween: easing endpoints + a linear integration to completion.
check(tween.linear(0.5) == 0.5, "tween linear identity")
check(
  approx(tween.ease_out_cubic(0), 0) and approx(tween.ease_out_cubic(1), 1),
  "ease_out_cubic endpoints"
)
check(
  approx(tween.ease_in_out_quad(0), 0) and approx(tween.ease_in_out_quad(1), 1),
  "ease_in_out_quad endpoints"
)
tween.clear()
local obj = { v = 0 }
tween.to(obj, "v", 10, 1.0, tween.linear)
tween.update(0.5)
check(approx(obj.v, 5), "tween reaches midpoint")
tween.update(0.5)
check(approx(obj.v, 10), "tween reaches end value")
check(tween.count() == 0, "tween entry cleared after completion")

-- is-visible: default true, explicit false, function predicate.
check(is_visible({}) == true, "node visible by default")
check(is_visible({ visible = false }) == false, "explicit hidden")
check(
  is_visible({ visible = function() return false end }) == false,
  "function visibility predicate"
)

-- Resolve: vstack stacks children top-to-bottom with the gap; content height sums.
local v1 = layout.node({ h = 10 })
local v2 = layout.node({ h = 20 })
local vs = layout.vstack({ v1, v2 }, { gap = 5, padding = 0 })
layout.resolve(vs, rect(0, 0, 100, 200))
check(v1.resolved_rect.y == 0, "vstack first child at top")
check(v2.resolved_rect.y == 15, "vstack second child after first + gap")
check(vs.resolved_rect.h == 35, "vstack content height = 10 + 5 + 20")
check(v1.resolved_rect.w == 100, "vstack fill child takes full width")

-- Resolve: hstack gives the fill child the remainder and pins the fixed child
-- right -- the exact geometry of the cell trait-row (fill label + fixed button).
local fill = layout.node({ w = "fill", h = 30 })
local fixed = layout.node({ w = 40, h = 30 })
local hs = layout.hstack({ fill, fixed }, { gap = 10, padding = 0 })
layout.resolve(hs, rect(0, 0, 200, 50))
check(
  fill.resolved_rect.x == 0 and fill.resolved_rect.w == 150,
  "hstack fill child = inner - fixed - gap"
)
check(
  fixed.resolved_rect.x == 160 and fixed.resolved_rect.w == 40,
  "hstack fixed child pinned right"
)
check(hs.resolved_rect.h == 30, "hstack content height = tallest child")

-- Resolve: a node whose height is a FUNCTION of width is evaluated with the width it
-- actually resolves to -- the contract the wrapping text-node relies on to size itself
-- to its wrapped line count once a column constrains it.
local sized = layout.node({ w = "fill", h = function(w) return w / 4 end })
layout.resolve(sized, rect(0, 0, 120, 999))
check(sized.resolved_rect.w == 120, "function-height node fills the available width")
check(sized.resolved_rect.h == 30, "function-height node sizes from the resolved width")

-- Resolve: hstack with an auto-width child measures it to its content, fill rest.
local inner = layout.node({ w = 30, h = 10 })
local auto_box = layout.vstack({ inner }, { w = "auto", padding = 0, gap = 0 })
local fill2 = layout.node({ w = "fill", h = 10 })
local hs2 = layout.hstack({ fill2, auto_box }, { gap = 0, padding = 0 })
layout.resolve(hs2, rect(0, 0, 100, 20))
check(auto_box.resolved_rect.w == 30, "hstack auto child measures to content")
check(fill2.resolved_rect.w == 70, "hstack fill child takes the remainder")
check(rawget(auto_box, "_measured_w") == nil, "measure cache cleared after placement")

-- Resolve: over-constrained layouts clamp to zero instead of going negative.
-- An hstack whose fixed children outgrow the row gives fill children 0 width...
local big_fixed = layout.node({ w = 300, h = 10 })
local squeezed = layout.node({ w = "fill", h = 10 })
local over_row = layout.hstack({ big_fixed, squeezed }, { gap = 10, padding = 0 })
layout.resolve(over_row, rect(0, 0, 100, 20))
check(squeezed.resolved_rect.w == 0, "over-constrained hstack clamps fill width to 0")
-- ...and a vstack whose content outgrows the rect hands later children 0 height.
local too_tall = layout.node({ h = 50 })
local squeezed_v = layout.node({ h = "fill" })
local over_col = layout.vstack({ too_tall, squeezed_v }, { gap = 0, padding = 0 })
layout.resolve(over_col, rect(0, 0, 100, 30))
check(squeezed_v.resolved_rect.h == 0, "overflowing vstack clamps child height to 0")

-- Stacks compact nil children (icon_node/count_badge_node return nil for "absent"),
-- so a hole no longer truncates the sibling list.
local before_hole = layout.node({ h = 10 })
local after_hole = layout.node({ h = 10 })
local holed_col = layout.vstack({ before_hole, nil, after_hole }, { gap = 5, padding = 0 })
check(#holed_col.children == 2, "vstack compacts nil children")
layout.resolve(holed_col, rect(0, 0, 100, 100))
check(after_hole.resolved_rect.y == 15, "vstack sibling after a nil child still resolves")
local h_before = layout.node({ w = 10, h = 10 })
local h_after = layout.node({ w = 10, h = 10 })
local holed_row = layout.hstack({ h_before, nil, h_after }, { gap = 5, padding = 0 })
layout.resolve(holed_row, rect(0, 0, 100, 20))
check(h_after.resolved_rect.x == 15, "hstack sibling after a nil child still resolves")

-- Grid height has no trailing gap: rows*(slot+gap) - gap, matching the width math.
local SLOT_SIZE = 20
local SLOT_GAP = 4
local slots = {}
for _ = 1, 5 do
  table.insert(slots, layout.node({ h = SLOT_SIZE }))
end
local grid_box = layout.grid.node(slots, { slot_size = SLOT_SIZE, gap = SLOT_GAP, cols = 2 })
local expected_grid_h = 3 * (SLOT_SIZE + SLOT_GAP) - SLOT_GAP -- 5 cells / 2 cols = 3 rows
check(grid_box.h(200) == expected_grid_h, "grid-node measured height drops trailing gap")
layout.resolve(grid_box, rect(0, 0, 200, 200))
check(grid_box.resolved_rect.h == expected_grid_h, "resolved grid height drops trailing gap")

-- Function-valued measure_w (dynamic text-node strings) drives auto-width measurement.
local dyn = layout.node({ w = "auto", h = 10, measure_w = function() return 42 end })
layout.resolve(dyn, rect(0, 0, 100, 20))
check(dyn.resolved_rect.w == 42, "auto node takes width from function measure_w")
local dyn_label = layout.node({ w = "fill", h = 10, measure_w = function() return 25 end })
local dyn_row = layout.hstack({ dyn_label }, { w = "auto", padding = 0, gap = 0 })
layout.resolve(dyn_row, rect(0, 0, 100, 20))
check(dyn_row.resolved_rect.w == 25, "auto hstack measures function measure_w child")

-- Cross-axis alignment: vstack `align` places narrower children horizontally...
local narrow_center = layout.node({ w = 20, h = 10 })
local centered_col = layout.vstack({ narrow_center }, { align = layout.align.CENTER, padding = 0 })
layout.resolve(centered_col, rect(0, 0, 100, 50))
check(narrow_center.resolved_rect.x == 40, "vstack align=center centers narrower child")
local narrow_end = layout.node({ w = 20, h = 10 })
local ended_col = layout.vstack({ narrow_end }, { align = layout.align.END, padding = 0 })
layout.resolve(ended_col, rect(0, 0, 100, 50))
check(narrow_end.resolved_rect.x == 80, "vstack align=end pins narrower child to the right")
-- ...the shift moves the whole resolved subtree, not just the child's own rect...
local nested_leaf = layout.node({ w = 20, h = 10 })
local nested_row = layout.hstack({ nested_leaf }, { w = 20, padding = 0, gap = 0 })
local nested_col = layout.vstack({ nested_row }, { align = layout.align.CENTER, padding = 0 })
layout.resolve(nested_col, rect(0, 0, 100, 50))
check(nested_leaf.resolved_rect.x == 40, "vstack align offsets the whole subtree")
-- ...and hstack `align_v` places shorter children vertically within the row.
local short_mid = layout.node({ w = 10, h = 10 })
local tall_mid = layout.node({ w = 10, h = 30 })
local mid_row = layout.hstack(
  { short_mid, tall_mid },
  { align_v = layout.align.MIDDLE, gap = 0, padding = 0 }
)
layout.resolve(mid_row, rect(0, 0, 100, 50))
check(short_mid.resolved_rect.y == 10, "hstack align_v=center centers shorter child")
check(tall_mid.resolved_rect.y == 0, "hstack align_v leaves the tallest child at the top")
local short_bottom = layout.node({ w = 10, h = 10 })
local tall_bottom = layout.node({ w = 10, h = 30 })
local bottom_row = layout.hstack(
  { short_bottom, tall_bottom },
  { align_v = layout.align.BOTTOM, gap = 0, padding = 0 }
)
layout.resolve(bottom_row, rect(0, 0, 100, 50))
check(short_bottom.resolved_rect.y == 20, "hstack align_v=bottom pins shorter child down")

print("all tests passed (" .. checks .. " checks)")
