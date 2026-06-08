local rect = require("lib.engine.ui.primitives.rect")
local is_visible = require("lib.engine.ui.layout.is-visible")

local ZERO_RECT = rect(0, 0, 0, 0)

local function normalize_padding(padding)
  if type(padding) == "number" then
    return { top = padding, right = padding, bottom = padding, left = padding }
  end
  if type(padding) == "table" then
    return {
      top = padding[1] or 0,
      right = padding[2] or padding[1] or 0,
      bottom = padding[3] or padding[1] or 0,
      left = padding[4] or padding[2] or padding[1] or 0,
    }
  end
  return { top = 0, right = 0, bottom = 0, left = 0 }
end

local resolve

local function resolve_grid(tree, available_rect)
  local slot_size = tree.slot_size
  local gap = tree.gap
  local cols = tree.cols or math.max(1, math.floor((available_rect.w + gap) / (slot_size + gap)))

  local grid_content_w = cols * (slot_size + gap) - gap
  local resolved_w = type(tree.w) == "number" and tree.w or available_rect.w
  local offset_x = 0
  if tree.align == "center" then
    offset_x = math.floor((resolved_w - grid_content_w) / 2)
  end

  local cursor = 0
  for _, child in ipairs(tree.children) do
    local col = cursor % cols
    local row = math.floor(cursor / cols)
    local cx = available_rect.x + offset_x + col * (slot_size + gap)
    local cy = available_rect.y + row * (slot_size + gap)

    if child then
      resolve(child, rect(cx, cy, slot_size, slot_size))
    end
    cursor = cursor + 1
  end

  local total_cells = #tree.children
  local rows = math.max(1, math.ceil(total_cells / cols))
  local total_h = rows * (slot_size + gap)

  tree.resolved_rect = rect(available_rect.x, available_rect.y, resolved_w, total_h)
  return tree
end

local measure_auto_width

local function measure_child_width(child, separator_w)
  if not is_visible(child) then
    return 0
  end

  if child.type == "separator" then
    return separator_w or 0
  end

  local child_w = child.w
  if child_w == "auto" then
    return measure_auto_width(child)
  end

  if child_w == "fill" or child_w == nil then
    if child.type == "vstack" or child.type == "hstack" then
      return measure_auto_width(child)
    end
    if type(child.measure_w) == "number" then
      return child.measure_w
    end
    return 0
  end

  if type(child_w) == "function" then
    return 0
  end

  return child_w
end

measure_auto_width = function(tree)
  local pad = normalize_padding(tree.padding)
  local gap = tree.gap or 0

  if tree.type == "vstack" then
    local max_child_w = 0
    for _, child in ipairs(tree.children) do
      if is_visible(child) then
        local child_w = measure_child_width(child, 0)
        if child_w > max_child_w then
          max_child_w = child_w
        end
      end
    end
    return max_child_w + pad.left + pad.right
  elseif tree.type == "hstack" then
    local total_w = 0
    local visible_count = 0
    for _, child in ipairs(tree.children) do
      if is_visible(child) then
        if visible_count > 0 then
          total_w = total_w + gap
        end
        total_w = total_w + measure_child_width(child, 1)
        visible_count = visible_count + 1
      end
    end
    return total_w + pad.left + pad.right
  end

  if type(tree.measure_w) == "number" then
    return tree.measure_w
  end
  return 0
end

function resolve(tree, available_rect)
  if not is_visible(tree) then
    tree.resolved_rect = ZERO_RECT
    return tree
  end

  if tree.type == "grid" then
    return resolve_grid(tree, available_rect)
  end

  if tree.type == "separator" then
    tree.resolved_rect =
      rect(available_rect.x, available_rect.y, available_rect.w, available_rect.h)
    return tree
  end

  if tree.type == "zstack" then
    local container_w = available_rect.w
    if type(tree.w) == "number" then
      container_w = tree.w
    end

    local max_child_w = 0
    local max_child_h = 0
    for _, child in ipairs(tree.children) do
      if is_visible(child) then
        resolve(child, rect(available_rect.x, available_rect.y, container_w, available_rect.h))
        if child.resolved_rect.w > max_child_w then
          max_child_w = child.resolved_rect.w
        end
        if child.resolved_rect.h > max_child_h then
          max_child_h = child.resolved_rect.h
        end
      else
        child.resolved_rect = ZERO_RECT
      end
    end

    local resolved_w = type(tree.w) == "number" and tree.w or container_w
    local resolved_h = type(tree.h) == "number" and tree.h or max_child_h
    tree.resolved_rect = rect(available_rect.x, available_rect.y, resolved_w, resolved_h)
    return tree
  end

  if tree.type == "node" or tree.type == "spacer" then
    local w = tree.w
    if w == "fill" or w == nil then
      w = available_rect.w
    elseif w == "auto" then
      w = type(tree.measure_w) == "number" and tree.measure_w or available_rect.w
    end
    local h = tree.h
    if h == "fill" then
      h = available_rect.h
    end
    if type(h) == "function" then
      h = h(w)
    end
    tree.resolved_rect = rect(available_rect.x, available_rect.y, w, h)
    return tree
  end

  local container_w = available_rect.w
  if tree.w == "auto" then
    container_w = measure_auto_width(tree)
  elseif type(tree.w) == "number" then
    container_w = tree.w
  end

  local pad = normalize_padding(tree.padding)
  local inner_x = available_rect.x + pad.left
  local inner_y = available_rect.y + pad.top
  local inner_w = container_w - pad.left - pad.right
  local inner_h = available_rect.h - pad.top - pad.bottom
  local gap = tree.gap or 0

  if tree.type == "vstack" then
    local cursor_y = inner_y
    local visible_count = 0
    for _, child in ipairs(tree.children) do
      if not is_visible(child) then
        child.resolved_rect = ZERO_RECT
      else
        if visible_count > 0 then
          cursor_y = cursor_y + gap
        end
        local child_w = inner_w
        if child.type == "separator" then
          resolve(child, rect(inner_x, cursor_y, child_w, 1))
          cursor_y = cursor_y + child.resolved_rect.h
        else
          local child_rect = rect(inner_x, cursor_y, child_w, inner_h - (cursor_y - inner_y))
          resolve(child, child_rect)
          cursor_y = cursor_y + child.resolved_rect.h
        end
        visible_count = visible_count + 1
      end
    end

    local content_h = cursor_y - inner_y
    local total_h = content_h + pad.top + pad.bottom

    if tree.h == "content" or tree.h == nil then
      tree.resolved_rect = rect(available_rect.x, available_rect.y, container_w, total_h)
    elseif tree.h == "fill" then
      tree.resolved_rect = rect(available_rect.x, available_rect.y, container_w, available_rect.h)
    else
      tree.resolved_rect = rect(available_rect.x, available_rect.y, container_w, tree.h)
    end
  elseif tree.type == "hstack" then
    local fixed_total = 0
    local fill_count = 0
    local visible_child_count = 0
    local is_auto_width = tree.w == "auto"

    for _, child in ipairs(tree.children) do
      if is_visible(child) then
        visible_child_count = visible_child_count + 1
        local child_w = child.w
        if child_w == "auto" then
          child_w = measure_auto_width(child)
          child._measured_w = child_w
          fixed_total = fixed_total + child_w
        elseif child.type == "separator" then
          fixed_total = fixed_total + 1
        elseif child_w == "fill" or child_w == nil then
          if is_auto_width then
            local measured = measure_child_width(child, 1)
            child._measured_w = measured
            fixed_total = fixed_total + measured
          else
            fill_count = fill_count + 1
          end
        else
          fixed_total = fixed_total + child_w
        end
      end
    end

    local gap_total = math.max(0, (visible_child_count - 1)) * gap
    local remaining = inner_w - fixed_total - gap_total
    local fill_w = fill_count > 0 and math.floor(remaining / fill_count) or 0

    local cursor_x = inner_x
    local max_h = 0
    local separators = {}
    local fill_h_children = {}
    local visible_count = 0
    for _, child in ipairs(tree.children) do
      if not is_visible(child) then
        child.resolved_rect = ZERO_RECT
      else
        if visible_count > 0 then
          cursor_x = cursor_x + gap
        end
        if child.type == "separator" then
          table.insert(separators, { child = child, x = cursor_x })
          cursor_x = cursor_x + 1
        else
          local child_w = child._measured_w or child.w
          if child_w == "fill" or child_w == nil then
            child_w = fill_w
          end
          local is_fill_h = child.h == "fill"
          local child_rect = rect(cursor_x, inner_y, child_w, inner_h)
          resolve(child, child_rect)
          cursor_x = cursor_x + child.resolved_rect.w
          if is_fill_h then
            table.insert(
              fill_h_children,
              { child = child, w = child_w, x = cursor_x - child.resolved_rect.w }
            )
          elseif child.resolved_rect.h > max_h then
            max_h = child.resolved_rect.h
          end
        end
        visible_count = visible_count + 1
      end
    end

    if #fill_h_children > 0 and max_h > 0 then
      for _, entry in ipairs(fill_h_children) do
        resolve(entry.child, rect(entry.x, inner_y, entry.w, max_h))
      end
    else
      for _, entry in ipairs(fill_h_children) do
        if entry.child.resolved_rect.h > max_h then
          max_h = entry.child.resolved_rect.h
        end
      end
    end

    local separator_h = (tree.h == "content" or tree.h == nil) and max_h or inner_h
    for _, entry in ipairs(separators) do
      resolve(entry.child, rect(entry.x, inner_y, 1, separator_h))
    end

    local total_h = max_h + pad.top + pad.bottom

    if tree.h == "content" or tree.h == nil then
      tree.resolved_rect = rect(available_rect.x, available_rect.y, container_w, total_h)
    elseif tree.h == "fill" then
      tree.resolved_rect = rect(available_rect.x, available_rect.y, container_w, available_rect.h)
    else
      tree.resolved_rect = rect(available_rect.x, available_rect.y, container_w, tree.h)
    end
  end

  return tree
end

return resolve
