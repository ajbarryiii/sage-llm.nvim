---@class SageConfig
---@field api_key string|nil API key for OpenRouter (falls back to $OPENROUTER_API_KEY)
---@field model string Default model to use
---@field base_url string OpenRouter API base URL
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

local config_file = require("sage-llm.config_file")

local M = {}

---@type SageConfig
M.defaults = {
  api_key = nil,
  model = "openai/gpt-oss-20b",
  base_url = "https://openrouter.ai/api/v1",

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
          .. "\nEdit it to add your API key.",
        vim.log.levels.INFO
      )
    elseif create_err then
      vim.notify_once("sage-llm: " .. create_err, vim.log.levels.WARN)
    end
  end

  M.options = base

  -- Validate required fields
  M.validate()
end

---Validate configuration
function M.validate()
  if type(M.options.rag) ~= "table" then
    error("sage-llm: rag config must be a table")
  end

  vim.validate({
    model = { M.options.model, "string" },
    base_url = { M.options.base_url, "string" },
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
  M.options.model = model

  -- Persist to config file by default
  if persist ~= false then
    local ok, err = config_file.update("model", model)
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

  if M.options.model == model then
    M.options.model = M.options.models[1]
  end

  -- Persist to config file by default
  if persist ~= false then
    local models_ok, models_err = config_file.update("models", M.options.models)
    if not models_ok and models_err then
      vim.notify_once("sage-llm: Failed to save models: " .. models_err, vim.log.levels.WARN)
    end

    local model_ok, model_err = config_file.update("model", M.options.model)
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
