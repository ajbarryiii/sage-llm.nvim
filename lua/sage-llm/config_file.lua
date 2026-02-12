--- Config file management for sage-llm
--- Handles loading and creating the dedicated config file at ~/.config/sage-llm/config.lua
---@class SageConfigFile
local M = {}

--- Template content for new config files
local TEMPLATE = [[
-- sage-llm.nvim configuration
-- This file is loaded automatically by sage-llm.nvim
-- Keep your API key here instead of in your Neovim config

return {
  -- Your OpenRouter API key (required)
  -- Get one at: https://openrouter.ai/keys
  api_key = "your-api-key-here",

  -- Uncomment to override defaults:
  -- model = "anthropic/claude-sonnet-4-20250514",
  -- detect_dependencies = false,
  --
  -- response = {
  --   width = 0.6,
  --   height = 0.4,
  --   border = "rounded",
  -- },
  --
  -- input = {
  --   width = 0.5,
  --   height = 5,
  --   border = "rounded",
  -- },
}
]]

--- Get the config directory path
--- Respects $XDG_CONFIG_HOME if set, otherwise uses ~/.config/sage-llm
---@return string
function M.get_config_dir()
  local xdg = vim.env.XDG_CONFIG_HOME
  if xdg and xdg ~= "" then
    return xdg .. "/sage-llm"
  end
  return vim.fn.expand("~/.config/sage-llm")
end

--- Get the full path to the config file
---@return string
function M.get_config_path()
  return M.get_config_dir() .. "/config.lua"
end

--- Check if the config file exists
---@return boolean
function M.exists()
  return vim.fn.filereadable(M.get_config_path()) == 1
end

--- Load the config file and return its contents
--- Returns nil if file doesn't exist or has errors
---@return table|nil config The loaded configuration table, or nil on error
---@return string|nil error Error message if loading failed
function M.load()
  local path = M.get_config_path()

  if not M.exists() then
    return nil, nil
  end

  local ok, result = pcall(dofile, path)
  if not ok then
    return nil, "Failed to load config file: " .. tostring(result)
  end

  if type(result) ~= "table" then
    return nil, "Config file must return a table"
  end

  return result, nil
end

--- Create the config directory and template file
--- Does nothing if the file already exists
---@return boolean success Whether the file was created
---@return string|nil error Error message if creation failed
function M.create_template()
  if M.exists() then
    return false, "Config file already exists"
  end

  local dir = M.get_config_dir()

  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(dir) == 0 then
    local mkdir_ok = vim.fn.mkdir(dir, "p")
    if mkdir_ok == 0 then
      return false, "Failed to create directory: " .. dir
    end
  end

  -- Write template file
  local path = M.get_config_path()
  local file = io.open(path, "w")
  if not file then
    return false, "Failed to create config file: " .. path
  end

  file:write(TEMPLATE)
  file:close()

  return true, nil
end

--- Serialize a value to a Lua string representation
---@param value any
---@param indent number
---@return string
local function serialize_value(value, indent)
  local t = type(value)
  if t == "string" then
    return string.format("%q", value)
  elseif t == "number" or t == "boolean" then
    return tostring(value)
  elseif t == "table" then
    local parts = {}
    local indent_str = string.rep("  ", indent)
    local inner_indent = string.rep("  ", indent + 1)

    for k, v in pairs(value) do
      local key_str
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        key_str = k
      else
        key_str = "[" .. serialize_value(k, 0) .. "]"
      end
      table.insert(parts, inner_indent .. key_str .. " = " .. serialize_value(v, indent + 1))
    end

    if #parts == 0 then
      return "{}"
    end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent_str .. "}"
  else
    return "nil"
  end
end

--- Save a configuration table to the config file
--- Preserves api_key from existing config if not provided
---@param config table The configuration to save
---@return boolean success
---@return string|nil error
function M.save(config)
  local dir = M.get_config_dir()

  -- Create directory if it doesn't exist
  if vim.fn.isdirectory(dir) == 0 then
    local mkdir_ok = vim.fn.mkdir(dir, "p")
    if mkdir_ok == 0 then
      return false, "Failed to create directory: " .. dir
    end
  end

  -- Load existing config to preserve api_key if not in new config
  local existing = M.load()
  if existing and existing.api_key and not config.api_key then
    config.api_key = existing.api_key
  end

  -- Build the config file content
  local lines = {
    "-- sage-llm.nvim configuration",
    "-- This file is loaded automatically by sage-llm.nvim",
    "",
    "return " .. serialize_value(config, 0),
    "",
  }

  local path = M.get_config_path()
  local file = io.open(path, "w")
  if not file then
    return false, "Failed to write config file: " .. path
  end

  file:write(table.concat(lines, "\n"))
  file:close()

  return true, nil
end

--- Update a single key in the config file
--- Creates the file if it doesn't exist
---@param key string The key to update (e.g., "model")
---@param value any The value to set
---@return boolean success
---@return string|nil error
function M.update(key, value)
  -- Load existing config or start fresh
  local config = M.load() or {}

  -- Update the key
  config[key] = value

  -- Save back
  return M.save(config)
end

return M
