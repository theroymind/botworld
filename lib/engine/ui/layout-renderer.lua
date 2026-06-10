local container = require("lib.engine.ui.primitives.container")
local separator = require("lib.engine.ui.primitives.separator")
local is_visible = require("lib.engine.ui.layout.is-visible")

local layout_renderer = {}

local function collect_draw(tree, ctx, click_map, press_map, right_click_map, hover_map)
  if not tree then
    return
  end

  if not is_visible(tree) then
    return
  end

  if not tree.resolved_rect then
    return
  end

  local resolved = tree.resolved_rect
  -- ctx is optional: a scroll/clip context maps + culls rects; a nil ctx (as the
  -- cell layer passes) is a passthrough -- no transform, nothing culled.
  local screen_rect = (ctx and ctx.to_screen_rect)
      and ctx:to_screen_rect(resolved.x, resolved.y, resolved.w, resolved.h)
    or resolved

  if ctx and ctx.is_visible and not ctx:is_visible(resolved.y, resolved.h) then
    return
  end

  if tree.type == "separator" then
    separator.draw(screen_rect, { color = tree.color })
    return
  end

  -- clip = true hard-contains the node and its whole subtree to its screen rect.
  -- intersectScissor composes with any clip already active; the previous scissor is
  -- saved and restored (same isolation discipline as the canvas rule) so a clipped
  -- panel never leaks scissor state into siblings.
  local prev_scissor_x, prev_scissor_y, prev_scissor_w, prev_scissor_h
  if tree.clip then
    prev_scissor_x, prev_scissor_y, prev_scissor_w, prev_scissor_h = love.graphics.getScissor()
    love.graphics.intersectScissor(
      screen_rect.x,
      screen_rect.y,
      math.max(0, screen_rect.w),
      math.max(0, screen_rect.h)
    )
  end

  if tree.bg then
    container(screen_rect, tree.bg)
  end

  if tree.draw_fn then
    tree.draw_fn(screen_rect)
  end

  if tree.on_click then
    table.insert(click_map, { rect = screen_rect, on_click = tree.on_click })
  end

  if tree.on_press then
    table.insert(press_map, { rect = screen_rect, on_press = tree.on_press })
  end

  if tree.on_right_click then
    table.insert(right_click_map, { rect = screen_rect, on_right_click = tree.on_right_click })
  end

  if tree.on_hover then
    table.insert(hover_map, { rect = screen_rect, on_hover = tree.on_hover })
  end

  if tree.children then
    for _, child in ipairs(tree.children) do
      if child then
        collect_draw(child, ctx, click_map, press_map, right_click_map, hover_map)
      end
    end
  end

  if tree.clip then
    love.graphics.setScissor(prev_scissor_x, prev_scissor_y, prev_scissor_w, prev_scissor_h)
  end
end

function layout_renderer.draw(tree, ctx)
  local click_map = {}
  local press_map = {}
  local right_click_map = {}
  local hover_map = {}
  collect_draw(tree, ctx, click_map, press_map, right_click_map, hover_map)
  return click_map, press_map, right_click_map, hover_map
end

function layout_renderer.hit_test(click_map, mx, my)
  for i = #click_map, 1, -1 do
    local entry = click_map[i]
    if entry.rect:contains(mx, my) then
      return entry.on_click, entry.rect
    end
  end
  return nil
end

function layout_renderer.right_click_test(right_click_map, mx, my)
  for i = #right_click_map, 1, -1 do
    local entry = right_click_map[i]
    if entry.rect:contains(mx, my) then
      return entry.on_right_click, entry.rect
    end
  end
  return nil
end

function layout_renderer.press_test(press_map, mx, my)
  for i = #press_map, 1, -1 do
    local entry = press_map[i]
    if entry.rect:contains(mx, my) then
      return entry.on_press, entry.rect
    end
  end
  return nil
end

function layout_renderer.hover_test(hover_map, mx, my)
  for i = #hover_map, 1, -1 do
    local entry = hover_map[i]
    if entry.rect:contains(mx, my) then
      return entry.on_hover, entry.rect
    end
  end
  return nil
end

return layout_renderer
