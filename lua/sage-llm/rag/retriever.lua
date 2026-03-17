local api = require("sage-llm.api")
local rag_index = require("sage-llm.rag.index")

local M = {}

---@class SageRagSearchResult
---@field id string
---@field path string
---@field start_line number
---@field end_line number
---@field text string
---@field score number

---@param a number[]
---@param b number[]
---@return number
local function cosine_similarity(a, b)
  local dot = 0
  local norm_a = 0
  local norm_b = 0
  local len = math.min(#a, #b)

  for i = 1, len do
    local av = tonumber(a[i]) or 0
    local bv = tonumber(b[i]) or 0
    dot = dot + (av * bv)
    norm_a = norm_a + (av * av)
    norm_b = norm_b + (bv * bv)
  end

  if norm_a == 0 or norm_b == 0 then
    return 0
  end

  return dot / (math.sqrt(norm_a) * math.sqrt(norm_b))
end

---@param chunks SageRagChunk[]
---@param query_embedding number[]
---@return SageRagSearchResult[]
function M.rank_chunks(chunks, query_embedding)
  local ranked = {}

  for _, chunk in ipairs(chunks) do
    local score = cosine_similarity(query_embedding, chunk.embedding)
    ranked[#ranked + 1] = {
      id = chunk.id,
      path = chunk.path,
      start_line = chunk.start_line,
      end_line = chunk.end_line,
      text = chunk.text,
      score = score,
    }
  end

  table.sort(ranked, function(a, b)
    return a.score > b.score
  end)

  return ranked
end

---@param ranked SageRagSearchResult[]
---@param rag_opts SageRagConfig
---@return SageRagSearchResult[]
function M.select_snippets(ranked, rag_opts)
  local selected = {}
  local per_file = {}
  local used_chars = 0

  local top_k = math.max(1, rag_opts.top_k)
  local min_similarity = rag_opts.min_similarity
  local max_chunks_per_file = math.max(1, rag_opts.max_chunks_per_file)
  local max_context_chars = math.max(1, rag_opts.max_context_chars)

  for _, candidate in ipairs(ranked) do
    if candidate.score < min_similarity then
      break
    end

    local file_count = per_file[candidate.path] or 0
    if file_count < max_chunks_per_file then
      local snippet_text = candidate.text
      local remaining = max_context_chars - used_chars

      if remaining <= 0 then
        break
      end

      if #snippet_text > remaining then
        if remaining < 160 then
          break
        end
        snippet_text = snippet_text:sub(1, remaining)
      end

      selected[#selected + 1] = {
        id = candidate.id,
        path = candidate.path,
        start_line = candidate.start_line,
        end_line = candidate.end_line,
        text = snippet_text,
        score = candidate.score,
      }

      per_file[candidate.path] = file_count + 1
      used_chars = used_chars + #snippet_text

      if #selected >= top_k or used_chars >= max_context_chars then
        break
      end
    end
  end

  return selected
end

---@param index SageRagIndex
---@param query string
---@param rag_opts SageRagConfig
---@param on_complete fun(results: SageRagSearchResult[]|nil, err: string|nil)
---@return SageRequestHandle
function M.search(index, query, rag_opts, on_complete)
  local chunks = rag_index.collect_chunks(index)
  if #chunks == 0 then
    on_complete({}, nil)
    return {
      cancel = function() end,
    }
  end

  local cancelled = false
  local inflight = nil

  inflight = api.embeddings(query, rag_opts.embedding_model, function(vectors, err)
    if cancelled then
      return
    end

    if err then
      on_complete(nil, err)
      return
    end

    if not vectors or type(vectors[1]) ~= "table" then
      on_complete(nil, "Invalid embeddings response for RAG query")
      return
    end

    local ranked = M.rank_chunks(chunks, vectors[1])
    local selected = M.select_snippets(ranked, rag_opts)
    on_complete(selected, nil)
  end)

  return {
    cancel = function()
      cancelled = true
      if inflight and inflight.cancel then
        inflight.cancel()
      end
    end,
  }
end

return M
