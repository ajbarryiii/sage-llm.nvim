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
  },

  detect_dependencies = false,
  debug = false,

  models = {
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
---@param opts SageConfig|nil
function M.setup(opts)
  opts = opts or {}

  -- Deep merge user options with defaults
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

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

---Set the current model
---@param model string
function M.set_model(model)
  M.options.model = model
end

return M
