local colors = {}

local function hex(str)
  local r = tonumber(str:sub(1, 2), 16) / 255
  local g = tonumber(str:sub(3, 4), 16) / 255
  local b = tonumber(str:sub(5, 6), 16) / 255
  return { r, g, b, 1 }
end

colors.palette = {
  tan_light = hex("a6884a"),
  tan = hex("906c30"),
  brown_warm = hex("825337"),
  brown_red = hex("83473d"),
  brown_rust = hex("66352e"),

  red_vibrant = hex("cc2222"),
  brown_dark = hex("562923"),
  plum = hex("612638"),
  brown_earth = hex("46332c"),
  gray_warm_dark = hex("323230"),
  gray_blue_dark = hex("3e4055"),

  purple_dark = hex("382d35"),
  slate_dark = hex("323b42"),
  navy = hex("1f2d36"),
  charcoal = hex("141f25"),
  black = hex("0b1016"),

  blue_deep = hex("245273"),
  blue = hex("4e7499"),
  blue_steel = hex("5e7e8b"),
  gray_blue = hex("798a92"),
  gray_blue_light = hex("879ea3"),

  cream = hex("e3ddd1"),
  beige = hex("bdbbae"),
  tan_muted = hex("af9e94"),
  mauve = hex("907c75"),
  olive_light = hex("a29f7e"),

  khaki = hex("969372"),
  khaki_dark = hex("78735d"),
  olive_brown = hex("696353"),
  olive_dark = hex("4f493b"),
  charcoal_warm = hex("212528"),

  gray_green = hex("595c55"),
  gray_neutral = hex("4b4e4f"),
  olive_deep = hex("57562a"),
  olive = hex("675f30"),
  olive_yellow = hex("727234"),

  green_muted = hex("73804b"),
  green_sage = hex("5f7b53"),
  teal = hex("3b6d62"),
  teal_dark = hex("32534a"),
}

local p = colors.palette

colors.ui = {
  accent = p.tan_light,
  accent_dim = p.tan,
  border = p.gray_neutral,
  border_light = p.gray_blue,
  border_dim = p.olive_dark,
  text = p.cream,
  text_dim = p.beige,
  text_muted = p.gray_blue_light,
  text_faint = p.gray_blue,
  bg_overlay = { p.black[1], p.black[2], p.black[3], 0.85 },
  bg_panel = { p.charcoal[1], p.charcoal[2], p.charcoal[3], 0.7 },
  bg_dark = p.black,
  divider = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.6 },
  shadow = { p.black[1], p.black[2], p.black[3], 0.6 },
  white = { 1, 1, 1, 1 },
  transition_black = { 0, 0, 0, 1 },
}

colors.game = {
  mp = p.blue,
  tp = { 0.9, 0.6, 0.1, 1 },
  xp = p.olive_yellow,
  physical = p.tan_light,
  magical = p.blue,
  equip = p.green_sage,
  equip_border = { p.green_sage[1], p.green_sage[2], p.green_sage[3], 0.8 },
  loot_pickup = p.blue_steel,
  xp_gain = p.olive_yellow,
  save_indicator = p.gray_blue_light,
  active_slot = { p.tan_light[1], p.tan_light[2], p.tan_light[3], 0.8 },
  inactive_slot = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.8 },
  selected_border = p.tan_light,
  item_border = { p.gray_blue[1], p.gray_blue[2], p.gray_blue[3], 0.8 },
  empty_border = { p.olive_dark[1], p.olive_dark[2], p.olive_dark[3], 0.6 },
  count_text = p.beige,
  category_text = p.gray_blue_light,
  stat_text = p.green_sage,
  name_shadow = { p.black[1], p.black[2], p.black[3], 0.6 },
  name_text = { p.cream[1], p.cream[2], p.cream[3], 0.9 },
  world_bg_default = p.black,
}

-- Generic GLOBAL color tokens -- the one palette every layer styles itself from.
-- Ordinal naming (primary, secondary, tertiary, ...): consumers bind a token to a
-- role at their edge (e.g. the cell view maps render kinds -> tokens; fx defaults
-- pull tokens), never a literal RGB. Extend with deeper ordinals (quaternary, ...)
-- only when a genuinely new hue is needed; shades of an existing hue are variant
-- suffixes (_dim, _bright, _dark) on their base token.
colors.primary = { 0.38, 0.96, 0.92 } -- teal: the protagonist hue (bright, pops on the dark field)
colors.primary_dark = { 0.16, 0.62, 0.54 } -- inner-detail shade of primary
colors.secondary = { 0.56, 1.0, 0.46 } -- green: nourishment / progress (bright, pops on the dark field)
colors.secondary_bright = { 0.72, 1.0, 0.66 } -- highlight shade of secondary
colors.tertiary = { 0.95, 0.86, 0.55 } -- warm sand: neutral third parties
colors.quaternary = { 0.96, 0.34, 0.30 } -- red: threat / violence
colors.success = p.green_sage
colors.destructive = p.red_vibrant
colors.info = p.blue_steel
colors.foreground = p.cream
colors.foreground_dim = p.beige
colors.foreground_muted = p.gray_blue_light
colors.foreground_faint = p.gray_blue
colors.background = p.black
colors.surface = p.charcoal
colors.border = p.gray_neutral
colors.border_dim = p.olive_dark
colors.border_inner_highlight = p.gray_blue
colors.muted = p.gray_neutral
colors.shadow = { 0, 0, 0, 1 }
colors.overlay_dark = { 0, 0, 0, 0.5 }

colors.gradient = {
  surface_top = p.charcoal_warm,
  surface_bottom = p.charcoal,
  title_top = p.tan_light,
  title_bottom = p.tan,
  hp_top = p.green_muted,
  hp_bottom = p.green_sage,
  mp_top = p.blue_steel,
  mp_bottom = p.blue_deep,
  tp_top = { 0.95, 0.65, 0.18, 1 },
  tp_bottom = { 0.7, 0.4, 0.05, 1 },
  xp_top = p.olive_yellow,
  xp_bottom = p.olive,
}

colors.console = {
  bg = { p.black[1], p.black[2], p.black[3], 0.85 },
  text = p.green_sage,
  cursor = p.green_sage,
}

colors.debug = {
  bg = { p.black[1], p.black[2], p.black[3], 0.7 },
  title = p.blue_steel,
  section = p.slate_dark,
  label = p.gray_blue_light,
  value = p.cream,

  neon_green = { 0.2, 1, 0.4, 1 },
  neon_red = { 1, 0.15, 0.3, 1 },
  neon_cyan = { 0, 0.9, 1, 1 },
  neon_magenta = { 1, 0.2, 0.8, 1 },
  neon_yellow = { 1, 1, 0.2, 1 },

  spawner_colors = {
    { p.green_sage[1], p.green_sage[2], p.green_sage[3], 0.4 },
    { p.blue[1], p.blue[2], p.blue[3], 0.4 },
    { p.tan_light[1], p.tan_light[2], p.tan_light[3], 0.4 },
    { p.plum[1], p.plum[2], p.plum[3], 0.4 },
    { p.teal[1], p.teal[2], p.teal[3], 0.4 },
    { p.olive_yellow[1], p.olive_yellow[2], p.olive_yellow[3], 0.4 },
  },
}

colors.hotkey = {
  border_empty = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.8 },
  border_filled = { p.gray_blue[1], p.gray_blue[2], p.gray_blue[3], 0.8 },
  slot_number = { p.gray_blue[1], p.gray_blue[2], p.gray_blue[3], 0.6 },
  icon_hp = p.brown_red,
  icon_mp = p.blue,
  icon_default = { 1, 1, 1, 0.9 },
  lock_bg = { 0, 0, 0, 0.5 },
  lock_border_locked = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.6 },
  lock_border_unlocked = { p.tan_light[1], p.tan_light[2], p.tan_light[3], 0.8 },
  lock_icon = { p.gray_blue_light[1], p.gray_blue_light[2], p.gray_blue_light[3], 0.8 },
  count_text = p.beige,
  casting_overlay = { 0, 0, 0, 0.55 },
}

colors.slot = {
  bg = { p.black[1], p.black[2], p.black[3], 0.6 },
  icon = { p.cream[1], p.cream[2], p.cream[3], 0.9 },
}

colors.shop = {
  selected_slot = p.tan_light,
  gold_icon = p.tan_light,
  numpad_border = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.8 },
  input_bg = { p.black[1], p.black[2], p.black[3], 0.7 },
  input_border = p.gray_blue,
  section_border = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.4 },
}

colors.menu_bar = {
  bg = { 0, 0, 0, 0.6 },
  icon = { 1, 1, 1, 0.9 },
}

colors.npc = {
  weapon_shop = p.tan_light,
  armor_shop = p.blue,
  grocery = p.teal,
  gatekeeper = p.plum,
  grand_master = p.tan,
  blacksmith = p.brown_warm,
  quest_giver = p.olive_yellow,
  instance_portal = p.blue_deep,
}

colors.feedback = {
  error = { 1, 0.4, 0.4, 1 },
  success = { 0.3, 1, 0.3, 1 },
  info = { 0.3, 0.7, 1, 1 },
  reward = { 1, 0.85, 0.3, 1 },
}

colors.glow = {
  physical = p.tan_muted,
  default = p.tan,
  magical = p.blue,
}

colors.element = {
  wind = hex("99e699"),
  fire = hex("ff6619"),
  water = hex("4d99ff"),
  dark = hex("9933cc"),
  holy = hex("ffffb3"),
  none = hex("cccccc"),
}

colors.scene = {
  accent = p.tan_light,
  border = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.8 },
  dim_text = p.gray_blue_light,
  empty_text = { p.gray_blue[1], p.gray_blue[2], p.gray_blue[3], 0.6 },
  disabled_bg = { p.gray_neutral[1], p.gray_neutral[2], p.gray_neutral[3], 0.6 },
  empty_slot_bg = { p.olive_dark[1], p.olive_dark[2], p.olive_dark[3], 0.3 },
}

function colors.hp(current, max)
  local pct = current / max
  if pct > 0.5 then
    return { p.green_sage[1], p.green_sage[2], p.green_sage[3] }
  elseif pct >= 0.25 then
    return { p.tan_light[1], p.tan_light[2], p.tan_light[3] }
  else
    return { p.brown_red[1], p.brown_red[2], p.brown_red[3] }
  end
end

function colors.hp_gradient(current, max)
  local pct = current / max
  if pct > 0.5 then
    return { top = p.green_muted, bottom = p.green_sage }
  elseif pct >= 0.25 then
    return { top = p.tan_light, bottom = p.tan }
  else
    return { top = p.brown_red, bottom = p.brown_rust }
  end
end

function colors.with_alpha(color, alpha) return { color[1], color[2], color[3], alpha } end

return colors
