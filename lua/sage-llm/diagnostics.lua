---@class SageDiagnostic
---@field line number Line number (1-indexed, relative to selection start)
---@field severity string Severity level (error, warning, info, hint)
---@field code string|nil Error code (e.g., E0382 for Rust)
---@field message string Diagnostic message
---@field source string|nil Source of diagnostic (e.g., rustc, lua_ls)

local M = {}

---Severity level names
local severity_names = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warning",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

---Get diagnostics within a line range
---@param bufnr number Buffer number
---@param start_line number Start line (1-indexed)
---@param end_line number End line (1-indexed)
---@return SageDiagnostic[]
function M.get_in_range(bufnr, start_line, end_line)
  local diagnostics = vim.diagnostic.get(bufnr)
  local result = {}

  for _, diag in ipairs(diagnostics) do
    -- vim.diagnostic uses 0-indexed lines
    local diag_line = diag.lnum + 1

    if diag_line >= start_line and diag_line <= end_line then
      ---@type SageDiagnostic
      local formatted = {
        line = diag_line,
        severity = severity_names[diag.severity] or "unknown",
        code = diag.code and tostring(diag.code) or nil,
        message = diag.message,
        source = diag.source,
      }
      table.insert(result, formatted)
    end
  end

  -- Sort by line number, then severity (errors first)
  table.sort(result, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    -- Sort by severity (error < warning < info < hint)
    local severity_order = { error = 1, warning = 2, info = 3, hint = 4 }
    return (severity_order[a.severity] or 5) < (severity_order[b.severity] or 5)
  end)

  return result
end

---Format diagnostics for inclusion in prompt
---@param diagnostics SageDiagnostic[]
---@return string
function M.format_for_prompt(diagnostics)
  if #diagnostics == 0 then
    return ""
  end

  local lines = { "Diagnostics:" }

  for _, diag in ipairs(diagnostics) do
    local parts = { "- Line " .. diag.line }

    -- Build severity + code part
    local severity_part = "[" .. diag.severity
    if diag.code then
      severity_part = severity_part .. " " .. diag.code
    end
    severity_part = severity_part .. "]"
    table.insert(parts, severity_part .. ":")

    -- Message
    table.insert(parts, diag.message)

    -- Source
    if diag.source then
      table.insert(parts, "(" .. diag.source .. ")")
    end

    table.insert(lines, table.concat(parts, " "))
  end

  return table.concat(lines, "\n")
end

return M
