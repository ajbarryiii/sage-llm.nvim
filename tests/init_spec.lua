describe("init conversation view", function()
  local original_preload = {}

  local function stub_module(name, mod)
    original_preload[name] = package.preload[name]
    package.preload[name] = function()
      return mod
    end
    package.loaded[name] = nil
  end

  local function restore_preload(name)
    package.preload[name] = original_preload[name]
    package.loaded[name] = nil
    original_preload[name] = nil
  end

  after_each(function()
    restore_preload("sage-llm.config")
    restore_preload("sage-llm.selection")
    restore_preload("sage-llm.prompt")
    restore_preload("sage-llm.api")
    restore_preload("sage-llm.ui")
    restore_preload("sage-llm.actions")
    restore_preload("sage-llm.models")
    restore_preload("sage-llm.conversation")
    restore_preload("sage-llm.infill")
    package.loaded["sage-llm"] = nil
  end)

  it("reopens hidden response window without opening follow-up input", function()
    local show_calls = 0
    local input_calls = 0

    stub_module("sage-llm.config", { options = { input = { height = 5 } } })
    stub_module("sage-llm.selection", {})
    stub_module("sage-llm.prompt", {})
    stub_module("sage-llm.api", {})
    stub_module("sage-llm.actions", {})
    stub_module("sage-llm.models", {})
    stub_module("sage-llm.conversation", {
      is_active = function()
        return true
      end,
    })
    stub_module("sage-llm.ui", {
      response = {
        is_open = function()
          return false
        end,
        show = function()
          show_calls = show_calls + 1
          return true
        end,
      },
      input = {
        open = function(_)
          input_calls = input_calls + 1
        end,
      },
    })

    local sage = require("sage-llm")
    sage.show_conversation()

    assert.equals(1, show_calls)
    assert.equals(0, input_calls)
  end)

  it("delegates remove_model to models.remove", function()
    local remove_calls = 0

    stub_module("sage-llm.config", { options = { input = { height = 5 } } })
    stub_module("sage-llm.selection", {})
    stub_module("sage-llm.prompt", {})
    stub_module("sage-llm.api", {})
    stub_module("sage-llm.actions", {})
    stub_module("sage-llm.conversation", {
      is_active = function()
        return false
      end,
    })
    stub_module("sage-llm.ui", {
      response = {
        is_open = function()
          return false
        end,
        show = function()
          return false
        end,
      },
      input = {
        open = function(_) end,
      },
    })
    stub_module("sage-llm.models", {
      select = function() end,
      remove = function()
        remove_calls = remove_calls + 1
      end,
    })

    local sage = require("sage-llm")
    sage.remove_model()

    assert.equals(1, remove_calls)
  end)

  it("applies search per query and resets after submit", function()
    local stream_opts = {}
    local stream_calls = 0
    local input_calls = 0

    stub_module("sage-llm.config", {
      options = {
        input = { height = 5, followup_prompt = "Follow-up question:" },
        debug = false,
      },
    })
    stub_module("sage-llm.selection", {
      get_visual_selection = function()
        return nil
      end,
    })
    stub_module("sage-llm.prompt", {
      format_question_header = function(question)
        return "Question: " .. question
      end,
      build_messages_no_selection = function(question)
        return {
          { role = "user", content = question },
        }
      end,
    })
    stub_module("sage-llm.api", {
      stream_chat = function(_, callbacks, opts)
        stream_calls = stream_calls + 1
        stream_opts[stream_calls] = opts
        if callbacks.on_complete then
          callbacks.on_complete()
        end
        return {
          cancel = function() end,
        }
      end,
    })
    stub_module("sage-llm.actions", {})
    stub_module("sage-llm.models", {})
    stub_module("sage-llm.conversation", {
      start = function(_) end,
      accumulate_token = function(_) end,
      finish_response = function() end,
    })
    stub_module("sage-llm.ui", {
      response = {
        open = function(_)
          return true
        end,
        show_loading = function() end,
        start_streaming = function() end,
        append_token = function(_) end,
        complete = function() end,
        show_error = function(_) end,
        set_request_handle = function(_) end,
        set_on_followup = function(_) end,
        set_on_toggle_search = function(_) end,
        set_search_enabled = function(_) end,
      },
      input = {
        open = function(opts)
          input_calls = input_calls + 1
          if input_calls == 1 then
            opts.on_toggle_search()
          end
          opts.on_submit("question " .. input_calls)
        end,
      },
    })

    local sage = require("sage-llm")
    sage.ask()
    sage.ask()

    assert.equals(2, stream_calls)
    assert.is_true(stream_opts[1].search)
    assert.is_false(stream_opts[2].search)
  end)

  it("runs infill flow and applies replacement", function()
    local chat_calls = 0
    local applied = 0
    local set_edit_actions_calls = 0

    stub_module("sage-llm.config", {
      options = {
        input = { height = 5, infill_prompt = "Describe the edit:" },
      },
    })
    stub_module("sage-llm.selection", {
      get_visual_selection = function()
        return {
          text = "print('old')",
          bufnr = 1,
          start_line = 1,
          end_line = 1,
          start_col = 0,
          end_col = 12,
          mode = "v",
          filetype = "python",
          filepath = "x.py",
        }
      end,
    })
    stub_module("sage-llm.prompt", {
      format_code_header = function(_)
        return "```python\nprint('old')\n```\n"
      end,
      build_infill_messages = function(_, _)
        return {
          { role = "user", content = "infill" },
        }
      end,
      format_infill_preview = function(_, replacement, _)
        return replacement
      end,
    })
    stub_module("sage-llm.api", {
      chat = function(_, cb, _)
        chat_calls = chat_calls + 1
        cb("print('new')", nil)
        return { cancel = function() end }
      end,
    })
    stub_module("sage-llm.actions", {})
    stub_module("sage-llm.models", {})
    stub_module("sage-llm.conversation", {
      is_active = function()
        return false
      end,
    })
    stub_module("sage-llm.infill", {
      normalize_response = function(text)
        return text, nil
      end,
      apply_selection = function(_, _)
        applied = applied + 1
        return true, nil
      end,
    })
    stub_module("sage-llm.ui", {
      response = {
        open = function(_) return true end,
        show_loading = function() end,
        start_streaming = function() end,
        append_token = function(_) end,
        complete = function() end,
        set_on_followup = function(_) end,
        set_request_handle = function(_) end,
        set_edit_actions = function(on_accept, _)
          set_edit_actions_calls = set_edit_actions_calls + 1
          on_accept()
        end,
        clear_edit_actions = function() end,
        set_search_enabled = function(_) end,
      },
      input = {
        open = function(opts)
          opts.on_submit("replace with new call")
        end,
      },
    })

    local sage = require("sage-llm")
    sage.infill()

    assert.equals(1, chat_calls)
    assert.equals(1, set_edit_actions_calls)
    assert.equals(1, applied)
  end)
end)
