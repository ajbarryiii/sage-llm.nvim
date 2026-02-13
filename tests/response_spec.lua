describe("response window hide behavior", function()
  local config
  local response
  local conversation
  local original_env

  before_each(function()
    original_env = vim.env.XDG_CONFIG_HOME
    vim.env.XDG_CONFIG_HOME = "/nonexistent/test/path"

    package.loaded["sage-llm.config_file"] = nil
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.conversation"] = nil
    package.loaded["sage-llm.ui.response"] = nil

    config = require("sage-llm.config")
    conversation = require("sage-llm.conversation")
    response = require("sage-llm.ui.response")

    config.setup({})
  end)

  after_each(function()
    vim.env.XDG_CONFIG_HOME = original_env
    conversation.reset()
  end)

  it("preserves conversation when response window is hidden", function()
    response.open("Header")
    conversation.start({
      { role = "system", content = "sys" },
      { role = "user", content = "q" },
    })

    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(winid, true)

    assert.is_false(response.is_open())
    assert.is_true(conversation.is_active())
    assert.is_true(response.show())
    assert.is_true(response.is_open())
  end)
end)
