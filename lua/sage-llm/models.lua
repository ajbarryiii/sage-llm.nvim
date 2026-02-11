local config = require("sage-llm.config")

local M = {}

---Open model selector using vim.ui.select
function M.select()
  local models = config.options.models
  local current = config.options.model

  -- Format items with current marker
  local items = {}
  for _, model in ipairs(models) do
    if model == current then
      table.insert(items, model .. " (current)")
    else
      table.insert(items, model)
    end
  end

  vim.ui.select(items, {
    prompt = "Select model:",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice and idx then
      -- Get the actual model name (without " (current)" suffix)
      local model = models[idx]
      config.set_model(model)
      vim.notify("sage-llm: Model set to " .. model, vim.log.levels.INFO)
    end
  end)
end

---Get the current model
---@return string
function M.current()
  return config.options.model
end

---Set the model directly
---@param model string
function M.set(model)
  config.set_model(model)
end

return M
