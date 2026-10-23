local config = require("sage-llm.config")
local selection = require("sage-llm.selection")
local prompt = require("sage-llm.prompt")
local input = require("sage-llm.ui.input")
local response = require("sage-llm.ui.response")
local conversation = require("sage-llm.conversation")
local client = require("sage-llm.t3_client")

local M = {}

---@class SageT3Thread
---@field threadId string
---@field title string
---@field status string|nil

---@class SageT3Connection
---@field command string
---@field cwd string
---@field base_dir string|nil
---@field timeout_ms number
---@field response_timeout_ms number
---@field poll_interval_ms number
---@field project string
---@field env table<string, string|boolean>
---@field key string

-- Destinations last only for this Neovim session and are scoped to the source
-- working directory and T3 connection. Never infer a target from recency.
---@type table<string, SageT3Thread>
local destinations = {}
local current_view

local function notify(message, level)
  vim.notify("sage-llm: " .. message, level or vim.log.levels.INFO)
end

---Capture connection settings before any asynchronous work or floating UI.
---@return SageT3Connection|nil
local function session()
  local opts = config.options.t3
  local command = vim.fn.expand(opts.command)
  if vim.fn.executable(command) ~= 1 and command == "t3" then
    command = vim.fn.expand("~/.t3/bin/t3")
  end
  if vim.fn.executable(command) ~= 1 then
    notify(
      "T3 CLI not found. Install T3's t3 command or set t3.command in Sage setup.",
      vim.log.levels.ERROR
    )
    return nil
  end

  local cwd = vim.fn.getcwd()
  local base_dir = opts.base_dir and vim.fn.fnamemodify(vim.fn.expand(opts.base_dir), ":p") or nil
  -- T3CODE_HOME is part of the connection even when base_dir is not configured.
  local home = vim.env.T3CODE_HOME
  return {
    command = command,
    cwd = cwd,
    base_dir = base_dir,
    timeout_ms = opts.timeout_ms,
    response_timeout_ms = opts.response_timeout_ms,
    poll_interval_ms = opts.poll_interval_ms,
    project = opts.project or cwd,
    env = { T3CODE_HOME = home or false },
    key = vim.json.encode({ cwd, command, base_dir or home or "", opts.project or cwd }),
  }
end

---@param connection SageT3Connection
---@param on_select fun(thread: SageT3Thread)
local function pick_thread(connection, on_select)
  client.list(connection, function(result, err)
    if result == nil and err ~= "unexpected" then
      notify(
        "Could not list T3 threads. Start T3 Code, register this project, and check that your CLI supports "
          .. "t3 thread list --json (older builds need an update).",
        vim.log.levels.ERROR
      )
      return
    end
    if type(result) ~= "table" or not vim.islist(result) then
      notify(
        "T3 returned an unexpected thread list. Update the t3 CLI to match the server.",
        vim.log.levels.ERROR
      )
      return
    end

    local threads = {}
    for _, thread in ipairs(result) do
      if
        type(thread) ~= "table"
        or type(thread.threadId) ~= "string"
        or thread.threadId == ""
        or type(thread.title) ~= "string"
      then
        notify(
          "T3 returned an unexpected thread list. Update the t3 CLI to match the server.",
          vim.log.levels.ERROR
        )
        return
      end
      if not thread.settled and thread.relationshipToParent ~= "subagent" then
        threads[#threads + 1] = thread
      end
    end
    if #threads == 0 then
      notify(
        "No open T3 threads for this project. Open or restore a thread in T3 Code first.",
        vim.log.levels.WARN
      )
      return
    end

    vim.ui.select(threads, {
      prompt = "Send Sage questions to T3 thread:",
      format_item = function(thread)
        return string.format(
          "%s [%s] (%s)",
          thread.title,
          thread.status or "unknown",
          thread.threadId
        )
      end,
    }, function(thread)
      if not thread then
        return
      end
      destinations[connection.key] = thread
      on_select(thread)
    end)
  end)
end

---Stream one reply into the current Sage window. Conversation history remains
---local display state; T3 owns the actual remote conversation and its context.
local function stream_reply(view, message)
  local settled, started = false, false
  response.show_loading()
  local handle = client.stream(view.connection, view.thread.threadId, message, {
    on_update = function(text)
      if settled then
        return
      end
      if not started then
        response.start_streaming()
        started = true
      end
      response.set_response_text(text)
    end,
    on_complete = function(text)
      if settled then
        return
      end
      settled = true
      if not started then
        response.start_streaming()
      end
      response.set_response_text(text)
      conversation.accumulate_token(text)
      conversation.finish_response()
      response.complete()
    end,
    on_error = function(err)
      if settled then
        return
      end
      settled = true
      conversation.discard_response()
      response.set_request_handle(nil)
      response.show_error(err)
    end,
  })
  if not settled then
    response.set_request_handle({
      cancel = function()
        if settled then
          return
        end
        settled = true
        handle.cancel()
        conversation.discard_response()
      end,
    })
  end
end

---Follow up on the T3 conversation displayed in Sage, retaining its destination.
function M.followup()
  local view = current_view
  if not view or not conversation.is_active() or conversation.get_backend() ~= "t3" then
    notify("No active T3 conversation", vim.log.levels.WARN)
    return
  end
  if not response.is_open() then
    notify("Response window is hidden (use :SageView)", vim.log.levels.WARN)
    return
  end
  if response.is_streaming() then
    notify("Wait for response to complete", vim.log.levels.WARN)
    return
  end
  input.open({
    prompt = "Follow-up to T3: " .. view.thread.title,
    on_submit = function(question)
      if vim.trim(question) == "" then
        return
      end
      if current_view ~= view or conversation.get_backend() ~= "t3" then
        notify("The conversation changed. Reopen the follow-up question.", vim.log.levels.WARN)
        return
      end
      response.append_followup_header(prompt.format_followup_header(question))
      conversation.add_followup(question)
      stream_reply(view, question)
    end,
  })
end

---Choose a destination for subsequent questions in this working directory.
function M.select_thread()
  local connection = session()
  if not connection then
    return
  end
  pick_thread(connection, function(thread)
    notify("T3 destination: " .. thread.title)
  end)
end

---Ask an existing T3 thread about the current visual selection.
---Mirror the T3 reply in Sage while T3 retains the remote conversation.
function M.ask()
  local sel, err = selection.get_visual_selection()
  if not sel then
    notify(err or "No visual selection found", vim.log.levels.WARN)
    return
  end
  local connection = session()
  if not connection then
    return
  end

  local path = vim.api.nvim_buf_get_name(sel.bufnr)
  local location =
    string.format("%s:%d-%d", path ~= "" and path or "[buffer]", sel.start_line, sel.end_line)
  -- Snapshot diagnostics and dependencies along with unsaved text before the
  -- picker/input changes the current buffer or the user changes directories.
  local context = table.concat({
    "Working directory: " .. connection.cwd,
    "Source: " .. location,
    prompt.build_selection_context(sel),
  }, "\n")

  local function ask_thread(thread)
    input.open({
      prompt = "Ask T3: " .. thread.title,
      on_submit = function(question)
        if vim.trim(question) == "" then
          return
        end
        local message = context .. "\n\nQuestion: " .. question
        response.open(
          prompt.format_code_header(sel) .. prompt.format_question_header(question),
          { title = "T3: " .. thread.title }
        )
        current_view = { connection = connection, thread = thread }
        conversation.start({ { role = "user", content = message } }, { backend = "t3" })
        response.set_on_followup(M.followup)
        response.set_on_toggle_search(nil)
        response.set_search_enabled(false)
        stream_reply(current_view, message)
      end,
    })
  end

  local destination = destinations[connection.key]
  if destination then
    ask_thread(destination)
  else
    pick_thread(connection, ask_thread)
  end
end

return M
