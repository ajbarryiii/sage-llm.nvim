---@class SageSelection
---@field text string Selected text
---@field bufnr number Buffer number
---@field start_line number Start line (1-indexed)
---@field end_line number End line (1-indexed)
---@field start_col number Start column (0-indexed)
---@field end_col number End column (0-indexed)
---@field mode string Visual mode (`v`, `V`, or CTRL-V)
---@field filetype string Buffer filetype
---@field filepath string Relative file path

local M = {}

---Get the current visual selection
---@return SageSelection|nil selection, string|nil error
function M.get_visual_selection()
  local bufnr = vim.api.nvim_get_current_buf()

  -- Get visual selection marks
  -- Note: These are set when leaving visual mode
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_line = start_pos[2]
  local start_col = start_pos[3] - 1 -- Convert to 0-indexed
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  -- Validate selection exists
  if start_line == 0 or end_line == 0 then
    return nil, "No visual selection found"
  end

  -- Get the selected lines
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  if #lines == 0 then
    return nil, "Selection is empty"
  end

  -- Handle character-wise selection
  local mode = vim.fn.visualmode()
  if mode == "v" then
    -- Character-wise: trim first and last lines
    if #lines == 1 then
      -- Single line selection
      lines[1] = string.sub(lines[1], start_col + 1, end_col)
    else
      -- Multi-line: trim start of first line, end of last line
      lines[1] = string.sub(lines[1], start_col + 1)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
  end
  -- For line-wise (V) and block-wise (<C-v>), keep full lines

  local text = table.concat(lines, "\n")

  if text == "" then
    return nil, "Selection is empty"
  end

  -- Get file info
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype

  -- Make filepath relative to cwd
  local cwd = vim.fn.getcwd()
  if filepath:sub(1, #cwd) == cwd then
    filepath = filepath:sub(#cwd + 2) -- +2 to skip the trailing slash
  end

  ---@type SageSelection
  return {
    text = text,
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
    start_col = start_col,
    end_col = end_col,
    mode = mode,
    filetype = filetype ~= "" and filetype or "text",
    filepath = filepath ~= "" and filepath or "[buffer]",
  },
    nil
end

return M
