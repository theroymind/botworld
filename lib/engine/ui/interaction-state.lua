local tween = require("lib.engine.ui.tween")

local interaction_state = {}

local TRANSITION_DURATION = 0.12
local IDLE_LIGHTEN = 0
local HOVER_LIGHTEN = 0.5
local PRESS_LIGHTEN = 1.0

local zones = {}
local zone_count = 0

local hovered_id = nil
local pressed_id = nil
local focused_id = nil

local transitions = {}

local function get_or_create_transition(id)
  local entry = transitions[id]
  if not entry then
    entry = { lighten = 0 }
    transitions[id] = entry
  end
  return entry
end

local function transition_to(id, target)
  local entry = get_or_create_transition(id)
  tween.to(entry, "lighten", target, TRANSITION_DURATION, tween.ease_out_cubic)
end

local function find_hovered_at(mx, my)
  for i = zone_count, 1, -1 do
    local z = zones[i]
    if z.rect:contains(mx, my) then
      return z.id
    end
  end
  return nil
end

function interaction_state.begin_frame() zone_count = 0 end

function interaction_state.register_zone(id, r)
  if not id or not r then
    return
  end
  zone_count = zone_count + 1
  zones[zone_count] = { id = id, rect = r }
end

local function update_hover(new_hover)
  if new_hover == hovered_id then
    return
  end
  if hovered_id and hovered_id ~= pressed_id then
    transition_to(hovered_id, IDLE_LIGHTEN)
  end
  if new_hover and new_hover ~= pressed_id then
    transition_to(new_hover, HOVER_LIGHTEN)
  end
  hovered_id = new_hover
end

local function update_press(mouse_down)
  if mouse_down and not pressed_id and hovered_id then
    pressed_id = hovered_id
    transition_to(pressed_id, PRESS_LIGHTEN)
    return
  end
  if mouse_down or not pressed_id then
    return
  end
  local was_pressed = pressed_id
  pressed_id = nil
  local target_lighten = was_pressed == hovered_id and HOVER_LIGHTEN or IDLE_LIGHTEN
  transition_to(was_pressed, target_lighten)
end

function interaction_state.commit_frame(mx, my, mouse_down)
  update_hover(find_hovered_at(mx, my))
  update_press(mouse_down)
end

function interaction_state.get_lighten(id)
  local entry = transitions[id]
  if not entry then
    return 0
  end
  return entry.lighten
end

function interaction_state.is_hovered(id) return hovered_id == id end

function interaction_state.is_pressed(id) return pressed_id == id end

function interaction_state.is_focused(id) return focused_id == id end

function interaction_state.set_focused(id) focused_id = id end

function interaction_state.get_hovered() return hovered_id end

function interaction_state.get_pressed() return pressed_id end

function interaction_state.reset()
  hovered_id = nil
  pressed_id = nil
  focused_id = nil
  zone_count = 0
  for k in pairs(transitions) do
    transitions[k] = nil
  end
end

return interaction_state
