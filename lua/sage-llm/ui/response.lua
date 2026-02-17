local config = require("sage-llm.config")
local conversation = require("sage-llm.conversation")

local M = {}

---@class SageResponseState
---@field bufnr number|nil Buffer number
---@field winid number|nil Window ID
---@field request_handle table|nil Handle to cancel in-flight request
---@field is_streaming boolean Whether currently streaming
---@field content_start_line number Line where response content starts (after code header)
---@field on_followup function|nil Callback invoked when user presses 'f' to follow up
---@field on_toggle_search fun(): boolean|nil Callback invoked when user presses 'S'
---@field search_enabled boolean Whether web search is enabled for next query
---@field on_accept_edit function|nil Callback invoked when user presses 'a'
---@field on_reject_edit function|nil Callback invoked when user presses 'r'
---@field edit_pending boolean Whether an inline edit is waiting for accept/reject
---@field awaiting_response_text boolean Whether next token should be separated

---@type SageResponseState
local state = {
  bufnr = nil,
  winid = nil,
  request_handle = nil,
  is_streaming = false,
  content_start_line = 0,
  on_followup = nil,
  on_toggle_search = nil,
  search_enabled = false,
  on_accept_edit = nil,
  on_reject_edit = nil,
  edit_pending = false,
  awaiting_response_text = false,
}

-- Spinner frames for loading indicator
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 1
local spinner_timer = nil
local setup_keymaps

local function is_blank_line(line)
  return (line or ""):match("^%s*$") ~= nil
end

---@return string
local function footer_text()
  local search_state = state.search_enabled and "on" or "off"
  if state.edit_pending then
    return " A accept+close | a apply | r reject | q hide | y yank | S search:" .. search_state .. " "
  end
  return " q hide | y yank | f follow-up | S search:" .. search_state .. " "
end

local function refresh_footer()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end

  local win_config = vim.api.nvim_win_get_config(state.winid)
  win_config.footer = footer_text()
  win_config.footer_pos = "center"
  pcall(vim.api.nvim_win_set_config, state.winid, win_config)
end

---Stop the loading spinner
local function stop_spinner()
  if spinner_timer then
    vim.fn.timer_stop(spinner_timer)
    spinner_timer = nil
  end
end

---Create or recreate the response window for an existing buffer
---@param bufnr number
---@return number|nil winid
local function open_window(bufnr)
  local ui_config = config.options.response

  -- Calculate window dimensions
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local width = math.floor(editor_width * ui_config.width)
  local height = math.floor(editor_height * ui_config.height)

  -- Position: centered vertically, right side of screen
  local row = math.floor((editor_height - height) / 2)
  local col = editor_width - width - 2 -- 2 for border/padding

  -- Get just the model name (after the slash)
  local model_name = config.options.model:match("[^/]+$") or config.options.model

  -- Create window
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = ui_config.border,
    title = " sage-llm (" .. model_name .. ") ",
    title_pos = "center",
    footer = footer_text(),
    footer_pos = "center",
  })

  -- Set window options
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].cursorline = false
  vim.wo[winid].conceallevel = 2

  -- Set up keymaps
  setup_keymaps(bufnr)

  return winid
end

---Hide the response window, preserving buffer and conversation state
local function hide_window()
  stop_spinner()

  -- Cancel any in-flight request
  if state.request_handle and state.request_handle.cancel then
    state.request_handle.cancel()
  end

  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end

  state.winid = nil
  state.request_handle = nil
  state.is_streaming = false
end

---Clear all response UI state and reset conversation history
local function clear_state()
  hide_window()

  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end

  conversation.reset()

  state.bufnr = nil
  state.on_followup = nil
  state.on_toggle_search = nil
  state.search_enabled = false
  state.on_accept_edit = nil
  state.on_reject_edit = nil
  state.edit_pending = false
  state.content_start_line = 0
  state.awaiting_response_text = false
end

---Get full response text (excluding code header)
---@return string
local function get_response_text()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(state.bufnr, state.content_start_line, -1, false)
  return table.concat(lines, "\n")
end

---Yank response to clipboard
local function yank_response()
  local text = get_response_text()
  if text ~= "" then
    vim.fn.setreg("+", text)
    vim.fn.setreg('"', text)
    vim.notify("Response copied to clipboard", vim.log.levels.INFO)
  end
end

---Cancel the current streaming request
local function cancel_stream()
  if state.request_handle and state.request_handle.cancel then
    state.request_handle.cancel()
    state.request_handle = nil
  end
  stop_spinner()
  state.is_streaming = false

  -- Add cancelled indicator
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, { "", "[Cancelled]" })
  end
end

---Set up buffer keymaps
---@param bufnr number
setup_keymaps = function(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Close window
  vim.keymap.set("n", "q", hide_window, opts)
  vim.keymap.set("n", "<Esc>", hide_window, opts)

  -- Yank response
  vim.keymap.set("n", "y", yank_response, opts)

  -- Follow-up question
  vim.keymap.set("n", "f", function()
    if state.is_streaming then
      vim.notify("sage-llm: Wait for response to complete", vim.log.levels.WARN)
      return
    end
    if state.on_followup then
      state.on_followup()
    end
  end, opts)

  -- Accept inline edit
  vim.keymap.set("n", "a", function()
    if not state.edit_pending then
      return
    end
    if state.on_accept_edit then
      state.on_accept_edit(false)
    end
  end, opts)

  -- Accept inline edit and hide response window
  vim.keymap.set("n", "A", function()
    if not state.edit_pending then
      return
    end
    if state.on_accept_edit then
      state.on_accept_edit(true)
    end
  end, opts)

  -- Reject inline edit
  vim.keymap.set("n", "r", function()
    if not state.edit_pending then
      return
    end
    if state.on_reject_edit then
      state.on_reject_edit()
    end
  end, opts)

  -- Toggle web search for next query
  vim.keymap.set("n", "S", function()
    local enabled = nil
    if state.on_toggle_search then
      enabled = state.on_toggle_search()
    end

    if type(enabled) == "boolean" then
      state.search_enabled = enabled
    else
      state.search_enabled = not state.search_enabled
    end

    refresh_footer()
  end, opts)

  -- Cancel streaming
  vim.keymap.set("n", "<C-c>", function()
    if state.is_streaming then
      cancel_stream()
    else
      hide_window()
    end
  end, opts)
end

---Update spinner animation
local function update_spinner()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    stop_spinner()
    return
  end

  if not state.is_streaming then
    stop_spinner()
    return
  end

  spinner_index = (spinner_index % #spinner_frames) + 1
  local spinner = spinner_frames[spinner_index]

  -- Update the loading line
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1]
    or ""

  -- Only update if we're still on the loading line
  if last_line:match("^" .. spinner_frames[1]) or last_line:match("Thinking") then
    vim.api.nvim_buf_set_lines(
      state.bufnr,
      line_count - 1,
      line_count,
      false,
      { spinner .. " Thinking..." }
    )
  end
end

---Start the loading spinner
local function start_spinner()
  spinner_index = 1
  stop_spinner() -- Ensure no existing timer

  spinner_timer = vim.fn.timer_start(80, function()
    vim.schedule(update_spinner)
  end, { ["repeat"] = -1 })
end

---Open the response window
---@param code_header string The formatted code to show at top
---@return boolean success
function M.open(code_header)
  -- Clear any previous response window and buffer before opening a fresh one
  clear_state()

  -- Create buffer
  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[state.bufnr].buftype = "nofile"
  vim.bo[state.bufnr].bufhidden = "hide"
  vim.bo[state.bufnr].modifiable = true
  vim.bo[state.bufnr].filetype = "markdown"

  state.winid = open_window(state.bufnr)

  -- Add code header
  local header_lines = vim.split(code_header, "\n")
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, header_lines)

  -- Track where response content starts
  state.content_start_line = #header_lines
  state.awaiting_response_text = true

  return true
end

---Show the most recent response window if hidden
---@return boolean success
function M.show()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    return true
  end

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = nil
    return false
  end

  state.winid = open_window(state.bufnr)
  return state.winid ~= nil
end

---Show loading indicator
function M.show_loading()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  state.is_streaming = true

  -- Add loading indicator
  vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, { spinner_frames[1] .. " Thinking..." })

  start_spinner()
end

---Clear loading indicator and prepare for streaming
function M.start_streaming()
  stop_spinner()

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  -- Remove loading line
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1]
    or ""

  if last_line:match("Thinking") then
    vim.api.nvim_buf_set_lines(state.bufnr, line_count - 1, line_count, false, {})
  end

  local trimmed_count = vim.api.nvim_buf_line_count(state.bufnr)
  local before_last = vim.api.nvim_buf_get_lines(state.bufnr, trimmed_count - 1, trimmed_count, false)[1] or ""
  if not is_blank_line(before_last) then
    vim.api.nvim_buf_set_lines(state.bufnr, trimmed_count, trimmed_count, false, { "" })
  end
end

---Append a token to the response
---@param token string
function M.append_token(token)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1] or ""

  if state.awaiting_response_text then
    if is_blank_line(last_line) then
      line_count = line_count + 1
    else
      vim.api.nvim_buf_set_lines(state.bufnr, line_count, line_count, false, { "" })
      line_count = line_count + 1
    end
    last_line = ""
    state.awaiting_response_text = false
  end

  -- Handle newlines in token
  local lines = vim.split(token, "\n", { plain = true })

  if #lines == 1 then
    -- Simple append to last line
    vim.api.nvim_buf_set_lines(
      state.bufnr,
      line_count - 1,
      line_count,
      false,
      { last_line .. lines[1] }
    )
  else
    -- First part goes on current line
    local new_lines = { last_line .. lines[1] }
    -- Rest are new lines
    for i = 2, #lines do
      table.insert(new_lines, lines[i])
    end
    vim.api.nvim_buf_set_lines(state.bufnr, line_count - 1, line_count, false, new_lines)
  end

  -- Auto-scroll to bottom if window is valid
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local new_line_count = vim.api.nvim_buf_line_count(state.bufnr)
    vim.api.nvim_win_set_cursor(state.winid, { new_line_count, 0 })
  end
end

---Mark streaming as complete
function M.complete()
  stop_spinner()
  state.is_streaming = false
  state.request_handle = nil

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.cmd("stopinsert")
    return
  end

  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1] or ""
  if not is_blank_line(last_line) then
    vim.api.nvim_buf_set_lines(state.bufnr, line_count, line_count, false, { "" })
  end

  state.awaiting_response_text = false

  -- Switch to normal mode
  vim.cmd("stopinsert")
end

---Show an error message
---@param message string
function M.show_error(message)
  stop_spinner()
  state.is_streaming = false

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.notify("sage-llm: " .. message, vim.log.levels.ERROR)
    return
  end

  -- Remove loading line if present
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1]
    or ""

  if last_line:match("Thinking") then
    vim.api.nvim_buf_set_lines(state.bufnr, line_count - 1, line_count, false, {})
  end

  -- Add error message
  vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, { "", "Error: " .. message })

  -- Switch to normal mode
  vim.cmd("stopinsert")
end

---Set the request handle for cancellation
---@param handle table|nil
function M.set_request_handle(handle)
  state.request_handle = handle
end

---Set the callback for when the user presses 'f' to ask a follow-up
---@param callback function|nil
function M.set_on_followup(callback)
  state.on_followup = callback
end

---Set the callback for when the user presses 'S' to toggle web search
---@param callback fun(): boolean|nil
function M.set_on_toggle_search(callback)
  state.on_toggle_search = callback
end

---Set whether web search is enabled for the next query
---@param enabled boolean
function M.set_search_enabled(enabled)
  state.search_enabled = enabled == true
  refresh_footer()
end

---Register inline edit accept/reject callbacks.
---@param on_accept function|nil
---@param on_reject function|nil
function M.set_edit_actions(on_accept, on_reject)
  state.on_accept_edit = on_accept
  state.on_reject_edit = on_reject
  state.edit_pending = (on_accept ~= nil) or (on_reject ~= nil)
  refresh_footer()
end

---Clear inline edit accept/reject callbacks.
function M.clear_edit_actions()
  state.on_accept_edit = nil
  state.on_reject_edit = nil
  state.edit_pending = false
  refresh_footer()
end

---Hide the response window while preserving buffer state.
function M.hide()
  hide_window()
end

---Append a follow-up question header (separator + question) to the response buffer
---@param header_text string Formatted follow-up header text
function M.append_followup_header(header_text)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local header_lines = vim.split(header_text, "\n")
  vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, header_lines)

  -- Update content_start_line so loading/streaming appends after the new header
  state.content_start_line = vim.api.nvim_buf_line_count(state.bufnr)
  state.awaiting_response_text = true

  -- Auto-scroll to bottom
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    local line_count = vim.api.nvim_buf_line_count(state.bufnr)
    vim.api.nvim_win_set_cursor(state.winid, { line_count, 0 })
  end
end

---Check if response window is currently open
---@return boolean
function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

---Get the response window's position and dimensions (for positioning related windows)
---@return {row: number, col: number, width: number, height: number}|nil
function M.get_geometry()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return nil
  end
  local win_config = vim.api.nvim_win_get_config(state.winid)
  return {
    row = win_config.row,
    col = win_config.col,
    width = win_config.width,
    height = win_config.height,
  }
end

---Check if currently streaming a response
---@return boolean
function M.is_streaming()
  return state.is_streaming
end

return M
