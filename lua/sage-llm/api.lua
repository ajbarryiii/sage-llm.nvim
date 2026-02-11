local config = require("sage-llm.config")
local curl = require("plenary.curl")

local M = {}

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
  -- SSE format: "data: {...}"
  if line:sub(1, 6) == "data: " then
    local data = line:sub(7)
    -- Handle [DONE] sentinel
    if data == "[DONE]" then
      return nil
    end
    return data
  end
  return nil
end

---Extract content delta from OpenRouter streaming response
---@param json_str string
---@return string|nil token
local function extract_token(json_str)
  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or not data then
    return nil
  end

  -- OpenRouter streaming format matches OpenAI
  if data.choices and data.choices[1] then
    local delta = data.choices[1].delta
    if delta and delta.content then
      return delta.content
    end
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

  -- Track partial lines for SSE parsing
  local buffer = ""

  if callbacks.on_start then
    callbacks.on_start()
  end

  local job = curl.post(url, {
    headers = {
      ["Authorization"] = "Bearer " .. api_key,
      ["Content-Type"] = "application/json",
      ["HTTP-Referer"] = "https://github.com/sage-llm/sage-llm.nvim",
      ["X-Title"] = "sage-llm.nvim",
    },
    body = body,
    stream = function(_, chunk)
      if cancelled then
        return
      end

      -- Accumulate chunks and process complete lines
      buffer = buffer .. chunk

      -- Process complete lines
      while true do
        local newline_pos = buffer:find("\n")
        if not newline_pos then
          break
        end

        local line = buffer:sub(1, newline_pos - 1)
        buffer = buffer:sub(newline_pos + 1)

        -- Skip empty lines (SSE format uses them as separators)
        if line ~= "" and line ~= "\r" then
          -- Remove trailing \r if present
          line = line:gsub("\r$", "")

          local data = parse_sse_line(line)
          if data then
            local token = extract_token(data)
            if token then
              -- Schedule callback on main thread
              vim.schedule(function()
                if not cancelled then
                  callbacks.on_token(token)
                end
              end)
            end
          end
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
      if cancelled then
        return
      end

      vim.schedule(function()
        vim.notify("DEBUG api.lua: inside vim.schedule", vim.log.levels.INFO)
        vim.notify(
          "DEBUG api.lua: response=" .. tostring(response ~= nil) .. ", status=" .. tostring(response and response.status or "nil"),
          vim.log.levels.INFO
        )

        if not response then
          vim.notify("DEBUG api.lua: response is nil!", vim.log.levels.ERROR)
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
          vim.notify("DEBUG api.lua: calling callback with error: " .. err_msg, vim.log.levels.INFO)
          callback(nil, err_msg)
          return
        end

        vim.notify("DEBUG api.lua: body length=" .. tostring(response.body and #response.body or "nil"), vim.log.levels.INFO)

        local ok, data = pcall(vim.json.decode, response.body)
        vim.notify("DEBUG api.lua: json decode ok=" .. tostring(ok), vim.log.levels.INFO)

        if not ok then
          vim.notify("DEBUG api.lua: json error: " .. tostring(data), vim.log.levels.ERROR)
          callback(nil, "Failed to parse response")
          return
        end

        if data.choices and data.choices[1] and data.choices[1].message then
          local content = data.choices[1].message.content
          vim.notify(
            "DEBUG api.lua: content length=" .. tostring(content and #content or "nil"),
            vim.log.levels.INFO
          )
          callback(content, nil)
        else
          vim.notify("DEBUG api.lua: unexpected format: " .. vim.inspect(data):sub(1, 200), vim.log.levels.INFO)
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
