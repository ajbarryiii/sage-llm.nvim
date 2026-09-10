# sage-llm.nvim

A plugin for interacting with LLMs in neovim.

## Why?

Suppose you have a simple question, want to understand a complier error or LSP diagnostic. Do you really want to open up a window and copy+paste into claude or chatgpt? You're using vim, of course you don't, you're allergic to the mouse. `sage-llm.nvim` lets you ask all these simple queries right from neovim. It is specifically intended for: 

- **Compiler errors** 
- **Type errors** and warnings
- **Syntax issues** in unfamiliar languages
- **Code patterns** you haven't seen before
- **ANYTHING ELSE** because fuck it, you're a dev.

Get concise explanations without leaving your editor.

## Features

-  **Ask about selected code** - Highlight and ask questions
-  **LSP diagnostics** - Automatically includes error codes and messages
-  **Dependency detection** - Understands your project's dependencies (Rust, JS/TS, Python, Go)
-  **Optional RAG code search** - Pulls semantically related snippets from your repo into `:SageAsk`
-  **Streaming responses** - See answers as they generate
-  **Concise explanations** - Focuses on the "why", not just the "fix"
-  **Multiple models** - Switch between Claude, GPT, Gemini, Mercury, and more

## Requirements

- Neovim >= 0.10
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- OpenRouter API key (bring your own)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "sage-llm/sage-llm.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("sage-llm").setup({
      -- Optional: override defaults
      -- model = "anthropic/claude-sonnet-4-20250514",
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "sage-llm/sage-llm.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("sage-llm").setup()
  end,
}
```

## Setup

### 1. Get an API Key

1. Sign up at [OpenRouter](https://openrouter.ai)
2. Generate an API key
3. **On first run**, sage-llm will auto-create `~/.config/sage-llm/config.lua`
4. Run `:SageConfig` to open the config file
5. Set your API key:

```lua
return {
  api_key = "sk-or-v1-...",
}
```

6. Restart Neovim (or re-source your config)

**Alternative methods** (less recommended):
- **Environment variable**: `export OPENROUTER_API_KEY="sk-or-v1-..."`
- **In setup()**: `require("sage-llm").setup({ api_key = "..." })` (don't commit this to public repos!)

### 2. Configure Keymaps (Optional)

The plugin doesn't set default keymaps. Add your own:

```lua
-- In your Neovim config
vim.keymap.set("v", "<leader>sa", ":SageAsk<CR>", { desc = "Ask LLM about selection" })
vim.keymap.set("n", "<leader>sa", ":SageAsk<CR>", { desc = "Ask LLM (no selection)" })
vim.keymap.set("v", "<leader>se", ":SageExplain<CR>", { desc = "Explain selection" })
vim.keymap.set("v", "<leader>sx", ":SageFix<CR>", { desc = "Fix diagnostics" })
vim.keymap.set("v", "<leader>sk", ":SageInfill<CR>", { desc = "Inline edit selection" })
vim.keymap.set("n", "<leader>sm", ":SageModel<CR>", { desc = "Select model" })
```

## Usage

### Basic Workflow

1. **Select code** in visual mode (v, V, or Ctrl-v)
2. **Run a command**:
   - `:SageAsk` - Opens input buffer for your question
   - `:SageExplain` - Explains the code immediately
   - `:SageFix` - Explains how to fix diagnostics
   - `:SageInfill` - Generates inline replacement for selected code
3. **Read the response** in the floating window (if you want, I'm not here to tell you what to do)
4. Press `q` to hide, `y` to yank response, `f` to ask follow-up, `S` to toggle web search for the next query

### Commands

| Command | Description |
|---------|-------------|
| `:SageAsk` | Open input buffer to ask about visual selection |
| `:SageExplain` | Explain what the selected code does |
| `:SageFix` | Explain how to fix errors/warnings in selection |
| `:SageInfill` | Generate and preview inline replacement for selection |
| `:SageView` | Reopen latest hidden response window |
| `:SageModel` | Open model picker to switch LLMs |
| `:SageModelRemove` | Open model picker to remove a model |
| `:SageConfig` | Open config file for editing |
| `:SageDepsOn` | Enable dependency detection (slower, more context) |
| `:SageDepsOff` | Disable dependency detection (default) |

### Input Window

When using `:SageAsk`:
- **Type your question** - Multi-line supported
- **`<CR>`** - Submit question
- **`<S-CR>`** (Shift+Enter) - Insert newline
- **`S`** (normal mode) - Toggle web search for the next query
- **`r`** (normal mode) - Toggle RAG context on/off
- **`q`** or `<Esc>` - Cancel

### Response Window

- **`q`** or `<Esc>` - Hide window (conversation stays available)
- **`y`** - Yank response to clipboard
- **`f`** - Ask a follow-up question
- **`a`** - Apply pending inline edit
- **`A`** - Apply pending inline edit and hide window
- **`r`** - Reject pending inline edit
- **`S`** - Toggle web search for the next query
- **`<C-c>`** - Cancel streaming (if in progress)

Web search is off by default. When enabled, the plugin sends `:online` model variants to OpenRouter (for example, `google/gemini-3.8-flash:online`). The toggle resets to off after each query.

## Configuration

### Config File (Recommended)

Edit `~/.config/sage-llm/config.lua` (or run `:SageConfig`):

```lua
return {
  -- Your OpenRouter API key (required)
  api_key = "sk-or-v1-...",
  
  -- Model to use (optional, selected model is auto-saved here)
  model = "google/gemini-3.8-flash",
}
```

### Setup Configuration (Optional)

You can override UI settings and prompts in your Neovim config:

```lua
require("sage-llm").setup({
  -- API settings (config file takes precedence)
  api_key = nil,  -- Falls back to config file, then $OPENROUTER_API_KEY
  model = "openai/gpt-oss-20b",
  base_url = "https://openrouter.ai/api/v1",
  
  -- Response window (floating window on right side)
  response = {
    width = 0.6,   -- 60% of editor width
    height = 0.4,  -- 40% of editor height
    border = "rounded",
  },
  
  -- Input window (centered)
  input = {
    width = 0.5,
    height = 5,    -- Lines
    border = "rounded",
    prompt = "Ask about this code: ",
    infill_prompt = "Describe the edit:",
  },
  
  -- Dependency detection (opt-in for performance)
  detect_dependencies = false,

  -- RAG code search for :SageAsk (opt-in)
  rag = {
    enabled = false,
    embedding_model = "openai/text-embedding-3-small",
    top_k = 6,
    chunk_lines = 80,
    chunk_overlap = 20,
    max_context_chars = 6000,
  },
  
  -- Default picker models (OpenRouter IDs verified 2026-09-10)
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
  
  -- System prompt (tuned for concise teaching)
  system_prompt = [[You are a concise coding tutor helping a developer understand code.

Rules:
- Be brief and direct
- Use `inline code` for short references rather than full code blocks
- Only show multi-line code blocks when essential for understanding
- When explaining errors, focus on the "why" not just the fix
- Reference language concepts by name (e.g., "ownership", "borrow checker", "lifetime")]],
})
```

## Dependency Detection

By default, dependency detection is **off** for performance. Enable it for better context:

```vim
:SageDepsOn
```

Supported languages :
- **Rust** - Parses `Cargo.toml`
- **JavaScript/TypeScript** - Parses `package.json`
- **Python** - Parses `pyproject.toml` or `requirements.txt`
- **Go** - Parses `go.mod`

The detected dependencies are included in the prompt so the LLM understands your project's context (e.g., "using tokio for async" or "using React hooks").

## RAG Code Search

RAG is **off by default**. When enabled, `:SageAsk` retrieves semantically similar snippets from your repository and includes them in the prompt as extra context.

Toggle it from the `:SageAsk` input window with `r` (normal mode). The current state is shown in the input title (`[RAG: on/off]`).

Or set the default in config:

```lua
return {
  rag = {
    enabled = true,
    embedding_model = "openai/text-embedding-3-small",
  },
}
```

Notes:
- RAG uses OpenRouter's `/embeddings` API and your configured `api_key`
- The index is cached under `stdpath("cache") .. "/sage-llm/rag"`
- Larger repositories may take longer on the first ask with RAG enabled while index chunks are embedded
- Retrieved snippets are sent to the model as additional prompt context (review for privacy-sensitive repos)

## Available Models

Default: `openai/gpt-oss-20b` (an inexpensive starting point).

The built-in picker balances everyday coding help with two flagships for harder problems. All ten IDs were checked against OpenRouter's [live model catalog](https://openrouter.ai/api/v1/models) and their provider endpoints on **2026-09-10**: each accepts text, returns text, has an active endpoint, and has no announced expiration in the catalog.

Prices below are the catalog's USD rates per **1 million tokens**, before caching or additional services. They are a dated comparison, not fixed prices; provider routing, promotions, and long-context or time-of-day rates can change the bill. Context is the catalog maximum and can vary by provider.

| Model / OpenRouter ID | Why it is included | Input / output | Context |
|---|---|---|---|
| [GPT-OSS-20B](https://openrouter.ai/openai/gpt-oss-20b) — `openai/gpt-oss-20b` | Existing low-cost default for short explanations | $0.03 / $0.13 | 131K |
| [Mercury 2.5](https://openrouter.ai/inception/mercury-2.5) — `inception/mercury-2.5` | Newer diffusion model for responsive coding help | $0.04 / $0.15 (promotion) | 260K |
| [Mercury 2](https://openrouter.ai/inception/mercury-2) — `inception/mercury-2` | Fast diffusion alternative for interactive questions | $0.25 / $0.75 | 128K |
| [Gemini 3.8 Flash](https://openrouter.ai/google/gemini-3.8-flash) — `google/gemini-3.8-flash` | Latest Gemini Flash, with improved coding and reasoning | $0.75 / $3.75 (promotion) | 1.05M |
| [GPT-5.6 Luna](https://openrouter.ai/openai/gpt-5.6-luna) — `openai/gpt-5.6-luna` | Fast, inexpensive GPT option | $0.20 / $1.20 | 1.05M |
| [Qwen3.8 Flash](https://openrouter.ai/qwen/qwen3.8-flash) — `qwen/qwen3.8-flash` | Low-cost coding and codebase analysis | $0.15 / $0.47 | 1M |
| [DeepSeek V4.1 Flash](https://openrouter.ai/deepseek/deepseek-v4.1-flash) — `deepseek/deepseek-v4.1-flash` | Latest DeepSeek Flash with inexpensive reasoning | $0.15 / $0.60 (off-peak) | 1.05M |
| [Claude Sonnet 5](https://openrouter.ai/anthropic/claude-sonnet-5) — `anthropic/claude-sonnet-5` | Strong coding option below flagship pricing | $2 / $10 | 1M |
| [GPT-6 Astra](https://openrouter.ai/openai/gpt-6-astra) — `openai/gpt-6-astra` | OpenAI flagship for demanding software engineering | $10 / $50 | 1.05M |
| [Claude Fable 5.1](https://openrouter.ai/anthropic/claude-fable-5.1) — `anthropic/claude-fable-5.1` | Anthropic flagship for complex coding and reasoning | $10 / $50 | 1M |

Mercury 2.5's listed price includes an 80% discount (undiscounted: $0.20 / $0.75); Gemini 3.8 Flash includes 50% off (undiscounted: $1.50 / $7.50). DeepSeek's direct endpoint also has peak rates of $0.30 / $1.20. GPT-5.6 Luna and GPT-6 Astra have higher rates above 272K input tokens. Check the linked provider listings for current terms.

For interactive use, start with Mercury 2/2.5 or Gemini 3.8 Flash; choose Qwen or DeepSeek when output cost matters most, or a flagship for a difficult explanation. These are selection guidelines based on the model descriptions, pricing, and OpenRouter's reported latency/throughput, not plugin-specific benchmarks. Actual speed depends on the provider, load, and reasoning effort. The list uses regular text-generation IDs rather than batch, image-generation, or free variants.

Switch models with `:SageModel` or configure in `setup()`:

- `:SageModel` includes `Add custom model...` and `Remove model...` options so you can manage your picker list and persist changes to config.
- `:SageModelRemove` jumps directly to the remove-model picker.

A `models` list saved by the picker in `:SageConfig` takes precedence over these defaults, as does a list supplied to `setup()`. To adopt the new defaults, remove those `models` overrides and restart Neovim, or copy the desired new IDs into your existing list to retain custom entries. Your saved `model` selection still takes precedence over the startup default.

See [OpenRouter pricing](https://openrouter.ai/models) for cost comparison.

## License

MIT

## Credits

Built with:
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - HTTP client
- [OpenRouter](https://openrouter.ai) - LLM API gateway
