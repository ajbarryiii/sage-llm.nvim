describe("config_file", function()
  local config_file
  local original_env

  before_each(function()
    -- Reset module cache
    package.loaded["sage-llm.config_file"] = nil
    config_file = require("sage-llm.config_file")

    -- Store original env
    original_env = vim.env.XDG_CONFIG_HOME
  end)

  after_each(function()
    -- Restore original env
    vim.env.XDG_CONFIG_HOME = original_env
  end)

  describe("get_config_dir", function()
    it("respects XDG_CONFIG_HOME when set", function()
      vim.env.XDG_CONFIG_HOME = "/custom/config"
      -- Need to reload module to pick up env change
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      assert.equals("/custom/config/sage-llm", config_file.get_config_dir())
    end)

    it("defaults to ~/.config/sage-llm when XDG not set", function()
      vim.env.XDG_CONFIG_HOME = nil
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      local expected = vim.fn.expand("~/.config/sage-llm")
      assert.equals(expected, config_file.get_config_dir())
    end)

    it("defaults to ~/.config/sage-llm when XDG is empty string", function()
      vim.env.XDG_CONFIG_HOME = ""
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      local expected = vim.fn.expand("~/.config/sage-llm")
      assert.equals(expected, config_file.get_config_dir())
    end)
  end)

  describe("get_config_path", function()
    it("returns path to config.lua in config dir", function()
      vim.env.XDG_CONFIG_HOME = "/test/config"
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      assert.equals("/test/config/sage-llm/config.lua", config_file.get_config_path())
    end)
  end)

  describe("exists", function()
    it("returns false for non-existent file", function()
      vim.env.XDG_CONFIG_HOME = "/nonexistent/path/that/does/not/exist"
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      assert.is_false(config_file.exists())
    end)
  end)

  describe("load", function()
    it("returns nil for non-existent file", function()
      vim.env.XDG_CONFIG_HOME = "/nonexistent/path/that/does/not/exist"
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      local result, err = config_file.load()
      assert.is_nil(result)
      assert.is_nil(err)
    end)
  end)

  describe("create_template", function()
    it("fails when directory cannot be created", function()
      -- Use an invalid path that can't be created
      vim.env.XDG_CONFIG_HOME = "/root/cannot/create/here"
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")

      local success, err = config_file.create_template()
      -- Should fail (either false with error, or false because dir creation failed)
      assert.is_false(success)
    end)
  end)

  describe("save and update", function()
    local temp_dir

    before_each(function()
      -- Create a temporary directory for testing
      temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir, "p")
      vim.env.XDG_CONFIG_HOME = temp_dir
      package.loaded["sage-llm.config_file"] = nil
      config_file = require("sage-llm.config_file")
    end)

    after_each(function()
      -- Clean up temp directory
      if temp_dir then
        vim.fn.delete(temp_dir, "rf")
      end
    end)

    it("save creates config file with provided values", function()
      local success, err = config_file.save({
        api_key = "test-key",
        model = "test-model",
      })

      assert.is_true(success)
      assert.is_nil(err)
      assert.is_true(config_file.exists())

      -- Verify the saved content can be loaded back
      local loaded = config_file.load()
      assert.equals("test-key", loaded.api_key)
      assert.equals("test-model", loaded.model)
    end)

    it("update modifies a single key", function()
      -- First create a config
      config_file.save({
        api_key = "my-key",
        model = "original-model",
      })

      -- Update just the model
      local success, err = config_file.update("model", "new-model")
      assert.is_true(success)
      assert.is_nil(err)

      -- Verify api_key is preserved and model is updated
      local loaded = config_file.load()
      assert.equals("my-key", loaded.api_key)
      assert.equals("new-model", loaded.model)
    end)

    it("update creates file if it doesn't exist", function()
      assert.is_false(config_file.exists())

      local success, err = config_file.update("model", "new-model")
      assert.is_true(success)
      assert.is_nil(err)

      local loaded = config_file.load()
      assert.equals("new-model", loaded.model)
    end)

    it("save preserves api_key from existing config", function()
      -- Create initial config with api_key
      config_file.save({ api_key = "secret-key" })

      -- Save new config without api_key
      config_file.save({ model = "new-model" })

      -- api_key should be preserved
      local loaded = config_file.load()
      assert.equals("secret-key", loaded.api_key)
      assert.equals("new-model", loaded.model)
    end)
  end)
end)
