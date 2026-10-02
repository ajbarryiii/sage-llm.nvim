local config = require("sage-llm.config")
local curl = require("plenary.curl")
local crypto = require("sage-llm.chatgpt_crypto")
local uv = vim.uv or vim.loop

-- POSIX flock owns a lock for an open file description and releases it on
-- process death. Keep the lock inode permanently: unlinking it would allow two
-- processes to lock different files at the same path.
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
local ISSUER = "https://auth.openai.com"
local AUTHORIZE = ISSUER .. "/api/accounts/authorize"
local TOKEN = ISSUER .. "/api/accounts/oauth/token"
local DISCOVERY = ISSUER .. "/.well-known/openid-configuration"
local JWKS = ISSUER .. "/.well-known/jwks.json"
local RESOURCE = "https://api.openai.com/v1"
local SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
local SIGN_IN = "Sign in with :SageChatGPTLogin to connect your ChatGPT plan"
local TERMINAL_REFRESH_ERRORS = {
  invalid_grant = true,
  invalid_refresh_token = true,
  token_expired = true,
  refresh_token_expired = true,
  refresh_token_invalidated = true,
  refresh_token_reused = true,
}
local login_attempt
local refresh_waiters
local active_requests = {}
local active_timers = {}
local held_locks = {}
local cleanup_registered = false
local exiting = false
local pending_logouts = {}
local ready_responses = {}

local function register_cleanup()
  if cleanup_registered then
    return
  end
  cleanup_registered = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("SageChatGPTAuth", { clear = true }),
    callback = function()
      exiting = true
      -- A received rotating grant must survive even if its scheduled callback
      -- has not run. Stage it while its session lock is still held; pending
      -- logout cleanup below will then remove it if sign-out was requested.
      for preserve in pairs(ready_responses) do
        preserve()
      end
      if login_attempt then
        login_attempt.cancel()
      end
      for handle in pairs(active_requests) do
        handle.cancel()
      end
      for timer in pairs(active_timers) do
        active_timers[timer] = nil
        if not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end
      for release in pairs(held_locks) do
        release()
      end
      -- Complete local sign-out synchronously after releasing this process's
      -- refresh locks; scheduled callbacks will not run reliably during exit.
      for complete in pairs(pending_logouts) do
        complete()
      end
    end,
  })
end

local function options()
  return config.options.chatgpt or {}
end

local function directory()
  return options().auth_dir or (vim.fn.stdpath("data") .. "/sage-llm/chatgpt")
end

local function request_timeout()
  return options().request_timeout_ms or 30000
end

local function close(handle)
  if handle then
    active_timers[handle] = nil
  end
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function ensure_directory()
  if uv.os_uname().sysname == "Windows_NT" then
    return nil, "ChatGPT sign-in currently requires a Unix filesystem with owner-only permissions"
  end
  local path = directory()
  local info = uv.fs_lstat(path)
  if info and info.type ~= "directory" then
    return nil, "ChatGPT credential storage must be a private directory"
  end
  local ok = pcall(vim.fn.mkdir, path, "p", 448)
  if not ok or not uv.fs_chmod(path, 448) then
    return nil, "Could not protect ChatGPT credential storage"
  end
  return path
end

local function read_file(path)
  local info = uv.fs_lstat(path)
  if not info then
    return nil
  end
  if info.type ~= "file" or info.size > 1048576 then
    return nil, "Invalid ChatGPT credential storage"
  end
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return nil, "Could not read ChatGPT credential storage"
  end
  -- Another process can atomically replace the path between lstat and open.
  -- Read and protect the opened inode, including its own size, so a complete
  -- replacement is never truncated using the preceding file's metadata.
  info = uv.fs_fstat(fd)
  if not info or info.type ~= "file" or info.size > 1048576 then
    uv.fs_close(fd)
    return nil, "Invalid ChatGPT credential storage"
  end
  if not uv.fs_fchmod(fd, 384) then
    uv.fs_close(fd)
    return nil, "Could not protect ChatGPT credential storage"
  end
  local data = uv.fs_read(fd, info.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil, "Could not read ChatGPT credential storage"
  end
  return data
end

local function read_json(path)
  local data, err = read_file(path)
  if not data then
    return nil, err
  end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok or type(decoded) ~= "table" then
    return nil, "Invalid ChatGPT credential storage"
  end
  return decoded
end

local function private_write(path, data)
  local fd = uv.fs_open(path, "wx", 384)
  if not fd then
    return nil
  end
  local written = uv.fs_write(fd, data, 0)
  local synced = written == #data and uv.fs_fsync(fd)
  uv.fs_close(fd)
  if not synced then
    uv.fs_unlink(path)
    return nil
  end
  return true
end

local function save_record(path, record)
  local suffix = crypto.random_token()
  if not suffix then
    return nil, "Could not securely save ChatGPT credentials"
  end
  local temporary = path .. "." .. suffix
  local ok, encoded = pcall(vim.json.encode, record)
  if not ok or not private_write(temporary, encoded) then
    return nil, "Could not securely save ChatGPT credentials"
  end
  if not uv.fs_rename(temporary, path) then
    uv.fs_unlink(temporary)
    return nil, "Could not securely save ChatGPT credentials"
  end
  return true
end

local function credentials()
  local path, directory_err = ensure_directory()
  if not path then
    return nil, directory_err
  end
  local record, err = read_json(path .. "/credentials.json")
  if not record then
    return nil, err
  end
  if
    type(record.client_id) ~= "string"
    or record.client_id == ""
    or record.client_id == "dynamic_agent_client"
  then
    return nil, "Invalid ChatGPT credential storage"
  end
  if record.issuer ~= ISSUER or type(record.subject) ~= "string" or record.subject == "" then
    return nil, "Invalid ChatGPT credential storage"
  end
  if record.email ~= nil and type(record.email) ~= "string" then
    return nil, "Invalid ChatGPT credential storage"
  end
  if
    record.expires_at ~= nil
    and (
      type(record.expires_at) ~= "number"
      or record.expires_at ~= record.expires_at
      or record.expires_at == math.huge
      or record.expires_at <= 0
    )
  then
    return nil, "Invalid ChatGPT credential storage"
  end
  return record
end

local function has_plan_scope(scopes)
  if type(scopes) ~= "table" then
    return false
  end
  local granted = {}
  for _, scope in ipairs(scopes) do
    granted[scope] = true
  end
  return granted["resource.invoke"] and granted["chatgpt.tokens.use.direct"] or false
end

local function scopes_from(value)
  if type(value) ~= "string" then
    return nil
  end
  local scopes = {}
  for scope in value:gmatch("%S+") do
    scopes[#scopes + 1] = scope
  end
  return scopes
end

local function connected(record)
  return record ~= nil
    and type(record.access_token) == "string"
    and record.access_token ~= ""
    and type(record.refresh_token) == "string"
    and record.refresh_token ~= ""
    and type(record.expires_at) == "number"
    and has_plan_scope(record.scopes)
end

---Bind account-specific results to the verified registration, not token rotations.
local function account_guard(record)
  local client_id, subject = record.client_id, record.subject
  return function()
    local current = credentials()
    return connected(current) and current.client_id == client_id and current.subject == subject
  end
end

local function encode(value)
  return (
    tostring(value):gsub("([^%w%-%.%_~])", function(byte)
      return string.format("%%%02X", byte:byte())
    end)
  )
end

local function form_encode(values)
  local fields = {}
  for key, value in pairs(values) do
    fields[#fields + 1] = encode(key) .. "=" .. encode(value)
  end
  table.sort(fields)
  return table.concat(fields, "&")
end

-- Form bodies live in owner-only files rather than curl's process arguments.
local function request(url, form, callback, on_exit)
  local done = false
  local job
  local body_path
  local handle
  local function finish(response, err)
    if done then
      return
    end
    done = true
    if handle then
      active_requests[handle] = nil
    end
    if body_path then
      uv.fs_unlink(body_path)
    end
    local waiting = true
    local received_at = os.time()
    local preserve
    if on_exit and response then
      preserve = function()
        if not waiting then
          return
        end
        waiting = false
        ready_responses[preserve] = nil
        on_exit(response, err, received_at)
      end
      ready_responses[preserve] = true
    end
    vim.schedule(function()
      if not waiting then
        return
      end
      waiting = false
      if preserve then
        ready_responses[preserve] = nil
      end
      if not exiting then
        callback(response, err, received_at)
      end
    end)
  end
  local opts = {
    raw = {
      "--max-time",
      tostring(math.max(1, math.ceil(request_timeout() / 1000))),
      "--max-redirs",
      "0",
      "--proto",
      "=https",
    },
    callback = function(response)
      finish(response)
    end,
    on_error = function()
      finish(nil, "Could not reach OpenAI. Try again")
    end,
  }
  if form then
    local path, err = ensure_directory()
    local suffix = crypto.random_token()
    if not path or not suffix then
      finish(nil, err or "Could not create a secure OpenAI request")
      return { cancel = function() end }
    end
    body_path = path .. "/.request-" .. suffix
    if not private_write(body_path, form_encode(form)) then
      finish(nil, "Could not create a secure OpenAI request")
      return { cancel = function() end }
    end
    opts.body = body_path
    opts.headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  end
  local ok, result = pcall(form and curl.post or curl.get, url, opts)
  if ok then
    job = result
  else
    finish(nil, "Could not reach OpenAI. Try again")
  end
  handle = {
    cancel = function()
      local killed = false
      if job and job.handle and job.handle.kill then
        local kill_ok, kill_result = pcall(job.handle.kill, job.handle, "sigterm")
        killed = kill_ok and kill_result == 0
      end
      -- A signalled process must remain open until Plenary reaps its exit.
      if not killed and job and job.shutdown then
        pcall(job.shutdown, job)
      end
      finish(nil, "OpenAI request cancelled")
    end,
  }
  if not done then
    active_requests[handle] = true
  end
  return handle
end

local function decode_response(response)
  if not response or type(response.body) ~= "string" then
    return nil
  end
  local ok, result = pcall(vim.json.decode, response.body)
  return ok and type(result) == "table" and result or nil
end

local function token_error(response)
  local data = decode_response(response)
  if data and TERMINAL_REFRESH_ERRORS[data.error] then
    return "ChatGPT authorization expired or was revoked. Sign in again with :SageChatGPTLogin"
  end
  return "OpenAI could not authorize your ChatGPT plan. Try signing in again"
end

local function validate_tokens(data, previous)
  if type(data) ~= "table" or type(data.access_token) ~= "string" or data.access_token == "" then
    return nil, "OpenAI returned invalid ChatGPT credentials"
  end
  if type(data.refresh_token) ~= "string" or data.refresh_token == "" then
    return nil, "OpenAI did not grant renewable access. Sign in again"
  end
  if type(data.token_type) ~= "string" or data.token_type:lower() ~= "bearer" then
    return nil, "OpenAI returned an unsupported credential type"
  end
  if
    type(data.expires_in) ~= "number"
    or data.expires_in ~= data.expires_in
    or data.expires_in <= 0
    or data.expires_in > 86400
    or data.expires_in % 1 ~= 0
  then
    return nil, "OpenAI returned invalid ChatGPT credential expiry"
  end
  if data.id_token ~= nil and (type(data.id_token) ~= "string" or data.id_token == "") then
    return nil, "OpenAI returned an invalid ChatGPT identity"
  end
  local scopes = scopes_from(data.scope) or (previous and previous.scopes)
  if not has_plan_scope(scopes) then
    return nil, "ChatGPT plan usage was not granted. Sign in again and allow ChatGPT plan usage"
  end
  return scopes
end

local function verify_identity(token, response, claims)
  local keys = decode_response(response)
  if not response or response.status ~= 200 or not keys then
    return nil
  end
  local ok, payload = pcall(crypto.verify_id_token, token, keys, claims)
  return ok and type(payload) == "table" and payload or nil
end

local function same_session(first, second)
  if not first or not second then
    return first == second
  end
  for _, key in ipairs({ "client_id", "subject", "access_token", "refresh_token", "id_token" }) do
    if first[key] ~= second[key] then
      return false
    end
  end
  return true
end

local function open_lock(path)
  if not flock then
    return nil, "ChatGPT sign-in requires Neovim with LuaJIT for secure session locking"
  end
  local info = uv.fs_lstat(path)
  if info and info.type ~= "file" then
    return nil, "Invalid ChatGPT lock storage"
  end
  local fd = uv.fs_open(path, "a", 384)
  if not fd then
    return nil, "Could not create a secure ChatGPT lock"
  end
  if not uv.fs_fchmod(fd, 384) then
    uv.fs_close(fd)
    return nil, "Could not protect ChatGPT lock storage"
  end
  return fd
end

local function unlock(fd)
  flock(fd, 8) -- LOCK_UN
  uv.fs_close(fd)
end

---Only run while holding session.lock. Every token-bearing OAuth POST holds
---that lock until its request file is removed, so remaining files are orphaned.
local function cleanup_orphaned_secrets(path, include_credentials)
  local entries = uv.fs_scandir(path)
  if not entries then
    return nil, "Could not inspect abandoned ChatGPT credential files"
  end
  while true do
    local name = uv.fs_scandir_next(entries)
    if not name then
      return true
    end
    local request_file = name:match("^%.request%-[%w_-]+$")
    local credential_file = include_credentials and name:match("^credentials%.json%.[%w_-]+$")
    if request_file or credential_file then
      -- Unlink the entry itself, without following a symlink or reading secrets.
      if not uv.fs_unlink(path .. "/" .. name) then
        return nil, "Could not remove abandoned ChatGPT credential files. Check file permissions"
      end
    end
  end
end

-- Protect rotating refresh tokens across Neovim instances, as well as locally.
local function acquire_lock(callback, immediate)
  local path, err = ensure_directory()
  if not path then
    callback(nil, err)
    return { cancel = function() end }
  end
  local fd, lock_err = open_lock(path .. "/session.lock")
  if not fd then
    callback(nil, lock_err)
    return { cancel = function() end }
  end
  local started = uv.hrtime()
  local timer = uv.new_timer()
  active_timers[timer] = true
  local finished = false
  local function finish(release, failure)
    if finished then
      return
    end
    finished = true
    close(timer)
    if not release then
      uv.fs_close(fd)
    end
    if immediate then
      callback(release, failure)
    else
      vim.schedule(function()
        callback(release, failure)
      end)
    end
  end
  local function attempt(final_attempt)
    if finished then
      return
    end
    if flock(fd, 6) == 0 then -- LOCK_EX | LOCK_NB
      local cleaned, cleanup_err = cleanup_orphaned_secrets(path, false)
      if not cleaned then
        flock(fd, 8)
        finish(nil, cleanup_err)
        return
      end
      local released = false
      local release
      release = function()
        if released then
          return
        end
        released = true
        held_locks[release] = nil
        unlock(fd)
      end
      held_locks[release] = true
      finish(release)
      return
    end
    if final_attempt or (uv.hrtime() - started) / 1e6 > request_timeout() then
      finish(nil, "Another Neovim instance is updating ChatGPT access. Try again")
      return
    end
    timer:start(
      100,
      0,
      vim.schedule_wrap(function()
        if not exiting then
          attempt()
        end
      end)
    )
  end
  attempt()
  return {
    retry_on_exit = function()
      attempt(true)
    end,
    cancel = function()
      finish(nil, "ChatGPT session update cancelled")
    end,
  }
end

local function host_id()
  local path, err = ensure_directory()
  if not path then
    return nil, err
  end
  local saved, read_err = read_json(path .. "/host.json")
  if read_err then
    return nil, read_err
  end
  if saved then
    if
      type(saved.ext_agent_host_id) ~= "string"
      or #saved.ext_agent_host_id ~= 45
      or not saved.ext_agent_host_id:match("^urn:uuid:%x+%-%x+%-4%x%x%x%-[89abAB]%x%x%x%-%x+$")
    then
      return nil, "Invalid ChatGPT host identifier"
    end
    return saved.ext_agent_host_id
  end
  local fd, lock_err = open_lock(path .. "/host.lock")
  if not fd then
    return nil, lock_err
  end
  if flock(fd, 6) ~= 0 then
    uv.fs_close(fd)
    return nil, "Another Neovim instance is initializing ChatGPT sign-in. Try again"
  end
  saved, read_err = read_json(path .. "/host.json")
  if saved or read_err then
    unlock(fd)
    if saved and type(saved.ext_agent_host_id) == "string" then
      return saved.ext_agent_host_id
    end
    return nil, read_err or "Invalid ChatGPT host identifier"
  end
  local uuid = crypto.random_uuid()
  if not uuid then
    unlock(fd)
    return nil, "Could not create a secure ChatGPT host identifier"
  end
  local value = "urn:uuid:" .. uuid
  local ok, save_err = save_record(path .. "/host.json", { ext_agent_host_id = value })
  unlock(fd)
  return ok and value or nil, save_err
end

---@return {connected: boolean, email: string|nil, subject: string|nil, expires_at: number|nil, scopes: string[]}
function M.status()
  local record = credentials()
  return {
    connected = connected(record),
    email = record and record.email or nil,
    subject = record and record.subject or nil,
    expires_at = record and record.expires_at or nil,
    scopes = record and vim.deepcopy(record.scopes or {}) or {},
  }
end

---@param callback fun(token: string|nil, err: string|nil, is_current: (fun(): boolean)|nil)
---@return SageRequestHandle
function M.get_access_token(callback)
  vim.validate({ callback = { callback, "function" } })
  register_cleanup()
  local caller = { callback = callback, cancelled = false }
  local handle = {
    cancel = function()
      caller.cancelled = true
    end,
  }
  if exiting or next(pending_logouts) then
    callback(nil, "ChatGPT sign-out is in progress. Sign in again after it completes")
    return handle
  end
  local record, read_err = credentials()
  if not connected(record) then
    callback(nil, read_err or SIGN_IN)
    return handle
  end
  caller.is_current = account_guard(record)
  if not record.pending_refresh and record.expires_at > os.time() + 60 then
    callback(record.access_token, nil, caller.is_current)
    return handle
  end
  if refresh_waiters then
    refresh_waiters[#refresh_waiters + 1] = caller
    return handle
  end
  refresh_waiters = { caller }
  local function finish(token, err)
    local waiting = refresh_waiters
    refresh_waiters = nil
    for _, waiter in ipairs(waiting or {}) do
      if not waiter.cancelled then
        waiter.callback(token, err, token and waiter.is_current or nil)
      end
    end
  end
  acquire_lock(function(release, lock_err)
    if not release then
      finish(nil, lock_err)
      return
    end
    if exiting then
      release()
      finish(nil, SIGN_IN)
      return
    end
    -- Another process may have renewed or signed out while we waited.
    local current, err = credentials()
    if not connected(current) then
      release()
      finish(nil, err or SIGN_IN)
      return
    end
    if current.client_id ~= record.client_id or current.subject ~= record.subject then
      release()
      finish(nil, "ChatGPT account changed while renewing access. Try again")
      return
    end
    local start_refresh
    local function verify_and_save(data, received_at, staged)
      local granted, validation_err = validate_tokens(data, current)
      if
        not granted
        or type(received_at) ~= "number"
        or received_at ~= received_at
        or received_at <= 0
        or received_at > os.time() + 60
      then
        release()
        finish(nil, validation_err or "Invalid pending ChatGPT renewal")
        return
      end
      -- A successful exchange consumes the previous refresh token. Securely
      -- retain its replacement before any further network request, without
      -- making the unverified identity or access token available to callers.
      if not staged then
        current.pending_refresh = { tokens = data, received_at = received_at }
        local ok, save_err = save_record(directory() .. "/credentials.json", current)
        if not ok then
          release()
          finish(nil, save_err)
          return
        end
      end
      local function save(payload)
        local renewed = vim.deepcopy(current)
        renewed.pending_refresh = nil
        renewed.access_token = data.access_token
        renewed.refresh_token = data.refresh_token
        renewed.token_type = "Bearer"
        renewed.expires_at = received_at + data.expires_in
        renewed.scopes = granted
        if data.id_token then
          renewed.id_token = data.id_token
          renewed.email = type(payload.email) == "string" and payload.email or current.email
        end
        local ok, save_err = save_record(directory() .. "/credentials.json", renewed)
        if not ok then
          release()
          finish(nil, save_err)
          return
        end
        current = renewed
        if renewed.expires_at <= os.time() then
          -- Recovery can happen after the staged access token has expired.
          -- Rotate the verified replacement rather than reuse the consumed one.
          start_refresh()
          return
        end
        release()
        finish(renewed.access_token)
      end
      if not data.id_token then
        save({})
        return
      end
      request(JWKS, nil, function(keys_response, keys_err)
        local payload = verify_identity(data.id_token, keys_response, {
          issuer = ISSUER,
          audience = current.client_id,
          subject = current.subject,
          -- Verify validity at receipt; a network outage must not make a
          -- securely staged, otherwise valid identity impossible to recover.
          time = received_at,
        })
        if not payload then
          release()
          finish(nil, keys_err or "OpenAI returned an invalid ChatGPT identity")
          return
        end
        save(payload)
      end)
    end
    start_refresh = function()
      request(TOKEN, {
        grant_type = "refresh_token",
        client_id = current.client_id,
        refresh_token = current.refresh_token,
        resource = RESOURCE,
      }, function(response, network_err, received_at)
        local data = decode_response(response)
        if network_err or not response or response.status ~= 200 then
          if data and TERMINAL_REFRESH_ERRORS[data.error] then
            current.access_token = nil
            current.refresh_token = nil
            current.id_token = nil
            current.expires_at = nil
            current.scopes = {}
            current.pending_refresh = nil
            save_record(directory() .. "/credentials.json", current)
          end
          release()
          finish(nil, network_err or token_error(response))
          return
        end
        verify_and_save(data, received_at, false)
      end, function(response, network_err, received_at)
        local data = decode_response(response)
        if network_err or response.status ~= 200 or not validate_tokens(data, current) then
          return
        end
        -- Do not activate credentials or perform network requests during exit.
        -- The next process verifies this staged identity before using the grant.
        current.pending_refresh = { tokens = data, received_at = received_at }
        local ok = save_record(directory() .. "/credentials.json", current)
        if not ok then
          vim.notify(
            "sage-llm: Could not save ChatGPT renewal during exit. Sign in again on next startup",
            vim.log.levels.WARN
          )
        end
      end)
    end
    if current.pending_refresh then
      local pending = current.pending_refresh
      if type(pending) ~= "table" then
        release()
        finish(nil, "Invalid pending ChatGPT renewal")
        return
      end
      verify_and_save(pending.tokens, pending.received_at, true)
    elseif current.expires_at > os.time() + 60 then
      release()
      finish(current.access_token)
    else
      start_refresh()
    end
  end)
  return handle
end

local function parse_query(query)
  local values = {}
  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=(.*)$")
    if not key or values[key] ~= nil then
      return nil
    end
    local function decode(part)
      if part:gsub("%%[%da-fA-F][%da-fA-F]", ""):find("%%") then
        return nil
      end
      return (
        part:gsub("+", " "):gsub("%%([%da-fA-F][%da-fA-F])", function(hex)
          return string.char(tonumber(hex, 16))
        end)
      )
    end
    key, value = decode(key), decode(value)
    if not key or not value or values[key] ~= nil then
      return nil
    end
    values[key] = value
  end
  return values
end

---@param callback fun(ok: boolean, err: string|nil)
---@param opts? {new_account: boolean}
---@return SageRequestHandle
function M.login(callback, opts)
  vim.validate({ callback = { callback, "function" }, opts = { opts, "table", true } })
  opts = opts or {}
  register_cleanup()
  if opts.new_account ~= nil then
    vim.validate({ new_account = { opts.new_account, "boolean" } })
  end
  if exiting or next(pending_logouts) then
    callback(false, "ChatGPT sign-out is in progress. Try signing in again shortly")
    return { cancel = function() end }
  end
  if login_attempt then
    callback(false, "ChatGPT sign-in is already in progress")
    return { cancel = function() end }
  end
  if refresh_waiters then
    callback(false, "ChatGPT access is being renewed. Try signing in again shortly")
    return { cancel = function() end }
  end
  local saved, read_err = credentials()
  if read_err then
    callback(false, read_err)
    return { cancel = function() end }
  end
  local host, host_err = host_id()
  local previous = not opts.new_account and saved or nil
  local registration
  if host and not previous then
    local candidate, registration_err = read_json(directory() .. "/pending_registration.json")
    if registration_err then
      callback(false, registration_err)
      return { cancel = function() end }
    end
    if candidate then
      if
        candidate.issuer ~= ISSUER
        or type(candidate.client_id) ~= "string"
        or candidate.client_id == ""
        or candidate.client_id == "dynamic_agent_client"
        or candidate.ext_agent_host_id ~= host
      then
        callback(false, "Invalid pending ChatGPT registration")
        return { cancel = function() end }
      end
      if
        candidate.origin_client_id == (saved and saved.client_id)
        and candidate.origin_subject == (saved and saved.subject)
      then
        registration = candidate
      end
    end
  end
  local selected_client_id = previous and previous.client_id
    or registration and registration.client_id
  local state = crypto.random_token()
  local nonce = crypto.random_token()
  local verifier = crypto.random_token()
  local challenge = verifier and crypto.challenge(verifier)
  if not host or not state or not nonce or not challenge then
    callback(false, host_err or "Could not initialize secure ChatGPT sign-in")
    return { cancel = function() end }
  end
  local attempt = { peers = {} }
  login_attempt = attempt
  local server = uv.new_tcp()
  local timer = uv.new_timer()
  local pending
  local release_lock
  local done = false
  local received = false
  local function close_listener()
    close(server)
    for peer in pairs(attempt.peers) do
      close(peer)
    end
    attempt.peers = {}
  end
  local function finish(ok, err)
    if done then
      return
    end
    done = true
    if login_attempt == attempt then
      login_attempt = nil
    end
    close_listener()
    close(timer)
    if pending then
      pending.cancel()
    end
    if release_lock then
      release_lock()
    end
    callback(ok, err)
  end
  local handle = {
    cancel = function()
      finish(false, "ChatGPT sign-in cancelled")
    end,
  }
  attempt.cancel = handle.cancel
  local ok, bind_err = server:bind("127.0.0.1", 0)
  if not ok then
    finish(
      false,
      bind_err and "Could not start the local ChatGPT sign-in callback" or "ChatGPT sign-in failed"
    )
    return handle
  end
  local address = server:getsockname()
  local redirect = "http://127.0.0.1:" .. address.port .. "/auth/callback"
  local values = {
    client_id = selected_client_id or "dynamic_agent_client",
    ext_agent_host_id = host,
    response_type = "code",
    redirect_uri = redirect,
    scope = SCOPE,
    resource = RESOURCE,
    state = state,
    nonce = nonce,
    code_challenge_method = "S256",
    code_challenge = challenge,
  }
  if previous then
    values.login_hint = previous.email
  elseif not selected_client_id then
    values.agent_name_hint = "sage-llm.nvim"
  end
  local function exchange(query)
    pending = acquire_lock(function(release, lock_err)
      if done then
        if release then
          release()
        end
        return
      end
      if not release then
        finish(false, lock_err)
        return
      end
      release_lock = release
      local current = credentials()
      if not same_session(saved, current) then
        finish(false, "ChatGPT account changed during sign-in. Try again")
        return
      end
      local client_id = selected_client_id or query.client_id
      if not previous then
        -- An issued public client ID is registration metadata, not a verified
        -- identity. Keep it separate so a rejected code can restart OAuth
        -- without creating another registration or changing an active account.
        local retained, retain_err = save_record(directory() .. "/pending_registration.json", {
          issuer = ISSUER,
          client_id = client_id,
          ext_agent_host_id = host,
          origin_client_id = saved and saved.client_id,
          origin_subject = saved and saved.subject,
        })
        if not retained then
          finish(false, retain_err)
          return
        end
      end
      pending = request(TOKEN, {
        grant_type = "authorization_code",
        client_id = client_id,
        code = query.code,
        code_verifier = verifier,
        redirect_uri = redirect,
        resource = RESOURCE,
      }, function(response, network_err, received_at)
        if done then
          return
        end
        if network_err or not response or response.status ~= 200 then
          local failed = decode_response(response)
          local retry_command = ":SageChatGPTLogin" .. (opts.new_account and saved and "!" or "")
          local exchange_err = token_error(response)
          if failed and failed.error == "invalid_grant" then
            exchange_err = "ChatGPT authorization code was rejected. Retry sign-in with "
              .. retry_command
          end
          finish(false, network_err or exchange_err)
          return
        end
        local data = decode_response(response)
        local granted, validation_err = validate_tokens(data)
        if not granted or type(data.id_token) ~= "string" then
          finish(false, validation_err or "OpenAI did not return a verifiable ChatGPT identity")
          return
        end
        pending = request(JWKS, nil, function(keys_response, keys_err)
          if done then
            return
          end
          local payload = verify_identity(data.id_token, keys_response, {
            issuer = ISSUER,
            audience = client_id,
            nonce = nonce,
            subject = previous and previous.subject or nil,
            time = received_at,
          })
          if not payload then
            finish(false, keys_err or "OpenAI returned an invalid ChatGPT identity")
            return
          end
          local saved_ok, save_err = save_record(directory() .. "/credentials.json", {
            issuer = ISSUER,
            subject = payload.sub,
            email = type(payload.email) == "string" and payload.email or nil,
            client_id = client_id,
            ext_agent_host_id = host,
            access_token = data.access_token,
            refresh_token = data.refresh_token,
            id_token = data.id_token,
            token_type = "Bearer",
            expires_at = received_at + data.expires_in,
            scopes = granted,
          })
          if saved_ok and not previous then
            uv.fs_unlink(directory() .. "/pending_registration.json")
          end
          finish(saved_ok == true, save_err)
        end)
      end)
    end)
  end
  local function respond(peer, status, message)
    peer:read_stop()
    local body = "<!doctype html><title>ChatGPT sign-in</title><p>" .. message .. "</p>"
    peer:write(
      "HTTP/1.1 "
        .. status
        .. "\r\nContent-Type: text/html; charset=utf-8\r\n"
        .. "Connection: close\r\nCache-Control: no-store\r\nContent-Length: "
        .. #body
        .. "\r\n\r\n"
        .. body,
      function()
        attempt.peers[peer] = nil
        close(peer)
      end
    )
  end
  local listening = server:listen(16, function(accept_err)
    if accept_err or done then
      return
    end
    local peer = uv.new_tcp()
    if not server:accept(peer) then
      close(peer)
      return
    end
    attempt.peers[peer] = true
    local buffer = ""
    peer:read_start(function(err, chunk)
      if err or not chunk then
        attempt.peers[peer] = nil
        close(peer)
        return
      end
      buffer = buffer .. chunk
      if #buffer > 8192 then
        respond(peer, "400 Bad Request", "Invalid sign-in request.")
        return
      end
      if not buffer:find("\r\n\r\n", 1, true) then
        return
      end
      local target = buffer:match("^GET ([^ ]+) HTTP/1%.[01]\r\n")
      local query_string = target and target:match("^/auth/callback%?(.*)$")
      local query = query_string and parse_query(query_string)
      if not query or query.state ~= state or received then
        respond(peer, "400 Bad Request", "Invalid sign-in request.")
        return
      end
      if query.error then
        respond(peer, "200 OK", "Sign-in was not approved. Return to Neovim.")
        received = true
        vim.schedule(function()
          finish(false, "ChatGPT sign-in was not approved")
        end)
        return
      end
      local issued = query.client_id
      if
        not query.code
        or query.code == ""
        or (selected_client_id and issued and issued ~= selected_client_id)
        or (
          not selected_client_id
          and (not issued or issued == "" or issued == "dynamic_agent_client")
        )
      then
        respond(peer, "400 Bad Request", "Incomplete sign-in request.")
        return
      end
      received = true
      respond(peer, "200 OK", "Authorization received. Return to Neovim to finish connecting.")
      close(server)
      vim.schedule(function()
        if not done then
          exchange(query)
        end
      end)
    end)
  end)
  if not listening then
    finish(false, "Could not start the local ChatGPT sign-in callback")
    return handle
  end
  timer:start(
    options().login_timeout_ms or 180000,
    0,
    vim.schedule_wrap(function()
      finish(false, "ChatGPT sign-in timed out. Run :SageChatGPTLogin to try again")
    end)
  )
  local browser_ok, browser_job, browser_err =
    pcall(vim.ui.open, AUTHORIZE .. "?" .. form_encode(values))
  if not browser_ok or not browser_job or browser_err then
    finish(false, "Could not open the browser for ChatGPT sign-in")
  end
  return handle
end

---Cancel a pending browser sign-in without changing the saved connection.
function M.cancel_login()
  if login_attempt then
    login_attempt.cancel()
  end
end

---@param callback fun(ok: boolean, err: string|nil)
---@return SageRequestHandle
function M.logout(callback)
  vim.validate({ callback = { callback, "function" } })
  register_cleanup()
  if login_attempt then
    M.cancel_login()
  end
  local done = false
  local cancelled = false
  local pending
  local release_lock
  local lock_finished = false
  local lock_handle
  local complete_on_exit
  local function finish(ok, err)
    if done then
      return
    end
    done = true
    pending_logouts[complete_on_exit] = nil
    if release_lock then
      release_lock()
    end
    callback(ok, err)
  end
  complete_on_exit = function()
    cancelled = true
    if release_lock then
      finish(
        true,
        "Signed out locally; remote revocation was not confirmed. Disconnect the app in ChatGPT Settings"
      )
    elseif lock_handle and lock_handle.retry_on_exit then
      lock_handle.retry_on_exit()
    end
  end
  pending_logouts[complete_on_exit] = true
  lock_handle = acquire_lock(function(release, lock_err)
    lock_finished = true
    if not release then
      finish(false, lock_err)
      return
    end
    release_lock = release
    -- Explicit sign-out also removes abandoned atomic credential writes, which
    -- can contain an access/refresh token even when credentials.json is clear.
    local cleaned, cleanup_err = cleanup_orphaned_secrets(directory(), true)
    if not cleaned then
      finish(false, cleanup_err)
      return
    end
    local record, err = credentials()
    if not record then
      finish(not err, err)
      return
    end
    local staged_refresh = record.pending_refresh
    local refresh_token = type(staged_refresh) == "table"
        and type(staged_refresh.tokens) == "table"
        and staged_refresh.tokens.refresh_token
      or record.refresh_token
    record.pending_refresh = nil
    record.access_token = nil
    record.refresh_token = nil
    record.id_token = nil
    record.expires_at = nil
    record.scopes = {}
    local saved, save_err = save_record(directory() .. "/credentials.json", record)
    if not saved then
      finish(false, save_err)
      return
    end
    local function complete(revoked)
      finish(
        true,
        not revoked
            and "Signed out locally; remote revocation was not confirmed. Disconnect the app in ChatGPT Settings"
          or nil
      )
    end
    if not refresh_token then
      complete(true)
      return
    end
    if exiting then
      complete(false)
      return
    end
    pending = request(DISCOVERY, nil, function(response)
      local data = decode_response(response)
      local endpoint = data and data.revocation_endpoint
      if
        not response
        or response.status ~= 200
        or not data
        or data.issuer ~= ISSUER
        or type(endpoint) ~= "string"
        or not endpoint:match("^https://auth%.openai%.com/[%w%-%._~/]+$")
      then
        complete(false)
        return
      end
      local function revoke(attempt)
        pending = request(endpoint, {
          token = refresh_token,
          token_type_hint = "refresh_token",
          client_id = record.client_id,
        }, function(revoke_response)
          if done then
            return
          end
          if
            not cancelled
            and attempt < 3
            and (not revoke_response or revoke_response.status >= 500)
          then
            local timer = uv.new_timer()
            active_timers[timer] = true
            pending = {
              cancel = function()
                close(timer)
                complete(false)
              end,
            }
            timer:start(
              250 * 4 ^ (attempt - 1),
              0,
              vim.schedule_wrap(function()
                close(timer)
                revoke(attempt + 1)
              end)
            )
            return
          end
          complete(revoke_response ~= nil and revoke_response.status == 200)
        end)
      end
      if cancelled then
        complete(false)
      else
        revoke(1)
      end
    end)
  end, true)
  if not lock_finished then
    pending = lock_handle
  end
  return {
    cancel = function()
      -- Sign-out still clears local secrets when its network request is cancelled.
      cancelled = true
      if pending then
        pending.cancel()
      end
    end,
  }
end

return M
