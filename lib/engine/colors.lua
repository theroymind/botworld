-- Botworld's color tokens: the love-ui default theme re-skinned with everything
-- game-specific. Requiring this module applies the overrides exactly once (Lua
-- caches the require), in place, so every love-ui module that already required
-- the library colors observes the same overridden tables. Game code requires
-- THIS module -- never lib.love-ui.theme.colors directly -- so colors.game and
-- friends are always present. main.lua requires it at boot, before any draw.
--
-- Tokens NOT overridden here (palette, ui, gradient, scene, hp/hp_gradient,
-- text_shadow, world_text, slot_border_equip, slot_border_default) are
-- byte-identical to the library defaults -- verified against the pre-extraction
-- vendored lib/engine/ui/colors.lua.
local colors = require("lib.love-ui.theme.colors")

local palette = colors.palette

colors.apply({
  -- Generic GLOBAL color tokens -- the one palette every layer styles itself
  -- from. Ordinal naming (primary, secondary, tertiary, ...): consumers bind a
  -- token to a role at their edge (e.g. the cell view maps render kinds ->
  -- tokens; fx defaults pull tokens), never a literal RGB. Extend with deeper
  -- ordinals (quaternary, ...) only when a genuinely new hue is needed; shades
  -- of an existing hue are variant suffixes (_dim, _bright, _dark) on their
  -- base token. These replace the library's tan/blue defaults wholesale.
  primary = { 0.38, 0.96, 0.92 }, -- teal: the protagonist hue (bright, pops on the dark field)
  primary_dark = { 0.16, 0.62, 0.54 }, -- inner-detail shade of primary
  secondary = { 0.56, 1.0, 0.46 }, -- green: nourishment / progress (bright, pops on the dark field)
  secondary_bright = { 0.72, 1.0, 0.66 }, -- highlight shade of secondary
  tertiary = { 0.95, 0.86, 0.55 }, -- warm sand: neutral third parties
  quaternary = { 0.96, 0.34, 0.30 }, -- red: threat / violence

  -- Rival SPECIES palette: vibrant, saturated hues for the neutral competitor
  -- microbes so a contested dish reads as several distinct other-life species
  -- rather than one grey mass. Deliberately spread across orange/gold/pink/
  -- purple/violet -- a warm-to-cool sweep that stays clear of the protagonist
  -- teal (primary), nourishment green (secondary) and threat red (quaternary),
  -- so rivals never get mistaken for your cells, food, or a predator. The view
  -- buckets each rival's color-free `tint` seed into one of these;
  -- extend/recolor here (the one home for the RGB).
  competitor_species = {
    { 1.00, 0.55, 0.10 }, -- vibrant orange
    { 1.00, 0.78, 0.16 }, -- amber gold
    { 1.00, 0.30, 0.66 }, -- hot pink
    { 0.78, 0.28, 0.98 }, -- magenta-purple
    { 0.42, 0.46, 1.00 }, -- violet blue
  },

  -- Game-domain tokens (bars, slots, combat text). The library kept generic
  -- copies of three of these under new names (name_shadow -> text_shadow,
  -- equip_border -> slot_border_equip, item_border -> slot_border_default) for
  -- its own primitives; the game-side names live on here unchanged.
  game = {
    mp = palette.blue,
    tp = { 0.9, 0.6, 0.1, 1 },
    xp = palette.olive_yellow,
    physical = palette.tan_light,
    magical = palette.blue,
    equip = palette.green_sage,
    equip_border = { palette.green_sage[1], palette.green_sage[2], palette.green_sage[3], 0.8 },
    loot_pickup = palette.blue_steel,
    xp_gain = palette.olive_yellow,
    save_indicator = palette.gray_blue_light,
    active_slot = { palette.tan_light[1], palette.tan_light[2], palette.tan_light[3], 0.8 },
    inactive_slot = {
      palette.gray_neutral[1],
      palette.gray_neutral[2],
      palette.gray_neutral[3],
      0.8,
    },
    selected_border = palette.tan_light,
    item_border = { palette.gray_blue[1], palette.gray_blue[2], palette.gray_blue[3], 0.8 },
    empty_border = { palette.olive_dark[1], palette.olive_dark[2], palette.olive_dark[3], 0.6 },
    count_text = palette.beige,
    category_text = palette.gray_blue_light,
    stat_text = palette.green_sage,
    name_shadow = { palette.black[1], palette.black[2], palette.black[3], 0.6 },
    name_text = { palette.cream[1], palette.cream[2], palette.cream[3], 0.9 },
    world_bg_default = palette.black,
  },

  console = {
    bg = { palette.black[1], palette.black[2], palette.black[3], 0.85 },
    text = palette.green_sage,
    cursor = palette.green_sage,
  },

  debug = {
    bg = { palette.black[1], palette.black[2], palette.black[3], 0.7 },
    title = palette.blue_steel,
    section = palette.slate_dark,
    label = palette.gray_blue_light,
    value = palette.cream,

    neon_green = { 0.2, 1, 0.4, 1 },
    neon_red = { 1, 0.15, 0.3, 1 },
    neon_cyan = { 0, 0.9, 1, 1 },
    neon_magenta = { 1, 0.2, 0.8, 1 },
    neon_yellow = { 1, 1, 0.2, 1 },

    spawner_colors = {
      { palette.green_sage[1], palette.green_sage[2], palette.green_sage[3], 0.4 },
      { palette.blue[1], palette.blue[2], palette.blue[3], 0.4 },
      { palette.tan_light[1], palette.tan_light[2], palette.tan_light[3], 0.4 },
      { palette.plum[1], palette.plum[2], palette.plum[3], 0.4 },
      { palette.teal[1], palette.teal[2], palette.teal[3], 0.4 },
      { palette.olive_yellow[1], palette.olive_yellow[2], palette.olive_yellow[3], 0.4 },
    },
  },
})

return colors
