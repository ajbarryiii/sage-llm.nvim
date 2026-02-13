describe("models", function()
  local original_preload
  local original_select
  local original_input
  local original_notify

  before_each(function()
    original_preload = package.preload["sage-llm.config"]
    original_select = vim.ui.select
    original_input = vim.ui.input
    original_notify = vim.notify
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.models"] = nil
  end)

  after_each(function()
    package.preload["sage-llm.config"] = original_preload
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.models"] = nil
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
end)
