local config = require("sage-llm.config")

local M = {}

---@class SageInputState
---@field bufnr number|nil Buffer number
---@field winid number|nil Window ID
---@field on_submit function|nil Callback for submit
---@field on_cancel function|nil Callback for cancel
---@field on_toggle_search fun(): boolean|nil Callback to toggle web search
---@field search_enabled boolean Whether web search is enabled for next query

---@type SageInputState
local state = {
  bufnr = nil,
  winid = nil,
  on_submit = nil,
  on_cancel = nil,
  on_toggle_search = nil,
  search_enabled = false,
}

---@return string
local function footer_text()
  local search_state = state.search_enabled and "on" or "off"
  return " <CR> submit | <S-CR> newline | S search:" .. search_state .. " | q cancel "
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
  state.on_toggle_search = nil
  state.search_enabled = false
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
  close_window()
  if callback and text ~= "" then
    callback(text)
  elseif state.on_cancel then
    state.on_cancel()
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

  -- Also allow <C-c> to cancel in any mode
  vim.keymap.set({ "n", "i" }, "<C-c>", handle_cancel, opts)
end

---Open the input window
---@param opts {on_submit: function, on_cancel: function|nil, prompt: string|nil, position: {row: number, col: number, width: number}|nil, on_toggle_search: fun(): boolean|nil, search_enabled: boolean|nil}
function M.open(opts)
  -- Close existing window if open
  close_window()

  state.on_submit = opts.on_submit
  state.on_cancel = opts.on_cancel
  state.on_toggle_search = opts.on_toggle_search
  state.search_enabled = opts.search_enabled == true

  local ui_config = config.options.input
  local prompt_text = opts.prompt or ui_config.prompt

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
    title = " " .. prompt_text .. " ",
    title_pos = "center",
    footer = footer_text(),
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

return M
