# AGENTS.md - sage-llm.nvim

## Instructions

Have basic common sense. For instance:
*   **Example** If the user asks for auth, make sure it is secure, 
*   **Security First:** Never hardcode secrets or API keys; use environment variables. Always use parameterized queries for database interactions to prevent SQL injection.
*   **Authn vs. Authz:** After implementing login (authentication), ensure every protected route checks if the specific user has the permission (authorization) to access that data.
*   **Production Hardening:** Ensure all error handling replaces verbose stack traces with generic messages for the client. Implement rate limiting on all public POST/PUT endpoints.
*   **Cryptographic Standards:** Use `crypto.randomBytes` (or equivalent) for tokens/IDs and `bcrypt` for password hashing; never use `Math.random()` or plain text for sensitive data.

Use scratchpad.txt as a scratchpad for persistent memory, and a place to reason through problems. 

## Project Overview

**sage-llm.nvim** is a Neovim plugin that allows users to highlight code in visual mode and ask an LLM questions about it. LSP diagnostics within the selection are automatically included in the context.

### Core Use Case

This plugin is designed for developers learning new languages or debugging syntax issues. The primary use case is understanding compiler errors (e.g., Rust borrow checker issues) by getting concise explanations of what's wrong and why.

## Architecture

```
lua/sage-llm/
├── init.lua           # Public API: setup(), ask(), explain(), fix(), followup(), select_model()
├── config.lua         # Configuration management, defaults, validation
├── config_file.lua    # External config file loading/saving (~/.config/sage-llm/config.lua)
├── api.lua            # OpenRouter HTTP client, SSE streaming
├── conversation.lua   # Multi-turn conversation state management
├── selection.lua      # Visual selection extraction
├── diagnostics.lua    # LSP diagnostics gathering (vim.diagnostic.get)
├── context.lua        # File metadata, dependency detection (Cargo.toml, etc.)
├── prompt.lua         # Prompt assembly from components
├── ui/
│   ├── init.lua       # UI module exports
│   ├── input.lua      # Floating input buffer for user questions
│   └── response.lua   # Response window with streaming display
├── actions.lua        # Predefined actions: explain, fix
└── models.lua         # Model picker via vim.ui.select()

plugin/
└── sage-llm.lua       # Command registration (:SageAsk, :SageExplain, etc.)
```

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Query mode | Conversational | Follow-up questions via `f` keymap in response window; `q` hides and `:SageView` restores latest conversation |
| Response style | Concise | Prefer `inline code` over full code blocks |
| Code replacement | Not supported | Read-only explanations, no buffer modifications |
| Context scope | Selection only | No surrounding code included |
| Dependency detection | Opt-in | User enables with `:SageDepsOn` (perf consideration) |
| Default keymaps | None | User must configure their own |
| LLM Provider | OpenRouter | Bring your own API key via config file or `$OPENROUTER_API_KEY` |
| Config file | `~/.config/sage-llm/config.lua` | XDG-compliant, auto-created on first run |
| Default model | openai/gpt-oss-20b | User can configure in config file |

## User Commands

| Command | Description |
|---------|-------------|
| `:SageAsk` | Visual mode: open input buffer, ask about selection |
| `:SageExplain` | Visual mode: explain selected code (no prompt) |
| `:SageFix` | Visual mode: explain how to fix diagnostics |
| `:SageView` | Reopen latest hidden conversation window |
| `:SageModel` | Open model picker |
| `:SageModelRemove` | Open remove-model picker |
| `:SageDepsOn` | Enable dependency detection for session |
| `:SageDepsOff` | Disable dependency detection |
| `:SageConfig` | Open config file for editing |

## Config File (`~/.config/sage-llm/config.lua`)

### Auto-Creation
- On first `setup()` call, if config file doesn't exist, a template is auto-created
- Notification shows: "Created config file at ~/.config/sage-llm/config.lua. Edit it to add your API key."
- User runs `:SageConfig` to open and edit the file

### Structure
```lua
return {
  api_key = "sk-or-v1-...",  -- Required: OpenRouter API key
  model = "anthropic/...",    -- Optional: current model (auto-updated by :SageModel)
}
```

### Priority Order
Configuration values are resolved in this order (highest to lowest):
1. **Config file** (`~/.config/sage-llm/config.lua`)
2. **setup() opts** (in Neovim config)
3. **Environment variable** (`$OPENROUTER_API_KEY` for api_key only)
4. **Defaults**

### Model Persistence
- When user runs `:SageModel` and selects a model, it's **automatically saved** to config file
- On next Neovim startup, the selected model is loaded from config file
- Model name is displayed in response window title: `" sage-llm (claude-sonnet-4.5) "`

### Implementation Details
- File location: `~/.config/sage-llm/config.lua` (respects `$XDG_CONFIG_HOME`)
- Module: `lua/sage-llm/config_file.lua`
- Functions:
  - `load()` - Load config table from file
  - `save(config)` - Save full config table (preserves api_key)
  - `update(key, value)` - Update single key in config
  - `create_template()` - Create template on first run

## User Flow

1. User selects code in visual mode
2. User runs `:SageAsk`
3. Floating input buffer opens (multi-line, `<CR>` submit, `<S-CR>` newline)
4. User types question, submits
5. Response window opens (centered, right side of screen)
6. Shows selected code, loading indicator, then streams response
7. User presses `f` to ask a follow-up question (opens input buffer, appends to conversation)
8. User presses `q` to hide (conversation persists), `:SageView` to reopen, or `y` to yank response

## Prompt Structure

```
System: {system_prompt}

User:
File: {relative_path} ({filetype})
Dependencies: {deps}  # Only if :SageDepsOn

```{filetype}
{selected_code}
```

Diagnostics:
- Line {n} [{severity} {code}]: {message} ({source})

Question: {user_question}
```

## Configuration Schema

```lua
{
  api_key = nil,                              -- Falls back to $OPENROUTER_API_KEY
  model = "openai/gpt-oss-20b",
  base_url = "https://openrouter.ai/api/v1",
  
  response = {
    width = 0.6,                              -- Fraction of editor width
    height = 0.4,                             -- Fraction of editor height
    border = "rounded",
  },
  
  input = {
    width = 0.5,
    height = 5,                               -- Lines
    border = "rounded",
    prompt = "Ask about this code: ",
    followup_prompt = "Follow-up question:",   -- Prompt for follow-up input
  },
  
  detect_dependencies = false,                -- Toggle with :SageDepsOn/Off
  
  models = {                                  -- List of models in picker
    "openai/gpt-5-nano",
    "openai/gpt-5.2-codex",
    "moonshotai/kimi-k2.5",
    "google/gemini-3-flash-preview",
    "anthropic/claude-sonnet-4.5",
    "x-ai/grok-4.1-fast",
    "anthropic/claude-opus-4.6",
    "anthropic/claude-haiku-4.5",
  },
  
  system_prompt = [[...]],                    -- Tuned for concise teaching
}
```

## Dependencies

- **Required**: Neovim >= 0.10
- **Required**: plenary.nvim (HTTP client via plenary.curl)
- **Optional**: nvim-treesitter (markdown highlighting in response)

## Code Style

- Use LuaCATS annotations for type hints
- Format with StyLua (see .stylua.toml when created)
- Lint with luacheck
- Prefer early returns over nested conditionals
- Keep functions small and focused
- Use `vim.validate()` for public API input validation

## Testing

Tests use busted via plenary.nvim test harness:

```bash
nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

## Key Implementation Notes

### API Client (api.lua)

- Use `plenary.curl` for HTTP requests
- OpenRouter uses SSE (Server-Sent Events) for streaming
- Parse `data: {...}` lines, handle `[DONE]` sentinel
- Include headers: `Authorization: Bearer {key}`, `Content-Type: application/json`
- Handle errors: network failures, 401 (bad key), 429 (rate limit)

### Selection (selection.lua)

- Use `vim.fn.getpos("'<")` and `vim.fn.getpos("'>")` for visual range
- Handle both line-wise and character-wise selection
- Return: text, bufnr, start_line, end_line, filetype, filepath

### Diagnostics (diagnostics.lua)

- Use `vim.diagnostic.get(bufnr, {lnum = ...})` filtered by selection range
- Include error codes when available (e.g., `E0382` for Rust)
- Format: `Line {n} [{severity} {code}]: {message} ({source})`

### Context (context.lua)

Dependency detection strategies by filetype:
- **rust**: Parse `Cargo.toml` `[dependencies]` section
- **javascript/typescript**: Parse `package.json` `dependencies` + `devDependencies`
- **python**: Parse `pyproject.toml` or `requirements.txt`
- **go**: Parse `go.mod` `require` block

Only run when `detect_dependencies = true` (set via `:SageDepsOn`).

### Conversation (conversation.lua)

- Pure state machine with no UI dependencies (fully testable with busted)
- Stores: messages array, active flag, token accumulator
- `start(messages)` - Initialize new conversation from initial API messages
- `accumulate_token(token)` / `finish_response()` - Build assistant response from streaming tokens
- `add_followup(question)` - Append user message, return full messages array for API
- `remove_last_user_message()` - Error recovery: remove failed follow-up so user can retry
- `reset()` - Clear all state (called when starting a new `:SageAsk`/`:SageExplain`/`:SageFix`)
- Conversation resets on: new `:SageAsk`/`:SageExplain`/`:SageFix`

### UI Response Window (ui/response.lua)

- Position: centered vertically, right side of screen
- Show selected code first (in fenced code block)
- Show loading indicator: `"Thinking..."` with spinner
- Stream tokens by appending to buffer
- Keymaps: `q`/`<Esc>` hide, `y` yank, `f` follow-up, `<C-c>` cancel stream

### UI Input Window (ui/input.lua)

- Floating buffer with prompt in border/title
- `<CR>` submits and closes
- `<S-CR>` inserts newline
- `q` in normal mode cancels
- Return user input text on submit, nil on cancel

## File Naming Conventions

- Lua modules: `snake_case.lua`
- Test files: `tests/{module}_spec.lua`
- All paths relative to plugin root

## Error Handling

- Wrap API calls in pcall, show user-friendly errors via `vim.notify()`
- Validate API key exists before making requests
- Handle empty selections gracefully
- Cancel in-flight requests when user closes window

## Future Work / TODOs

None currently.
