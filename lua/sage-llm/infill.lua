local M = {}

---@param text string
---@return string
local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Normalize model output into replacement text.
---Accepts raw text or a fenced code block and returns the replacement body.
---@param raw string
---@return string|nil replacement, string|nil error
function M.normalize_response(raw)
  if type(raw) ~= "string" then
    return nil, "Invalid response type"
  end

  local text = trim(raw)
  if text == "" then
    return nil, "Model returned empty response"
  end

  -- Exact fenced response.
  local exact_block = text:match("^```[^\n`]*\n(.-)\n```$")
  if exact_block then
    text = exact_block
  else
    -- Best-effort extraction when model adds extra prose around a fenced block.
    local any_block = text:match("```[^\n`]*\n(.-)\n```")
    if any_block then
      text = any_block
    end
  end

  if text == "" then
    return nil, "Model returned empty replacement"
  end

  return text, nil
end

---Apply replacement text to a visual selection.
---@param selection SageSelection
---@param replacement string
---@return boolean ok, string|nil error
function M.apply_selection(selection, replacement)
  local bufnr = selection.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "Selection buffer is no longer valid"
  end

  if vim.bo[bufnr].modifiable == false or vim.bo[bufnr].readonly == true then
    return false, "Buffer is not modifiable"
  end

  local replacement_lines = vim.split(replacement, "\n", { plain = true })
  local ok, err

  if selection.mode == "v" then
    ok, err = pcall(vim.api.nvim_buf_set_text, bufnr, selection.start_line - 1, selection.start_col, selection.end_line - 1, selection.end_col, replacement_lines)
  else
    ok, err = pcall(
      vim.api.nvim_buf_set_lines,
      bufnr,
      selection.start_line - 1,
      selection.end_line,
      false,
      replacement_lines
    )
  end

  if not ok then
    return false, tostring(err)
  end

  return true, nil
end

return M
