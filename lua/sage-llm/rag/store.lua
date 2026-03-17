local config = require("sage-llm.config")

local M = {}

local INDEX_VERSION = 1

---@class SageRagChunk
---@field id string
---@field path string
---@field start_line number
---@field end_line number
---@field text string
---@field embedding number[]

---@class SageRagFileEntry
---@field mtime number
---@field size number
---@field chunks SageRagChunk[]

---@class SageRagIndex
---@field version number
---@field root string
---@field embedding_model string
---@field updated_at number
---@field files table<string, SageRagFileEntry>

---@return string
local function get_base_dir()
  local rag = config.options.rag or {}
  if rag.index_dir and rag.index_dir ~= "" then
    return rag.index_dir
  end
  return vim.fn.stdpath("cache") .. "/sage-llm/rag"
end

---@param dir string
---@return boolean, string|nil
local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 1 then
    return true, nil
  end

  local ok, mkdir_ok = pcall(vim.fn.mkdir, dir, "p")
  if not ok or mkdir_ok == 0 then
    return false, "Failed to create directory: " .. dir
  end

  return true, nil
end

---@param root string
---@param embedding_model string
---@return string
local function build_key(root, embedding_model)
  return vim.fn.sha256(root .. "::" .. embedding_model)
end

---@param root string
---@param embedding_model string
---@return string
function M.get_index_path(root, embedding_model)
  return get_base_dir() .. "/" .. build_key(root, embedding_model) .. ".json"
end

---@param root string
---@param embedding_model string
---@return SageRagIndex
function M.new_index(root, embedding_model)
  return {
    version = INDEX_VERSION,
    root = root,
    embedding_model = embedding_model,
    updated_at = os.time(),
    files = {},
  }
end

---@param root string
---@param embedding_model string
---@return SageRagIndex|nil
function M.load(root, embedding_model)
  local path = M.get_index_path(root, embedding_model)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local content = file:read("*a")
  file:close()

  if not content or content == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  if decoded.version ~= INDEX_VERSION then
    return nil
  end

  decoded.files = decoded.files or {}
  return decoded
end

---@param root string
---@param embedding_model string
---@param index SageRagIndex
---@return boolean, string|nil
function M.save(root, embedding_model, index)
  local dir = get_base_dir()
  local ok, err = ensure_dir(dir)
  if not ok then
    return false, err
  end

  index.version = INDEX_VERSION
  index.root = root
  index.embedding_model = embedding_model
  index.updated_at = os.time()

  local path = M.get_index_path(root, embedding_model)
  local file = io.open(path, "w")
  if not file then
    return false, "Failed to write index file: " .. path
  end

  local encoded = vim.json.encode(index)
  file:write(encoded)
  file:close()

  return true, nil
end

return M
