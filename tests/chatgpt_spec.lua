describe("ChatGPT subscription provider", function()
  local provider
  local options
  local requests
  local scheduled
  local originals
  local auth_callback
  local auth_cancelled
  local defer_auth
  local auth_error
  local account_current
  local modules = { "sage-llm.config", "sage-llm.chatgpt_auth", "plenary.curl", "sage-llm.chatgpt" }

  local function flush()
    while #scheduled > 0 do
      local callback = table.remove(scheduled, 1)
      callback()
    end
  end

  local function request(method, url, opts)
    local item = { method = method, url = url, opts = opts, cancelled = false }
    for index, arg in ipairs(opts.raw) do
      if arg == "--header" then
        item.header_path = opts.raw[index + 1]:sub(2)
      elseif arg == "--data-binary" then
        item.body_path = opts.raw[index + 1]:sub(2)
      end
    end
    item.header_dir = vim.fn.fnamemodify(item.header_path, ":h")
    local file = assert(io.open(item.header_path, "r"))
    item.authorization = file:read("*a")
    file:close()
    item.header_mode = vim.uv.fs_stat(item.header_path).mode % 512
    item.directory_mode = vim.uv.fs_stat(item.header_dir).mode % 512
    if item.body_path then
      local body_file = assert(io.open(item.body_path, "r"))
      item.body = body_file:read("*a")
      body_file:close()
      item.body_mode = vim.uv.fs_stat(item.body_path).mode % 512
    end
    table.insert(requests, item)
    return {
      handle = {
        kill = function(_, signal)
          item.signal = signal
        end,
      },
      shutdown = function()
        item.cancelled = true
      end,
    }
  end

  local function emit(item, data)
    item.opts.stream(nil, "event: " .. data.type)
    item.opts.stream(nil, "data: " .. vim.json.encode(data))
    item.opts.stream(nil, "")
  end

  local function complete(item, text)
    if text then
      emit(item, { type = "response.output_text.delta", delta = text })
    end
    emit(item, { type = "response.completed", response = { status = "completed" } })
    item.opts.callback({ status = 200, body = "" })
    flush()
  end

  local function observe()
    local result = { starts = 0, tokens = {}, completions = 0, errors = {} }
    local callbacks = {
      on_start = function()
        result.starts = result.starts + 1
      end,
      on_token = function(token)
        table.insert(result.tokens, token)
      end,
      on_complete = function()
        result.completions = result.completions + 1
      end,
      on_error = function(err)
        table.insert(result.errors, err)
      end,
    }
    return result, callbacks
  end

  before_each(function()
    options = {
      model = "openrouter/unrelated-model",
      chatgpt = { model = "account-model", request_timeout_ms = 12345 },
    }
    requests = {}
    scheduled = {}
    auth_callback = nil
    auth_cancelled = false
    defer_auth = false
    auth_error = nil
    account_current = true
    originals = { schedule = vim.schedule, loaded = {}, preload = {} }
    for _, name in ipairs(modules) do
      originals.loaded[name] = package.loaded[name]
      originals.preload[name] = package.preload[name]
      package.loaded[name] = nil
    end
    vim.schedule = function(callback)
      table.insert(scheduled, callback)
    end
    package.preload["sage-llm.config"] = function()
      return { options = options }
    end
    package.preload["sage-llm.chatgpt_auth"] = function()
      return {
        get_access_token = function(callback)
          auth_callback = callback
          if not defer_auth then
            if auth_error then
              callback(nil, auth_error)
            else
              callback("synthetic-test-access-token", nil, function()
                return account_current
              end)
            end
          end
          return {
            cancel = function()
              auth_cancelled = true
            end,
          }
        end,
      }
    end
    package.preload["plenary.curl"] = function()
      return {
        get = function(url, opts)
          return request("GET", url, opts)
        end,
        post = function(url, opts)
          return request("POST", url, opts)
        end,
      }
    end
    provider = require("sage-llm.chatgpt")
  end)

  after_each(function()
    -- Also remove fixture header files from requests that the test left open.
    for _, item in ipairs(requests) do
      if item.body_path then
        vim.uv.fs_unlink(item.body_path)
      end
      vim.uv.fs_unlink(item.header_path)
      vim.uv.fs_rmdir(item.header_dir)
    end
    for _, name in ipairs(modules) do
      package.loaded[name] = originals.loaded[name]
      package.preload[name] = originals.preload[name]
    end
    vim.schedule = originals.schedule
  end)

  it("uses the Responses contract and carries all follow-up history", function()
    local result, callbacks = observe()
    provider.stream_chat({
      { role = "system", content = "Explain concisely" },
      { role = "developer", content = "Use plain text" },
      { role = "user", content = "Selected code" },
      { role = "assistant", content = "First explanation" },
      { role = "user", content = "Why?" },
    }, callbacks)
    assert.equals(1, result.starts)
    assert.equals(1, #requests)
    local item = requests[1]
    assert.equals("POST", item.method)
    assert.equals("https://api.openai.com/v1/responses", item.url)
    assert.same({
      model = "account-model",
      input = {
        { role = "user", content = "Selected code" },
        { role = "assistant", content = "First explanation" },
        { role = "user", content = "Why?" },
      },
      instructions = "Explain concisely\n\nUse plain text",
      stream = true,
      store = false,
    }, vim.json.decode(item.body))
    complete(item, "Because")
    assert.same({ "Because" }, result.tokens)
    assert.equals(1, result.completions)
    assert.same({}, result.errors)
  end)

  it("keeps credentials out of argv and removes protected files on completion", function()
    local _, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    local item = requests[1]
    assert.equals("Authorization: Bearer synthetic-test-access-token\n", item.authorization)
    assert.equals(384, item.header_mode)
    assert.equals(384, item.body_mode)
    assert.equals(448, item.directory_mode)
    assert.is_nil(item.opts.headers.Authorization)
    assert.is_nil(vim.inspect(item.opts):find("synthetic-test-access-token", 1, true))
    assert.equals("--max-time", item.opts.raw[2])
    assert.equals("12.345", item.opts.raw[3])
    assert.equals("--max-redirs", item.opts.raw[4])
    assert.equals("0", item.opts.raw[5])
    complete(item, "Hello")
    assert.is_nil(vim.uv.fs_stat(item.header_path))
    assert.is_nil(vim.uv.fs_stat(item.body_path))
    assert.is_nil(vim.uv.fs_stat(item.header_dir))
  end)

  it("lists current account models in server order and omits hidden entries", function()
    local models
    local err
    provider.list_models(function(value, failure)
      models, err = value, failure
    end)
    assert.equals("https://api.openai.com/v1/models", requests[1].url)
    requests[1].opts.callback({
      status = 200,
      body = vim.json.encode({
        models = {
          { slug = "hidden", display_name = "Hidden", visibility = "hide" },
          { slug = "second", display_name = "Second", visibility = "list" },
          { slug = "first", display_name = "First", visibility = "list" },
          { slug = "first", display_name = "Duplicate", visibility = "list" },
          { slug = "missing-name", visibility = "list" },
        },
      }),
    })
    flush()
    assert.same(
      { { slug = "second", display_name = "Second" }, { slug = "first", display_name = "First" } },
      models
    )
    assert.is_nil(err)
    assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
  end)

  it("rejects a catalog queued before another instance changed accounts", function()
    local result
    provider.list_models(function(models, err, is_current)
      result = { models = models, err = err, is_current = is_current }
    end)
    requests[1].opts.callback({
      status = 200,
      body = vim.json.encode({
        models = { { slug = "account-a-model", display_name = "Account A", visibility = "list" } },
      }),
    })
    account_current = false
    flush()
    assert.is_nil(result.models)
    assert.matches("account changed", result.err)
    assert.is_false(result.is_current())
  end)

  it("invalidates an already delivered catalog when the shared account changes", function()
    local result
    provider.list_models(function(models, err, is_current)
      assert.is_nil(err)
      result = { models = models, is_current = is_current }
    end)
    requests[1].opts.callback({
      status = 200,
      body = vim.json.encode({
        models = { { slug = "account-a-model", display_name = "Account A", visibility = "list" } },
      }),
    })
    flush()
    assert.equals("account-a-model", result.models[1].slug)
    assert.is_true(result.is_current())
    account_current = false
    assert.is_false(result.is_current())
  end)

  it("does not fetch models with an account superseded before token delivery", function()
    defer_auth = true
    local result
    provider.list_models(function(models, err)
      result = { models = models, err = err }
    end)
    account_current = false
    auth_callback("synthetic-test-access-token", nil, function()
      return account_current
    end)
    flush()
    assert.equals(0, #requests)
    assert.is_nil(result.models)
    assert.matches("account changed", result.err)
  end)

  it("discovers the default account model instead of using the OpenRouter model", function()
    options.chatgpt.model = nil
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    assert.equals(1, #requests)
    assert.equals("GET", requests[1].method)
    requests[1].opts.callback({
      status = 200,
      body = vim.json.encode({
        models = {
          { slug = "hidden", display_name = "Hidden", visibility = "hidden" },
          { slug = "account-default", display_name = "Default", visibility = "list" },
        },
      }),
    })
    assert.equals(2, #requests)
    assert.equals("account-default", vim.json.decode(requests[2].body).model)
    complete(requests[2], "Hello")
    assert.equals(1, result.completions)
  end)

  it("fails if model discovery has no available choices", function()
    options.chatgpt.model = nil
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    requests[1].opts.callback({ status = 200, body = '{"models":[]}' })
    flush()
    assert.equals(1, #requests)
    assert.equals(1, #result.errors)
    assert.matches("No models", result.errors[1])
    assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
  end)

  it("requires completed inference before reporting success", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(requests[1], { type = "response.output_text.delta", delta = "Partial" })
    requests[1].opts.stream(nil, "data: [DONE]")
    requests[1].opts.callback({ status = 200, body = "" })
    flush()
    assert.same({ "Partial" }, result.tokens)
    assert.equals(0, result.completions)
    assert.equals(1, #result.errors)
    assert.matches("before completion", result.errors[1])
  end)

  it("does not complete an empty or whitespace-only response", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    complete(requests[1], " \n")
    assert.equals(0, result.completions)
    assert.equals(1, #result.errors)
    assert.matches("without an answer", result.errors[1])
  end)

  it("accepts complete output text when no deltas were sent", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(requests[1], {
      type = "response.completed",
      response = {
        status = "completed",
        output = {
          { type = "reasoning", summary = {} },
          {
            type = "message",
            content = {
              { type = "output_text", text = "One" },
              { type = "output_text", text = "Two" },
            },
          },
        },
      },
    })
    requests[1].opts.callback({ status = 200, body = "" })
    flush()
    assert.same({ "OneTwo" }, result.tokens)
    assert.equals(1, result.completions)
  end)

  it("does not duplicate text included in the completion event", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(requests[1], { type = "response.output_text.delta", delta = "Hello" })
    emit(requests[1], {
      type = "response.completed",
      response = {
        status = "completed",
        output = { { type = "message", content = { { type = "output_text", text = "Hello" } } } },
      },
    })
    requests[1].opts.callback({ status = 200, body = "" })
    flush()
    assert.same({ "Hello" }, result.tokens)
  end)

  it("collects streams for the complete-response API without changing billing paths", function()
    local text
    local err
    provider.chat({ { role = "user", content = "Hello" } }, function(value, failure)
      text, err = value, failure
    end)
    emit(requests[1], { type = "response.output_text.delta", delta = "One" })
    complete(requests[1], "Two")
    assert.equals("OneTwo", text)
    assert.is_nil(err)
    assert.is_true(vim.json.decode(requests[1].body).stream)
    assert.equals(1, #requests)
  end)

  for _, event_type in ipairs({ "response.failed", "response.incomplete", "error" }) do
    it("fails exactly once on " .. event_type .. " after partial output", function()
      local result, callbacks = observe()
      provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
      emit(requests[1], { type = "response.output_text.delta", delta = "Partial" })
      emit(requests[1], {
        type = event_type,
        response = {
          error = {
            code = "subscription_sharing_usage_limit_exceeded",
            message = "secret-server-detail",
          },
        },
        message = "secret-server-detail",
      })
      requests[1].opts.on_error({ message = "secret-curl-detail" })
      requests[1].opts.callback({ status = 200, body = "" })
      flush()
      assert.equals(0, result.completions)
      assert.equals(1, #result.errors)
      assert.is_nil(result.errors[1]:find("secret", 1, true))
      assert.equals(1, #requests)
      assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
    end)
  end

  for _, status in ipairs({ 401, 403, 429, 503 }) do
    it("rejects HTTP " .. status .. " even after a completed stream", function()
      local result, callbacks = observe()
      provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
      emit(requests[1], { type = "response.output_text.delta", delta = "Hello" })
      emit(requests[1], { type = "response.completed", response = { status = "completed" } })
      flush()
      assert.equals(0, result.completions)
      requests[1].opts.callback({
        status = status,
        body = '{"detail":"secret-account-information"}',
      })
      flush()
      assert.equals(0, result.completions)
      assert.equals(1, #result.errors)
      assert.is_nil(result.errors[1]:find("secret", 1, true))
    end)
  end

  it("cancels authentication and suppresses its late callback", function()
    defer_auth = true
    local result, callbacks = observe()
    local handle = provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    handle.cancel()
    auth_callback("synthetic-test-access-token", nil)
    flush()
    assert.is_true(auth_cancelled)
    assert.equals(0, #requests)
    assert.equals(0, result.completions)
    assert.same({}, result.errors)
  end)

  it("cancels model discovery before inference and cleans credentials", function()
    options.chatgpt.model = nil
    local result, callbacks = observe()
    local handle = provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    handle.cancel()
    requests[1].opts.callback({ status = 200, body = '{"models":[]}' })
    flush()
    assert.is_true(requests[1].cancelled)
    assert.equals("sigterm", requests[1].signal)
    assert.equals(1, #requests)
    assert.same({}, result.errors)
    assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
  end)

  it("cancels streams and suppresses already queued token and terminal callbacks", function()
    local result, callbacks = observe()
    local handle = provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(requests[1], { type = "response.output_text.delta", delta = "Hello" })
    emit(requests[1], { type = "response.completed", response = { status = "completed" } })
    requests[1].opts.callback({ status = 200, body = "" })
    handle.cancel()
    flush()
    assert.is_true(requests[1].cancelled)
    assert.equals("sigterm", requests[1].signal)
    assert.same({}, result.tokens)
    assert.equals(0, result.completions)
    assert.same({}, result.errors)
    assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
  end)

  it("kills active curl requests and removes credentials and prompts on editor exit", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "sage_llm_chatgpt_requests" })
    complete(requests[1], "Hello")
    assert.is_true(requests[1].cancelled)
    assert.equals("sigterm", requests[1].signal)
    assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
    assert.is_nil(vim.uv.fs_stat(requests[1].body_path))
    assert.is_nil(vim.uv.fs_stat(requests[1].header_dir))
    assert.same({}, result.tokens)
    assert.equals(0, result.completions)
    assert.same({}, result.errors)
  end)

  it("cancels a model picker request including a queued result", function()
    local calls = 0
    local handle = provider.list_models(function()
      calls = calls + 1
    end)
    requests[1].opts.callback({ status = 200, body = '{"models":[]}' })
    handle.cancel()
    flush()
    assert.equals(0, calls)
    assert.is_true(requests[1].cancelled)
  end)

  it("cancels pending discovery so sign-out cannot start a later inference request", function()
    options.chatgpt.model = nil
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "selected code" } }, callbacks)
    assert.equals(1, #requests)
    provider.cancel_all()
    requests[1].opts.callback({
      status = 200,
      body = '{"models":[{"slug":"model-a","display_name":"A","visibility":"list"}]}',
    })
    flush()
    assert.equals(1, #requests)
    assert.is_true(requests[1].cancelled)
    assert.equals("sigterm", requests[1].signal)
    assert.same({}, result.tokens)
    assert.equals(0, result.completions)
  end)

  it("stops active streams and invalidates already queued completions on sign-out", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(requests[1], { type = "response.output_text.delta", delta = "queued" })
    provider.cancel_all()
    complete(requests[1])
    assert.is_true(requests[1].cancelled)
    assert.same({}, result.tokens)
    assert.equals(0, result.completions)

    local next_result, next_callbacks = observe()
    provider.stream_chat({ { role = "user", content = "New account" } }, next_callbacks)
    emit(requests[2], { type = "response.output_text.delta", delta = "answer" })
    emit(requests[2], { type = "response.completed", response = { status = "completed" } })
    requests[2].opts.callback({ status = 200, body = "" })
    provider.cancel_all()
    flush()
    assert.same({}, next_result.tokens)
    assert.equals(0, next_result.completions)
  end)

  it("invalidates a queued model picker result on sign-out", function()
    local calls = 0
    provider.list_models(function()
      calls = calls + 1
    end)
    requests[1].opts.callback({ status = 200, body = '{"models":[]}' })
    provider.cancel_all()
    flush()
    assert.equals(0, calls)
  end)

  it("invalidates a previously delivered catalog's account guard", function()
    local current
    provider.list_models(function(_, _, is_current)
      current = is_current
    end)
    requests[1].opts.callback({ status = 200, body = '{"models":[]}' })
    flush()
    assert.is_true(current())
    provider.cancel_all()
    assert.is_false(current())
  end)

  it("reports sign-in errors without making an HTTP request", function()
    auth_error = "Sign in with :SageChatGPTLogin to connect your ChatGPT plan"
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    flush()
    assert.equals(0, #requests)
    assert.same({ auth_error }, result.errors)
  end)

  it("rejects unsupported search before authentication or inference", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks, { search = true })
    flush()
    assert.is_nil(auth_callback)
    assert.equals(0, #requests)
    assert.equals(1, #result.errors)
    assert.matches("Web search", result.errors[1])
  end)

  it("sanitizes network errors and finishes once", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    requests[1].opts.on_error({ message = "Authorization: Bearer synthetic-test-access-token" })
    requests[1].opts.callback({ status = 200, body = "" })
    flush()
    assert.equals(1, #result.errors)
    assert.is_nil(result.errors[1]:find("synthetic", 1, true))
    assert.equals(0, result.completions)
    assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
  end)

  it(
    "reports streamed refusals distinctly without duplicate text or empty-answer advice",
    function()
      local result, callbacks = observe()
      provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
      emit(requests[1], { type = "response.refusal.delta", delta = "I cannot " })
      emit(requests[1], { type = "response.refusal.delta", delta = "help with that." })
      emit(requests[1], { type = "response.refusal.done", refusal = "I cannot help with that." })
      complete(requests[1])
      assert.same({}, result.tokens)
      assert.equals(0, result.completions)
      assert.same({ "ChatGPT declined this request: I cannot help with that." }, result.errors)
      assert.is_nil(vim.uv.fs_stat(requests[1].header_path))
      assert.is_nil(vim.uv.fs_stat(requests[1].body_path))
    end
  )

  it("surfaces completed refusal content when there are no refusal deltas", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(requests[1], {
      type = "response.completed",
      response = {
        status = "completed",
        output = {
          {
            type = "message",
            content = {
              { type = "refusal", refusal = "I cannot help.\nPlease ask about another topic." },
            },
          },
        },
      },
    })
    requests[1].opts.callback({ status = 200, body = "" })
    flush()
    assert.same({}, result.tokens)
    assert.equals(0, result.completions)
    assert.same(
      { "ChatGPT declined this request: I cannot help. Please ask about another topic." },
      result.errors
    )
  end)

  it("keeps separate finalized refusal parts without repeating their deltas", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    emit(
      requests[1],
      { type = "response.refusal.delta", item_id = "message", content_index = 0, delta = "Cannot " }
    )
    emit(requests[1], {
      type = "response.refusal.done",
      item_id = "message",
      content_index = 0,
      refusal = "Cannot do this.",
    })
    emit(requests[1], {
      type = "response.refusal.done",
      item_id = "message",
      content_index = 1,
      refusal = "Try a different topic.",
    })
    complete(requests[1])
    assert.same(
      { "ChatGPT declined this request: Cannot do this. Try a different topic." },
      result.errors
    )
  end)

  it(
    "returns a refusal as an error to infill callers instead of previewing partial text",
    function()
      local result
      provider.chat({ { role = "user", content = "Replace this code" } }, function(text, err)
        result = { text = text, err = err }
      end)
      emit(requests[1], { type = "response.output_text.delta", delta = "partial code" })
      emit(requests[1], { type = "response.refusal.done", refusal = "I cannot provide that code." })
      complete(requests[1])
      assert.is_nil(result.text)
      assert.equals("ChatGPT declined this request: I cannot provide that code.", result.err)
    end
  )

  it("parses multiline SSE JSON and CRLF without raw chunk buffering", function()
    local result, callbacks = observe()
    provider.stream_chat({ { role = "user", content = "Hello" } }, callbacks)
    requests[1].opts.stream(nil, ": keepalive\r")
    requests[1].opts.stream(nil, 'data: {"type": "response.output_text.delta",\r')
    requests[1].opts.stream(nil, 'data: "delta": "Hello"}\r')
    requests[1].opts.stream(nil, "\r")
    complete(requests[1])
    assert.same({ "Hello" }, result.tokens)
    assert.equals(1, result.completions)
  end)
end)
