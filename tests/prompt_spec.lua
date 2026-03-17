describe("prompt formatting", function()
  local prompt

  before_each(function()
    package.loaded["sage-llm.prompt"] = nil
    prompt = require("sage-llm.prompt")
  end)

  it("formats code headers as copied line count", function()
    local sel = {
      filetype = "lua",
      start_line = 10,
      end_line = 12,
      text = "a\nb\nc",
    }

    local header = prompt.format_code_header(sel)
    assert.equals("[3 lines copied]\n", header)
  end)

  it("uses singular form for one line", function()
    local sel = {
      filetype = "lua",
      start_line = 5,
      end_line = 5,
      text = "single",
    }

    local header = prompt.format_code_header(sel)
    assert.equals("[1 line copied]\n", header)
  end)
end)

describe("prompt rag context", function()
  local config
  local prompt
  local original_env

  before_each(function()
    original_env = vim.env.XDG_CONFIG_HOME
    vim.env.XDG_CONFIG_HOME = "/nonexistent/test/path"

    package.loaded["sage-llm.config_file"] = nil
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.prompt"] = nil

    config = require("sage-llm.config")
    config.setup({})
    prompt = require("sage-llm.prompt")
  end)

  after_each(function()
    vim.env.XDG_CONFIG_HOME = original_env
  end)

  it("includes repository context when rag snippets are provided", function()
    local bufnr = vim.api.nvim_create_buf(false, true)

    local selection = {
      text = "local value = 42",
      bufnr = bufnr,
      start_line = 1,
      end_line = 1,
      start_col = 0,
      end_col = 16,
      filetype = "lua",
      filepath = "lua/example.lua",
    }

    local content = prompt.build_user_message(selection, "What is this?", {
      rag_snippets = {
        {
          id = "README.md:10-16",
          path = "README.md",
          start_line = 10,
          end_line = 16,
          text = "A helpful snippet",
          score = 0.9,
        },
      },
    })

    assert.truthy(content:match("Repository Context %(semantic search%)"))
    assert.truthy(content:match("README%.md:10%-16"))
    assert.truthy(content:match("A helpful snippet"))
  end)

  it("adds rag context for no-selection messages", function()
    local messages = prompt.build_messages_no_selection("How does this work?", {
      rag_snippets = {
        {
          id = "lua/sage-llm/init.lua:1-8",
          path = "lua/sage-llm/init.lua",
          start_line = 1,
          end_line = 8,
          text = "local config = require('sage-llm.config')",
          score = 0.8,
        },
      },
    })

    assert.equals("user", messages[2].role)
    assert.truthy(messages[2].content:match("Repository Context %(semantic search%)"))
    assert.truthy(messages[2].content:match("Question: How does this work%?"))
  end)
end)
