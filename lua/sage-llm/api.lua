local config = require("sage-llm.config")
local curl = require("plenary.curl")

local M = {}

-- Debug helper that works in fast event context
local function debug_log(msg)
  if not config.options.debug then
    return
  end
  local f = io.open("/tmp/sage-llm-debug.log", "a")
  if f then
    f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
    f:close()
  end
end

---@class SageStreamCallbacks
---@field on_start function|nil Called when streaming starts
---@field on_token function Called with each token: function(token: string)
---@field on_complete function|nil Called when streaming completes
---@field on_error function|nil Called on error: function(err: string)

---@class SageRequestHandle
---@field cancel function Cancel the in-flight request

---Parse a Server-Sent Events line
---@param line string
---@return string|nil event_data
local function parse_sse_line(line)
  if line == "" then
    return nil
  end

  -- Ignore comments/keepalive lines
  if line:sub(1, 1) == ":" then
    return nil
  end

  -- SSE format: "data: {...}" or "data:{...}"
  local data = nil
  if line:sub(1, 6) == "data: " then
    data = line:sub(7)
  elseif line:sub(1, 5) == "data:" then
    data = line:sub(6)
  else
    return nil
  end

  -- Handle [DONE] sentinel
  if data == "[DONE]" then
    return nil
  end

  return data
end

---Extract content delta from OpenRouter streaming response
---@param json_str string
---@return string|nil token
local function extract_token(json_str)
  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or not data then
    return nil
  end

  if not data.choices or not data.choices[1] then
    return nil
  end

  local choice = data.choices[1]
  local delta = choice.delta

  if delta then
    if delta.content then
      if type(delta.content) == "string" then
        return delta.content
      end
      if type(delta.content) == "table" then
        local parts = {}
        for _, item in ipairs(delta.content) do
          if type(item) == "table" and item.type == "text" and item.text then
            table.insert(parts, item.text)
          end
        end
        if #parts > 0 then
          return table.concat(parts, "")
        end
      end
    end

    if delta.text and type(delta.text) == "string" then
      return delta.text
    end
  end

  if choice.message and type(choice.message.content) == "string" then
    return choice.message.content
  end

  return nil
end

---Extract message content from a non-streaming response
---@param data table
---@return string|nil content
local function extract_message_content(data)
  if not data or not data.choices or not data.choices[1] then
    return nil
  end

  local choice = data.choices[1]
  if choice.message and type(choice.message.content) == "string" then
    return choice.message.content
  end

  return nil
end

---Make a streaming chat completion request
---@param messages table[] Array of {role, content} messages
---@param callbacks SageStreamCallbacks
---@return SageRequestHandle|nil handle, string|nil error
function M.stream_chat(messages, callbacks)
  local api_key = config.get_api_key()
  if not api_key then
    if callbacks.on_error then
      callbacks.on_error(
        "No API key found. Set $OPENROUTER_API_KEY or configure api_key in setup()"
      )
    end
    return nil, "No API key"
  end

  local url = config.options.base_url .. "/chat/completions"

  local body = vim.json.encode({
    model = config.options.model,
    messages = messages,
    stream = true,
  })

  local cancelled = false

  local token_count = 0
  local content_length = 0 -- total characters of actual content received
  local debug_line_count = 0

  if callbacks.on_start then
    callbacks.on_start()
  end

  if config.options.debug then
    vim.schedule(function()
      vim.notify("sage-llm: stream_chat started", vim.log.levels.INFO)
    end)
  end

  debug_log("stream_chat started, model=" .. config.options.model)

  local job = curl.post(url, {
    headers = {
      ["Authorization"] = "Bearer " .. api_key,
      ["Content-Type"] = "application/json",
      ["HTTP-Referer"] = "https://github.com/sage-llm/sage-llm.nvim",
      ["X-Title"] = "sage-llm.nvim",
    },
    body = body,
    raw = { "-N" }, -- Disable output buffering for real-time streaming
    -- NOTE: plenary.curl maps `stream` to plenary.Job's `on_stdout`, which
    -- delivers data as individual lines with newlines already stripped.
    -- Each `chunk` is a single line, NOT a raw byte buffer.
    stream = function(_, chunk)
      if cancelled then
        return
      end

      -- plenary.Job's on_stdout strips newlines, so each chunk is a single line
      local line = chunk or ""

      -- Skip empty lines (SSE format uses them as separators)
      if line == "" or line == "\r" then
        return
      end

      -- Remove trailing \r if present
      line = line:gsub("\r$", "")

      if debug_line_count < 10 then
        debug_log("stream line[" .. debug_line_count .. "]=" .. line:sub(1, 200))
        debug_line_count = debug_line_count + 1
      end

      local data = parse_sse_line(line)
      if data then
        local token = extract_token(data)
        if token then
          token_count = token_count + 1
          content_length = content_length + #token
          if token_count <= 3 then
            debug_log("token[" .. token_count .. "] len=" .. #token .. " =" .. token:sub(1, 50))
          end
          -- Only deliver non-empty tokens to the UI
          if #token > 0 then
            -- Schedule callback on main thread
            vim.schedule(function()
              if not cancelled then
                callbacks.on_token(token)
              end
            end)
          end
        else
          debug_log("extract_token returned nil for data=" .. data:sub(1, 200))
        end
      end
    end,
    on_error = function(err)
      if cancelled then
        return
      end
      vim.schedule(function()
        if callbacks.on_error then
          callbacks.on_error("Network error: " .. vim.inspect(err))
        end
      end)
    end,
    callback = function(response)
      if cancelled then
        return
      end

      vim.schedule(function()
        debug_log("stream callback fired")
        if not response then
          if callbacks.on_error then
            callbacks.on_error("No response received")
          end
          return
        end

        debug_log("stream callback status=" .. tostring(response.status))
        debug_log("stream token_count=" .. tostring(token_count) .. " content_length=" .. tostring(content_length))
        debug_log("stream response.body length=" .. tostring(response.body and #response.body or "nil"))

        -- Check for HTTP errors
        if response.status ~= 200 then
          if callbacks.on_error then
            local err_msg = "API error (HTTP " .. response.status .. ")"
            -- Try to parse error message from body
            if response.body then
              local ok, err_data = pcall(vim.json.decode, response.body)
              if ok and err_data and err_data.error then
                err_msg = err_msg .. ": " .. (err_data.error.message or vim.inspect(err_data.error))
              end
            end
            callbacks.on_error(err_msg)
          end
          return
        end

        -- Fallback: if streaming produced no meaningful content but we got a body,
        -- try to parse it as a non-streaming JSON response.
        -- This handles:
        --   1. Servers that return a complete response despite stream=true
        --   2. Models that send empty-delta SSE chunks (e.g. GPT-OSS-20B sends
        --      role-only deltas with no content, then the full response in the body)
        if content_length == 0 and response.body and response.body ~= "" then
          debug_log("stream fallback: content_length=0 (token_count=" .. token_count
            .. "), body length=" .. #response.body
            .. ", starts with: " .. response.body:sub(1, 100))
          -- Strategy 1: try parsing body as a single JSON response
          -- (server returned non-streaming response despite stream=true)
          local ok, data = pcall(vim.json.decode, response.body)
          if ok then
            local content = extract_message_content(data)
            if content and callbacks.on_token then
              debug_log("stream fallback: extracted from JSON body, length=" .. #content)
              callbacks.on_token(content)
            elseif callbacks.on_error then
              callbacks.on_error("Received response but could not extract content")
            end
          else
            -- Strategy 2: body is SSE lines (e.g. model sent empty deltas
            -- during streaming but has content in the final chunk).
            -- Re-parse the SSE lines from the body to extract any content.
            debug_log("stream fallback: trying SSE re-parse of body")
            local collected = {}
            for body_line in response.body:gmatch("[^\n]+") do
              body_line = body_line:gsub("\r$", "")
              local sse_data = parse_sse_line(body_line)
              if sse_data then
                -- Try as streaming delta
                local t = extract_token(sse_data)
                if t and #t > 0 then
                  table.insert(collected, t)
                else
                  -- Try as complete message
                  local msg_ok, msg_data = pcall(vim.json.decode, sse_data)
                  if msg_ok then
                    local msg_content = extract_message_content(msg_data)
                    if msg_content and #msg_content > 0 then
                      table.insert(collected, msg_content)
                    end
                  end
                end
              end
            end
            if #collected > 0 then
              local full_content = table.concat(collected, "")
              debug_log("stream fallback: extracted from SSE re-parse, length=" .. #full_content)
              if callbacks.on_token then
                callbacks.on_token(full_content)
              end
            else
              debug_log("stream fallback: no content found in body")
              if callbacks.on_error then
                callbacks.on_error("No content received from model. It may not support streaming.")
              end
            end
          end
        end

        if callbacks.on_complete then
          callbacks.on_complete()
        end
      end)
    end,
  })

  ---@type SageRequestHandle
  return {
    cancel = function()
      cancelled = true
      if job and job.shutdown then
        job:shutdown()
      end
    end,
  },
    nil
end

---Make a non-streaming chat completion request (for simpler use cases)
---@param messages table[] Array of {role, content} messages
---@param callback function Called with (response_text, error)
---@return SageRequestHandle|nil
function M.chat(messages, callback)
  local api_key = config.get_api_key()
  if not api_key then
    callback(nil, "No API key found. Set $OPENROUTER_API_KEY or configure api_key in setup()")
    return nil
  end

  local url = config.options.base_url .. "/chat/completions"

  local body = vim.json.encode({
    model = config.options.model,
    messages = messages,
    stream = false,
  })

  local cancelled = false

  local job = curl.post(url, {
    headers = {
      ["Authorization"] = "Bearer " .. api_key,
      ["Content-Type"] = "application/json",
      ["HTTP-Referer"] = "https://github.com/sage-llm/sage-llm.nvim",
      ["X-Title"] = "sage-llm.nvim",
    },
    body = body,
    on_error = function(err)
      if cancelled then
        return
      end
      vim.schedule(function()
        callback(nil, "Network error: " .. vim.inspect(err))
      end)
    end,
    callback = function(response)
      debug_log("callback fired, cancelled=" .. tostring(cancelled))
      
      if cancelled then
        return
      end

      debug_log("response exists=" .. tostring(response ~= nil))
      if response then
        debug_log("response.status=" .. tostring(response.status))
        debug_log("response.body length=" .. tostring(response.body and #response.body or "nil"))
        debug_log("response.body first 500 chars=" .. tostring(response.body and response.body:sub(1, 500) or "nil"))
      end

      vim.schedule(function()
        debug_log("inside vim.schedule")

        if not response then
          debug_log("response is nil!")
          callback(nil, "No response received")
          return
        end

        if response.status ~= 200 then
          local err_msg = "API error (HTTP " .. tostring(response.status) .. ")"
          if response.body then
            local ok, err_data = pcall(vim.json.decode, response.body)
            if ok and err_data and err_data.error then
              err_msg = err_msg .. ": " .. (err_data.error.message or vim.inspect(err_data.error))
            end
          end
          debug_log("error: " .. err_msg)
          callback(nil, err_msg)
          return
        end

        local ok, data = pcall(vim.json.decode, response.body)
        debug_log("json decode ok=" .. tostring(ok))

        if not ok then
          debug_log("json error: " .. tostring(data))
          callback(nil, "Failed to parse response")
          return
        end

        if data.choices and data.choices[1] and data.choices[1].message then
          local content = data.choices[1].message.content
          debug_log("content length=" .. tostring(content and #content or "nil"))
          callback(content, nil)
        else
          debug_log("unexpected format")
          callback(nil, "Unexpected response format")
        end
      end)
    end,
  })

  return {
    cancel = function()
      cancelled = true
      if job and job.shutdown then
        job:shutdown()
      end
    end,
  }
end

return M
