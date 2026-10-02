local config = require("sage-llm.config")

local M = {}
local ADD_CUSTOM_MODEL = "Add custom model..."
local REMOVE_MODEL = "Remove model..."
local CHATGPT_SUBSCRIPTION = "ChatGPT subscription..."

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
    if config.set_provider then
      config.set_provider("openrouter")
    else
      config.options.provider = "openrouter"
    end
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
      vim.notify(
        "sage-llm: Removed " .. model .. "; switched to " .. config.options.model,
        vim.log.levels.INFO
      )
      return
    end

    vim.notify("sage-llm: Removed model " .. model, vim.log.levels.INFO)
  end)
end

---Open remove-model picker
function M.remove()
  remove_model()
end

---Load available models for the authenticated ChatGPT subscription
function M.select_chatgpt()
  require("sage-llm.chatgpt").list_models(function(models, err, is_current)
    if err then
      vim.notify("sage-llm: " .. err, vim.log.levels.ERROR)
      return
    end
    if not models or #models == 0 then
      vim.notify("sage-llm: No ChatGPT models available for this account", vim.log.levels.WARN)
      return
    end

    local current = config.options.chatgpt and config.options.chatgpt.model
    vim.ui.select(models, {
      prompt = "Select ChatGPT subscription model:",
      format_item = function(model)
        local label = model.display_name or model.slug
        if label ~= model.slug then
          label = label .. " (" .. model.slug .. ")"
        end
        if config.options.provider == "chatgpt" and model.slug == current then
          label = label .. " (current)"
        end
        return label
      end,
    }, function(model)
      if not model or (is_current and not is_current()) then
        return
      end
      config.set_provider("chatgpt")
      config.set_model(model.slug)
      vim.notify("sage-llm: ChatGPT model set to " .. model.slug, vim.log.levels.INFO)
    end)
  end)
end

---Open model selector using vim.ui.select
function M.select()
  local models = config.options.models
  local current = config.options.model
  local current_provider = config.options.provider or "openrouter"

  -- Format items with current marker
  local items = {}
  local item_kinds = {}
  for _, model in ipairs(models) do
    local label = "OpenRouter: " .. model
    if current_provider == "openrouter" and model == current then
      label = label .. " (current)"
    end
    table.insert(items, label)
    table.insert(item_kinds, { provider = "openrouter", model = model })
  end

  table.insert(items, ADD_CUSTOM_MODEL)
  table.insert(item_kinds, { action = "add" })
  table.insert(items, REMOVE_MODEL)
  table.insert(item_kinds, { action = "remove" })
  table.insert(items, CHATGPT_SUBSCRIPTION)
  table.insert(item_kinds, { action = "chatgpt" })

  vim.ui.select(items, {
    prompt = "Select model:",
    format_item = function(item)
      return item
    end,
  }, function(choice, idx)
    if not choice or not idx then
      return
    end

    local item = item_kinds[idx]
    if item.action == "add" then
      add_custom_model()
      return
    end

    if item.action == "remove" then
      remove_model()
      return
    end

    if item.action == "chatgpt" then
      M.select_chatgpt()
      return
    end

    if config.set_provider then
      config.set_provider(item.provider)
    else
      config.options.provider = item.provider
    end
    config.set_model(item.model)
    vim.notify("sage-llm: Model set to " .. item.model, vim.log.levels.INFO)
  end)
end

return M
