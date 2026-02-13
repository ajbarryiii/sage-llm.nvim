---@mod sage-llm sage-llm.nvim
---@brief [[
---A Neovim plugin that allows users to highlight code in visual mode
---and ask an LLM questions about it. LSP diagnostics within the selection
---are automatically included in the context.
---@brief ]]

local config = require("sage-llm.config")
local selection = require("sage-llm.selection")
local prompt = require("sage-llm.prompt")
local api = require("sage-llm.api")
local ui = require("sage-llm.ui")
local actions = require("sage-llm.actions")
local models = require("sage-llm.models")

local M = {}

---Execute a query with the given question (with code selection)
---@param sel SageSelection
---@param question string
local function execute_query(sel, question)
  -- Build the code header for display
  local code_header = prompt.format_code_header(sel)

  -- Open response window with code
  ui.response.open(code_header)
  ui.response.show_loading()

  -- Build messages for API
  local messages = prompt.build_messages(sel, question)

  if config.options.debug then
    vim.schedule(function()
      vim.notify("sage-llm: execute_query using stream_chat", vim.log.levels.INFO)
    end)
  end

  -- Make streaming request and display tokens as they arrive
  local started = false
  local handle = api.stream_chat(messages, {
    on_start = function()
      -- Keep spinner until first token arrives
    end,
    on_token = function(token)
      if not started then
        ui.response.start_streaming()
        started = true
      end
      ui.response.append_token(token)
    end,
    on_complete = function()
      if not started then
        ui.response.start_streaming()
      end
      ui.response.complete()
    end,
    on_error = function(err)
      ui.response.show_error(err)
    end,
  })

  if handle then
    ui.response.set_request_handle(handle)
  end
end

---Execute a simple query without code selection
---@param question string
local function execute_simple_query(question)
  -- Build the question header for display
  local question_header = prompt.format_question_header(question)

  -- Open response window with question
  ui.response.open(question_header)
  ui.response.show_loading()

  -- Build messages for API (no selection)
  local messages = prompt.build_messages_no_selection(question)

  if config.options.debug then
    vim.schedule(function()
      vim.notify("sage-llm: execute_simple_query using stream_chat", vim.log.levels.INFO)
    end)
  end

  -- Make streaming request and display tokens as they arrive
  local started = false
  local handle = api.stream_chat(messages, {
    on_start = function()
      -- Keep spinner until first token arrives
    end,
    on_token = function(token)
      if not started then
        ui.response.start_streaming()
        started = true
      end
      ui.response.append_token(token)
    end,
    on_complete = function()
      if not started then
        ui.response.start_streaming()
      end
      ui.response.complete()
    end,
    on_error = function(err)
      ui.response.show_error(err)
    end,
  })

  if handle then
    ui.response.set_request_handle(handle)
  end
end

---Ask a question about code
---In visual mode: asks about the selection
---In normal mode: asks a general question
function M.ask()
  -- Try to get visual selection
  local sel = selection.get_visual_selection()

  if sel then
    -- Visual mode: ask about selection
    ui.input.open({
      prompt = "Ask about this code:",
      on_submit = function(question)
        execute_query(sel, question)
      end,
      on_cancel = function()
        -- User cancelled, do nothing
      end,
    })
  else
    -- Normal mode: ask without selection
    ui.input.open({
      prompt = "Ask a question:",
      on_submit = function(question)
        execute_simple_query(question)
      end,
      on_cancel = function()
        -- User cancelled, do nothing
      end,
    })
  end
end

---Explain the current visual selection
---Uses predefined "explain" action
function M.explain()
  local sel, err = selection.get_visual_selection()
  if not sel then
    vim.notify("sage-llm: " .. (err or "No selection"), vim.log.levels.WARN)
    return
  end

  local question = actions.get_prompt("explain")
  if question then
    execute_query(sel, question)
  end
end

---Explain how to fix diagnostics in the current visual selection
---Uses predefined "fix" action
function M.fix()
  local sel, err = selection.get_visual_selection()
  if not sel then
    vim.notify("sage-llm: " .. (err or "No selection"), vim.log.levels.WARN)
    return
  end

  local question = actions.get_prompt("fix")
  if question then
    execute_query(sel, question)
  end
end

---Open model selector
function M.select_model()
  models.select()
end

---Enable dependency detection
function M.deps_on()
  config.set_detect_dependencies(true)
  vim.notify("sage-llm: Dependency detection enabled", vim.log.levels.INFO)
end

---Disable dependency detection
function M.deps_off()
  config.set_detect_dependencies(false)
  vim.notify("sage-llm: Dependency detection disabled", vim.log.levels.INFO)
end

---Setup the plugin
---@param opts SageConfig|nil User configuration
function M.setup(opts)
  config.setup(opts)
end

---Get the path to the config file
---@return string
function M.get_config_path()
  return config.get_config_path()
end

---Open the config file for editing
function M.edit_config()
  local path = config.get_config_path()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

return M
