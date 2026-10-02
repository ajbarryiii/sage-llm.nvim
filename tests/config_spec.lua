describe("config", function()
  local config
  local original_env

  before_each(function()
    -- Store original env
    original_env = vim.env.XDG_CONFIG_HOME

    -- Point to non-existent config to avoid loading real config
    vim.env.XDG_CONFIG_HOME = "/nonexistent/test/path"

    -- Reset module cache
    package.loaded["sage-llm.config_file"] = nil
    package.loaded["sage-llm.config"] = nil
    config = require("sage-llm.config")
  end)

  after_each(function()
    -- Restore original env
    vim.env.XDG_CONFIG_HOME = original_env
  end)

  describe("defaults", function()
    it("has default model", function()
      assert.equals("openai/gpt-oss-20b", config.defaults.model)
    end)

    it("has default base_url", function()
      assert.equals("https://openrouter.ai/api/v1", config.defaults.base_url)
    end)

    it("defaults to OpenRouter provider", function()
      assert.equals("openrouter", config.defaults.provider)
    end)

    it("has ChatGPT subscription defaults", function()
      assert.is_nil(config.defaults.chatgpt.model)
      assert.is_nil(config.defaults.chatgpt.auth_dir)
      assert.equals(180000, config.defaults.chatgpt.login_timeout_ms)
      assert.equals(30000, config.defaults.chatgpt.request_timeout_ms)
    end)

    it("has detect_dependencies disabled by default", function()
      assert.is_false(config.defaults.detect_dependencies)
    end)

    it("has rag disabled by default", function()
      assert.is_false(config.defaults.rag.enabled)
    end)

    it("has rag embedding model", function()
      assert.equals("openai/text-embedding-3-small", config.defaults.rag.embedding_model)
    end)

    it("has response config", function()
      assert.equals(0.6, config.defaults.response.width)
      assert.equals(0.4, config.defaults.response.height)
      assert.equals("rounded", config.defaults.response.border)
    end)

    it("has input config", function()
      assert.equals(0.5, config.defaults.input.width)
      assert.equals(5, config.defaults.input.height)
    end)
  end)

  describe("setup", function()
    it("merges user options with defaults", function()
      config.setup({
        model = "openai/gpt-4o",
        response = {
          width = 0.8,
        },
      })

      assert.equals("openai/gpt-4o", config.options.model)
      assert.equals(0.8, config.options.response.width)
      -- Should keep default height
      assert.equals(0.4, config.options.response.height)
    end)

    it("handles empty options", function()
      config.setup({})
      assert.equals(config.defaults.model, config.options.model)
    end)

    it("handles nil options", function()
      config.setup(nil)
      assert.equals(config.defaults.model, config.options.model)
    end)

    it("validates rag chunk overlap", function()
      assert.has_error(function()
        config.setup({
          rag = {
            chunk_lines = 20,
            chunk_overlap = 20,
          },
        })
      end)
    end)

    it("rejects invalid provider", function()
      assert.has_error(function()
        config.setup({ provider = "bogus" })
      end)
    end)

    it("uses the selected ChatGPT model without replacing the OpenRouter choice", function()
      config.setup({
        provider = "chatgpt",
        model = "openai/gpt-oss-20b",
        chatgpt = { model = "subscription-model" },
      })

      assert.equals("subscription-model", config.options.model)
      config.set_provider("openrouter", false)
      assert.equals("openai/gpt-oss-20b", config.options.model)
    end)

    it("shows a friendly placeholder before discovering a subscription model", function()
      config.setup({ provider = "chatgpt" })
      assert.equals("ChatGPT", config.options.model)
    end)

    it("validates subscription configuration types", function()
      for _, opts in ipairs({
        { chatgpt = "invalid" },
        { chatgpt = { model = 1 } },
        { chatgpt = { auth_dir = false } },
        { chatgpt = { request_timeout_ms = "30000" } },
      }) do
        assert.has_error(function()
          config.setup(opts)
        end)
      end
    end)

    it("requires positive finite integer subscription timeouts", function()
      for _, key in ipairs({ "login_timeout_ms", "request_timeout_ms" }) do
        for _, value in ipairs({ 0, -1, 0.5, math.huge, -math.huge, 0 / 0 }) do
          assert.has_error(function()
            config.setup({ chatgpt = { [key] = value } })
          end)
        end
      end
    end)
  end)

  describe("get_api_key", function()
    it("returns config api_key if set", function()
      config.setup({ api_key = "test-key" })
      assert.equals("test-key", config.get_api_key())
    end)

    it("falls back to environment variable", function()
      config.setup({})
      -- Note: actual env var test would need mocking
      -- This just ensures the function exists and runs
      local key = config.get_api_key()
      -- Returns nil or env var value
      assert.is_true(key == nil or type(key) == "string")
    end)
  end)

  describe("set_detect_dependencies", function()
    it("enables dependency detection", function()
      config.setup({})
      config.set_detect_dependencies(true)
      assert.is_true(config.options.detect_dependencies)
    end)

    it("disables dependency detection", function()
      config.setup({ detect_dependencies = true })
      config.set_detect_dependencies(false)
      assert.is_false(config.options.detect_dependencies)
    end)
  end)

  describe("set_rag_enabled", function()
    it("enables rag retrieval", function()
      config.setup({})
      config.set_rag_enabled(true)
      assert.is_true(config.options.rag.enabled)
    end)

    it("disables rag retrieval", function()
      config.setup({ rag = { enabled = true } })
      config.set_rag_enabled(false)
      assert.is_false(config.options.rag.enabled)
    end)
  end)

  describe("set_model", function()
    it("updates the model", function()
      config.setup({})
      config.set_model("google/gemini-2.0-flash")
      assert.equals("google/gemini-2.0-flash", config.options.model)
    end)

    it("persists subscription model settings separately from the global model", function()
      config.setup({ provider = "chatgpt", chatgpt = { auth_dir = "/private/auth" } })
      local saved_key, saved_value
      require("sage-llm.config_file").update = function(key, value)
        saved_key, saved_value = key, vim.deepcopy(value)
        return true
      end

      config.set_model("subscription-model")

      assert.equals("chatgpt", saved_key)
      assert.equals("subscription-model", saved_value.model)
      assert.equals("/private/auth", saved_value.auth_dir)
      assert.equals("subscription-model", config.options.model)
      assert.equals("subscription-model", config.options.chatgpt.model)
    end)

    it("restores each provider's model when switching", function()
      config.setup({ model = "openrouter-model" })
      config.set_provider("chatgpt", false)
      config.set_model("subscription-model", false)
      config.set_provider("openrouter", false)
      assert.equals("openrouter-model", config.options.model)
      config.set_provider("chatgpt", false)
      assert.equals("subscription-model", config.options.model)
    end)
  end)

  describe("provider helpers", function()
    it("sets provider", function()
      config.setup({})
      config.set_provider("chatgpt", false)

      assert.equals("chatgpt", config.options.provider)
      assert.is_true(config.is_chatgpt_provider())
      assert.is_false(config.supports_search())
      assert.is_false(config.supports_rag())
    end)

    it("disables search and RAG for ChatGPT subscriptions", function()
      config.setup({ provider = "chatgpt" })
      assert.is_true(config.is_chatgpt_provider())
      assert.is_false(config.supports_search())
      assert.is_false(config.supports_rag())
      config.set_provider("openrouter", false)
      assert.is_false(config.is_chatgpt_provider())
      assert.is_true(config.supports_search())
      assert.is_true(config.supports_rag())
    end)
  end)

  describe("add_model", function()
    it("adds a new model to the picker list", function()
      config.setup({ models = { "openai/gpt-oss-20b" } })
      config.add_model("openai/gpt-5.3-codex", false)

      assert.same({ "openai/gpt-oss-20b", "openai/gpt-5.3-codex" }, config.options.models)
    end)

    it("does not duplicate an existing model", function()
      config.setup({ models = { "openai/gpt-oss-20b" } })
      config.add_model("openai/gpt-oss-20b", false)

      assert.same({ "openai/gpt-oss-20b" }, config.options.models)
    end)
  end)

  describe("remove_model", function()
    it("removes a model from the picker list", function()
      config.setup({ models = { "a", "b" }, model = "a" })
      local removed = config.remove_model("b", false)

      assert.is_true(removed)
      assert.same({ "a" }, config.options.models)
      assert.equals("a", config.options.model)
    end)

    it("switches current model when removing the selected one", function()
      config.setup({ models = { "a", "b", "c" }, model = "b" })
      local removed = config.remove_model("b", false)

      assert.is_true(removed)
      assert.same({ "a", "c" }, config.options.models)
      assert.equals("a", config.options.model)
    end)

    it("refuses to remove the last remaining model", function()
      config.setup({ models = { "a" }, model = "a" })
      local removed = config.remove_model("a", false)

      assert.is_false(removed)
      assert.same({ "a" }, config.options.models)
      assert.equals("a", config.options.model)
    end)

    it("preserves subscription selection when removing an OpenRouter model", function()
      config.setup({
        provider = "chatgpt",
        models = { "a", "b" },
        model = "a",
        chatgpt = { model = "subscription-model" },
      })
      local updates = {}
      require("sage-llm.config_file").update = function(key, value)
        updates[key] = value
        return true
      end

      assert.is_true(config.remove_model("a"))
      assert.equals("subscription-model", config.options.model)
      assert.equals("b", updates.model)
      config.set_provider("openrouter", false)
      assert.equals("b", config.options.model)
    end)
  end)

  describe("get_config_path", function()
    it("returns the config file path", function()
      local path = config.get_config_path()
      assert.is_string(path)
      assert.truthy(path:match("config%.lua$"))
    end)
  end)

  describe("config file integration", function()
    it("setup opts are applied when no config file exists", function()
      config.setup({ model = "test-model" })
      assert.equals("test-model", config.options.model)
    end)
  end)
end)
