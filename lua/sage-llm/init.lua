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
local conversation = require("sage-llm.conversation")
local infill = require("sage-llm.infill")

local M = {}

---@class SageRequestOptions
---@field search boolean Enable web search by appending :online to model id

---@type SageRequestOptions
local request_opts = {
  search = false,
}

---@return boolean
local function toggle_search()
  request_opts.search = not request_opts.search
  local status = request_opts.search and "enabled" or "disabled"
  vim.notify("sage-llm: Web search " .. status, vim.log.levels.INFO)
  ui.response.set_search_enabled(request_opts.search)
  return request_opts.search
end

---@return SageRequestOptions
local function consume_request_opts()
  local opts = {
    search = request_opts.search,
  }

  request_opts.search = false
  ui.response.set_search_enabled(false)

  return opts
end

---Stream a response into the response window and conversation state
---@param messages table[]
---@param on_error fun(err: string)|nil
---@param opts SageRequestOptions|nil
local function stream_response(messages, on_error, opts)
  local started = false
  local handle = api.stream_chat(messages, {
    on_start = function() end,
    on_token = function(token)
      if not started then
        ui.response.start_streaming()
        started = true
      end
      ui.response.append_token(token)
      conversation.accumulate_token(token)
    end,
    on_complete = function()
      if not started then
        ui.response.start_streaming()
      end
      conversation.finish_response()
      ui.response.complete()
    end,
    on_error = function(err)
      if on_error then
        on_error(err)
        return
      end
      ui.response.show_error(err)
    end,
  }, opts)

  if handle then
    ui.response.set_request_handle(handle)
  end
end

---Execute a follow-up question within the current conversation
---@param question string
local function execute_followup(question)
  -- Add follow-up to conversation and get updated messages
  local messages = conversation.add_followup(question)

  -- Append follow-up header to the existing response window
  local header = prompt.format_followup_header(question)
  ui.response.append_followup_header(header)
  ui.response.show_loading()

  local opts = consume_request_opts()

  if config.options.debug then
    vim.schedule(function()
      vim.notify(
        "sage-llm: execute_followup (turn " .. (conversation.turn_count() + 1) .. ")",
        vim.log.levels.INFO
      )
    end)
  end

  stream_response(messages, function(err)
    -- Remove the failed follow-up message so user can retry
    conversation.remove_last_user_message()
    ui.response.show_error(err)
  end, opts)
end

---Set up the follow-up callback on the response window
local function setup_followup_callback()
  ui.response.set_on_followup(function()
    M.followup()
  end)

  ui.response.set_on_toggle_search(function()
    return toggle_search()
  end)

  ui.response.set_search_enabled(request_opts.search)
end

---Execute a query with the given question (with code selection)
---@param sel SageSelection
---@param question string
local function execute_query(sel, question)
  local opts = consume_request_opts()

  -- Build the code header for display
  local code_header = prompt.format_code_header(sel)

  -- Open response window with code
  ui.response.open(code_header)
  ui.response.show_loading()

  -- Build messages for API
  local messages = prompt.build_messages(sel, question)

  -- Start conversation tracking
  conversation.start(messages)

  -- Set up follow-up callback
  setup_followup_callback()

  if config.options.debug then
    vim.schedule(function()
      vim.notify("sage-llm: execute_query using stream_chat", vim.log.levels.INFO)
    end)
  end

  stream_response(messages, nil, opts)
end

---Execute a simple query without code selection
---@param question string
local function execute_simple_query(question)
  local opts = consume_request_opts()

  -- Build the question header for display
  local question_header = prompt.format_question_header(question)

  -- Open response window with question
  ui.response.open(question_header)
  ui.response.show_loading()

  -- Build messages for API (no selection)
  local messages = prompt.build_messages_no_selection(question)

  -- Start conversation tracking
  conversation.start(messages)

  -- Set up follow-up callback
  setup_followup_callback()

  if config.options.debug then
    vim.schedule(function()
      vim.notify("sage-llm: execute_simple_query using stream_chat", vim.log.levels.INFO)
    end)
  end

  stream_response(messages, nil, opts)
end

---Execute an inline infill request for the current visual selection.
---@param sel SageSelection
---@param instruction string
local function execute_infill(sel, instruction)
  local opts = consume_request_opts()

  local code_header = prompt.format_code_header(sel)
  ui.response.open(code_header)
  ui.response.show_loading()
  ui.response.set_on_followup(nil)

  local messages = prompt.build_infill_messages(sel, instruction)
  local handle = api.chat(messages, function(content, err)
    if err then
      ui.response.show_error(err)
      return
    end

    local replacement, normalize_err = infill.normalize_response(content or "")
    if not replacement then
      ui.response.show_error(normalize_err or "Failed to parse infill response")
      return
    end

    ui.response.start_streaming()
    ui.response.append_token(prompt.format_infill_preview(instruction, replacement, sel.filetype))
    ui.response.complete()

    ui.response.set_edit_actions(function(close_after_apply)
      local ok, apply_err = infill.apply_selection(sel, replacement)
      if not ok then
        vim.notify("sage-llm: " .. (apply_err or "Failed to apply edit"), vim.log.levels.ERROR)
        return
      end
      ui.response.clear_edit_actions()
      vim.notify("sage-llm: Inline edit applied", vim.log.levels.INFO)
      if close_after_apply then
        ui.response.hide()
      end
    end, function()
      ui.response.clear_edit_actions()
      vim.notify("sage-llm: Inline edit discarded", vim.log.levels.INFO)
    end)
  end, opts)

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
      search_enabled = request_opts.search,
      on_toggle_search = function()
        return toggle_search()
      end,
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
      search_enabled = request_opts.search,
      on_toggle_search = function()
        return toggle_search()
      end,
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

---Edit the current visual selection inline using an LLM-generated replacement.
function M.infill()
  local sel, err = selection.get_visual_selection()
  if not sel then
    vim.notify("sage-llm: " .. (err or "No selection"), vim.log.levels.WARN)
    return
  end

  ui.input.open({
    prompt = config.options.input.infill_prompt or "Describe the edit:",
    search_enabled = request_opts.search,
    on_toggle_search = function()
      return toggle_search()
    end,
    on_submit = function(instruction)
      execute_infill(sel, instruction)
    end,
    on_cancel = function()
      -- User cancelled, do nothing
    end,
  })
end

---Ask a follow-up question about the current conversation
---Opens the input window for the user to type a follow-up
function M.followup()
  if not conversation.is_active() then
    vim.notify("sage-llm: No active conversation", vim.log.levels.WARN)
    return
  end

  if not ui.response.is_open() then
    vim.notify("sage-llm: Response window is hidden (use :SageView)", vim.log.levels.WARN)
    return
  end

  if ui.response.is_streaming() then
    vim.notify("sage-llm: Wait for response to complete", vim.log.levels.WARN)
    return
  end

  -- Position the input window directly below the response window
  local position = nil
  local geo = ui.response.get_geometry()
  if geo then
    -- +2 accounts for the response window's top and bottom border lines
    local input_height = config.options.input.height
    local below_row = geo.row + geo.height + 2
    -- Clamp so the input window doesn't go off-screen
    local editor_height = vim.o.lines
    if below_row + input_height + 2 > editor_height then
      below_row = geo.row - input_height - 2
    end
    position = {
      row = below_row,
      col = geo.col,
      width = geo.width,
    }
  end

  ui.input.open({
    prompt = config.options.input.followup_prompt or "Follow-up question:",
    position = position,
    search_enabled = request_opts.search,
    on_toggle_search = function()
      return toggle_search()
    end,
    on_submit = function(question)
      execute_followup(question)
    end,
    on_cancel = function()
      -- User cancelled, do nothing
    end,
  })
end

---Show the most recent conversation window if it was hidden
function M.show_conversation()
  if not conversation.is_active() then
    vim.notify("sage-llm: No active conversation", vim.log.levels.WARN)
    return
  end

  if ui.response.is_open() then
    return
  end

  local shown = ui.response.show()
  if not shown then
    vim.notify("sage-llm: No previous response to reopen", vim.log.levels.WARN)
  end
end

---Open model selector
function M.select_model()
  models.select()
end

---Open model removal picker
function M.remove_model()
  models.remove()
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
