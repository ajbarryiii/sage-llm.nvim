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

  it("adds a blank line before and after streamed llm response", function()
    response.open("Header")
    response.show_loading()
    response.start_streaming()
    response.append_token("Response line 1")
    response.complete()

    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)

    assert.same({ "Header", "", "Response line 1", "" }, lines)
  end)

  it("replaces progressive reply snapshots while preserving the header", function()
    response.open("Header")
    response.show_loading()
    response.start_streaming()
    response.set_response_text("Draft")
    response.set_response_text("Revised\nanswer λ")
    response.complete()
    assert.same(
      { "Header", "", "Revised", "answer λ", "" },
      vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    )
  end)

  it("preserves earlier answers when replacing a follow-up response", function()
    response.open("Header\n")
    response.set_response_text("First answer")
    response.complete()
    response.append_followup_header("Follow-up:\n")
    response.show_loading()
    response.start_streaming()
    response.set_response_text("Draft")
    response.set_response_text("Second answer")
    response.complete()
    assert.same(
      { "Header", "", "First answer", "", "Follow-up:", "", "Second answer", "" },
      vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    )
  end)

  it("keeps an explicit T3 title when the window is hidden and reopened", function()
    response.open("Header", { title = "T3: Investigate ownership" })
    response.hide()
    assert.is_true(response.show())
    local title = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).title
    assert.truthy(vim.inspect(title):find("T3: Investigate ownership", 1, true))
  end)

  it("cancels the displayed request by its original provider after a switch", function()
    response.open("Header")
    response.show_loading()
    local cancelled = 0
    response.set_request_handle({
      provider = "chatgpt",
      cancel = function()
        cancelled = cancelled + 1
      end,
    })
    config.options.provider = "openrouter"
    response.cancel_stream("chatgpt")
    assert.equals(1, cancelled)
    assert.is_false(response.is_streaming())

    response.show_loading()
    response.set_request_handle({
      provider = "openrouter",
      cancel = function()
        cancelled = cancelled + 1
      end,
    })
    response.cancel_stream("chatgpt")
    assert.equals(1, cancelled)
    assert.is_true(response.is_streaming())
    response.cancel_stream()
  end)

  it("removes the search keymap and footer when the provider lacks search", function()
    response.open("Header")
    response.set_on_toggle_search(function()
      return true
    end)
    local bufnr = vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()
    local function has_search_keymap()
      for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if keymap.lhs == "S" then
          return true
        end
      end
      return false
    end
    assert.is_true(has_search_keymap())
    response.set_on_toggle_search(nil)
    assert.is_false(has_search_keymap())
    local footer = vim.api.nvim_win_get_config(winid).footer
    assert.is_nil(vim.inspect(footer):find("search:", 1, true))
  end)
end)
