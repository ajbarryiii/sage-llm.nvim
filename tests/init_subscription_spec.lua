describe("subscription conversation recovery", function()
  local originals = {}
  local names = {
    "sage-llm.config",
    "sage-llm.selection",
    "sage-llm.prompt",
    "sage-llm.api",
    "sage-llm.ui",
    "sage-llm.actions",
    "sage-llm.models",
    "sage-llm.infill",
    "sage-llm.rag",

    "sage-llm.conversation",
    "sage-llm.chatgpt_auth",
    "sage-llm.chatgpt",
    "sage-llm.config_file",
  }
  local requests, current_handle, cancelled, errors, question
  local conversation, sage
  local original_notify, notifications

  local function stub(name, module)
    package.preload[name] = function()
      return module
    end
  end

  before_each(function()
    requests, cancelled, errors, question = {}, 0, {}, "initial"
    original_notify, notifications = vim.notify, {}
    vim.notify = function(message)
      notifications[#notifications + 1] = message
    end
    for _, name in ipairs(names) do
      originals[name] = { preload = package.preload[name], loaded = package.loaded[name] }
      package.loaded[name] = nil
    end
    package.loaded["sage-llm"] = nil
    stub("sage-llm.config", {
      options = { provider = "chatgpt", input = { height = 5 }, rag = { enabled = false } },
      supports_search = function()
        return false
      end,
      supports_rag = function()
        return false
      end,
    })
    stub("sage-llm.selection", {
      get_visual_selection = function()
        return nil
      end,
    })
    stub("sage-llm.prompt", {
      format_question_header = function(text)
        return text
      end,
      format_followup_header = function(text)
        return text
      end,
      build_messages_no_selection = function(text)
        return { { role = "user", content = text } }
      end,
    })
    stub("sage-llm.api", {
      stream_chat = function(messages, callbacks)
        requests[#requests + 1] = { messages = messages, callbacks = callbacks }
        return {
          cancel = function()
            cancelled = cancelled + 1
          end,
        }
      end,
    })
    stub("sage-llm.ui", {
      input = {
        open = function(opts)
          opts.on_submit(question)
        end,
      },
      response = {
        open = function() end,
        show_loading = function() end,
        start_streaming = function() end,
        append_token = function() end,
        append_followup_header = function() end,
        complete = function() end,
        set_on_followup = function() end,
        set_on_toggle_search = function() end,
        set_search_enabled = function() end,
        cancel_stream = function()
          if current_handle then
            current_handle.cancel()
          end
        end,
        set_request_handle = function(handle)
          current_handle = handle
        end,
        show_error = function(err)
          errors[#errors + 1] = err
        end,
        is_open = function()
          return true
        end,
        is_streaming = function()
          return false
        end,
        get_geometry = function()
          return nil
        end,
      },
    })
    for _, name in ipairs({ "actions", "models", "infill", "rag" }) do
      stub("sage-llm." .. name, {})
    end
    stub("sage-llm.chatgpt", { cancel_all = function() end })
    conversation = require("sage-llm.conversation")
    sage = require("sage-llm")
    sage.ask()
    requests[1].callbacks.on_token("initial answer")
    requests[1].callbacks.on_complete()
  end)

  after_each(function()
    vim.notify = original_notify
    for _, name in ipairs(names) do
      package.preload[name] = originals[name].preload
      package.loaded[name] = originals[name].loaded
    end
    package.loaded["sage-llm"] = nil
  end)

  local function retry_and_check()
    question = "retry"
    sage.followup()
    assert.equals(3, #requests[3].messages)
    assert.equals("retry", requests[3].messages[3].content)
    requests[3].callbacks.on_token("retry answer")
    requests[3].callbacks.on_complete()
    local messages = conversation.add_followup("next")
    assert.equals("\nretry answer", messages[4].content)
    assert.equals(2, conversation.turn_count())
  end

  it("discards a failed partial response before a follow-up retry", function()
    question = "fails"
    sage.followup()
    requests[2].callbacks.on_token("partial")
    requests[2].callbacks.on_error("Subscription quota reached")
    assert.same({ "Subscription quota reached" }, errors)
    retry_and_check()
  end)

  it("discards a cancelled follow-up without removing a completed answer", function()
    question = "cancelled"
    sage.followup()
    requests[2].callbacks.on_token("partial")
    current_handle.cancel()
    assert.equals(1, cancelled)
    retry_and_check()
    current_handle.cancel()
    assert.equals(2, conversation.turn_count())
  end)

  it("keeps provider and model unchanged after unsuccessful sign-in", function()
    local config = require("sage-llm.config")
    config.options.provider = "openrouter"
    config.options.chatgpt = { model = "previous-slug" }
    stub("sage-llm.chatgpt_auth", {
      login = function(callback)
        callback(false, "Sign-in cancelled")
      end,
    })
    sage.chatgpt_login(true)
    assert.equals("openrouter", config.options.provider)
    assert.equals("previous-slug", config.options.chatgpt.model)
    assert.matches("Sign-in cancelled", notifications[1], 1, true)
  end)

  it("clears the old account's model only after another account connects", function()
    local config = require("sage-llm.config")
    config.options.chatgpt = { model = "old-account-slug", request_timeout_ms = 30000 }
    local saved, picked, login_options
    config.set_provider = function(provider)
      config.options.provider = provider
    end
    require("sage-llm.models").select_chatgpt = function()
      picked = true
    end
    stub("sage-llm.config_file", {
      update = function(key, value)
        assert.equals("chatgpt", key)
        saved = vim.deepcopy(value)
        return true
      end,
    })
    stub("sage-llm.chatgpt_auth", {
      login = function(callback, opts)
        login_options = opts
        callback(true)
      end,
    })
    sage.chatgpt_login(true)
    assert.same({ new_account = true }, login_options)
    assert.equals("chatgpt", config.options.provider)
    assert.is_nil(config.options.chatgpt.model)
    assert.same({ request_timeout_ms = 30000 }, saved)
    assert.is_true(picked)
  end)

  it("shows connection status without exposing credentials", function()
    local config = require("sage-llm.config")
    config.options.chatgpt = { model = "account-model" }
    stub("sage-llm.chatgpt_auth", {
      status = function()
        return { connected = true, email = "test@example.com", access_token = "sensitive-token" }
      end,
    })
    sage.chatgpt_status()
    assert.matches("test@example.com", notifications[1], 1, true)
    assert.matches("account-model", notifications[1], 1, true)
    assert.is_nil(notifications[1]:find("sensitive-token", 1, true))
  end)

  it("cancels conversation and subscription operations before clearing credentials", function()
    question = "follow-up"
    sage.followup()
    requests[2].callbacks.on_token("partial")
    local events = {}
    stub("sage-llm.chatgpt", {
      cancel_all = function()
        assert.equals(1, cancelled)
        events[#events + 1] = "cancel"
      end,
    })
    stub("sage-llm.chatgpt_auth", {
      logout = function(callback)
        events[#events + 1] = "logout"
        callback(true)
      end,
    })
    sage.chatgpt_logout()
    requests[2].callbacks.on_complete()
    assert.same({ "cancel", "logout" }, events)
    local messages = conversation.add_followup("retry")
    assert.equals(3, #messages)
    assert.equals("\ninitial answer", messages[2].content)
    assert.equals("retry", messages[3].content)
  end)

  it("reports unconfirmed remote revocation after local sign-out", function()
    stub("sage-llm.chatgpt_auth", {
      logout = function(callback)
        callback(true, "Signed out locally; remote revocation was not confirmed")
      end,
    })
    sage.chatgpt_logout()
    assert.matches("remote revocation was not confirmed", notifications[1], 1, true)
  end)
end)
