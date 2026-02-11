local config = require("sage-llm.config")

local M = {}

---@class SageResponseState
---@field bufnr number|nil Buffer number
---@field winid number|nil Window ID
---@field request_handle table|nil Handle to cancel in-flight request
---@field is_streaming boolean Whether currently streaming
---@field content_start_line number Line where response content starts (after code header)

---@type SageResponseState
local state = {
  bufnr = nil,
  winid = nil,
  request_handle = nil,
  is_streaming = false,
  content_start_line = 0,
}

-- Spinner frames for loading indicator
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 1
local spinner_timer = nil

---Stop the loading spinner
local function stop_spinner()
  if spinner_timer then
    vim.fn.timer_stop(spinner_timer)
    spinner_timer = nil
  end
end

---Close the response window
local function close_window()
  stop_spinner()

  -- Cancel any in-flight request
  if state.request_handle and state.request_handle.cancel then
    state.request_handle.cancel()
  end

  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end

  state.winid = nil
  state.bufnr = nil
  state.request_handle = nil
  state.is_streaming = false
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
local function setup_keymaps(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Close window
  vim.keymap.set("n", "q", close_window, opts)
  vim.keymap.set("n", "<Esc>", close_window, opts)

  -- Yank response
  vim.keymap.set("n", "y", yank_response, opts)

  -- Cancel streaming
  vim.keymap.set("n", "<C-c>", function()
    if state.is_streaming then
      cancel_stream()
    else
      close_window()
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
  -- Close existing window if open
  close_window()

  local ui_config = config.options.response

  -- Calculate window dimensions
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local width = math.floor(editor_width * ui_config.width)
  local height = math.floor(editor_height * ui_config.height)

  -- Position: centered vertically, right side of screen
  local row = math.floor((editor_height - height) / 2)
  local col = editor_width - width - 2 -- 2 for border/padding

  -- Create buffer
  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[state.bufnr].buftype = "nofile"
  vim.bo[state.bufnr].bufhidden = "wipe"
  vim.bo[state.bufnr].modifiable = true
  vim.bo[state.bufnr].filetype = "markdown"

  -- Create window
  state.winid = vim.api.nvim_open_win(state.bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = ui_config.border,
    title = " sage-llm ",
    title_pos = "center",
    footer = " q close | y yank ",
    footer_pos = "center",
  })

  -- Set window options
  vim.wo[state.winid].wrap = true
  vim.wo[state.winid].linebreak = true
  vim.wo[state.winid].cursorline = false
  vim.wo[state.winid].conceallevel = 2

  -- Set up keymaps
  setup_keymaps(state.bufnr)

  -- Add code header
  local header_lines = vim.split(code_header, "\n")
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, header_lines)

  -- Track where response content starts
  state.content_start_line = #header_lines

  return true
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
end

---Append a token to the response
---@param token string
function M.append_token(token)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  -- Get current content
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1]
    or ""

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
end

---Set the complete response text at once (non-streaming)
---@param text string The complete response text
function M.set_response(text)
  vim.notify(
    "DEBUG response.lua: set_response called, text length=" .. tostring(text and #text or "nil"),
    vim.log.levels.INFO
  )

  stop_spinner()
  state.is_streaming = false

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.notify("DEBUG response.lua: buffer invalid, returning early", vim.log.levels.INFO)
    return
  end

  -- Remove loading line if present
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(state.bufnr, line_count - 1, line_count, false)[1]
    or ""

  if last_line:match("Thinking") then
    vim.api.nvim_buf_set_lines(state.bufnr, line_count - 1, line_count, false, {})
  end

  -- Add the complete response
  local response_lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, response_lines)

  -- Scroll to top of response
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_set_cursor(state.winid, { state.content_start_line + 1, 0 })
  end
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
end

---Set the request handle for cancellation
---@param handle table|nil
function M.set_request_handle(handle)
  state.request_handle = handle
end

---Check if response window is currently open
---@return boolean
function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

---Close the response window (public API)
function M.close()
  close_window()
end

return M
