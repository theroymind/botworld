-- Luacheck configuration for the botworld LÖVE 2D project.
std = "lua51+love"

-- Project globals.
globals = {
  "love",
}

-- Exclude non-project directories.
exclude_files = {
  ".claude/",
}

-- stylua owns formatting, so don't double-report line length.
max_line_length = false

-- Ignore unused self warnings.
self = false

-- Ignore unused variables/args prefixed with underscore.
ignore = { "21./_.*", "31./_.*" }

-- Specs are plain Lua scripts (no busted) and read the global arg table.
files["tests/**/*.lua"] = {
  globals = { "arg" },
}

-- Dev labs use LuaJIT's bit library.
files["tools/**/*.lua"] = {
  globals = { "bit" },
}
