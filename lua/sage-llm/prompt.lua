local config = require("sage-llm.config")
local diagnostics = require("sage-llm.diagnostics")
local context = require("sage-llm.context")

local M = {}

---@class SagePromptBuildOpts
---@field rag_snippets SageRagSearchResult[]|nil

---@param snippets SageRagSearchResult[]|nil
---@return string
local function format_rag_context(snippets)
  if not snippets or #snippets == 0 then
    return ""
  end

  local lines = { "Repository Context (semantic search):" }

  for _, snippet in ipairs(snippets) do
    local location = string.format("%s:%d-%d", snippet.path, snippet.start_line, snippet.end_line)
    lines[#lines + 1] = "- " .. location
    lines[#lines + 1] = "```"
    lines[#lines + 1] = snippet.text
    lines[#lines + 1] = "```"
  end

  return table.concat(lines, "\n")
end

---Build the user message content from selection and context
---@param selection SageSelection
---@param question string User's question
---@param opts SagePromptBuildOpts|nil
---@return string
function M.build_user_message(selection, question, opts)
  local parts = {}

  -- File info
  table.insert(parts, string.format("File: %s (%s)", selection.filepath, selection.filetype))

  -- Dependencies (if enabled)
  if config.options.detect_dependencies then
    local deps = context.detect_dependencies(selection.bufnr)
    local deps_str = context.format_for_prompt(deps)
    if deps_str ~= "" then
      table.insert(parts, deps_str)
    end
  end

  -- Empty line before code
  table.insert(parts, "")

  -- Selected code in fenced code block
  table.insert(parts, string.format("```%s", selection.filetype))
  table.insert(parts, selection.text)
  table.insert(parts, "```")

  -- Diagnostics
  local diags = diagnostics.get_in_range(selection.bufnr, selection.start_line, selection.end_line)
  local diags_str = diagnostics.format_for_prompt(diags)
  if diags_str ~= "" then
    table.insert(parts, "")
    table.insert(parts, diags_str)
  end

  local rag_context = format_rag_context(opts and opts.rag_snippets or nil)
  if rag_context ~= "" then
    table.insert(parts, "")
    table.insert(parts, rag_context)
  end

  -- Question
  table.insert(parts, "")
  table.insert(parts, "Question: " .. question)

  return table.concat(parts, "\n")
end

---Build the complete messages array for the API
---@param selection SageSelection
---@param question string
---@param opts SagePromptBuildOpts|nil
---@return table[] messages Array of {role, content} tables
function M.build_messages(selection, question, opts)
  return {
    {
      role = "system",
      content = config.options.system_prompt,
    },
    {
      role = "user",
      content = M.build_user_message(selection, question, opts),
    },
  }
end

---Format selected code for display in response window
---@param selection SageSelection
---@return string
function M.format_code_header(selection)
  local lines_copied = selection.end_line - selection.start_line + 1
  local line_label = "lines"
  if lines_copied == 1 then
    line_label = "line"
  end

  local lines = {}
  table.insert(lines, string.format("[%d %s copied]", lines_copied, line_label))
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

---Build the complete messages array for a simple query (no code selection)
---@param question string
---@param opts SagePromptBuildOpts|nil
---@return table[] messages Array of {role, content} tables
function M.build_messages_no_selection(question, opts)
  local user_content = question

  local rag_context = format_rag_context(opts and opts.rag_snippets or nil)
  if rag_context ~= "" then
    user_content = table.concat({ rag_context, "", "Question: " .. question }, "\n")
  end

  return {
    {
      role = "system",
      content = config.options.system_prompt_no_selection,
    },
    {
      role = "user",
      content = user_content,
    },
  }
end

---Build the user message for an inline infill request.
---@param selection SageSelection
---@param instruction string
---@return string
function M.build_infill_user_message(selection, instruction)
  local parts = {}

  table.insert(parts, string.format("File: %s (%s)", selection.filepath, selection.filetype))

  if config.options.detect_dependencies then
    local deps = context.detect_dependencies(selection.bufnr)
    local deps_str = context.format_for_prompt(deps)
    if deps_str ~= "" then
      table.insert(parts, deps_str)
    end
  end

  table.insert(parts, "")
  table.insert(parts, "Selected code:")
  table.insert(parts, string.format("```%s", selection.filetype))
  table.insert(parts, selection.text)
  table.insert(parts, "```")

  local diags = diagnostics.get_in_range(selection.bufnr, selection.start_line, selection.end_line)
  local diags_str = diagnostics.format_for_prompt(diags)
  if diags_str ~= "" then
    table.insert(parts, "")
    table.insert(parts, diags_str)
  end

  table.insert(parts, "")
  table.insert(parts, "Instruction: " .. instruction)
  table.insert(parts, "")
  table.insert(parts, "Return only the replacement text for the selected code.")

  return table.concat(parts, "\n")
end

---Build the complete messages array for inline infill.
---@param selection SageSelection
---@param instruction string
---@return table[] messages
function M.build_infill_messages(selection, instruction)
  return {
    {
      role = "system",
      content = config.options.system_prompt_infill,
    },
    {
      role = "user",
      content = M.build_infill_user_message(selection, instruction),
    },
  }
end

---Format infill preview for display in the response window.
---@param instruction string
---@param replacement string
---@param filetype string
---@return string
function M.format_infill_preview(instruction, replacement, filetype)
  local lines = {}
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "**Inline Edit Instruction:** " .. instruction)
  table.insert(lines, "")
  table.insert(lines, "**Proposed Replacement** (`a` apply, `r` reject):")
  table.insert(lines, string.format("```%s", filetype))
  table.insert(lines, replacement)
  table.insert(lines, "```")
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

---Format question for display in response window header
---@param question string
---@return string
function M.format_question_header(question)
  local lines = {}
  table.insert(lines, "> " .. question)
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

---Format follow-up question header for display in the response window
---Shows a separator and the follow-up question
---@param question string
---@return string
function M.format_followup_header(question)
  local lines = {}
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "**Follow-up:** " .. question)
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

return M
