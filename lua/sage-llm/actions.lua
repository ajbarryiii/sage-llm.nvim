---Predefined actions with prompt templates

local M = {}

---@class SageAction
---@field name string Action name
---@field prompt string Prompt template

---@type table<string, SageAction>
local actions = {
  explain = {
    name = "explain",
    prompt = "Explain what this code does and how it works.",
  },
  fix = {
    name = "fix",
    prompt = "Explain the errors/warnings shown in the diagnostics and how to fix them.",
  },
}

---Get prompt for an action
---@param name string
---@return string|nil
function M.get_prompt(name)
  local action = actions[name]
  return action and action.prompt or nil
end

return M
