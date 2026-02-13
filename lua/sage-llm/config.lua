---@class SageConfig
---@field api_key string|nil API key for OpenRouter (falls back to $OPENROUTER_API_KEY)
---@field model string Default model to use
---@field base_url string OpenRouter API base URL
---@field response SageResponseConfig Response window configuration
---@field input SageInputConfig Input window configuration
---@field detect_dependencies boolean Whether to detect and include dependencies
---@field models string[] Available models for picker
---@field system_prompt string System prompt for the LLM (with code selection)
---@field system_prompt_no_selection string System prompt for the LLM (without code selection)
---@field debug boolean Enable debug logging to /tmp/sage-llm-debug.log

---@class SageResponseConfig
---@field width number Width as fraction of editor (0-1)
---@field height number Height as fraction of editor (0-1)
---@field border string Border style

---@class SageInputConfig
---@field width number Width as fraction of editor (0-1)
---@field height number Height in lines
---@field border string Border style
---@field prompt string Prompt text shown in title

local config_file = require("sage-llm.config_file")

local M = {}

---@type SageConfig
M.defaults = {
  api_key = nil,
  model = "openai/gpt-oss-20b",
  base_url = "https://openrouter.ai/api/v1",

  response = {
    width = 0.6,
    height = 0.4,
    border = "rounded",
  },

  input = {
    width = 0.5,
    height = 5,
    border = "rounded",
    prompt = "Ask about this code: ",
    followup_prompt = "Follow-up question:",
  },

  detect_dependencies = false,
  debug = false,

  models = {
    "openai/gpt-oss-20b",
    "openai/gpt-5-nano",
    "openai/gpt-5.2-codex",
    "moonshotai/kimi-k2.5",
    "google/gemini-3-flash-preview",
    "anthropic/claude-sonnet-4.5",
    "x-ai/grok-4.1-fast",
    "anthropic/claude-opus-4.6",
    "anthropic/claude-haiku-4.5",
  },

  system_prompt = [[You are a concise coding tutor helping a developer understand code.

Rules:
- Be brief and direct
- Use `inline code` for short references rather than full code blocks
- Only show multi-line code blocks when essential for understanding
- When explaining errors, focus on the "why" not just the fix
- Reference language concepts by name (e.g., "ownership", "borrow checker", "lifetime")]],

  system_prompt_no_selection = [[You are a concise coding assistant.

Rules:
- Be brief and direct
- Use `inline code` for short references rather than full code blocks
- Only show multi-line code blocks when essential for understanding
- Focus on practical, actionable answers]],
}

---@type SageConfig
M.options = vim.deepcopy(M.defaults)

---Merge user options with defaults
---Priority: config file > setup() opts > env var > defaults
---@param opts SageConfig|nil
function M.setup(opts)
  opts = opts or {}

  -- Start with defaults
  local base = vim.deepcopy(M.defaults)

  -- Merge setup() opts (lower priority)
  base = vim.tbl_deep_extend("force", base, opts)

  -- Load external config file (highest priority)
  local external, err = config_file.load()
  if external then
    base = vim.tbl_deep_extend("force", base, external)
  elseif err then
    vim.notify_once("sage-llm: " .. err, vim.log.levels.WARN)
  elseif not config_file.exists() then
    -- First run: create template config file
    local created, create_err = config_file.create_template()
    if created then
      vim.notify_once(
        "sage-llm: Created config file at "
          .. config_file.get_config_path()
          .. "\nEdit it to add your API key.",
        vim.log.levels.INFO
      )
    elseif create_err then
      vim.notify_once("sage-llm: " .. create_err, vim.log.levels.WARN)
    end
  end

  M.options = base

  -- Validate required fields
  M.validate()
end

---Validate configuration
function M.validate()
  vim.validate({
    model = { M.options.model, "string" },
    base_url = { M.options.base_url, "string" },
    ["response.width"] = { M.options.response.width, "number" },
    ["response.height"] = { M.options.response.height, "number" },
    ["input.width"] = { M.options.input.width, "number" },
    ["input.height"] = { M.options.input.height, "number" },
    detect_dependencies = { M.options.detect_dependencies, "boolean" },
    debug = { M.options.debug, "boolean" },
    models = { M.options.models, "table" },
    system_prompt = { M.options.system_prompt, "string" },
    system_prompt_no_selection = { M.options.system_prompt_no_selection, "string" },
  })
end

---Get the API key from config or environment
---@return string|nil
function M.get_api_key()
  return M.options.api_key or vim.env.OPENROUTER_API_KEY
end

---Set dependency detection on/off
---@param enabled boolean
function M.set_detect_dependencies(enabled)
  M.options.detect_dependencies = enabled
end

---Set the current model and persist to config file
---@param model string
---@param persist boolean|nil Whether to persist to config file (default: true)
function M.set_model(model, persist)
  M.options.model = model

  -- Persist to config file by default
  if persist ~= false then
    local ok, err = config_file.update("model", model)
    if not ok and err then
      vim.notify_once("sage-llm: Failed to save model: " .. err, vim.log.levels.WARN)
    end
  end
end

---Add a model to the picker list and persist to config file
---@param model string
---@param persist boolean|nil Whether to persist to config file (default: true)
function M.add_model(model, persist)
  if model == "" then
    return
  end

  local exists = vim.tbl_contains(M.options.models, model)
  if not exists then
    table.insert(M.options.models, model)
  end

  -- Persist to config file by default
  if persist ~= false then
    local ok, err = config_file.update("models", M.options.models)
    if not ok and err then
      vim.notify_once("sage-llm: Failed to save models: " .. err, vim.log.levels.WARN)
    end
  end
end

---Remove a model from the picker list and persist to config file
---@param model string
---@param persist boolean|nil Whether to persist to config file (default: true)
---@return boolean removed Whether the model was removed
function M.remove_model(model, persist)
  local idx = nil
  for i, value in ipairs(M.options.models) do
    if value == model then
      idx = i
      break
    end
  end

  if not idx then
    return false
  end

  if #M.options.models == 1 then
    return false
  end

  table.remove(M.options.models, idx)

  if M.options.model == model then
    M.options.model = M.options.models[1]
  end

  -- Persist to config file by default
  if persist ~= false then
    local models_ok, models_err = config_file.update("models", M.options.models)
    if not models_ok and models_err then
      vim.notify_once("sage-llm: Failed to save models: " .. models_err, vim.log.levels.WARN)
    end

    local model_ok, model_err = config_file.update("model", M.options.model)
    if not model_ok and model_err then
      vim.notify_once("sage-llm: Failed to save model: " .. model_err, vim.log.levels.WARN)
    end
  end

  return true
end

---Get the path to the external config file
---@return string
function M.get_config_path()
  return config_file.get_config_path()
end

return M
