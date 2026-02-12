# sage-llm.nvim

A Neovim plugin that lets you highlight code in visual mode and ask an LLM about it. LSP diagnostics within the selection are automatically included for better context.

## Why?

Suppose you have a simple syntax question, or want to understand a complier error. Do you really want to open up a window to ask claude or chatgpt? Or would it be better to just have it right in neovim. `sage-llm.nvim` lets you ask all these simple queries right from neovim. It is specifically intended for: 
- **Compiler errors** 
- **Type errors** and warnings
- **Syntax issues** in unfamiliar languages
- **Code patterns** you haven't seen before

Get concise explanations without leaving your editor.

## Features

- 🔍 **Ask about selected code** - Highlight and ask questions
- 🩺 **LSP diagnostics** - Automatically includes error codes and messages
- 📦 **Dependency detection** - Understands your project's dependencies (Rust, JS/TS, Python, Go)
- 🌊 **Streaming responses** - See answers as they generate
- 🎯 **Concise explanations** - Focuses on the "why", not just the "fix"
- 🔄 **Multiple models** - Switch between Claude, GPT-4, Gemini, etc.

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
vim.keymap.set("v", "<leader>se", ":SageExplain<CR>", { desc = "Explain selection" })
vim.keymap.set("v", "<leader>sx", ":SageFix<CR>", { desc = "Fix diagnostics" })
vim.keymap.set("n", "<leader>sm", ":SageModel<CR>", { desc = "Select model" })
```

## Usage

### Basic Workflow

1. **Select code** in visual mode (v, V, or Ctrl-v)
2. **Run a command**:
   - `:SageAsk` - Opens input buffer for your question
   - `:SageExplain` - Explains the code immediately
   - `:SageFix` - Explains how to fix diagnostics
3. **Read the response** in the floating window
4. Press `q` to close, `y` to yank response

### Commands

| Command | Description |
|---------|-------------|
| `:SageAsk` | Open input buffer to ask about visual selection |
| `:SageExplain` | Explain what the selected code does |
| `:SageFix` | Explain how to fix errors/warnings in selection |
| `:SageModel` | Open model picker to switch LLMs |
| `:SageConfig` | Open config file for editing |
| `:SageDepsOn` | Enable dependency detection (slower, more context) |
| `:SageDepsOff` | Disable dependency detection (default) |

### Input Window

When using `:SageAsk`:
- **Type your question** - Multi-line supported
- **`<CR>`** - Submit question
- **`<S-CR>`** (Shift+Enter) - Insert newline
- **`q`** or `<Esc>` - Cancel

### Response Window

- **`q`** or `<Esc>` - Close window
- **`y`** - Yank response to clipboard
- **`<C-c>`** - Cancel streaming (if in progress)

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
  model = "anthropic/claude-sonnet-4-20250514",
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
  },
  
  -- Dependency detection (opt-in for performance)
  detect_dependencies = false,
  
  -- Available models (shown in :SageModel picker)
  models = {
    "anthropic/claude-sonnet-4-20250514",
    "anthropic/claude-3-5-haiku",
    "openai/gpt-4o",
    "openai/gpt-4o-mini",
    "google/gemini-2.0-flash",
    "deepseek/deepseek-chat",
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

## Examples

### Understanding a Rust Borrow Checker Error

```rust
let x = String::from("hello");
let y = &x;
let z = x;  // Error: borrow of moved value
println!("{}", y);
```

1. Select the code
2. Run `:SageFix`
3. Get explanation:
   > The error occurs because `x` is moved to `z` on line 3. After a move, the original binding `x` 
   > becomes invalid. Since `y` is a reference to `x`, using `y` after `x` is moved violates Rust's 
   > ownership rules. To fix: either clone `x` (`let z = x.clone()`), borrow it (`let z = &x`), or 
   > reorder so `y` is used before the move.

### Learning TypeScript Syntax

```typescript
const users: User[] = await fetchUsers();
const names = users.map(u => u.name);
```

1. Select `users.map(u => u.name)`
2. Run `:SageAsk`
3. Type: "what does this arrow function syntax mean?"
4. Get explanation of arrow functions and their concise form

## Dependency Detection

By default, dependency detection is **off** for performance. Enable it for better context:

```vim
:SageDepsOn
```

Supported languages:
- **Rust** - Parses `Cargo.toml`
- **JavaScript/TypeScript** - Parses `package.json`
- **Python** - Parses `pyproject.toml` or `requirements.txt`
- **Go** - Parses `go.mod`

The detected dependencies are included in the prompt so the LLM understands your project's context (e.g., "using tokio for async" or "using React hooks").

## Available Models

Default: `anthropic/claude-sonnet-4-20250514`

Switch models with `:SageModel` or configure in `setup()`:
- `anthropic/claude-sonnet-4-20250514` - Best for complex code explanations
- `anthropic/claude-3-5-haiku` - Faster, cheaper, good for simple questions
- `openai/gpt-4o` - Strong general coding knowledge
- `openai/gpt-4o-mini` - Fast and cheap
- `google/gemini-2.0-flash` - Free tier available
- `deepseek/deepseek-chat` - Good for code, very cheap

See [OpenRouter pricing](https://openrouter.ai/models) for cost comparison.

## Development

```bash
# Enter dev shell (if using Nix)
nix develop

# Or install tools manually
# - Neovim >= 0.10
# - luacheck
# - stylua
# - busted (via plenary.nvim)

# Lint
make lint

# Format
make format

# Test
make test
```

## Troubleshooting

### "No API key found"

**Recommended:** Edit the config file:

1. Run `:SageConfig`
2. Set `api_key = "sk-or-v1-..."`
3. Restart Neovim

**Alternative:** Set environment variable:

```bash
export OPENROUTER_API_KEY="sk-or-v1-..."
```

### "No selection found"

Make sure you're in visual mode (v, V, or Ctrl-v) when running commands. The commands only work on visual selections.

### Tests fail with "command not found: PlenaryBustedDirectory"

Install [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) in your Neovim setup.

## Roadmap

- [ ] Conversation history (multi-turn conversations)
- [ ] Code replacement actions (apply suggested fixes)
- [ ] Custom actions (user-defined prompt templates)
- [ ] `:checkhealth` integration

## License

MIT

## Credits

Built with:
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) - HTTP client
- [OpenRouter](https://openrouter.ai) - LLM API gateway
