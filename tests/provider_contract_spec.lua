describe("supported provider contract", function()
  local original_env, config, directory

  before_each(function()
    original_env = vim.env.XDG_CONFIG_HOME
    directory = vim.fn.tempname()
    vim.env.XDG_CONFIG_HOME = directory
    package.loaded["sage-llm.config_file"] = nil
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm"] = nil
    config = require("sage-llm.config")
  end)

  after_each(function()
    vim.env.XDG_CONFIG_HOME = original_env
    vim.fn.delete(directory, "rf")
  end)

  it("rejects llama.cpp during setup and provider switching", function()
    assert.has_error(function()
      config.setup({ provider = "llama_cpp" })
    end)
    config.setup({})
    assert.has_error(function()
      config.set_provider("llama_cpp", false)
    end)
    assert.is_nil(config.defaults.llama_cpp)
  end)

  it("does not expose local model commands or public API entry points", function()
    local commands = vim.api.nvim_get_commands({ builtin = false })
    local sage = require("sage-llm")
    for _, suffix in ipairs({ "Setup", "Start", "Stop", "Status", "Install" }) do
      assert.is_nil(commands["SageLocal" .. suffix])
      assert.is_nil(sage["local_" .. suffix:lower()])
    end
  end)
end)
