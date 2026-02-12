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
      assert.equals("anthropic/claude-sonnet-4-20250514", config.defaults.model)
    end)

    it("has default base_url", function()
      assert.equals("https://openrouter.ai/api/v1", config.defaults.base_url)
    end)

    it("has detect_dependencies disabled by default", function()
      assert.is_false(config.defaults.detect_dependencies)
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

  describe("set_model", function()
    it("updates the model", function()
      config.setup({})
      config.set_model("google/gemini-2.0-flash")
      assert.equals("google/gemini-2.0-flash", config.options.model)
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
