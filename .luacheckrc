-- Luacheck configuration for sage-llm.nvim
std = "lua51"

-- Neovim globals
globals = {
  "vim",
}

-- Don't report unused self arguments
self = false

-- Max line length
max_line_length = 120

-- Ignore unused loop variables starting with _
ignore = {
  "212/_.*",  -- Unused argument starting with _
  "213/_.*",  -- Unused loop variable starting with _
}

-- Files to exclude
exclude_files = {
  "tests/minimal_init.lua",
}
