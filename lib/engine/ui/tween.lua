local tween = {}

local active = {}

function tween.linear(t) return t end

function tween.ease_out_cubic(t)
  local f = 1 - t
  return 1 - f * f * f
end

function tween.ease_in_out_quad(t)
  if t < 0.5 then
    return 2 * t * t
  end
  local f = 1 - t
  return 1 - 2 * f * f
end

local function find_index(target_table, key)
  for i = 1, #active do
    local entry = active[i]
    if entry.target == target_table and entry.key == key then
      return i
    end
  end
  return nil
end

function tween.to(target_table, key, end_value, duration, ease_fn, on_complete)
  local existing = find_index(target_table, key)
  if existing then
    table.remove(active, existing)
  end
  table.insert(active, {
    target = target_table,
    key = key,
    from = target_table[key] or 0,
    to = end_value,
    elapsed = 0,
    duration = math.max(duration, 0.0001),
    ease = ease_fn or tween.linear,
    on_complete = on_complete,
  })
end

function tween.cancel(target_table, key)
  local existing = find_index(target_table, key)
  if existing then
    table.remove(active, existing)
  end
end

function tween.update(dt)
  local i = 1
  while i <= #active do
    local entry = active[i]
    entry.elapsed = entry.elapsed + dt
    local t = entry.elapsed / entry.duration
    if t > 1 then
      t = 1
    end
    local eased = entry.ease(t)
    entry.target[entry.key] = entry.from + (entry.to - entry.from) * eased
    if t >= 1 then
      table.remove(active, i)
      if entry.on_complete then
        entry.on_complete()
      end
    else
      i = i + 1
    end
  end
end

function tween.count() return #active end

function tween.clear()
  for i = #active, 1, -1 do
    active[i] = nil
  end
end

return tween
