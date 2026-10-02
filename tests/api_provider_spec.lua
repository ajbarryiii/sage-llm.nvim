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
