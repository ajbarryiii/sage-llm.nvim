# sage-llm.nvim

A plugin for interacting with LLMs in neovim.

## Why?

Suppose you have a simple question, want to understand a complier error or LSP diagnostic. Do you really want to open up a window and copy+paste into claude or chatgpt? You're using vim, of course you don't, you're allergic to the mouse. `sage-llm.nvim` lets you ask all these simple queries right from neovim. It is specifically intended for: 

- **Compiler errors** 
- **Type errors** and warnings
- **Syntax issues** in unfamiliar languages
- **Code patterns** you haven't seen before
- **ANYTHING ELSE** because fuck it, you're a dev, you're not a chatbot.

Get concise explanations without leaving your editor.

## Features

-  **Ask about selected code** - Highlight and ask questions
-  **LSP diagnostics** - Automatically includes error codes and messages
-  **Dependency detection** - Understands your project's dependencies (Rust, JS/TS, Python, Go)
-  **Streaming responses** - See answers as they generate
-  **Inline edits** - Replace selected code with AI edits (`:SageInfill`)
-  **Concise explanations** - Focuses on the "why", not just the "fix"
-  **Multiple models** - Switch between Claude, GPT-5, Gemini, etc.

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

Web search is off by default. When enabled, the plugin sends `:online` model variants to OpenRouter (for example, `anthropic/claude-sonnet-4.5:online`). The toggle resets to off after each query.

## Configuration

### Config File (Recommended)

Edit `~/.config/sage-llm/config.lua` (or run `:SageConfig`):

```lua
return {
  -- Your OpenRouter API key (required)
  api_key = "sk-or-v1-...",
  
  -- Model to use (optional, selected model is auto-saved here)
  model = "anthropic/claude-sonnet-4-20250514",
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
  
  -- Currently configured models (shown in :SageModel picker)
  models = {                                  
    "openai/gpt-oss-20b",
    "openai/gpt-5-nano",
    "openai/gpt-5.2-codex",
    "moonshotai/kimi-k2.5",
    "google/gemini-3-flash-preview",
    "anthropic/claude-sonnet-4.5",
    "x-ai/grok-4.1-fast",
    "anthropic/claude-opus-4.6",
    "anthropic/claude-haiku-4.5",
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

## Available Models

Default: `openai/gpt-oss-20b`

Switch models with `:SageModel` or configure in `setup()`:

- `:SageModel` includes `Add custom model...` and `Remove model...` options so you can manage your picker list and persist changes to config.
- `:SageModelRemove` jumps directly to the remove-model picker.

See [OpenRouter pricing](https://openrouter.ai/models) for cost comparison.

## License

MIT

## Credits

Built with:
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - HTTP client
- [OpenRouter](https://openrouter.ai) - LLM API gateway
