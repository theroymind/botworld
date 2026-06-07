std = "lua51+love"

globals = {
  "love",
}

max_line_length = false
self = false

-- Ignore unused variables/args prefixed with underscore
ignore = { "21./_.*", "31./_.*" }

files["**/*_test.lua"] = {
  std = "+busted",
}
