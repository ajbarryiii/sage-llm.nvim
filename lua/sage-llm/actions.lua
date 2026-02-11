---Predefined actions with prompt templates

local M = {}

---@class SageAction
---@field name string Action name
---@field prompt string Prompt template

---@type table<string, SageAction>
M.actions = {
  explain = {
    name = "explain",
    prompt = "Explain what this code does and how it works.",
  },
  fix = {
    name = "fix",
    prompt = "Explain the errors/warnings shown in the diagnostics and how to fix them.",
  },
}

---Get an action by name
---@param name string
---@return SageAction|nil
function M.get(name)
  return M.actions[name]
end

---Get prompt for an action
---@param name string
---@return string|nil
function M.get_prompt(name)
  local action = M.actions[name]
  return action and action.prompt or nil
end

---List all available action names
---@return string[]
function M.list()
  local names = {}
  for name, _ in pairs(M.actions) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

return M
