local theme = {}

theme.font = { sm = "hud_small", md = "hud", lg = "hud_lg" }

theme.spacing = {
  xs = 4,
  sm = 8,
  md = 12,
  lg = 16,
  xl = 24,
}

theme.sizing = {
  row_height = 50,
  row_radius = 4,
  button_height = 36,
  button_min_width = 60,
  slot_size = 36,
  slot_gap = 3,
  scrollbar_gutter = 14,
  row_text_x = 10,
  row_title_y = 7,
  row_detail_y = 25,
  action_button_w = 44,
  action_button_gap = 6,
  action_button_margin = 10,
  action_button_y = 12,
  cart_row_height = 44,
  price_w = 68,
  summary_button_w = 84,
  clear_button_w = 66,
  gold_w = 110,
  summary_row_h = 28,
  popover_w = 160,
  popover_pad = 6,
  shop_slot_size = 40,
  shop_slot_gap = 4,
  shop_right_panel_w = 220,
  shop_numpad_button = 32,
  shop_numpad_gap = 4,
  shop_quantity_input_h = 28,
  text_input_width = 280,
  text_input_height = 36,
  text_input_padding = 8,
  text_input_radius = 4,
  bar_height = 8,
}

theme.padding = {
  panel_content = {
    theme.spacing.md,
    theme.spacing.md + theme.sizing.scrollbar_gutter,
    theme.spacing.md,
    theme.spacing.md,
  },
}

theme.panel = {
  width = 440,
  height = 360,
  padding = 12,
  title_height = 30,
  close_size = 22,
  title_padding_x = 12,
  title_padding_y = 8,
  close_margin_x = 8,
  scroll_step = 32,
  hud_margin = 10,
}

theme.world_text = {
  shadow_offset = 1,
  label_gap = 2,
  label_above_offset = 8,
}

theme.shadow = {
  sm = { offsets = { 1, 2 }, alphas = { 0.25, 0.12 } },
  md = { offsets = { 1, 2, 4 }, alphas = { 0.30, 0.18, 0.10 } },
  lg = { offsets = { 2, 4, 8 }, alphas = { 0.35, 0.22, 0.12 } },
}

theme.gradient = {
  panel_radius = 6,
  title_radius = 4,
}

theme.border = {
  refined_inset = 1,
}

theme.grip = {
  width = 6,
  dot_count = 4,
  dot_height = 2,
  dot_gap = 2,
}

theme.layout = {
  grid_size = 8,
}

theme.tween = {
  ui_state_duration = 0.12,
  panel_slide = 0.18,
}

function theme.panel.hud_position(screen_w, screen_h, panel_w, panel_h)
  return screen_w - panel_w - theme.panel.hud_margin, math.floor((screen_h - panel_h) / 2)
end

function theme.panel.size(content_w, content_h)
  return content_w + theme.panel.padding * 2,
    theme.panel.title_height + content_h + theme.panel.padding * 2
end

return theme
