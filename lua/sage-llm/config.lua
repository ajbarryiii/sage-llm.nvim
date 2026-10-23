---@class SageConfig
---@field provider string LLM provider: "openrouter", "llama_cpp", or "chatgpt"
---@field api_key string|nil API key for OpenRouter (falls back to $OPENROUTER_API_KEY)
---@field model string Default model to use
---@field base_url string OpenRouter API base URL
---@field llama_cpp SageLlamaCppConfig Local llama.cpp configuration
---@field chatgpt SageChatGPTConfig ChatGPT subscription configuration
---@field t3 SageT3Config T3 Code thread handoff configuration
---@field response SageResponseConfig Response window configuration
---@field input SageInputConfig Input window configuration
---@field detect_dependencies boolean Whether to detect and include dependencies
---@field rag SageRagConfig RAG code search configuration
---@field models string[] Available models for picker
---@field system_prompt string System prompt for the LLM (with code selection)
---@field system_prompt_no_selection string System prompt for the LLM (without code selection)
---@field system_prompt_infill string System prompt for inline edits
---@field debug boolean Enable debug logging to /tmp/sage-llm-debug.log

---@class SageResponseConfig
---@field width number Width as fraction of editor (0-1)
---@field height number Height as fraction of editor (0-1)
---@field border string Border style

---@class SageInputConfig
---@field width number Width as fraction of editor (0-1)
---@field height number Height in lines
---@field border string Border style
---@field prompt string Prompt text shown in title

---@class SageRagConfig
---@field enabled boolean Enable semantic repository context retrieval for :SageAsk
---@field embedding_model string Embedding model used for indexing and search
---@field top_k number Maximum number of retrieved snippets to include
---@field chunk_lines number Number of lines per indexed chunk
---@field chunk_overlap number Overlap lines between chunks
---@field embed_batch_size number Number of chunks per embeddings request
---@field max_context_chars number Maximum total retrieved context characters
---@field max_file_size_kb number Maximum file size (KB) to index
---@field max_chunks_per_file number Maximum snippets per file in retrieval results
---@field min_similarity number Minimum cosine similarity threshold
---@field include string[] Glob patterns for files to include in index
---@field exclude string[] Glob patterns for files to exclude from index
---@field index_dir string|nil Optional custom directory for persisted index cache

---@class SageLlamaCppConfig
---@field auto_install boolean Download llama-server when missing
---@field auto_start boolean Start llama-server automatically for local requests
---@field binary string|nil Path to llama-server. Falls back to managed install or $PATH
---@field install_dir string|nil Directory for managed llama.cpp installs
---@field release_tag string Release tag to install, or "latest"
---@field host string Host to bind/connect to
---@field port number|string Port number or "auto"
---@field startup_timeout_ms number Timeout waiting for server readiness
---@field health_check_interval_ms number Poll interval while waiting for readiness
---@field stop_on_exit boolean Stop plugin-owned server on VimLeavePre
---@field ctx_size number Default context size for local models
---@field gpu_layers number|string Default GPU layers for local models
---@field threads number|nil Default CPU threads for local models
---@field extra_args string[] Extra llama-server args
---@field models table[] Local model entries

---@class SageChatGPTConfig
---@field model string|nil Model slug from the authenticated ChatGPT catalog
---@field auth_dir string|nil Custom directory for private subscription credentials
---@field login_timeout_ms number Timeout waiting for browser login
---@field request_timeout_ms number Timeout for subscription HTTP requests

---@class SageT3Config
---@field command string Path to the T3 CLI executable
---@field base_dir string|nil T3 data directory (otherwise T3CODE_HOME or the CLI default)
---@field project string|nil T3 project id or path (otherwise Neovim's working directory)
---@field timeout_ms number Timeout for listing threads or reading reply snapshots
---@field response_timeout_ms number Maximum wait for a queued or running T3 reply
---@field poll_interval_ms number Delay between reads of incremental T3 reply snapshots

local config_file = require("sage-llm.config_file")

local M = {}

---@type SageConfig
M.defaults = {
  provider = "openrouter",
  api_key = nil,
  model = "openai/gpt-oss-20b",
  base_url = "https://openrouter.ai/api/v1",

  t3 = {
    command = "t3",
    base_dir = nil,
    project = nil,
    timeout_ms = 15000,
    response_timeout_ms = 600000,
    poll_interval_ms = 500,
  },

  chatgpt = {
    model = nil,
    auth_dir = nil,
    login_timeout_ms = 180000,
    request_timeout_ms = 30000,
  },

  llama_cpp = {
    auto_install = true,
    auto_start = true,
    binary = nil,
    install_dir = nil,
    release_tag = "latest",
    host = "127.0.0.1",
    port = "auto",
    startup_timeout_ms = 300000,
    health_check_interval_ms = 500,
    stop_on_exit = true,
    ctx_size = 8192,
    gpu_layers = "auto",
    threads = nil,
    extra_args = {},
    models = {},
  },

  response = {
    width = 0.6,
    height = 0.4,
    border = "rounded",
  },

  input = {
    width = 0.5,
    height = 5,
    border = "rounded",
    prompt = "Ask about this code: ",
    followup_prompt = "Follow-up question:",
    infill_prompt = "Describe the edit:",
  },

  detect_dependencies = false,
  rag = {
    enabled = false,
    embedding_model = "openai/text-embedding-3-small",
    top_k = 6,
    chunk_lines = 80,
    chunk_overlap = 20,
    embed_batch_size = 32,
    max_context_chars = 6000,
    max_file_size_kb = 256,
    max_chunks_per_file = 2,
    min_similarity = 0.2,
    include = {
      "**/*.lua",
      "**/*.md",
      "**/*.txt",
      "**/*.vim",
      "**/*.js",
      "**/*.jsx",
      "**/*.ts",
      "**/*.tsx",
      "**/*.json",
      "**/*.toml",
      "**/*.yaml",
      "**/*.yml",
      "**/*.py",
      "**/*.go",
      "**/*.rs",
      "**/*.c",
      "**/*.h",
      "**/*.cpp",
      "**/*.hpp",
      "**/*.java",
      "**/*.rb",
      "**/*.sh",
    },
    exclude = {
      ".git/**",
      "node_modules/**",
      "dist/**",
      "build/**",
      "target/**",
      ".next/**",
      ".venv/**",
      "vendor/**",
      "**/*.lock",
      "**/*.png",
      "**/*.jpg",
      "**/*.jpeg",
      "**/*.gif",
      "**/*.webp",
      "**/*.pdf",
      "**/*.zip",
      "**/*.gz",
      "**/*.sqlite",
      "**/*.db",
    },
    index_dir = nil,
  },
  debug = false,

  -- OpenRouter IDs verified 2026-09-10; pricing and selection notes are in README.md.
  models = {
    -- Budget choices for everyday questions and edits
    "openai/gpt-oss-20b",
    "inception/mercury-2.5",
    "inception/mercury-2",
    "google/gemini-3.8-flash",
    "openai/gpt-5.6-luna",
    "qwen/qwen3.8-flash",
    "deepseek/deepseek-v4.1-flash",
    -- More capable coding option at a moderate price
    "anthropic/claude-sonnet-5",
    -- Flagships for difficult questions
    "openai/gpt-6-astra",
    "anthropic/claude-fable-5.1",
  },

  system_prompt = [[You are a concise coding tutor helping a developer understand code.

Rules:
- Be brief and direct
- Use `inline code` for short references rather than full code blocks
- Only show multi-line code blocks when essential for understanding
- When explaining errors, focus on the "why" not just the fix
- Reference language concepts by name (e.g., "ownership", "borrow checker", "lifetime")]],

  system_prompt_no_selection = [[You are a concise coding assistant.

Rules:
- Be brief and direct
- Use `inline code` for short references rather than full code blocks
- Only show multi-line code blocks when essential for understanding
- Focus on practical, actionable answers]],

  system_prompt_infill = [[You are an inline code editor.

Rules:
- Return only the replacement code for the selected region
- Do not include markdown fences
- Do not include explanations or commentary
- Preserve the surrounding style and indentation]],
}

---@type SageConfig
M.options = vim.deepcopy(M.defaults)

-- The subscription model is stored separately; remember other provider choices
-- when switching within this Neovim session.
local provider_models = { openrouter = M.defaults.model }

local function first_local_model()
  local model = M.options.llama_cpp.models[1]
  return model and (model.name or model.hf_repo or model.model_path) or "llama.cpp"
end

local function valid_provider(provider)
  return provider == "openrouter" or provider == "llama_cpp" or provider == "chatgpt"
end

---Merge user options with defaults
---Priority: config file > setup() opts > env var > defaults
---@param opts SageConfig|nil
function M.setup(opts)
  opts = opts or {}

  -- Start with defaults
  local base = vim.deepcopy(M.defaults)

  -- Merge setup() opts (lower priority)
  base = vim.tbl_deep_extend("force", base, opts)

  -- Load external config file (highest priority)
  local external, err = config_file.load()
  if external then
    base = vim.tbl_deep_extend("force", base, external)
  elseif err then
    vim.notify_once("sage-llm: " .. err, vim.log.levels.WARN)
  elseif not config_file.exists() then
    -- First run: create template config file
    local created, create_err = config_file.create_template()
    if created then
      vim.notify_once(
        "sage-llm: Created config file at "
          .. config_file.get_config_path()
          .. "\nUse :SageChatGPTLogin for a subscription, or set $OPENROUTER_API_KEY.",
        vim.log.levels.INFO
      )
    elseif create_err then
      vim.notify_once("sage-llm: " .. create_err, vim.log.levels.WARN)
    end
  end

  M.options = base

  -- Validate required fields
  M.validate()

  provider_models = {
    openrouter = base.provider == "llama_cpp" and (base.models[1] or M.defaults.model)
      or base.model,
    llama_cpp = base.provider == "llama_cpp" and base.model or first_local_model(),
  }
  if M.is_chatgpt_provider() then
    M.options.model = M.options.chatgpt.model or "ChatGPT"
  end
end

---Validate configuration
function M.validate()
  if type(M.options.t3) ~= "table" then
    error("sage-llm: t3 config must be a table")
  end

  if type(M.options.rag) ~= "table" then
    error("sage-llm: rag config must be a table")
  end

  if type(M.options.llama_cpp) ~= "table" then
    error("sage-llm: llama_cpp config must be a table")
  end

  if type(M.options.chatgpt) ~= "table" then
    error("sage-llm: chatgpt config must be a table")
  end

  vim.validate({
    ["t3.command"] = { M.options.t3.command, "string" },
    ["t3.base_dir"] = { M.options.t3.base_dir, "string", true },
    ["t3.project"] = { M.options.t3.project, "string", true },
    ["t3.timeout_ms"] = { M.options.t3.timeout_ms, "number" },
    ["t3.response_timeout_ms"] = { M.options.t3.response_timeout_ms, "number" },
    ["t3.poll_interval_ms"] = { M.options.t3.poll_interval_ms, "number" },
    provider = { M.options.provider, "string" },
    model = { M.options.model, "string" },
    base_url = { M.options.base_url, "string" },
    ["chatgpt.model"] = { M.options.chatgpt.model, "string", true },
    ["chatgpt.auth_dir"] = { M.options.chatgpt.auth_dir, "string", true },
    ["chatgpt.login_timeout_ms"] = { M.options.chatgpt.login_timeout_ms, "number" },
    ["chatgpt.request_timeout_ms"] = { M.options.chatgpt.request_timeout_ms, "number" },
    ["llama_cpp.auto_install"] = { M.options.llama_cpp.auto_install, "boolean" },
    ["llama_cpp.auto_start"] = { M.options.llama_cpp.auto_start, "boolean" },
    ["llama_cpp.host"] = { M.options.llama_cpp.host, "string" },
    ["llama_cpp.startup_timeout_ms"] = { M.options.llama_cpp.startup_timeout_ms, "number" },
    ["llama_cpp.health_check_interval_ms"] = {
      M.options.llama_cpp.health_check_interval_ms,
      "number",
    },
    ["llama_cpp.stop_on_exit"] = { M.options.llama_cpp.stop_on_exit, "boolean" },
    ["llama_cpp.ctx_size"] = { M.options.llama_cpp.ctx_size, "number" },
    ["llama_cpp.extra_args"] = { M.options.llama_cpp.extra_args, "table" },
    ["llama_cpp.models"] = { M.options.llama_cpp.models, "table" },
    ["response.width"] = { M.options.response.width, "number" },
    ["response.height"] = { M.options.response.height, "number" },
    ["input.width"] = { M.options.input.width, "number" },
    ["input.height"] = { M.options.input.height, "number" },
    detect_dependencies = { M.options.detect_dependencies, "boolean" },
    ["rag.enabled"] = { M.options.rag.enabled, "boolean" },
    ["rag.embedding_model"] = { M.options.rag.embedding_model, "string" },
    ["rag.top_k"] = { M.options.rag.top_k, "number" },
    ["rag.chunk_lines"] = { M.options.rag.chunk_lines, "number" },
    ["rag.chunk_overlap"] = { M.options.rag.chunk_overlap, "number" },
    ["rag.embed_batch_size"] = { M.options.rag.embed_batch_size, "number" },
    ["rag.max_context_chars"] = { M.options.rag.max_context_chars, "number" },
    ["rag.max_file_size_kb"] = { M.options.rag.max_file_size_kb, "number" },
    ["rag.max_chunks_per_file"] = { M.options.rag.max_chunks_per_file, "number" },
    ["rag.min_similarity"] = { M.options.rag.min_similarity, "number" },
    ["rag.include"] = { M.options.rag.include, "table" },
    ["rag.exclude"] = { M.options.rag.exclude, "table" },
    debug = { M.options.debug, "boolean" },
    models = { M.options.models, "table" },
    system_prompt = { M.options.system_prompt, "string" },
    system_prompt_no_selection = { M.options.system_prompt_no_selection, "string" },
    system_prompt_infill = { M.options.system_prompt_infill, "string" },
  })

  if not valid_provider(M.options.provider) then
    error("sage-llm: provider must be 'openrouter', 'llama_cpp', or 'chatgpt'")
  end

  for _, key in ipairs({ "command", "base_dir", "project" }) do
    local value = M.options.t3[key]
    if value and vim.trim(value) == "" then
      error("sage-llm: t3." .. key .. " must not be empty")
    end
  end
  for _, key in ipairs({ "timeout_ms", "response_timeout_ms", "poll_interval_ms" }) do
    local value = M.options.t3[key]
    if value < 1 or value == math.huge or value ~= math.floor(value) then
      error("sage-llm: t3." .. key .. " must be a positive finite integer")
    end
  end

  for _, key in ipairs({ "login_timeout_ms", "request_timeout_ms" }) do
    local value = M.options.chatgpt[key]
    if value < 1 or value == math.huge or value ~= math.floor(value) then
      error("sage-llm: chatgpt." .. key .. " must be a positive finite integer")
    end
  end

  local port = M.options.llama_cpp.port
  if port ~= "auto" then
    local n = tonumber(port)
    if not n or n < 1 or n > 65535 then
      error("sage-llm: llama_cpp.port must be 'auto' or a valid TCP port")
    end
  end

  if M.options.llama_cpp.startup_timeout_ms < 1 then
    error("sage-llm: llama_cpp.startup_timeout_ms must be >= 1")
  end

  if M.options.llama_cpp.health_check_interval_ms < 1 then
    error("sage-llm: llama_cpp.health_check_interval_ms must be >= 1")
  end

  for _, model in ipairs(M.options.llama_cpp.models) do
    if type(model) ~= "table" then
      error("sage-llm: llama_cpp.models entries must be tables")
    end
    if not model.hf_repo and not model.model_path then
      error("sage-llm: llama_cpp model entries must define hf_repo or model_path")
    end
  end

  if M.options.rag.chunk_overlap >= M.options.rag.chunk_lines then
    error("sage-llm: rag.chunk_overlap must be smaller than rag.chunk_lines")
  end

  if M.options.rag.top_k < 1 then
    error("sage-llm: rag.top_k must be >= 1")
  end

  if M.options.rag.chunk_lines < 1 then
    error("sage-llm: rag.chunk_lines must be >= 1")
  end

  if M.options.rag.chunk_overlap < 0 then
    error("sage-llm: rag.chunk_overlap must be >= 0")
  end

  if M.options.rag.embed_batch_size < 1 then
    error("sage-llm: rag.embed_batch_size must be >= 1")
  end

  if M.options.rag.max_context_chars < 1 then
    error("sage-llm: rag.max_context_chars must be >= 1")
  end

  if M.options.rag.max_file_size_kb < 1 then
    error("sage-llm: rag.max_file_size_kb must be >= 1")
  end

  if M.options.rag.max_chunks_per_file < 1 then
    error("sage-llm: rag.max_chunks_per_file must be >= 1")
  end
end

---Get the API key from config or environment
---@return string|nil
function M.get_api_key()
  return M.options.api_key or vim.env.OPENROUTER_API_KEY
end

---@return boolean
function M.is_local_provider()
  return M.options.provider == "llama_cpp"
end

---@return boolean
function M.is_chatgpt_provider()
  return M.options.provider == "chatgpt"
end

---@return boolean
function M.supports_search()
  return M.options.provider == "openrouter"
end

---@return boolean
function M.supports_rag()
  return M.options.provider == "openrouter"
end

---@param provider string
---@param persist boolean|nil Whether to persist to config file (default: true)
function M.set_provider(provider, persist)
  vim.validate({ provider = { provider, "string" } })
  if not valid_provider(provider) then
    error("sage-llm: provider must be 'openrouter', 'llama_cpp', or 'chatgpt'")
  end

  if not M.is_chatgpt_provider() then
    provider_models[M.options.provider] = M.options.model
  end
  M.options.provider = provider
  if M.is_chatgpt_provider() then
    M.options.model = M.options.chatgpt.model or "ChatGPT"
  else
    M.options.model = provider_models[provider]
      or (provider == "llama_cpp" and first_local_model() or M.defaults.model)
  end

  if persist ~= false then
    local ok, err = config_file.update("provider", provider)
    if not ok and err then
      vim.notify_once("sage-llm: Failed to save provider: " .. err, vim.log.levels.WARN)
    end
  end
end

---@param name string|nil
---@return table|nil
function M.get_llama_cpp_model(name)
  local target = name or M.options.model
  for _, model in ipairs(M.options.llama_cpp.models or {}) do
    if model.name == target or model.hf_repo == target or model.model_path == target then
      return model
    end
  end
  return nil
end

---@param entry table
---@param persist boolean|nil Whether to persist to config file (default: true)
function M.add_llama_cpp_model(entry, persist)
  if type(entry) ~= "table" then
    error("sage-llm: local model entry must be a table")
  end

  local name = entry.name or entry.hf_repo or entry.model_path
  if not name or name == "" then
    error("sage-llm: local model entry must have a name, hf_repo, or model_path")
  end

  entry.name = name
  local models = M.options.llama_cpp.models
  for i, model in ipairs(models) do
    if model.name == name or (entry.hf_repo and model.hf_repo == entry.hf_repo) then
      models[i] = vim.tbl_deep_extend("force", model, entry)
      if persist ~= false then
        local ok, err = config_file.update("llama_cpp", M.options.llama_cpp)
        if not ok and err then
          vim.notify_once("sage-llm: Failed to save local models: " .. err, vim.log.levels.WARN)
        end
      end
      return models[i]
    end
  end

  table.insert(models, entry)
  if persist ~= false then
    local ok, err = config_file.update("llama_cpp", M.options.llama_cpp)
    if not ok and err then
      vim.notify_once("sage-llm: Failed to save local models: " .. err, vim.log.levels.WARN)
    end
  end
  return entry
end

---Set dependency detection on/off
---@param enabled boolean
function M.set_detect_dependencies(enabled)
  M.options.detect_dependencies = enabled
end

---Set RAG retrieval on/off
---@param enabled boolean
function M.set_rag_enabled(enabled)
  M.options.rag.enabled = enabled
end

---Set the current model and persist to config file
---@param model string
---@param persist boolean|nil Whether to persist to config file (default: true)
function M.set_model(model, persist)
  vim.validate({ model = { model, "string" } })
  M.options.model = model

  local key, value = "model", model
  if M.is_chatgpt_provider() then
    M.options.chatgpt.model = model
    key, value = "chatgpt", M.options.chatgpt
  else
    provider_models[M.options.provider] = model
  end

  -- Persist to config file by default
  if persist ~= false then
    local ok, err = config_file.update(key, value)
    if not ok and err then
      vim.notify_once("sage-llm: Failed to save model: " .. err, vim.log.levels.WARN)
    end
  end
end

---Add a model to the picker list and persist to config file
---@param model string
---@param persist boolean|nil Whether to persist to config file (default: true)
function M.add_model(model, persist)
  if model == "" then
    return
  end

  local exists = vim.tbl_contains(M.options.models, model)
  if not exists then
    table.insert(M.options.models, model)
  end

  -- Persist to config file by default
  if persist ~= false then
    local ok, err = config_file.update("models", M.options.models)
    if not ok and err then
      vim.notify_once("sage-llm: Failed to save models: " .. err, vim.log.levels.WARN)
    end
  end
end

---Remove a model from the picker list and persist to config file
---@param model string
---@param persist boolean|nil Whether to persist to config file (default: true)
---@return boolean removed Whether the model was removed
function M.remove_model(model, persist)
  local idx = nil
  for i, value in ipairs(M.options.models) do
    if value == model then
      idx = i
      break
    end
  end

  if not idx then
    return false
  end

  if #M.options.models == 1 then
    return false
  end

  table.remove(M.options.models, idx)

  if provider_models.openrouter == model then
    provider_models.openrouter = M.options.models[1]
    if M.options.provider == "openrouter" then
      M.options.model = provider_models.openrouter
    end
  end

  -- Persist to config file by default
  if persist ~= false then
    local models_ok, models_err = config_file.update("models", M.options.models)
    if not models_ok and models_err then
      vim.notify_once("sage-llm: Failed to save models: " .. models_err, vim.log.levels.WARN)
    end

    local saved_model = M.is_chatgpt_provider() and provider_models.openrouter or M.options.model
    local model_ok, model_err = config_file.update("model", saved_model)
    if not model_ok and model_err then
      vim.notify_once("sage-llm: Failed to save model: " .. model_err, vim.log.levels.WARN)
    end
  end

  return true
end

---Get the path to the external config file
---@return string
function M.get_config_path()
  return config_file.get_config_path()
end

return M
