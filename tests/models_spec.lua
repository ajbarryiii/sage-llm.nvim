describe("models", function()
  local original_preload
  local original_select
  local original_input
  local original_notify
  local original_chatgpt_preload
  local original_chatgpt_loaded

  before_each(function()
    original_preload = package.preload["sage-llm.config"]
    original_select = vim.ui.select
    original_input = vim.ui.input
    original_notify = vim.notify
    original_chatgpt_preload = package.preload["sage-llm.chatgpt"]
    original_chatgpt_loaded = package.loaded["sage-llm.chatgpt"]
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.models"] = nil
    package.loaded["sage-llm.chatgpt"] = nil
  end)

  after_each(function()
    package.preload["sage-llm.config"] = original_preload
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.models"] = nil
    package.preload["sage-llm.chatgpt"] = original_chatgpt_preload
    package.loaded["sage-llm.chatgpt"] = original_chatgpt_loaded
    vim.ui.select = original_select
    vim.ui.input = original_input
    vim.notify = original_notify
  end)

  it("selects an existing model from the picker", function()
    local set_to
    package.preload["sage-llm.config"] = function()
      return {
        options = {
          models = { "openai/gpt-oss-20b", "openai/gpt-5.2-codex" },
          model = "openai/gpt-oss-20b",
        },
        set_model = function(model)
          set_to = model
        end,
        add_model = function(_) end,
        remove_model = function(_)
          return true
        end,
      }
    end

    vim.ui.select = function(_, _, on_choice)
      on_choice("openai/gpt-5.2-codex", 2)
    end

    local models = require("sage-llm.models")
    models.select()

    assert.equals("openai/gpt-5.2-codex", set_to)
  end)

  it("adds and selects a custom model", function()
    local added
    local set_to
    package.preload["sage-llm.config"] = function()
      return {
        options = {
          models = { "openai/gpt-oss-20b" },
          model = "openai/gpt-oss-20b",
        },
        set_model = function(model)
          set_to = model
        end,
        add_model = function(model)
          added = model
        end,
        remove_model = function(_)
          return true
        end,
      }
    end

    vim.ui.select = function(_, _, on_choice)
      on_choice("Add custom model...", 2)
    end

    vim.ui.input = function(_, on_input)
      on_input("  openai/gpt-5.3-codex  ")
    end

    local models = require("sage-llm.models")
    models.select()

    assert.equals("openai/gpt-5.3-codex", added)
    assert.equals("openai/gpt-5.3-codex", set_to)
  end)

  it("ignores empty custom model input", function()
    local added = false
    local set_called = false
    package.preload["sage-llm.config"] = function()
      return {
        options = {
          models = { "openai/gpt-oss-20b" },
          model = "openai/gpt-oss-20b",
        },
        set_model = function(_)
          set_called = true
        end,
        add_model = function(_)
          added = true
        end,
        remove_model = function(_)
          return true
        end,
      }
    end

    vim.ui.select = function(_, _, on_choice)
      on_choice("Add custom model...", 2)
    end

    vim.ui.input = function(_, on_input)
      on_input("   ")
    end

    local models = require("sage-llm.models")
    models.select()

    assert.is_false(added)
    assert.is_false(set_called)
  end)

  it("removes a model from the picker", function()
    local removed
    package.preload["sage-llm.config"] = function()
      return {
        options = {
          models = { "openai/gpt-oss-20b", "openai/gpt-5.2-codex" },
          model = "openai/gpt-oss-20b",
        },
        set_model = function(_) end,
        add_model = function(_) end,
        remove_model = function(model)
          removed = model
          return true
        end,
      }
    end

    local select_calls = 0
    vim.ui.select = function(_, _, on_choice)
      select_calls = select_calls + 1
      if select_calls == 1 then
        on_choice("Remove model...", 4)
        return
      end
      on_choice("openai/gpt-5.2-codex", 2)
    end

    local models = require("sage-llm.models")
    models.select()

    assert.equals("openai/gpt-5.2-codex", removed)
  end)

  it("warns when trying to remove the final model", function()
    local warned
    package.preload["sage-llm.config"] = function()
      return {
        options = {
          models = { "openai/gpt-oss-20b" },
          model = "openai/gpt-oss-20b",
        },
        set_model = function(_) end,
        add_model = function(_) end,
        remove_model = function(_)
          return false
        end,
      }
    end

    vim.notify = function(msg, _)
      warned = msg
    end

    local select_calls = 0
    vim.ui.select = function(_, _, on_choice)
      select_calls = select_calls + 1
      if select_calls == 1 then
        on_choice("Remove model...", 3)
        return
      end
      on_choice("openai/gpt-oss-20b (current)", 1)
    end

    local models = require("sage-llm.models")
    models.select()

    assert.truthy(warned)
    assert.truthy(warned:match("At least one model"))
  end)

  it("appends subscription discovery after the existing picker actions", function()
    local chosen_provider, chosen_model
    local options = {
      provider = "openrouter",
      models = { "openrouter-model" },
      model = "openrouter-model",
      chatgpt = {},
    }
    package.preload["sage-llm.config"] = function()
      return {
        options = options,
        set_provider = function(provider)
          chosen_provider = provider
        end,
        set_model = function(model)
          chosen_model = model
        end,
      }
    end
    local catalog = {
      { slug = "subscription-model", display_name = "Subscription Model" },
    }
    package.preload["sage-llm.chatgpt"] = function()
      return {
        list_models = function(callback)
          callback(catalog)
        end,
      }
    end
    local select_calls = 0
    vim.ui.select = function(items, opts, callback)
      select_calls = select_calls + 1
      if select_calls == 1 then
        assert.equals("Add custom model...", items[2])
        assert.equals("Remove model...", items[3])
        assert.equals("ChatGPT subscription...", items[4])
        callback(items[4], 4)
        return
      end
      assert.same(catalog, items)
      assert.equals("Subscription Model (subscription-model)", opts.format_item(items[1]))
      callback(items[1], 1)
    end

    require("sage-llm.models").select()

    assert.equals(2, select_calls)
    assert.equals("chatgpt", chosen_provider)
    assert.equals("subscription-model", chosen_model)
  end)

  it("ignores an open subscription picker after its account changes or signs out", function()
    local valid = true
    local chosen
    package.preload["sage-llm.config"] = function()
      return {
        options = { chatgpt = {} },
        set_provider = function()
          error("Stale picker must not switch providers")
        end,
        set_model = function(value)
          chosen = value
        end,
      }
    end
    package.preload["sage-llm.chatgpt"] = function()
      return {
        list_models = function(callback)
          callback({ { slug = "account-a-model", display_name = "A" } }, nil, function()
            return valid
          end)
        end,
      }
    end
    local select_callback
    vim.ui.select = function(_, _, callback)
      select_callback = callback
    end
    require("sage-llm.models").select_chatgpt()
    valid = false
    select_callback({ slug = "account-a-model", display_name = "A" })
    assert.is_nil(chosen)
  end)

  it("warns when the subscription has no available models", function()
    package.preload["sage-llm.config"] = function()
      return { options = { chatgpt = {} } }
    end
    package.preload["sage-llm.chatgpt"] = function()
      return {
        list_models = function(callback)
          callback({})
        end,
      }
    end
    local warned
    vim.notify = function(message)
      warned = message
    end
    vim.ui.select = function()
      error("Empty model catalogs must not open a picker")
    end

    require("sage-llm.models").select_chatgpt()

    assert.truthy(warned:find("No ChatGPT models available", 1, true))
  end)

  it("shows login guidance when subscription discovery fails", function()
    package.preload["sage-llm.config"] = function()
      return { options = { chatgpt = {} } }
    end
    package.preload["sage-llm.chatgpt"] = function()
      return {
        list_models = function(callback)
          callback(nil, "Sign in with :SageChatGPTLogin")
        end,
      }
    end
    local warned
    vim.notify = function(message)
      warned = message
    end

    require("sage-llm.models").select_chatgpt()

    assert.truthy(warned:find(":SageChatGPTLogin", 1, true))
  end)

  it("preserves the provider and model when subscription selection is canceled", function()
    package.preload["sage-llm.config"] = function()
      return {
        options = { chatgpt = {} },
        set_provider = function()
          error("Cancel must not change provider")
        end,
        set_model = function()
          error("Cancel must not change model")
        end,
      }
    end
    package.preload["sage-llm.chatgpt"] = function()
      return {
        list_models = function(callback)
          callback({ { slug = "subscription-model" } })
        end,
      }
    end
    vim.ui.select = function(_, _, callback)
      callback(nil)
    end

    require("sage-llm.models").select_chatgpt()
  end)

  it("switches to OpenRouter before selecting a custom model from ChatGPT", function()
    local options = {
      provider = "chatgpt",
      models = { "openrouter-model" },
      model = "subscription-model",
    }
    package.preload["sage-llm.config"] = function()
      return {
        options = options,
        add_model = function() end,
        set_provider = function(provider)
          options.provider = provider
        end,
        set_model = function(model)
          assert.equals("openrouter", options.provider)
          options.model = model
        end,
      }
    end
    vim.ui.select = function(items, _, callback)
      callback(items[2], 2)
    end
    vim.ui.input = function(_, callback)
      callback("openrouter-custom")
    end

    require("sage-llm.models").select()

    assert.equals("openrouter-custom", options.model)
  end)
end)
