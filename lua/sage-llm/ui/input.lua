local config = require("sage-llm.config")

local M = {}

---@class SageInputState
---@field bufnr number|nil Buffer number
---@field winid number|nil Window ID
---@field on_submit function|nil Callback for submit
---@field on_cancel function|nil Callback for cancel
---@field on_toggle_search fun(): boolean|nil Callback to toggle web search
---@field search_enabled boolean Whether web search is enabled for next query
---@field on_toggle_rag fun(enabled: boolean)|nil Callback for RAG toggle
---@field rag_enabled boolean Whether RAG is enabled for this ask
---@field prompt_text string|nil Prompt text shown in title

---@type SageInputState
local state = {
  bufnr = nil,
  winid = nil,
  on_submit = nil,
  on_cancel = nil,
  on_toggle_search = nil,
  search_enabled = false,
  on_toggle_rag = nil,
  rag_enabled = false,
  prompt_text = nil,
}

---@return string
local function build_title()
  local prompt = state.prompt_text or "Ask"
  if not state.on_toggle_rag then
    return " " .. prompt .. " "
  end

  local rag_text = state.rag_enabled and "on" or "off"
  return string.format(" %s [RAG: %s] ", prompt, rag_text)
end

---@return string
local function build_footer()
  local parts = { "<CR> submit", "<S-CR> newline" }

  if state.on_toggle_search then
    local search_text = state.search_enabled and "on" or "off"
    parts[#parts + 1] = "S search:" .. search_text
  end

  if state.on_toggle_rag then
    local rag_text = state.rag_enabled and "on" or "off"
    parts[#parts + 1] = "r RAG:" .. rag_text
  end

  parts[#parts + 1] = "q cancel"
  return " " .. table.concat(parts, " | ") .. " "
end

local function refresh_window_chrome()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end

  local win_config = vim.api.nvim_win_get_config(state.winid)
  win_config.title = build_title()
  win_config.title_pos = "center"
  win_config.footer = build_footer()
  win_config.footer_pos = "center"
  pcall(vim.api.nvim_win_set_config, state.winid, win_config)
end

---Close the input window
local function close_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end

  state.winid = nil
  state.bufnr = nil
  state.on_submit = nil
  state.on_cancel = nil
  state.on_toggle_search = nil
  state.search_enabled = false
  state.on_toggle_rag = nil
  state.rag_enabled = false
  state.prompt_text = nil
end

---Get the text from the input buffer
---@return string
local function get_input_text()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
  return table.concat(lines, "\n")
end

---Handle submit action
local function handle_submit()
  local text = get_input_text()
  local callback = state.on_submit
  local cancel_callback = state.on_cancel
  close_window()
  if callback and text ~= "" then
    callback(text)
  elseif cancel_callback then
    cancel_callback()
  end
end

---Handle cancel action
local function handle_cancel()
  local callback = state.on_cancel
  close_window()
  if callback then
    callback()
  end
end

local function handle_toggle_search()
  local enabled = nil
  if state.on_toggle_search then
    enabled = state.on_toggle_search()
  end

  if type(enabled) == "boolean" then
    state.search_enabled = enabled
  else
    state.search_enabled = not state.search_enabled
  end

  refresh_window_chrome()
end

local function handle_toggle_rag()
  if not state.on_toggle_rag then
    return
  end

  state.rag_enabled = not state.rag_enabled
  state.on_toggle_rag(state.rag_enabled)
  refresh_window_chrome()
end

---Set up buffer keymaps
---@param bufnr number
local function setup_keymaps(bufnr)
  local opts = { buffer = bufnr, noremap = true, silent = true }

  -- Submit: <CR> in insert mode
  vim.keymap.set("i", "<CR>", function()
    handle_submit()
  end, opts)

  -- Newline: <S-CR> in insert mode
  vim.keymap.set("i", "<S-CR>", function()
    -- Insert actual newline
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local before = line:sub(1, col)
    local after = line:sub(col + 1)
    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { before, after })
    vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
  end, opts)

  -- Cancel: q in normal mode, <Esc> in normal mode
  vim.keymap.set("n", "q", handle_cancel, opts)
  vim.keymap.set("n", "<Esc>", handle_cancel, opts)

  if state.on_toggle_search then
    vim.keymap.set("n", "S", handle_toggle_search, opts)
  end

  if state.on_toggle_rag then
    vim.keymap.set("n", "r", handle_toggle_rag, opts)
  end

  -- Also allow <C-c> to cancel in any mode
  vim.keymap.set({ "n", "i" }, "<C-c>", handle_cancel, opts)
end

---@class SageInputOpts
---@field on_submit function
---@field on_cancel function|nil
---@field prompt string|nil
---@field position {row: number, col: number, width: number}|nil
---@field on_toggle_search fun(): boolean|nil
---@field search_enabled boolean|nil
---@field rag_enabled boolean|nil
---@field on_toggle_rag fun(enabled: boolean)|nil

---Open the input window
---@param opts SageInputOpts
function M.open(opts)
  -- Close existing window if open
  close_window()

  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_toggle_search = opts.on_toggle_search
  state.search_enabled = opts.search_enabled == true
  state.on_toggle_rag = opts.on_toggle_rag

  local ui_config = config.options.input
  local prompt_text = opts.prompt or ui_config.prompt
  state.prompt_text = prompt_text
  state.rag_enabled = opts.rag_enabled == true

  -- Calculate window dimensions
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local width = math.floor(editor_width * ui_config.width)
  local height = ui_config.height

  local row, col
  if opts.position then
    -- Position relative to a parent window (e.g., below the response window)
    row = opts.position.row
    col = opts.position.col
    width = opts.position.width
  else
    -- Default: center the window
    row = math.floor((editor_height - height) / 2)
    col = math.floor((editor_width - width) / 2)
  end

  -- Create buffer
  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[state.bufnr].buftype = "nofile"
  vim.bo[state.bufnr].bufhidden = "wipe"
  vim.bo[state.bufnr].filetype = "sage-input"

  -- Create window
  state.winid = vim.api.nvim_open_win(state.bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = ui_config.border,
    title = build_title(),
    title_pos = "center",
    footer = build_footer(),
    footer_pos = "center",
  })

  -- Set window options
  vim.wo[state.winid].wrap = true
  vim.wo[state.winid].linebreak = true
  vim.wo[state.winid].cursorline = false

  -- Set up keymaps
  setup_keymaps(state.bufnr)

  -- Start in insert mode
  vim.cmd("startinsert")

  -- Close on WinLeave
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = state.bufnr,
    once = true,
    callback = function()
      -- Only cancel if we're actually leaving (not submitting)
      if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        handle_cancel()
      end
    end,
  })
end

---Check if input window is currently open
---@return boolean
function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

---Close the input window (public API)
function M.close()
  close_window()
end

return M
