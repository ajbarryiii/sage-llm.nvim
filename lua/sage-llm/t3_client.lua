local M = {}
local uv = vim.uv or vim.loop

---@class SageT3Callbacks
---@field on_update fun(text: string) Complete current reply snapshot
---@field on_complete fun(text: string) Authoritative final reply
---@field on_error fun(err: string)

local function spawn(connection, args, message, timeout_ms, callback)
  local command = { connection.command, "thread" }
  vim.list_extend(command, args)
  if connection.base_dir then
    vim.list_extend(command, { "--base-dir", connection.base_dir })
  end
  local ok, process = pcall(vim.system, command, {
    cwd = connection.cwd,
    env = connection.env,
    stdin = message,
    text = true,
    timeout = timeout_ms,
  }, vim.schedule_wrap(callback))
  if not ok then
    callback({ code = -1, signal = 0, stdout = "" })
    return nil
  end
  return process
end

local function decode(result)
  local ok, value = pcall(vim.json.decode, result.stdout)
  return ok and value or nil
end

---List threads through T3's public host CLI.
---@param connection SageT3Connection
---@param callback fun(result: any, err: string|nil)
function M.list(connection, callback)
  return spawn(
    connection,
    { "list", "--project", connection.project, "--json" },
    nil,
    connection.timeout_ms,
    function(result)
      if result.code ~= 0 or result.signal ~= 0 then
        callback(nil)
        return
      end
      local value = decode(result)
      callback(value, value == nil and "unexpected" or nil)
    end
  )
end

local function kill(process)
  if process then
    pcall(function()
      process:kill(15)
    end)
  end
end

---Mirror partial text while the CLI waits for this exact submitted turn.
---The CLI has no token-event command: show supplies snapshots, and send --wait
---provides authoritative completion, including restarts and pending approvals.
---@param connection SageT3Connection
---@param thread_id string
---@param message string
---@param callbacks SageT3Callbacks
---@return {cancel: function}
function M.stream(connection, thread_id, message, callbacks)
  local settled = false
  local waiter, reader, timer
  local run_id, previous_text

  local function stop()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
    kill(waiter)
    kill(reader)
    waiter, reader = nil, nil
  end

  local handle = {
    cancel = function()
      if settled then
        return
      end
      settled = true
      stop()
    end,
  }

  local function fail(err)
    if settled then
      return
    end
    settled = true
    stop()
    callbacks.on_error(err)
  end

  -- A unique tag distinguishes concurrent identical questions. Match the exact
  -- user message first, then only assistant messages belonging to that run.
  local ok, bytes = pcall(uv.random, 16)
  if not ok or type(bytes) ~= "string" then
    fail("Could not create a T3 request identifier.")
    return handle
  end
  local tag = bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end)
  message = "Sage request: " .. tag .. "\n" .. message

  local function update(value)
    if
      type(value) ~= "table"
      or type(value.thread) ~= "table"
      or value.thread.threadId ~= thread_id
      or type(value.messages) ~= "table"
      or not vim.islist(value.messages)
    then
      return
    end
    if not run_id then
      for _, entry in ipairs(value.messages) do
        if
          type(entry) == "table"
          and entry.role == "user"
          and entry.text == message
          and type(entry.runId) == "string"
        then
          run_id = entry.runId
          break
        end
      end
    end
    if not run_id then
      return
    end
    local parts = {}
    for _, entry in ipairs(value.messages) do
      if
        type(entry) == "table"
        and entry.role == "assistant"
        and entry.runId == run_id
        and type(entry.text) == "string"
        and entry.text ~= ""
      then
        parts[#parts + 1] = entry.text
      end
    end
    local text = table.concat(parts, "\n\n")
    if text ~= "" and text ~= previous_text then
      previous_text = text
      callbacks.on_update(text)
    end
  end

  local poll
  local function schedule_read()
    if settled then
      return
    end
    timer = vim.defer_fn(function()
      timer = nil
      poll()
    end, connection.poll_interval_ms)
  end
  poll = function()
    if settled then
      return
    end
    reader = spawn(
      connection,
      { "show", thread_id, "--messages", "1000", "--json" },
      nil,
      connection.timeout_ms,
      function(result)
        reader = nil
        if settled then
          return
        end
        if result.code == 0 and result.signal == 0 then
          update(decode(result))
        end
        -- Snapshot failures are read-only and do not replace the authoritative
        -- waiter. Only one read is in flight, bounded by its own timeout.
        schedule_read()
      end
    )
  end

  waiter = spawn(
    connection,
    { "send", thread_id, "-", "--wait", "--json" },
    message,
    connection.response_timeout_ms,
    function(result)
      waiter = nil
      if settled then
        return
      end
      local value = decode(result)
      if
        type(value) == "table"
        and value.threadId == thread_id
        and type(value.runId) == "string"
        and result.signal == 0
      then
        if
          result.code == 0
          and value.status == "completed"
          and type(value.reply) == "string"
          and value.reply ~= ""
        then
          settled = true
          stop()
          callbacks.on_complete(value.reply)
          return
        end
        if result.code == 2 and value.status == "waiting" then
          fail("T3 needs input or approval. Open the thread in T3 Code to respond.")
          return
        end
        if
          result.code == 1
          and vim.tbl_contains(
            { "failed", "cancelled", "interrupted", "rolled_back" },
            value.status
          )
        then
          fail("T3 turn " .. value.status .. ". Open the thread in T3 Code for details.")
          return
        end
        if
          result.code == 0
          and value.status == "completed"
          and (value.reply == vim.NIL or value.reply == "")
        then
          fail("T3 completed without a text reply. Open the thread in T3 Code for details.")
          return
        end
      end
      fail(
        "T3 reply could not be confirmed. Check the thread before retrying; it may still be running."
      )
    end
  )
  schedule_read()
  return handle
end

return M
