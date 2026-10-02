describe("subscription API routing", function()
  local originals = {}
  local names = { "sage-llm.config", "plenary.curl", "sage-llm.chatgpt" }
  local options
  local calls
  local handle

  before_each(function()
    options = { provider = "chatgpt", model = "ChatGPT" }
    calls = {}
    handle = { cancel = function() end }
    for _, name in ipairs(names) do
      originals[name] = { preload = package.preload[name], loaded = package.loaded[name] }
      package.loaded[name] = nil
    end
    package.loaded["sage-llm.api"] = nil
    package.preload["sage-llm.config"] = function()
      return {
        options = options,
        get_api_key = function()
          error("Subscription requests must not read an OpenRouter key")
        end,
        is_local_provider = function()
          return false
        end,
      }
    end
    package.preload["plenary.curl"] = function()
      return {
        post = function()
          error("Subscription requests must not use chat completions or embeddings")
        end,
      }
    end
    package.preload["sage-llm.chatgpt"] = function()
      return {
        stream_chat = function(messages, callbacks, opts)
          calls.messages, calls.opts = messages, opts
          callbacks.on_error("ChatGPT usage limit reached")
          return handle
        end,
        chat = function(messages, callback, opts)
          calls.messages, calls.opts = messages, opts
          callback("replacement code", nil)
          return handle
        end,
      }
    end
  end)

  after_each(function()
    for _, name in ipairs(names) do
      package.preload[name] = originals[name].preload
      package.loaded[name] = originals[name].loaded
    end
    package.loaded["sage-llm.api"] = nil
  end)

  it("routes full follow-up history without an API key or billing fallback", function()
    local messages = {
      { role = "system", content = "Teach concisely" },
      { role = "user", content = "Explain this selection" },
      { role = "assistant", content = "It borrows the value" },
      { role = "user", content = "Why?" },
    }
    local error_message
    local result = require("sage-llm.api").stream_chat(messages, {
      on_error = function(err)
        error_message = err
      end,
    }, { search = false })
    assert.equals(handle, result)
    assert.same(messages, calls.messages)
    assert.same({ search = false }, calls.opts)
    assert.equals("ChatGPT usage limit reached", error_message)
  end)

  it("routes infill through the subscription provider", function()
    local messages = { { role = "user", content = "Replace the selection" } }
    local result_text
    local result = require("sage-llm.api").chat(messages, function(content, err)
      assert.is_nil(err)
      result_text = content
    end)
    assert.equals(handle, result)
    assert.equals("replacement code", result_text)
    assert.same(messages, calls.messages)
  end)

  it("rejects subscription embeddings before reading an API key", function()
    local error_message
    local result = require("sage-llm.api").embeddings(
      { "selection" },
      "embedding-model",
      function(_, err)
        error_message = err
      end
    )
    assert.is_nil(result)
    assert.matches("ChatGPT subscription embeddings/RAG are not supported", error_message, 1, true)
  end)
end)

describe("OpenRouter retry ownership", function()
  local originals = {}
  local names = { "sage-llm.config", "plenary.curl", "sage-llm.chatgpt", "sage-llm.api" }
  local options
  local requests
  local subscription_calls
  local callbacks_called
  local api
  local empty_response = {
    status = 200,
    body = 'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\ndata: [DONE]\n',
  }
  local messages = { { role = "user", content = "Explain this selection" } }

  local function callbacks()
    local function called()
      callbacks_called = callbacks_called + 1
    end
    return { on_token = called, on_error = called, on_complete = called }
  end

  before_each(function()
    for _, name in ipairs(names) do
      originals[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    options = {
      provider = "openrouter",
      model = "original-model",
      base_url = "https://original.example.test/v1",
      api_key = "synthetic-key",
    }
    requests = {}
    subscription_calls = 0
    callbacks_called = 0
    package.loaded["sage-llm.config"] = {
      options = options,
      get_api_key = function()
        return options.api_key
      end,
    }
    package.loaded["sage-llm.chatgpt"] = {
      chat = function()
        subscription_calls = subscription_calls + 1
        error("An OpenRouter retry must retain its original provider")
      end,
    }
    package.loaded["plenary.curl"] = {
      post = function(url, opts)
        local entry = { url = url, options = opts }
        requests[#requests + 1] = entry
        return {
          handle = {
            kill = function(_, signal)
              entry.signal = signal
            end,
          },
          shutdown = function()
            entry.cancelled = true
          end,
        }
      end,
    }
    api = require("sage-llm.api")
  end)

  after_each(function()
    vim.wait(20, function()
      return false
    end, 1)
    for _, name in ipairs(names) do
      package.loaded[name] = originals[name]
    end
  end)

  it("keeps retries on the original provider and cancels both transport handles", function()
    local handle = api.stream_chat(messages, callbacks(), { search = true })
    options.provider = "chatgpt"
    options.model = "ChatGPT"
    options.base_url = "https://changed.example.test/v1"
    options.api_key = "changed-key"
    requests[1].options.callback(empty_response)
    assert.is_true(vim.wait(500, function()
      return #requests == 2
    end, 1))
    local retry = requests[2]
    assert.equals(0, subscription_calls)
    assert.equals(requests[1].url, retry.url)
    assert.equals("Bearer synthetic-key", retry.options.headers.Authorization)
    local body = vim.json.decode(retry.options.body)
    assert.equals("original-model:online", body.model)
    assert.same(messages, body.messages)
    assert.is_false(body.stream)
    assert.equals(0, callbacks_called)
    handle.cancel()
    for _, request in ipairs(requests) do
      assert.is_true(request.cancelled)
      assert.equals("sigterm", request.signal)
    end
    retry.options.callback({
      status = 200,
      body = vim.json.encode({ choices = { { message = { content = "late reply" } } } }),
    })
    vim.wait(20, function()
      return false
    end, 1)
    assert.equals(0, callbacks_called)
  end)

  it("does not start a retry or deliver errors after queued completion is cancelled", function()
    local handle = api.stream_chat(messages, callbacks())
    requests[1].options.callback(empty_response)
    requests[1].options.on_error("queued error")
    handle.cancel()
    vim.wait(20, function()
      return false
    end, 1)
    assert.equals(1, #requests)
    assert.equals(0, callbacks_called)
  end)

  it("suppresses a retry completion queued before cancellation", function()
    local handle = api.stream_chat(messages, callbacks())
    requests[1].options.callback(empty_response)
    assert.is_true(vim.wait(500, function()
      return #requests == 2
    end, 1))
    requests[2].options.callback({
      status = 200,
      body = vim.json.encode({ choices = { { message = { content = "queued reply" } } } }),
    })
    requests[2].options.on_error("queued retry error")
    handle.cancel()
    vim.wait(20, function()
      return false
    end, 1)
    assert.equals(0, callbacks_called)
  end)
end)
