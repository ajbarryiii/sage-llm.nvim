local config = require("sage-llm.config")
local uv = vim.uv or vim.loop
local ffi_ok, ffi = pcall(require, "ffi")
local flock
if ffi_ok then
  pcall(ffi.cdef, "int flock(int fd, int operation);")
  local ok, symbol = pcall(function()
    return ffi.C.flock
  end)
  if ok then
    flock = symbol
  end
end

local M = {}
local cleanup_error =
  "Could not remove abandoned ChatGPT request files. Check data-directory permissions"

local function storage_root(create)
  local auth_dir = (config.options.chatgpt or {}).auth_dir
    or (vim.fn.stdpath("data") .. "/sage-llm/chatgpt")
  local parent = uv.fs_lstat(auth_dir)
  if parent and parent.type ~= "directory" then
    return nil, "ChatGPT request storage must use a private directory"
  end
  if not parent then
    if not create then
      return nil
    end
    if not uv.fs_mkdir(auth_dir, 448) then
      parent = uv.fs_lstat(auth_dir)
      if not parent or parent.type ~= "directory" then
        return nil, "Could not create ChatGPT request storage"
      end
    end
  end
  local root = auth_dir .. "/requests"
  local info = uv.fs_lstat(root)
  if info and info.type ~= "directory" then
    return nil, "ChatGPT request storage must use a private directory"
  end
  if not info then
    if not create then
      return nil
    end
    if not uv.fs_mkdir(root, 448) then
      info = uv.fs_lstat(root)
      if not info or info.type ~= "directory" then
        return nil, "Could not create ChatGPT request storage"
      end
    end
  end
  if not uv.fs_chmod(root, 448) then
    return nil, "Could not protect ChatGPT request storage"
  end
  return root
end

local function open_lock(path)
  if not flock then
    return nil, "ChatGPT request storage requires LuaJIT and Unix file locking"
  end
  local info = uv.fs_lstat(path)
  if info and info.type ~= "file" then
    return nil, "Invalid ChatGPT request lock storage"
  end
  local fd = uv.fs_open(path, "a", 384)
  if not fd then
    return nil, "Could not open ChatGPT request lock"
  end
  if not uv.fs_fchmod(fd, 384) then
    uv.fs_close(fd)
    return nil, "Could not protect ChatGPT request lock"
  end
  return fd
end

local function unlock(fd)
  flock(fd, 8)
  uv.fs_close(fd)
end

-- A permanent collection lock serializes allocation, scanning, and removal.
-- Its critical sections perform only filesystem work, never network requests.
local function with_collection(root, operation)
  local fd, err = open_lock(root .. "/collection.lock")
  if not fd then
    return nil, err
  end
  if flock(fd, 2) ~= 0 then
    uv.fs_close(fd)
    return nil, "Could not lock ChatGPT request storage"
  end
  local ok, result, operation_err = pcall(operation)
  unlock(fd)
  if not ok then
    return nil, cleanup_error
  end
  return result, operation_err
end

local function remove_request(path)
  for _, name in ipairs({ "headers", "body", "owner.lock" }) do
    local file = path .. "/" .. name
    if uv.fs_lstat(file) and not uv.fs_unlink(file) then
      return nil, cleanup_error
    end
  end
  if uv.fs_lstat(path) and not uv.fs_rmdir(path) then
    return nil, cleanup_error
  end
  return true
end

local function cleanup_locked(root)
  local entries = uv.fs_scandir(root)
  if not entries then
    return nil, cleanup_error
  end
  while true do
    local name = uv.fs_scandir_next(entries)
    if not name then
      return true
    end
    if name:match("^request%-[%w_-]+$") then
      local path = root .. "/" .. name
      local info = uv.fs_lstat(path)
      if not info then
        return nil, cleanup_error
      end
      if info.type == "link" then
        -- Remove the link itself; never inspect or delete its target.
        if not uv.fs_unlink(path) then
          return nil, cleanup_error
        end
      elseif info.type == "directory" then
        local fd, err = open_lock(path .. "/owner.lock")
        if not fd then
          return nil, err
        end
        if flock(fd, 6) == 0 then
          local removed, remove_err = remove_request(path)
          unlock(fd)
          if not removed then
            return nil, remove_err
          end
        else
          uv.fs_close(fd)
        end
      else
        return nil, "Invalid ChatGPT request storage"
      end
    end
  end
end

---Delete dead editors' request files, preserving every live ownership lock.
---@return boolean|nil, string|nil
function M.cleanup_orphans()
  local root, err = storage_root(false)
  if not root then
    return not err, err
  end
  return with_collection(root, function()
    return cleanup_locked(root)
  end)
end

---@class SageChatGPTRequestStorage
---@field path string
---@field owner_fd integer|nil
---@field release fun(): boolean|nil, string|nil

---Allocate private request storage with an OS-owned lifetime lock.
---@return SageChatGPTRequestStorage|nil, string|nil
function M.create()
  local root, err = storage_root(true)
  if not root then
    return nil, err
  end
  return with_collection(root, function()
    local cleaned, cleanup_err = cleanup_locked(root)
    if not cleaned then
      return nil, cleanup_err
    end
    local path = uv.fs_mkdtemp(root .. "/request-XXXXXX")
    if not path then
      return nil, "Could not allocate private ChatGPT request storage"
    end
    local fd, lock_err = open_lock(path .. "/owner.lock")
    if not fd or flock(fd, 6) ~= 0 then
      if fd then
        uv.fs_close(fd)
      end
      remove_request(path)
      return nil, lock_err or "Could not own ChatGPT request storage"
    end
    local store = { path = path, owner_fd = fd }
    function store.release()
      if not store.owner_fd then
        return true
      end
      local removed, remove_err = with_collection(root, function()
        return remove_request(path)
      end)
      -- Even failed removal ends ownership, so restart/logout can retry it.
      unlock(store.owner_fd)
      store.owner_fd = nil
      return removed, remove_err
    end
    return store
  end)
end

return M
