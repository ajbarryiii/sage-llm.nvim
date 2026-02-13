local config = require("sage-llm.config")

local M = {}
local ADD_CUSTOM_MODEL = "Add custom model..."
local REMOVE_MODEL = "Remove model..."

---@param model string|nil
---@return string
local function normalize_model(model)
  if not model then
    return ""
  end

  return vim.trim(model)
end

local function add_custom_model()
  vim.ui.input({ prompt = "Enter OpenRouter model id:" }, function(input)
    local model = normalize_model(input)
    if model == "" then
      return
    end

    config.add_model(model)
    config.set_model(model)
    vim.notify("sage-llm: Added and selected model " .. model, vim.log.levels.INFO)
  end)
end

local function remove_model()
  local current = config.options.model
  local models = config.options.models
  local items = {}

  for _, model in ipairs(models) do
    if model == current then
      table.insert(items, model .. " (current)")
    else
      table.insert(items, model)
    end
  end

  vim.ui.select(items, {
    prompt = "Remove model:",
    format_item = function(item)
      return item
    end,
  }, function(_, idx)
    if not idx then
      return
    end

    local model = models[idx]
    local removed = config.remove_model(model)
    if not removed then
      vim.notify("sage-llm: At least one model must remain in picker", vim.log.levels.WARN)
      return
    end

    if model == current then
      vim.notify("sage-llm: Removed " .. model .. "; switched to " .. config.options.model, vim.log.levels.INFO)
      return
    end

    vim.notify("sage-llm: Removed model " .. model, vim.log.levels.INFO)
  end)
end

---Open remove-model picker
function M.remove()
  remove_model()
end

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

  table.insert(items, ADD_CUSTOM_MODEL)
  table.insert(items, REMOVE_MODEL)

  vim.ui.select(items, {
    prompt = "Select model:",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if choice and idx then
      if choice == ADD_CUSTOM_MODEL then
        add_custom_model()
        return
      end

      if choice == REMOVE_MODEL then
        remove_model()
        return
      end

      -- Get the actual model name (without " (current)" suffix)
      local model = models[idx]
      config.set_model(model)
      vim.notify("sage-llm: Model set to " .. model, vim.log.levels.INFO)
    end
  end)
end

return M
