describe("T3 incremental replies", function()
  local client, original, calls, timers, updates, completed, errors, handle, connection

  local function drain()
    local done = false
    vim.schedule(function()
      done = true
    end)
    assert.is_true(vim.wait(1000, function()
      return done
    end))
  end

  local function respond(call, value, code)
    call.callback({ code = code or 0, signal = 0, stdout = vim.json.encode(value), stderr = "" })
    drain()
  end

  local function advance()
    local timer = table.remove(timers, 1)
    if timer and not timer.closed then
      timer.callback()
    end
    drain()
    return calls[#calls]
  end

  local function start()
    handle = client.stream(connection, "thread-one", "Question: Why?", {
      on_update = function(text)
        updates[#updates + 1] = text
      end,
      on_complete = function(text)
        completed[#completed + 1] = text
      end,
      on_error = function(err)
        errors[#errors + 1] = err
      end,
    })
    return calls[1] and calls[1].opts.stdin
  end

  local function snapshot(messages)
    return { thread = { threadId = "thread-one", status = "running" }, messages = messages }
  end

  before_each(function()
    original = { system = vim.system, defer_fn = vim.defer_fn }
    package.loaded["sage-llm.t3_client"] = nil
    calls, timers, updates, completed, errors = {}, {}, {}, {}, {}
    connection = {
      command = "/opt/t3 cli",
      cwd = "/tmp",
      env = { T3CODE_HOME = "/tmp/t3" },
      base_dir = "/tmp/t3 home",
      timeout_ms = 15000,
      response_timeout_ms = 600000,
      poll_interval_ms = 500,
    }
    vim.system = function(args, opts, callback)
      local call = { args = args, opts = opts, callback = callback, killed = false }
      calls[#calls + 1] = call
      return {
        kill = function()
          call.killed = true
        end,
      }
    end
    vim.defer_fn = function(callback)
      local timer = { callback = callback, closed = false }
      timers[#timers + 1] = timer
      return {
        is_closing = function()
          return timer.closed
        end,
        stop = function() end,
        close = function()
          timer.closed = true
        end,
      }
    end
    client = require("sage-llm.t3_client")
  end)

  after_each(function()
    if handle then
      handle.cancel()
    end
    handle = nil
    vim.system, vim.defer_fn = original.system, original.defer_fn
    package.loaded["sage-llm.t3_client"] = nil
  end)

  it("waits for the submitted turn and displays its text before completion", function()
    local message = start()
    assert.truthy(message:find("Question: Why?", 1, true))
    assert.same({
      "/opt/t3 cli",
      "thread",
      "send",
      "thread-one",
      "-",
      "--wait",
      "--json",
      "--base-dir",
      "/tmp/t3 home",
    }, calls[1].args)
    assert.equals(600000, calls[1].opts.timeout)
    local read = advance()
    assert.same({
      "/opt/t3 cli",
      "thread",
      "show",
      "thread-one",
      "--messages",
      "1000",
      "--json",
      "--base-dir",
      "/tmp/t3 home",
    }, read.args)
    assert.equals(15000, read.opts.timeout)
    assert.equals("/tmp", read.opts.cwd)
    assert.equals("/tmp/t3", read.opts.env.T3CODE_HOME)
    respond(
      read,
      snapshot({
        { role = "assistant", runId = "older", text = "Unrelated old answer" },
        { role = "user", runId = "our-run", text = message },
        { role = "assistant", runId = "our-run", text = "Ownership" },
      })
    )
    assert.same({ "Ownership" }, updates)
    assert.equals(0, #completed)
    respond(
      advance(),
      snapshot({
        { role = "assistant", runId = "our-run", text = "Ownership moved" },
        { role = "assistant", runId = "later-run", text = "Someone else's answer" },
      })
    )
    assert.same({ "Ownership", "Ownership moved" }, updates)
    respond(calls[1], {
      threadId = "thread-one",
      runId = "our-run",
      status = "completed",
      reply = "Ownership moved.",
    })
    assert.same({ "Ownership moved." }, completed)
    local count = #calls
    advance()
    assert.equals(count, #calls)
  end)

  it("uses unique correlation even when identical questions are queued", function()
    local message = start()
    respond(
      advance(),
      snapshot({
        { role = "user", runId = "other", text = "Question: Why?" },
        { role = "assistant", runId = "other", text = "Wrong reply" },
      })
    )
    assert.equals(0, #updates)
    respond(
      advance(),
      snapshot({
        { role = "user", runId = "ours", text = message },
        { role = "assistant", runId = "ours", text = "Correct reply" },
      })
    )
    assert.same({ "Correct reply" }, updates)
  end)

  it(
    "delivers rewritten snapshots and multiple assistant messages without duplicating unchanged text",
    function()
      local message = start()
      local messages = {
        { role = "user", runId = "ours", text = message },
        { role = "assistant", runId = "ours", text = "Draft" },
      }
      respond(advance(), snapshot(messages))
      respond(advance(), snapshot(messages))
      messages[2].text = "Revised"
      messages[3] = { role = "assistant", runId = "ours", text = "Answer" }
      respond(advance(), snapshot(messages))
      assert.same({ "Draft", "Revised\n\nAnswer" }, updates)
    end
  )

  it("does not confuse snapshot read failures or a different thread with completion", function()
    start()
    respond(advance(), { thread = { threadId = "another" }, messages = {} })
    local read = advance()
    read.callback({ code = 1, signal = 0, stdout = "", stderr = "network failure" })
    drain()
    assert.equals(0, #errors)
    assert.equals(0, #completed)
    respond(
      calls[1],
      { threadId = "thread-one", runId = "ours", status = "completed", reply = "Final" }
    )
    assert.same({ "Final" }, completed)
  end)

  it(
    "cancels local processes and ignores late output without interrupting the T3 thread",
    function()
      local message = start()
      local read = advance()
      handle.cancel()
      assert.is_true(calls[1].killed)
      assert.is_true(read.killed)
      respond(
        read,
        snapshot({
          { role = "user", runId = "ours", text = message },
          { role = "assistant", runId = "ours", text = "Late" },
        })
      )
      respond(
        calls[1],
        { threadId = "thread-one", runId = "ours", status = "completed", reply = "Late final" }
      )
      advance()
      assert.equals(2, #calls)
      assert.same({}, updates)
      assert.same({}, completed)
      assert.same({}, errors)
    end
  )

  it("stops in-flight snapshot reads when the authoritative reply arrives", function()
    local message = start()
    local read = advance()
    respond(
      calls[1],
      { threadId = "thread-one", runId = "ours", status = "completed", reply = "Final" }
    )
    assert.is_true(read.killed)
    respond(
      read,
      snapshot({
        { role = "user", runId = "ours", text = message },
        { role = "assistant", runId = "ours", text = "Late draft" },
      })
    )
    assert.same({}, updates)
    assert.same({ "Final" }, completed)
  end)

  for _, status in ipairs({ "failed", "cancelled", "interrupted", "rolled_back" }) do
    it(
      "reports a " .. status .. " turn without treating partial text as a completed answer",
      function()
        start()
        respond(calls[1], {
          threadId = "thread-one",
          runId = "ours",
          status = status,
          error = "verbose stack trace",
        }, 1)
        assert.equals(0, #completed)
        assert.truthy(errors[1]:find(status, 1, true))
        assert.is_nil(errors[1]:find("stack trace", 1, true))
      end
    )
  end

  it("directs pending approvals and questions to T3 Code", function()
    start()
    respond(
      calls[1],
      { threadId = "thread-one", runId = "ours", status = "waiting", reply = vim.NIL },
      2
    )
    assert.truthy(errors[1]:find("T3 Code", 1, true))
    assert.truthy(errors[1]:find("input or approval", 1, true))
  end)

  it("treats a timeout as ambiguous and never resends the message", function()
    start()
    calls[1].callback({ code = 124, signal = 15, stdout = "", stderr = "" })
    drain()
    advance()
    assert.equals(1, #calls)
    assert.truthy(errors[1]:find("before retrying", 1, true))
  end)

  it("reports malformed or missing final reply data", function()
    start()
    respond(calls[1], { threadId = "wrong", status = "completed", reply = "Wrong reply" })
    assert.equals(0, #completed)
    assert.equals(1, #errors)
  end)

  it("reports a completed turn without text as complete but without a reply", function()
    start()
    respond(calls[1], { threadId = "thread-one", runId = "ours", status = "completed", reply = "" })
    assert.truthy(errors[1]:find("completed without a text reply", 1, true))
    assert.equals(0, #completed)
  end)

  it("handles synchronous spawn failure without scheduling reads", function()
    vim.system = function()
      error("spawn failed")
    end
    assert.has_no.errors(start)
    advance()
    assert.equals(1, #errors)
  end)

  it("mirrors partial output through real CLI processes before the waiter completes", function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local executable, capture = directory .. "/t3 fixture", directory .. "/request"
    local reply, pipe = directory .. "/snapshot", directory .. "/completion"
    vim.fn.writefile({
      "#!/bin/sh",
      'if [ "$1" = thread ] && [ "$2" = send ]; then',
      "  cat > " .. vim.fn.shellescape(capture),
      "  exec cat " .. vim.fn.shellescape(pipe),
      'elif [ "$1" = thread ] && [ "$2" = show ]; then',
      "  exec cat " .. vim.fn.shellescape(reply),
      "else exit 1; fi",
    }, executable)
    vim.fn.setfperm(executable, "rwx------")
    local made = original.system({ "mkfifo", pipe }):wait(1000)
    assert.equals(0, made.code)
    vim.system, vim.defer_fn = original.system, original.defer_fn
    connection.command, connection.poll_interval_ms = executable, 10
    local fd
    local ok, err = pcall(function()
      start()
      local message
      assert.is_true(vim.wait(3000, function()
        if vim.fn.filereadable(capture) ~= 1 then
          return false
        end
        message = table.concat(vim.fn.readfile(capture), "\n")
        return message:sub(-14) == "Question: Why?"
      end))
      local messages = {
        { role = "user", runId = "ours", text = message },
        { role = "assistant", runId = "ours", text = "Partial λ" },
      }
      vim.fn.writefile({ vim.json.encode(snapshot(messages)) }, reply)
      assert.is_true(vim.wait(3000, function()
        return updates[1] == "Partial λ"
      end))
      assert.equals(0, #completed)
      messages[2].text = "Revised λ"
      vim.fn.writefile({ vim.json.encode(snapshot(messages)) }, reply)
      assert.is_true(vim.wait(3000, function()
        return updates[#updates] == "Revised λ"
      end))
      local uv = vim.uv or vim.loop
      assert.is_true(vim.wait(3000, function()
        fd = uv.fs_open(pipe, uv.constants.O_WRONLY + uv.constants.O_NONBLOCK, 384)
        return fd ~= nil
      end))
      uv.fs_write(
        fd,
        vim.json.encode({
          threadId = "thread-one",
          runId = "ours",
          status = "completed",
          reply = "Final λ",
        }),
        -1
      )
      uv.fs_close(fd)
      fd = nil
      assert.is_true(vim.wait(3000, function()
        return #completed > 0
      end))
      assert.same({ "Final λ" }, completed)
      assert.same({}, errors)
    end)
    if fd then
      (vim.uv or vim.loop).fs_close(fd)
    end
    if handle then
      handle.cancel()
    end
    vim.fn.delete(directory, "rf")
    if not ok then
      error(err)
    end
  end)
end)
