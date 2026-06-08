local math_utils = {}

math_utils.atan2 = math.atan2 or math.atan

function math_utils.normalize_angle(angle) return (angle + math.pi) % (2 * math.pi) - math.pi end

function math_utils.clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

function math_utils.smoothstep(edge0, edge1, x)
  local t = math.max(0, math.min(1, (x - edge0) / (edge1 - edge0)))
  return t * t * (3 - 2 * t)
end

function math_utils.lerp(a, b, t) return a + (b - a) * t end

function math_utils.lerp_color(color_a, color_b, t)
  return {
    color_a[1] + (color_b[1] - color_a[1]) * t,
    color_a[2] + (color_b[2] - color_a[2]) * t,
    color_a[3] + (color_b[3] - color_a[3]) * t,
    (color_a[4] or 1) + ((color_b[4] or 1) - (color_a[4] or 1)) * t,
  }
end

function math_utils.distance_squared(ax, ay, bx, by)
  local dx = bx - ax
  local dy = by - ay
  return dx * dx + dy * dy
end

function math_utils.is_in_cone(origin_x, origin_y, facing_angle, target_x, target_y, fov_radians)
  local dx = target_x - origin_x
  local dy = target_y - origin_y
  if dx == 0 and dy == 0 then
    return true
  end
  local target_angle = math_utils.atan2(dy, dx)
  local diff = math_utils.normalize_angle(target_angle - facing_angle)
  return math.abs(diff) <= fov_radians / 2
end

return math_utils
