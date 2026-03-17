local config = require("sage-llm.config")
local rag_index = require("sage-llm.rag.index")
local retriever = require("sage-llm.rag.retriever")

local M = {}

---@param question string
---@param selection SageSelection|nil
---@return string
local function build_retrieval_query(question, selection)
  if not selection or not selection.text or selection.text == "" then
    return question
  end

  local selection_text = selection.text
  local max_selection_chars = 1200
  if #selection_text > max_selection_chars then
    selection_text = selection_text:sub(1, max_selection_chars)
  end

  return table.concat({ question, "", "Selected code:", selection_text }, "\n")
end

---@param opts {question: string, bufnr: number|nil, selection: SageSelection|nil}
---@param on_complete fun(results: SageRagSearchResult[]|nil, err: string|nil)
---@return SageRequestHandle
function M.retrieve_context(opts, on_complete)
  local rag_opts = config.options.rag

  if not rag_opts or not rag_opts.enabled then
    on_complete({}, nil)
    return {
      cancel = function() end,
    }
  end

  local cancelled = false
  local active_handle = nil

  active_handle = rag_index.ensure_index(opts.bufnr, rag_opts, function(index, index_err)
    if cancelled then
      return
    end

    if index_err then
      on_complete(nil, index_err)
      return
    end

    local query = build_retrieval_query(opts.question, opts.selection)
    active_handle = retriever.search(index, query, rag_opts, function(results, search_err)
      if cancelled then
        return
      end
      on_complete(results, search_err)
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      if active_handle and active_handle.cancel then
        active_handle.cancel()
      end
    end,
  }
end

return M
