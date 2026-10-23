describe("T3 thread handoff", function()
  local t3, config, original, calls, notices, picks, input, sel, bufnr, namespace, window, conversation
  local modules = {
    "sage-llm",
    "sage-llm.ui",
    "sage-llm.t3",
    "sage-llm.t3_client",
    "sage-llm.prompt",
    "sage-llm.selection",
    "sage-llm.ui.input",
    "sage-llm.ui.response",
    "sage-llm.conversation",
  }
  local saved_modules

  local function finish(result, call)
    call = call or calls[#calls]
    call.callback(
      vim.tbl_extend("force", { code = 0, signal = 0, stdout = "", stderr = "" }, result)
    )
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    assert.is_true(vim.wait(1000, function()
      return drained
    end))
  end

  local function list_threads()
    finish({
      stdout = vim.json.encode({
        { threadId = "thread-one", title = "Fix compiler errors", status = "idle" },
        { threadId = "thread-two", title = "Investigate ownership", status = "running" },
        { threadId = "settled", title = "Old work", settled = true },
        { threadId = "child", title = "Child review", relationshipToParent = "subagent" },
      }),
    })
  end

  before_each(function()
    saved_modules = {}
    for _, name in ipairs(modules) do
      saved_modules[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    config = require("sage-llm.config")
    original = {
      system = vim.system,
      select = vim.ui.select,
      notify = vim.notify,
      executable = vim.fn.executable,
      options = config.options,
      cwd = vim.fn.getcwd(),
      t3_home = vim.env.T3CODE_HOME,
    }
    config.options = vim.deepcopy(config.defaults)
    config.options.api_key = nil
    config.options.t3 = vim.deepcopy(config.defaults.t3)
    calls, notices, picks, input = {}, {}, {}, nil
    window = {}
    conversation = require("sage-llm.conversation")
    package.loaded["sage-llm.ui.response"] = {
      open = function(header, opts)
        if window.handle then
          window.handle.cancel()
        end
        window = { header = header, title = opts.title, open = true }
        conversation.reset()
        return true
      end,
      show_loading = function()
        window.streaming = true
      end,
      start_streaming = function() end,
      set_response_text = function(text)
        window.text = text
      end,
      complete = function()
        window.complete = true
        window.streaming = false
        window.handle = nil
      end,
      show_error = function(err)
        window.error = err
        window.streaming = false
      end,
      set_request_handle = function(handle)
        window.handle = handle
      end,
      set_on_followup = function(callback)
        window.followup = callback
      end,
      set_on_toggle_search = function() end,
      set_search_enabled = function() end,
      append_followup_header = function(header)
        window.followup_header = header
      end,
      is_open = function()
        return window.open
      end,
      is_streaming = function()
        return window.streaming
      end,
      show = function()
        window.open = true
        return true
      end,
      get_geometry = function()
        return nil
      end,
    }
    vim.system = function(args, opts, callback)
      calls[#calls + 1] = { args = args, opts = opts, callback = callback }
      return { kill = function() end }
    end
    vim.fn.executable = function()
      return 1
    end
    vim.ui.select = function(items, opts, callback)
      picks[#picks + 1] = { items = items, opts = opts, callback = callback }
    end
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = message, level = level }
    end
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, original.cwd .. "/src/example.rs")
    vim.api.nvim_buf_set_lines(
      bufnr,
      0,
      -1,
      false,
      { "outside", "let a = value;", "consume(a);", "outside" }
    )
    namespace = vim.api.nvim_create_namespace("sage-t3-contract")
    vim.diagnostic.set(namespace, bufnr, {
      {
        lnum = 0,
        col = 0,
        message = "Outside selection",
        severity = vim.diagnostic.severity.ERROR,
      },
      {
        lnum = 2,
        col = 0,
        message = "Value moved",
        code = "E0382",
        source = "rustc",
        severity = vim.diagnostic.severity.ERROR,
      },
    })
    sel = {
      bufnr = bufnr,
      text = "let a = value;\nconsume(a);",
      filepath = "src/example.rs",
      filetype = "rust",
      start_line = 2,
      end_line = 3,
      start_col = 0,
      end_col = 11,
      mode = "V",
    }
    package.loaded["sage-llm.selection"] = {
      get_visual_selection = function()
        return sel, "No visual selection found"
      end,
    }
    package.loaded["sage-llm.ui.input"] = {
      open = function(opts)
        input = opts
      end,
    }
    t3 = require("sage-llm.t3")
  end)

  after_each(function()
    if window.handle then
      window.handle.cancel()
    end
    vim.system, vim.ui.select, vim.notify = original.system, original.select, original.notify
    vim.fn.executable = original.executable
    config.options = original.options
    vim.env.T3CODE_HOME = original.t3_home
    vim.api.nvim_set_current_dir(original.cwd)
    vim.diagnostic.reset(namespace, bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    for _, name in ipairs(modules) do
      package.loaded[name] = saved_modules[name]
    end
  end)

  it("lists the current project's threads and shows an explicit destination picker", function()
    t3.select_thread()
    assert.same({ "t3", "thread", "list", "--project", original.cwd, "--json" }, calls[1].args)
    assert.equals(original.cwd, calls[1].opts.cwd)
    assert.equals(15000, calls[1].opts.timeout)
    list_threads()
    assert.equals(2, #picks[1].items)
    local label = picks[1].opts.format_item(picks[1].items[2])
    assert.truthy(label:find("Investigate ownership", 1, true))
    assert.truthy(label:find("running", 1, true))
    assert.truthy(label:find("thread-two", 1, true))
  end)

  it("sends captured code, file location, range, diagnostics and question on stdin", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[2])
    assert.truthy(input.prompt:find("Investigate ownership", 1, true))
    input.on_submit("Why does this fail?\n`$HOME` $(touch /tmp/no) 'quoted'")
    assert.equals(2, #calls)
    assert.same({ "t3", "thread", "send", "thread-two", "-", "--wait", "--json" }, calls[2].args)
    assert.truthy(window.title:find("T3", 1, true))
    assert.is_true(window.streaming)
    local message = calls[2].opts.stdin
    for _, expected in ipairs({
      "Working directory: " .. original.cwd,
      "Source: " .. original.cwd .. "/src/example.rs:2-3",
      "File: src/example.rs (rust)",
      "```rust\nlet a = value;\nconsume(a);\n```",
      "Line 3 [error E0382]: Value moved (rustc)",
      "Question: Why does this fail?\n`$HOME` $(touch /tmp/no) 'quoted'",
    }) do
      assert.truthy(message:find(expected, 1, true), expected)
    end
    assert.is_nil(message:find("Outside selection", 1, true))
    assert.is_nil(message:find(config.options.system_prompt, 1, true))
    finish({
      stdout = vim.json.encode({
        threadId = "thread-two",
        runId = "run-two",
        status = "completed",
        reply = "The value was moved.",
      }),
    })
    assert.equals("The value was moved.", window.text)
    assert.is_true(window.complete)
    assert.equals("t3", conversation.get_backend())
    assert.equals(1, conversation.turn_count())
  end)

  it("captures unsaved text, diagnostics and cwd before asynchronous UI changes", function()
    t3.ask()
    sel.text = "different text"
    vim.diagnostic.reset(namespace, bufnr)
    vim.api.nvim_set_current_dir("/tmp")
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit("Explain")
    assert.truthy(calls[2].opts.stdin:find("let a = value;", 1, true))
    assert.truthy(calls[2].opts.stdin:find("Value moved", 1, true))
    assert.equals(original.cwd, calls[2].opts.cwd)
  end)

  it("reuses a chosen thread for the same working directory", function()
    t3.select_thread()
    list_threads()
    picks[1].callback(picks[1].items[1])
    t3.ask()
    assert.equals(1, #calls)
    input.on_submit("Explain")
    assert.equals("thread-one", calls[2].args[4])
  end)

  it("does not reuse a destination from another directory or environment", function()
    t3.select_thread()
    list_threads()
    picks[1].callback(picks[1].items[1])
    vim.api.nvim_set_current_dir("/tmp")
    t3.ask()
    assert.equals("list", calls[2].args[3])
    vim.api.nvim_set_current_dir(original.cwd)
    config.options.t3.base_dir = "/tmp/other-t3"
    t3.ask()
    assert.equals("list", calls[3].args[3])
  end)

  it("allows an explicit thread change without retargeting an open question", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[1])
    local first_input = input
    t3.select_thread()
    list_threads()
    picks[2].callback(picks[2].items[2])
    first_input.on_submit("First target")
    assert.equals("thread-one", calls[3].args[4])
    t3.ask()
    input.on_submit("Second target")
    assert.equals("thread-two", calls[4].args[4])
  end)

  it("honors CLI, project and base directory overrides", function()
    config.options.t3.command = "/opt/t3 cli"
    config.options.t3.project = "project-id"
    config.options.t3.base_dir = "/data/t3 home"
    t3.ask()
    assert.same({
      "/opt/t3 cli",
      "thread",
      "list",
      "--project",
      "project-id",
      "--json",
      "--base-dir",
      "/data/t3 home",
    }, calls[1].args)
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit("Explain")
    assert.same({
      "/opt/t3 cli",
      "thread",
      "send",
      "thread-one",
      "-",
      "--wait",
      "--json",
      "--base-dir",
      "/data/t3 home",
    }, calls[2].args)
  end)

  it("finds T3's installed launcher when it is not on PATH", function()
    local launcher = vim.fn.expand("~/.t3/bin/t3")
    vim.fn.executable = function(path)
      return path == launcher and 1 or 0
    end
    t3.select_thread()
    assert.equals(launcher, calls[1].args[1])
  end)

  it("captures T3CODE_HOME and scopes destinations to it", function()
    vim.env.T3CODE_HOME = "/tmp/t3-first"
    t3.ask()
    list_threads()
    vim.env.T3CODE_HOME = "/tmp/t3-second"
    picks[1].callback(picks[1].items[1])
    input.on_submit("Explain")
    assert.equals("/tmp/t3-first", calls[2].opts.env.T3CODE_HOME)
    t3.ask()
    assert.equals("list", calls[3].args[3])
  end)

  it("uses the real process transport to preserve multiline context on stdin", function()
    -- Exercise the OS boundary without sending a message to a real agent.
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local executable = directory .. "/t3 fixture"
    local capture = directory .. "/message"
    vim.fn.writefile({
      "#!/bin/sh",
      'if [ "$1" = thread ] && [ "$2" = list ]; then',
      '  printf \'%s\\n\' \'[{"threadId":"fixture","title":"Fixture thread","status":"idle"}]\'',
      'elif [ "$1" = thread ] && [ "$2" = send ] && [ "$3" = fixture ] && [ "$4" = - ]; then',
      "  cat > " .. vim.fn.shellescape(capture),
      '  printf \'%s\\n\' \'{"threadId":"fixture","runId":"fixture-run","status":"completed","reply":"Fixture reply"}\'',
      "else exit 1; fi",
    }, executable)
    vim.fn.setfperm(executable, "rwx------")
    vim.system = original.system
    vim.fn.executable = original.executable
    config.options.t3.command = executable
    local ok, err = pcall(function()
      t3.ask()
      assert.is_true(vim.wait(3000, function()
        return #picks == 1
      end))
      picks[1].callback(picks[1].items[1])
      local question = "Why?\n`$HOME` $(false) 'quotes' — λ"
      input.on_submit(question)
      assert.is_true(vim.wait(3000, function()
        return window.complete or window.error
      end))
      assert.equals("Fixture reply", window.text)
      local message = table.concat(vim.fn.readfile(capture), "\n")
      assert.truthy(message:find("Question: " .. question, 1, true))
      assert.truthy(message:find("Value moved", 1, true))
      assert.truthy(message:find(sel.text, 1, true))
    end)
    vim.fn.delete(directory, "rf")
    if not ok then
      error(err)
    end
  end)

  it("does nothing when the picker or input is cancelled", function()
    t3.ask()
    list_threads()
    picks[1].callback(nil)
    assert.is_nil(input)
    assert.equals(1, #calls)
    t3.ask()
    list_threads()
    picks[2].callback(picks[2].items[1])
    if input.on_cancel then
      input.on_cancel()
    end
    assert.equals(2, #calls)
  end)

  it("does not send an empty question", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit(" \n ")
    assert.equals(1, #calls)
  end)

  it("requires a selection before opening UI or contacting T3", function()
    sel = nil
    t3.ask()
    assert.equals(0, #calls)
    assert.is_nil(input)
    assert.truthy(notices[1].message:find("No visual selection", 1, true))
  end)

  it("reports an empty thread list without sending", function()
    t3.ask()
    finish({ stdout = "[]" })
    assert.equals(0, #picks)
    assert.truthy(notices[1].message:find("No open T3 threads", 1, true))
  end)

  for _, stdout in ipairs({ "not json", "{}", '[{"title":"Missing id"}]' }) do
    it("rejects malformed thread results: " .. stdout, function()
      t3.ask()
      finish({ stdout = stdout })
      assert.equals(0, #picks)
      assert.truthy(notices[1].message:find("unexpected", 1, true))
    end)
  end

  it("reports missing CLI with installation instructions", function()
    vim.fn.executable = function()
      return 0
    end
    t3.ask()
    assert.equals(0, #calls)
    assert.truthy(notices[1].message:find("t3", 1, true))
    assert.truthy(notices[1].message:find("command", 1, true))
  end)

  it("reports unsupported CLI/server failures without opening a question", function()
    t3.ask()
    finish({ code = 1, stderr = "Unknown command thread\nverbose stack trace" })
    assert.is_nil(input)
    assert.truthy(notices[1].message:find("t3 thread", 1, true))
    assert.is_nil(notices[1].message:find("stack trace", 1, true))
  end)

  it("reports timeouts without retrying or claiming success", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit("Explain")
    finish({ code = 124, signal = 15 })
    assert.equals(2, #calls)
    assert.is_false(window.streaming)
    assert.truthy(window.error:find("before retrying", 1, true))
  end)

  it("rejects unexpected final replies", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit("Explain")
    finish({ stdout = '{"threadId":"wrong-thread","delivery":"started"}' })
    assert.is_false(window.streaming)
    assert.truthy(window.error:find("before retrying", 1, true))
  end)

  it(
    "routes follow-ups to the same T3 thread even after changing the default destination",
    function()
      t3.ask()
      list_threads()
      picks[1].callback(picks[1].items[1])
      input.on_submit("Explain")
      finish({
        stdout = vim.json.encode({
          threadId = "thread-one",
          runId = "ours",
          status = "completed",
          reply = "First answer",
        }),
      })
      t3.select_thread()
      list_threads()
      picks[2].callback(picks[2].items[2])
      require("sage-llm").followup()
      input.on_submit("What about a clone?")
      assert.equals("thread-one", calls[4].args[4])
      assert.truthy(calls[4].opts.stdin:find("What about a clone?", 1, true))
      assert.is_nil(calls[4].opts.stdin:find("let a = value;", 1, true))
      finish({
        stdout = vim.json.encode({
          threadId = "thread-one",
          runId = "follow-up",
          status = "completed",
          reply = "Second answer",
        }),
      })
      assert.equals("Second answer", window.text)
      assert.equals(2, conversation.turn_count())
    end
  )

  it("ignores old replies after opening another Sage question", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit("First question")
    local old = calls[2]
    t3.ask()
    input.on_submit("Second question")
    finish({
      stdout = vim.json.encode({
        threadId = "thread-one",
        runId = "old",
        status = "completed",
        reply = "Stale answer",
      }),
    }, old)
    assert.is_nil(window.text)
    assert.is_true(window.streaming)
    finish({
      stdout = vim.json.encode({
        threadId = "thread-one",
        runId = "new",
        status = "completed",
        reply = "Current answer",
      }),
    })
    assert.equals("Current answer", window.text)
    assert.equals(1, conversation.turn_count())
  end)

  it("keeps partial text viewable after the local reader is cancelled", function()
    t3.ask()
    list_threads()
    picks[1].callback(picks[1].items[1])
    input.on_submit("Explain")
    window.handle.cancel()
    window.open = false
    require("sage-llm").show_conversation()
    assert.is_true(window.open)
    assert.is_true(conversation.is_active())
    assert.equals("t3", conversation.get_backend())
  end)

  it("handles a process spawn failure", function()
    vim.system = function()
      error("spawn failed")
    end
    assert.has_no.errors(function()
      t3.ask()
    end)
    assert.equals(vim.log.levels.ERROR, notices[#notices].level)
  end)
end)
