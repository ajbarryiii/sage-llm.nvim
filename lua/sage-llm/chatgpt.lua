local config = require("sage-llm.config")
local auth = require("sage-llm.chatgpt_auth")
local curl = require("plenary.curl")

local M = {}
local base_url = "https://api.openai.com/v1"
local uv = vim.uv or vim.loop
local active_requests = {}
local request_epoch = 0

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("sage_llm_chatgpt_requests", { clear = true }),
  callback = function()
    for state in pairs(active_requests) do
      state.handle.cancel()
    end
  end,
})

---@param handle table|nil
local function cancel_handle(handle)
  if type(handle) ~= "table" then
    return
  end
  if type(handle.cancel) == "function" then
    pcall(handle.cancel)
  elseif type(handle.shutdown) == "function" then
    if handle.is_shutdown then
      return
    end
    -- Plenary's shutdown closes pipes and the process handle without signalling
    -- the process. Stop curl before closing its handle to stop the HTTP request.
    if handle.handle and type(handle.handle.kill) == "function" then
      local ok, result = pcall(handle.handle.kill, handle.handle, "sigterm")
      if ok and result == 0 then
        -- Let Plenary reap the terminated process before closing its handle.
        return
      end
    end
    pcall(handle.shutdown, handle)
  end
end

---Each operation owns its callbacks and cancellation, including queued callbacks.
---@return table
local function new_request()
  local state = { cancelled = false, finished = false, handles = {}, epoch = request_epoch }
  function state.cleanup()
    active_requests[state] = nil
    if state.body_path then
      uv.fs_unlink(state.body_path)
      state.body_path = nil
    end
    if state.header_path then
      uv.fs_unlink(state.header_path)
      state.header_path = nil
    end
    if state.header_dir then
      uv.fs_rmdir(state.header_dir)
      state.header_dir = nil
    end
  end
  function state.track(handle)
    if state.cancelled or state.finished then
      cancel_handle(handle)
    elseif handle then
      table.insert(state.handles, handle)
    end
  end
  function state.stop_handles()
    for _, handle in ipairs(state.handles) do
      cancel_handle(handle)
    end
  end
  function state.is_current()
    return not state.cancelled and state.epoch == request_epoch
  end
  function state.deliver(callback, ...)
    if not callback then
      return
    end
    local args = { ... }
    local count = select("#", ...)
    vim.schedule(function()
      if state.is_current() then
        callback(unpack(args, 1, count))
      end
    end)
  end
  state.handle = {
    cancel = function()
      if state.cancelled then
        return
      end
      state.cancelled = true
      state.stop_handles()
      state.cleanup()
    end,
  }
  active_requests[state] = true
  return state
end

---Stop subscription operations and suppress callbacks already queued for delivery.
function M.cancel_all()
  request_epoch = request_epoch + 1
  for state in pairs(active_requests) do
    state.handle.cancel()
  end
end

---@param state table
---@param name string
---@param content string
---@return string|nil
local function write_private_file(state, name, content)
  local path = state.header_dir .. "/" .. name
  local fd = uv.fs_open(path, "wx", 384) -- 0600, in a mkdtemp directory (0700).
  if not fd then
    return nil
  end
  local written = uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  if written ~= #content then
    uv.fs_unlink(path)
    return nil
  end
  return path
end

---Keep the bearer credential out of curl's process arguments and debug output.
---@param state table
---@param token string
---@return boolean
local function prepare_credentials(state, token)
  if type(token) ~= "string" or token == "" or token:find("[\r\n]") then
    return false
  end
  state.header_dir = uv.fs_mkdtemp(uv.os_tmpdir() .. "/sage-llm-chatgpt-XXXXXX")
  if not state.header_dir then
    return false
  end
  state.header_path =
    write_private_file(state, "headers", "Authorization: Bearer " .. token .. "\n")
  return state.header_path ~= nil
end

---@return table<string, string>
local function headers()
  return {
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "sage-llm.nvim",
  }
end

---@return string[]
local function curl_args(state)
  local timeout = (config.options.chatgpt or {}).request_timeout_ms or 30000
  -- Plenary's timeout only covers synchronous calls. Bound asynchronous curl too,
  -- and do not follow redirects away from the documented OAuth resource.
  local args = {
    "-N",
    "--max-time",
    tostring(timeout / 1000),
    "--max-redirs",
    "0",
    "--header",
    "@" .. state.header_path,
  }
  if state.body_path then
    table.insert(args, "--data-binary")
    table.insert(args, "@" .. state.body_path)
  end
  return args
end

---@param body string|nil
---@return table|nil
local function decode(body)
  if type(body) ~= "string" or body == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, body)
  if ok and type(value) == "table" then
    return value
  end
end

---@param status number|nil
---@param data table|nil
---@return string
local function response_error(status, data)
  local err = type(data) == "table" and data.error
  local code = type(err) == "table" and err.code or (type(data) == "table" and data.code)
  if code == "subscription_sharing_usage_limit_exceeded" or status == 429 then
    return "ChatGPT plan usage limit reached. Check ChatGPT Settings > Usage before trying again."
  end
  if code == "subscription_sharing_user_not_eligible" then
    return "ChatGPT plan usage is unavailable for this account or workspace."
  end
  if code == "subscription_sharing_unsupported_capability" then
    return "The selected model or request is unsupported by ChatGPT plan usage. Choose a model with :SageModel."
  end
  if
    code == "subscription_sharing_usage_unavailable"
    or code == "subscription_sharing_user_unavailable"
    or status == 503
  then
    return "ChatGPT plan usage is temporarily unavailable. Try again later."
  end
  if code == "subscription_sharing_invalid_user" or status == 401 then
    return "ChatGPT authorization was not accepted. Sign in again with :SageChatGPTLogin."
  end
  if
    status == 403
    or code == "subscription_sharing_route_not_supported"
    or code == "chatpass_v2_scope_not_authorized"
    or code == "chatpass_v2_invalid_authorization_context"
  then
    return "ChatGPT plan usage is not permitted for this account, workspace, or region."
  end
  if status == 400 or status == 404 then
    return "ChatGPT rejected the model or request. Refresh the available models with :SageModel."
  end
  if status and status >= 500 then
    return "ChatGPT is temporarily unavailable. Try again later."
  end
  -- Never include untrusted server messages or curl stderr: they can contain
  -- account information, request content, or credentials.
  return "ChatGPT could not complete the request. Try again or check your ChatGPT connection."
end

---@param state table
---@param callback fun(models: table[]|nil, err: string|nil)
local function fetch_models(state, callback)
  local settled = false
  local function finish(models, err)
    if settled or state.cancelled then
      return
    end
    settled = true
    callback(models, err)
  end
  local ok, job = pcall(curl.get, base_url .. "/models", {
    headers = headers(),
    raw = curl_args(state),
    on_error = function()
      finish(
        nil,
        "Could not connect to ChatGPT to load models. Check your connection and try again."
      )
    end,
    callback = function(response)
      if state.cancelled or settled then
        return
      end
      local data = decode(response and response.body)
      if not response or response.status ~= 200 then
        finish(nil, response_error(response and response.status, data))
        return
      end
      if not data or type(data.models) ~= "table" or not vim.islist(data.models) then
        finish(nil, "ChatGPT returned an invalid model catalog. Try again later.")
        return
      end
      local models = {}
      local seen = {}
      for _, model in ipairs(data.models) do
        if
          type(model) == "table"
          and model.visibility == "list"
          and type(model.slug) == "string"
          and model.slug ~= ""
          and type(model.display_name) == "string"
          and model.display_name ~= ""
          and not seen[model.slug]
        then
          seen[model.slug] = true
          table.insert(models, { slug = model.slug, display_name = model.display_name })
        end
      end
      finish(models, nil)
    end,
  })
  if not ok then
    finish(nil, "Could not start the ChatGPT model request. Check that curl is installed.")
    return
  end
  state.track(job)
end

---Fetch the current account's model choices; never share a catalog across accounts.
---@param callback fun(models: table[]|nil, err: string|nil, is_current: fun(): boolean)
---@return SageRequestHandle
function M.list_models(callback)
  vim.validate({ callback = { callback, "function" } })
  local state = new_request()
  local function finish(models, err)
    if state.finished or state.cancelled then
      return
    end
    state.finished = true
    if err then
      state.stop_handles()
    end
    state.cleanup()
    state.deliver(callback, models, err, state.is_current)
  end
  state.track(auth.get_access_token(function(token, err)
    if state.cancelled or state.finished then
      return
    end
    if not token then
      finish(nil, err or "Sign in with :SageChatGPTLogin to connect your ChatGPT plan.")
      return
    end
    if not prepare_credentials(state, token) then
      finish(nil, "Could not securely prepare the ChatGPT request. Check your temporary directory.")
      return
    end
    fetch_models(state, finish)
  end))
  return state.handle
end

---@param messages table[]
---@return table
local function build_body(messages)
  local input = {}
  local instructions = {}
  for _, message in ipairs(messages) do
    vim.validate({ message = { message, "table" } })
    vim.validate({ role = { message.role, "string" }, content = { message.content, "string" } })
    if message.role == "system" or message.role == "developer" then
      table.insert(instructions, message.content)
    elseif message.role == "user" or message.role == "assistant" then
      table.insert(input, { role = message.role, content = message.content })
    else
      error("ChatGPT supports only system, developer, user, and assistant text messages")
    end
  end
  local body = { input = input, store = false, stream = true }
  if #instructions > 0 then
    body.instructions = table.concat(instructions, "\n\n")
  end
  return body
end

---@param response table|nil
---@return string
local function completed_text(response)
  local parts = {}
  if type(response) ~= "table" or type(response.output) ~= "table" then
    return ""
  end
  for _, item in ipairs(response.output) do
    if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
      for _, part in ipairs(item.content) do
        if type(part) == "table" and part.type == "output_text" and type(part.text) == "string" then
          table.insert(parts, part.text)
        end
      end
    end
  end
  return table.concat(parts, "")
end

---@param response table|nil
---@return string|nil
local function completed_refusal(response)
  local parts = {}
  local found = false
  if type(response) ~= "table" or type(response.output) ~= "table" then
    return nil
  end
  for _, item in ipairs(response.output) do
    if type(item) == "table" and item.type == "message" and type(item.content) == "table" then
      for _, part in ipairs(item.content) do
        if type(part) == "table" and part.type == "refusal" then
          found = true
          table.insert(parts, type(part.refusal) == "string" and part.refusal or "")
        end
      end
    end
  end
  return found and table.concat(parts, "\n") or nil
end

local function refusal_message(text)
  -- Model refusal explanations are display content, unlike untrusted transport
  -- errors. Normalize controls/newlines for the response window's error line.
  local explanation = vim.trim(text:gsub("%c", " ")):gsub("%s+", " ")
  return explanation == "" and "ChatGPT declined this request."
    or "ChatGPT declined this request: " .. explanation
end

---Stream text using the OAuth grant for the user's ChatGPT plan.
---@param messages table[]
---@param callbacks SageStreamCallbacks
---@param request_opts {search: boolean}|nil
---@return SageRequestHandle
function M.stream_chat(messages, callbacks, request_opts)
  vim.validate({ messages = { messages, "table" }, callbacks = { callbacks, "table" } })
  local body = build_body(messages)
  local state = new_request()
  local function finish(err)
    if state.finished or state.cancelled then
      return
    end
    state.finished = true
    if err then
      state.stop_handles()
    end
    state.cleanup()
    if err then
      state.deliver(callbacks.on_error, err)
    else
      state.deliver(callbacks.on_complete)
    end
  end
  if callbacks.on_start then
    callbacks.on_start()
  end
  if request_opts and request_opts.search then
    finish("Web search is unavailable with the ChatGPT provider.")
    return state.handle
  end

  local function start_stream(model)
    if state.cancelled or state.finished then
      return
    end
    body.model = model
    state.body_path = write_private_file(state, "body", vim.json.encode(body))
    if not state.body_path then
      finish("Could not securely prepare the ChatGPT request. Check your temporary directory.")
      return
    end
    local text_parts = {}
    local refusal_parts = {}
    local refusal_order = {}
    local refusal_seen = false
    local function record_refusal(data, text, append)
      local key = tostring(data.item_id or data.output_index or "")
        .. ":"
        .. tostring(data.content_index or 0)
      if refusal_parts[key] == nil then
        table.insert(refusal_order, key)
      end
      refusal_parts[key] = append and ((refusal_parts[key] or "") .. text) or text
      refusal_seen = true
    end
    local completed = false
    local pending_data = {}
    local function event(data)
      if state.cancelled or state.finished then
        return
      end
      if data.type == "response.failed" then
        finish(response_error(nil, data.response))
      elseif data.type == "response.incomplete" then
        finish("ChatGPT returned an incomplete response. Try again or choose another model.")
      elseif data.type == "error" or data.error then
        finish(response_error(nil, data))
      elseif data.type == "response.completed" then
        if type(data.response) ~= "table" or data.response.status ~= "completed" then
          finish("ChatGPT returned an invalid completion event. Try again later.")
          return
        end
        completed = true
        local refusal = completed_refusal(data.response)
        if refusal ~= nil then
          refusal_seen = true
          refusal_parts = { completed = refusal }
          refusal_order = { "completed" }
        end
        if not refusal_seen and #text_parts == 0 then
          local text = completed_text(data.response)
          if text ~= "" then
            table.insert(text_parts, text)
            state.deliver(callbacks.on_token, text)
          end
        end
      elseif data.type == "response.refusal.delta" and not completed then
        if type(data.delta) ~= "string" then
          finish("ChatGPT returned an invalid refusal event. Try again later.")
          return
        end
        record_refusal(data, data.delta, true)
      elseif data.type == "response.refusal.done" and not completed then
        if type(data.refusal) ~= "string" then
          finish("ChatGPT returned an invalid refusal event. Try again later.")
          return
        end
        record_refusal(data, data.refusal, false)
      elseif data.type == "response.output_text.delta" and not completed then
        if type(data.delta) ~= "string" then
          finish("ChatGPT returned invalid response text. Try again later.")
          return
        end
        if data.delta ~= "" then
          table.insert(text_parts, data.delta)
          state.deliver(callbacks.on_token, data.delta)
        end
      end
    end
    local function flush_data()
      if #pending_data == 0 then
        return
      end
      local data = decode(table.concat(pending_data, "\n"))
      pending_data = {}
      if data then
        event(data)
      else
        finish("ChatGPT returned an invalid response event. Try again later.")
      end
    end
    local ok, job = pcall(curl.post, base_url .. "/responses", {
      headers = headers(),
      raw = curl_args(state),
      -- Plenary delivers individual lines with their newlines already stripped.
      stream = function(err, line)
        if state.cancelled or state.finished then
          return
        end
        if err then
          finish("The ChatGPT connection was interrupted. Check your connection and try again.")
          return
        end
        line = (line or ""):gsub("\r$", "")
        if line == "" then
          flush_data()
          return
        end
        if line:sub(1, 5) ~= "data:" then
          return
        end
        local payload = line:sub(6):gsub("^ ", "")
        if payload == "[DONE]" then
          flush_data()
          return
        end
        if #pending_data > 0 then
          table.insert(pending_data, payload)
          return
        end
        local data = decode(payload)
        if data then
          event(data)
        else
          table.insert(pending_data, payload)
        end
      end,
      on_error = function()
        finish("The ChatGPT connection was interrupted. Check your connection and try again.")
      end,
      callback = function(response)
        if state.cancelled or state.finished then
          return
        end
        if not response or response.status ~= 200 then
          finish(response_error(response and response.status, decode(response and response.body)))
          return
        end
        flush_data()
        if state.finished then
          return
        end
        if not completed then
          finish("The ChatGPT stream ended before completion. Try again.")
        elseif refusal_seen then
          local explanations = {}
          for _, key in ipairs(refusal_order) do
            table.insert(explanations, refusal_parts[key])
          end
          finish(refusal_message(table.concat(explanations, "\n")))
        elseif not table.concat(text_parts, ""):find("%S") then
          finish(
            "ChatGPT completed the request without an answer. Try again or choose another model."
          )
        else
          finish(nil)
        end
      end,
    })
    if not ok then
      finish("Could not start the ChatGPT request. Check that curl is installed.")
      return
    end
    state.track(job)
  end

  state.track(auth.get_access_token(function(token, err)
    if state.cancelled or state.finished then
      return
    end
    if not token then
      finish(err or "Sign in with :SageChatGPTLogin to connect your ChatGPT plan.")
      return
    end
    if not prepare_credentials(state, token) then
      finish("Could not securely prepare the ChatGPT request. Check your temporary directory.")
      return
    end
    local model = (config.options.chatgpt or {}).model
    if type(model) == "string" and model ~= "" then
      start_stream(model)
      return
    end
    fetch_models(state, function(models, model_err)
      if not models or not models[1] then
        finish(model_err or "No models are available for this ChatGPT account.")
        return
      end
      start_stream(models[1].slug)
    end)
  end))
  return state.handle
end

---Collect the required stream for callers that need a complete response.
---@param messages table[]
---@param callback fun(text: string|nil, err: string|nil)
---@param request_opts {search: boolean}|nil
---@return SageRequestHandle
function M.chat(messages, callback, request_opts)
  vim.validate({ callback = { callback, "function" } })
  local parts = {}
  return M.stream_chat(messages, {
    on_token = function(token)
      table.insert(parts, token)
    end,
    on_complete = function()
      callback(table.concat(parts, ""), nil)
    end,
    on_error = function(err)
      callback(nil, err)
    end,
  }, request_opts)
end

return M
