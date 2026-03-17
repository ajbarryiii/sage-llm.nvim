local api = require("sage-llm.api")
local store = require("sage-llm.rag.store")

local M = {}

local uv = vim.uv or vim.loop

---@param patterns string[]|nil
---@return string[]
local function compile_globs(patterns)
  local compiled = {}
  if not patterns then
    return compiled
  end

  for _, pattern in ipairs(patterns) do
    table.insert(compiled, vim.fn.glob2regpat(pattern))

    local root_pattern = pattern:gsub("^%*%*/", "")
    if root_pattern ~= pattern then
      table.insert(compiled, vim.fn.glob2regpat(root_pattern))
    end
  end

  return compiled
end

---@param path string
---@param patterns string[]
---@return boolean
local function matches_any(path, patterns)
  for _, pattern in ipairs(patterns) do
    if vim.fn.match(path, pattern) ~= -1 then
      return true
    end
  end
  return false
end

---@param rel_path string
---@param include_patterns string[]
---@param exclude_patterns string[]
---@return boolean
local function should_index(rel_path, include_patterns, exclude_patterns)
  if #include_patterns > 0 and not matches_any(rel_path, include_patterns) then
    return false
  end

  if #exclude_patterns > 0 and matches_any(rel_path, exclude_patterns) then
    return false
  end

  return true
end

---@param root string
---@return string[]|nil
local function list_git_files(root)
  local files = vim.fn.systemlist({
    "git",
    "-C",
    root,
    "ls-files",
    "--cached",
    "--others",
    "--exclude-standard",
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return files
end

---@param root string
---@param rel string
---@param acc string[]
local function walk_files(root, rel, acc)
  local abs = rel == "" and root or (root .. "/" .. rel)
  local iterator = vim.fs.dir(abs)
  if not iterator then
    return
  end

  for name, entry_type in iterator do
    local child_rel = rel == "" and name or (rel .. "/" .. name)
    if entry_type == "file" then
      table.insert(acc, child_rel)
    elseif entry_type == "directory" then
      walk_files(root, child_rel, acc)
    end
  end
end

---@param root string
---@return string[]
local function list_all_files(root)
  local files = {}
  walk_files(root, "", files)
  return files
end

---@param abs_path string
---@return boolean
local function is_probably_text(abs_path)
  local file = io.open(abs_path, "rb")
  if not file then
    return false
  end

  local sample = file:read(2048) or ""
  file:close()

  return not sample:find("\0", 1, true)
end

---@param abs_path string
---@return table|nil
local function get_file_stat(abs_path)
  if not uv or not uv.fs_stat then
    return nil
  end

  local stat = uv.fs_stat(abs_path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  local mtime = 0
  if type(stat.mtime) == "table" then
    mtime = stat.mtime.sec or 0
  elseif type(stat.mtime) == "number" then
    mtime = stat.mtime
  end

  return {
    size = stat.size or 0,
    mtime = mtime,
  }
end

---@param rel_path string
---@param lines string[]
---@param chunk_lines number
---@param overlap number
---@return SageRagChunk[]
local function chunk_lines_for_file(rel_path, lines, chunk_lines, overlap)
  local chunks = {}
  if #lines == 0 then
    return chunks
  end

  local step = chunk_lines - overlap
  if step < 1 then
    step = 1
  end

  local start_line = 1
  while start_line <= #lines do
    local end_line = math.min(start_line + chunk_lines - 1, #lines)
    local part = {}
    for i = start_line, end_line do
      part[#part + 1] = lines[i]
    end

    local text = table.concat(part, "\n")
    if text ~= "" then
      table.insert(chunks, {
        id = string.format("%s:%d-%d", rel_path, start_line, end_line),
        path = rel_path,
        start_line = start_line,
        end_line = end_line,
        text = text,
      })
    end

    if end_line == #lines then
      break
    end

    start_line = start_line + step
  end

  return chunks
end

---@param rel_path string
---@param abs_path string
---@param rag_opts SageRagConfig
---@return SageRagChunk[]|nil, string|nil
local function build_chunks_for_file(rel_path, abs_path, rag_opts)
  local ok, lines = pcall(vim.fn.readfile, abs_path)
  if not ok then
    return nil, "Failed to read file for RAG index: " .. rel_path
  end

  if type(lines) ~= "table" or #lines == 0 then
    return {}, nil
  end

  local chunks = chunk_lines_for_file(rel_path, lines, rag_opts.chunk_lines, rag_opts.chunk_overlap)
  return chunks, nil
end

---@param chunks SageRagChunk[]
---@param rag_opts SageRagConfig
---@param on_complete fun(chunks: SageRagChunk[]|nil, err: string|nil)
---@return SageRequestHandle
local function embed_chunks(chunks, rag_opts, on_complete)
  local cancelled = false
  local inflight = nil
  local batch_size = math.max(1, rag_opts.embed_batch_size)
  local index = 1

  local function done(result, err)
    if cancelled then
      return
    end
    on_complete(result, err)
  end

  local function process_batch()
    if cancelled then
      return
    end

    if index > #chunks then
      done(chunks, nil)
      return
    end

    local last = math.min(index + batch_size - 1, #chunks)
    local inputs = {}
    for i = index, last do
      inputs[#inputs + 1] = chunks[i].text
    end

    inflight = api.embeddings(inputs, rag_opts.embedding_model, function(vectors, err)
      if cancelled then
        return
      end

      if err then
        done(nil, err)
        return
      end

      if not vectors or #vectors ~= #inputs then
        done(nil, "Invalid embeddings response: mismatched vector count")
        return
      end

      for offset = 0, (last - index) do
        local chunk = chunks[index + offset]
        chunk.embedding = vectors[offset + 1]
      end

      index = last + 1
      process_batch()
    end)
  end

  process_batch()

  return {
    cancel = function()
      cancelled = true
      if inflight and inflight.cancel then
        inflight.cancel()
      end
    end,
  }
end

---@param root string
---@param rag_opts SageRagConfig
---@return table<string, {abs_path: string, mtime: number, size: number}>
local function collect_candidates(root, rag_opts)
  local include_patterns = compile_globs(rag_opts.include)
  local exclude_patterns = compile_globs(rag_opts.exclude)

  local files = list_git_files(root) or list_all_files(root)
  local max_size = math.max(1, rag_opts.max_file_size_kb) * 1024
  local candidates = {}

  for _, rel_path in ipairs(files) do
    if rel_path ~= "" and should_index(rel_path, include_patterns, exclude_patterns) then
      local abs_path = root .. "/" .. rel_path
      local stat = get_file_stat(abs_path)
      if stat and stat.size <= max_size and is_probably_text(abs_path) then
        candidates[rel_path] = {
          abs_path = abs_path,
          mtime = stat.mtime,
          size = stat.size,
        }
      end
    end
  end

  return candidates
end

---@param index SageRagIndex
---@return SageRagChunk[]
function M.collect_chunks(index)
  local chunks = {}
  for _, file_entry in pairs(index.files or {}) do
    for _, chunk in ipairs(file_entry.chunks or {}) do
      if type(chunk.embedding) == "table" and #chunk.embedding > 0 then
        chunks[#chunks + 1] = chunk
      end
    end
  end
  return chunks
end

---@param bufnr number|nil
---@return string
function M.get_project_root(bufnr)
  local current_buf = bufnr
  if not current_buf or current_buf <= 0 or not vim.api.nvim_buf_is_valid(current_buf) then
    current_buf = vim.api.nvim_get_current_buf()
  end

  local filepath = vim.api.nvim_buf_get_name(current_buf)
  if filepath ~= "" and vim.fs and vim.fs.root then
    local root = vim.fs.root(filepath, { ".git" })
    if root then
      return root
    end
  end

  return vim.fn.getcwd()
end

---@param bufnr number|nil
---@param rag_opts SageRagConfig
---@param on_complete fun(index: SageRagIndex|nil, err: string|nil)
---@return SageRequestHandle
function M.ensure_index(bufnr, rag_opts, on_complete)
  local root = M.get_project_root(bufnr)
  local index = store.load(root, rag_opts.embedding_model)
  if not index then
    index = store.new_index(root, rag_opts.embedding_model)
  end

  index.files = index.files or {}

  local candidates = collect_candidates(root, rag_opts)

  for rel_path, _ in pairs(index.files) do
    if not candidates[rel_path] then
      index.files[rel_path] = nil
    end
  end

  local pending = {}
  for rel_path, meta in pairs(candidates) do
    local existing = index.files[rel_path]
    if not existing or existing.mtime ~= meta.mtime or existing.size ~= meta.size then
      pending[#pending + 1] = {
        rel_path = rel_path,
        abs_path = meta.abs_path,
        mtime = meta.mtime,
        size = meta.size,
      }
    end
  end

  table.sort(pending, function(a, b)
    return a.rel_path < b.rel_path
  end)

  if #pending == 0 then
    on_complete(index, nil)
    return {
      cancel = function() end,
    }
  end

  local cancelled = false
  local inflight = nil
  local pending_index = 1

  local function fail(err)
    if cancelled then
      return
    end
    on_complete(nil, err)
  end

  local function process_next()
    if cancelled then
      return
    end

    local item = pending[pending_index]
    if not item then
      local ok, save_err = store.save(root, rag_opts.embedding_model, index)
      if not ok then
        fail(save_err or "Failed to persist RAG index")
        return
      end
      on_complete(index, nil)
      return
    end

    pending_index = pending_index + 1

    local chunks, chunk_err = build_chunks_for_file(item.rel_path, item.abs_path, rag_opts)
    if chunk_err then
      fail(chunk_err)
      return
    end

    if not chunks or #chunks == 0 then
      index.files[item.rel_path] = {
        mtime = item.mtime,
        size = item.size,
        chunks = {},
      }
      process_next()
      return
    end

    inflight = embed_chunks(chunks, rag_opts, function(embedded_chunks, err)
      if cancelled then
        return
      end

      if err then
        fail(err)
        return
      end

      index.files[item.rel_path] = {
        mtime = item.mtime,
        size = item.size,
        chunks = embedded_chunks,
      }

      process_next()
    end)
  end

  process_next()

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
