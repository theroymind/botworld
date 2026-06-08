local function spacer(height)
  return {
    type = "spacer",
    h = height or 0,
    resolved_rect = nil,
  }
end

return spacer
