local config = require("sage-llm.config")
local installer = require("sage-llm.local_install")
local curl = require("plenary.curl")

local M = {}

local state = {
  job_id = nil,
  owned = false,
  host = nil,
  port = nil,
  model = nil,
  binary = nil,
  log_path = nil,
  starting = false,
  ready = false,
}

---@param msg string
local function notify_info(msg)
  vim.schedule(function()
    vim.notify("sage-llm: " .. msg, vim.log.levels.INFO)
  end)
end

---@return string
local function log_path(port)
  local dir = vim.fn.stdpath("cache") .. "/sage-llm/llama.cpp"
  vim.fn.mkdir(dir, "p")
  return dir .. "/server-" .. tostring(port) .. ".log"
end

---@param path string
---@param lines string[]
local function append_log(path, lines)
  if not path or not lines or #lines == 0 then
    return
  end
  local file = io.open(path, "a")
  if not file then
    return
  end
  for _, line in ipairs(lines) do
    file:write(line .. "\n")
  end
  file:close()
end

---@param port number
---@return boolean
local function port_available(port)
  local server = vim.uv and vim.uv.new_tcp and vim.uv.new_tcp() or nil
  if not server then
    return true
  end
  local ok = server:bind("127.0.0.1", port)
  server:close()
  return ok == 0
end

---@param port number|string
---@return number|nil, string|nil
local function resolve_port(port)
  if port ~= "auto" then
    return tonumber(port), nil
  end

  for candidate = 8080, 8099 do
    if port_available(candidate) then
      return candidate, nil
    end
  end

  return nil, "No available local llama.cpp port found in 8080-8099"
end

---@return string|nil, string|nil
local function resolve_binary()
  local opts = config.options.llama_cpp
  if opts.binary and opts.binary ~= "" then
    if vim.fn.executable(opts.binary) == 1 then
      return opts.binary, nil
    end
    return nil, "Configured llama_cpp.binary is not executable: " .. opts.binary
  end

  local managed = installer.managed_binary(opts)
  if managed then
    return managed, nil
  end

  if vim.fn.executable("llama-server") == 1 then
    return "llama-server", nil
  end

  if opts.auto_install then
    notify_info("Installing llama.cpp server...")
    return installer.install(opts)
  end

  return nil, "llama-server not found. Install llama.cpp or enable llama_cpp.auto_install"
end

---@param model table|nil
---@return table|nil, string|nil
local function resolve_model(model)
  model = model or config.get_llama_cpp_model()
  if model then
    return model, nil
  end

  local current = config.options.model
  if current and current ~= "" then
    return {
      name = current,
      hf_repo = current,
    }, nil
  end

  return nil, "No local llama.cpp model configured"
end

---@param model table
---@param binary string
---@param host string
---@param port number
---@return string[]
function M.build_args(model, binary, host, port)
  local opts = config.options.llama_cpp
  local args = { binary }

  if model.model_path and model.model_path ~= "" then
    vim.list_extend(args, { "--model", model.model_path })
  elseif model.hf_repo and model.hf_repo ~= "" then
    vim.list_extend(args, { "--hf-repo", model.hf_repo })
    if model.hf_file and model.hf_file ~= "" then
      vim.list_extend(args, { "--hf-file", model.hf_file })
    end
  end

  vim.list_extend(args, { "--alias", model.name or model.hf_repo or model.model_path })
  vim.list_extend(args, { "--host", host, "--port", tostring(port), "--no-webui" })

  local ctx_size = model.ctx_size or opts.ctx_size
  if ctx_size then
    vim.list_extend(args, { "--ctx-size", tostring(ctx_size) })
  end

  local gpu_layers = model.gpu_layers or opts.gpu_layers
  if gpu_layers then
    vim.list_extend(args, { "--n-gpu-layers", tostring(gpu_layers) })
  end

  local threads = model.threads or opts.threads
  if threads then
    vim.list_extend(args, { "--threads", tostring(threads) })
  end

  vim.list_extend(args, model.extra_args or opts.extra_args or {})

  return args
end

---@return string|nil
function M.get_base_url()
  if not state.port then
    return nil
  end
  return "http://" .. (state.host or config.options.llama_cpp.host) .. ":" .. state.port .. "/v1"
end

---@param callback fun(ok: boolean, err: string|nil)
local function wait_until_ready(callback)
  local opts = config.options.llama_cpp
  local started_at = vim.loop.now()
  local url = "http://" .. state.host .. ":" .. state.port .. "/v1/health"

  local function poll()
    curl.get(url, {
      callback = function(response)
        vim.schedule(function()
          if response and response.status == 200 then
            state.ready = true
            state.starting = false
            callback(true, nil)
            return
          end

          if vim.loop.now() - started_at >= opts.startup_timeout_ms then
            state.starting = false
            callback(
              false,
              "llama-server did not become ready before timeout. Log: "
                .. (state.log_path or "unknown")
            )
            return
          end

          vim.defer_fn(poll, opts.health_check_interval_ms)
        end)
      end,
    })
  end

  poll()
end

---@param model table|nil
---@param callback fun(ok: boolean, err: string|nil)
function M.start(model, callback)
  callback = callback or function() end

  if state.ready then
    callback(true, nil)
    return
  end

  if state.starting then
    wait_until_ready(callback)
    return
  end

  local resolved_model, model_err = resolve_model(model)
  if not resolved_model then
    callback(false, model_err)
    return
  end

  local port, port_err = resolve_port(config.options.llama_cpp.port)
  if not port then
    callback(false, port_err)
    return
  end

  local binary, binary_err = resolve_binary()
  if not binary then
    callback(false, binary_err)
    return
  end

  local host = config.options.llama_cpp.host
  local log = log_path(port)
  local args = M.build_args(resolved_model, binary, host, port)

  state.host = host
  state.port = port
  state.model = resolved_model.name or resolved_model.hf_repo or resolved_model.model_path
  state.binary = binary
  state.log_path = log
  state.starting = true
  state.ready = false
  state.owned = true

  append_log(log, { "Starting llama-server: " .. table.concat(args, " ") })

  local job_id = vim.fn.jobstart(args, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      append_log(log, data)
    end,
    on_stderr = function(_, data)
      append_log(log, data)
    end,
    on_exit = function(_, code)
      append_log(log, { "llama-server exited with code " .. tostring(code) })
      state.job_id = nil
      state.ready = false
      state.starting = false
    end,
  })

  if job_id <= 0 then
    state.starting = false
    state.owned = false
    callback(false, "Failed to start llama-server")
    return
  end

  state.job_id = job_id
  wait_until_ready(callback)
end

---@param callback fun(ok: boolean, err: string|nil)
function M.ensure_ready(callback)
  if state.ready then
    callback(true, nil)
    return
  end

  if not config.options.llama_cpp.auto_start then
    callback(false, "llama.cpp server is not running and llama_cpp.auto_start is disabled")
    return
  end

  M.start(nil, callback)
end

---@return boolean, string|nil
function M.stop()
  if not state.job_id then
    return false, "No plugin-owned llama-server is running"
  end

  if not state.owned then
    return false, "Current llama-server was not started by sage-llm"
  end

  vim.fn.jobstop(state.job_id)
  state.job_id = nil
  state.ready = false
  state.starting = false
  state.owned = false
  return true, nil
end

---@return table
function M.status()
  return vim.deepcopy(state)
end

---@param hf_repo string
---@param callback fun(ok: boolean, err: string|nil)
function M.setup_model(hf_repo, callback)
  hf_repo = vim.trim(hf_repo or "")
  if hf_repo == "" then
    callback(false, "Model string is required")
    return
  end

  local entry = config.add_llama_cpp_model({
    name = hf_repo,
    hf_repo = hf_repo,
    ctx_size = config.options.llama_cpp.ctx_size,
    gpu_layers = config.options.llama_cpp.gpu_layers,
  })
  config.set_provider("llama_cpp")
  config.set_model(entry.name)
  M.start(entry, callback)
end

---@param callback fun(ok: boolean, err: string|nil, binary: string|nil)
function M.install(callback)
  local binary, err = resolve_binary()
  if not binary then
    callback(false, err, nil)
    return
  end
  callback(true, nil, binary)
end

function M.setup_autocmd()
  if not config.options.llama_cpp.stop_on_exit then
    return
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("sage_llm_local", { clear = true }),
    callback = function()
      if state.job_id and state.owned then
        pcall(vim.fn.jobstop, state.job_id)
      end
    end,
  })
end

return M
