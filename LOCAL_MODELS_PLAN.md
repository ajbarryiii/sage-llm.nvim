# Plan: Local Models with llama.cpp

## Summary

Add first-class local model support to `sage-llm.nvim` using `llama.cpp` and its OpenAI-compatible `llama-server` API. The first version should support local chat and local infill only. Local embeddings and local RAG are explicitly out of scope.

The desired user experience is automated setup with minimal user input:

```vim
:SageLocalSetup owner/model-GGUF:Q4_K_M
```

After setup, the plugin should install or locate `llama-server`, persist the local model configuration, start the server, let `llama.cpp` download/cache the model through Hugging Face, wait until the server is healthy, and then use that model for `:SageAsk`, `:SageExplain`, `:SageFix`, and `:SageInfill`.

The user should only need to provide a llama.cpp-compatible Hugging Face model string, assuming access permissions are already satisfied. For gated models, this means `HF_TOKEN` must already be set in the user's environment.

## Goals

- Keep OpenRouter as the default provider and preserve existing behavior.
- Add a `llama_cpp` provider for local chat and local infill.
- Automate `llama-server` installation when possible.
- Automate local server start, health polling, and stop for plugin-owned processes.
- Let `llama.cpp` handle Hugging Face model downloads through `--hf-repo`.
- Require only one model string for the common setup path.
- Persist selected local provider/model state in the existing config file.
- Avoid storing or exposing Hugging Face tokens.
- Disable or bypass local RAG paths when using the local provider.
- Provide clear status and troubleshooting commands.

## Non-Goals

- Do not implement local embeddings in the first version.
- Do not implement local RAG in the first version.
- Do not replace the existing OpenRouter integration.
- Do not implement model quantization or conversion.
- Do not download arbitrary non-GGUF model files manually in the plugin.
- Do not expose llama.cpp's built-in local filesystem tools.
- Do not kill externally started `llama-server` processes.

## Current State

The current architecture is centralized around `lua/sage-llm/api.lua`:

- `stream_chat()` sends OpenRouter-compatible streaming chat requests.
- `chat()` sends non-streaming chat requests, used by infill.
- `embeddings()` sends OpenRouter embeddings requests, used by RAG.
- `config.get_api_key()` currently requires an OpenRouter API key for all requests.
- `resolve_model_id()` appends `:online` for web search requests.
- `base_url` defaults to `https://openrouter.ai/api/v1`.

This is a good fit for llama.cpp because modern `llama-server` exposes OpenAI-compatible `/v1/chat/completions` and `/v1/embeddings` endpoints. For this first version, only `/v1/chat/completions` should be used locally.

Relevant modules:

| File | Current Role | Local Model Impact |
| --- | --- | --- |
| `lua/sage-llm/config.lua` | Defaults, validation, model persistence helpers | Add provider and `llama_cpp` config |
| `lua/sage-llm/config_file.lua` | Creates and updates `~/.config/sage-llm/config.lua` | Add local setup template comments and token guidance |
| `lua/sage-llm/api.lua` | OpenRouter HTTP client | Make provider-aware and start local server before local requests |
| `lua/sage-llm/init.lua` | Public API and request flow | Disable RAG/search for local provider and expose local functions |
| `lua/sage-llm/models.lua` | Model picker | Show local models and switch providers |
| `plugin/sage-llm.lua` | User commands | Add local setup/start/stop/status commands |
| `lua/sage-llm/rag/*` | OpenRouter embeddings-backed RAG | Must not be invoked for local provider |
| `lua/sage-llm/ui/*` | Floating input/response windows | Hide search/RAG controls when unavailable |

## User Experience

### First-Time Setup

The primary setup flow should be:

```vim
:SageLocalSetup owner/model-GGUF:Q4_K_M
```

Expected behavior:

1. Validate the model string is non-empty.
2. Check whether `llama-server` is configured or present on `$PATH`.
3. If missing and auto-install is enabled, download a matching llama.cpp release binary.
4. Persist the model in `~/.config/sage-llm/config.lua`.
5. Switch `provider` to `llama_cpp`.
6. Start the local server using the model string.
7. Let `llama.cpp` download/cache the model from Hugging Face.
8. Poll `/v1/health` until the server reports ready.
9. Notify the user that local model setup is complete.

### Normal Usage

After setup, existing commands should work:

```vim
:SageAsk
:SageExplain
:SageFix
:SageInfill
```

If the local provider is selected and the server is not running, the plugin should auto-start it when `auto_start = true`.

### Manual Local Commands

Add these commands:

| Command | Purpose |
| --- | --- |
| `:SageLocalSetup <hf-repo[:quant]>` | Install/locate llama.cpp, save model, select local provider, start server |
| `:SageLocalStart [model]` | Start the configured local model or a named configured local model |
| `:SageLocalStop` | Stop only the plugin-owned local server process |
| `:SageLocalStatus` | Show binary path, model, port, health, ownership, and log path |
| `:SageLocalInstall` | Optional explicit install/update of `llama-server` |

## Configuration Design

Add provider-aware configuration while preserving current defaults.

### Defaults

```lua
{
  provider = "openrouter",

  api_key = nil,
  model = "openai/gpt-oss-20b",
  base_url = "https://openrouter.ai/api/v1",

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
}
```

### Persisted Config Example

```lua
return {
  provider = "llama_cpp",
  model = "owner/model-GGUF:Q4_K_M",

  llama_cpp = {
    auto_install = true,
    auto_start = true,
    host = "127.0.0.1",
    port = "auto",

    models = {
      {
        name = "owner/model-GGUF:Q4_K_M",
        hf_repo = "owner/model-GGUF:Q4_K_M",
        ctx_size = 8192,
        gpu_layers = "auto",
      },
    },
  },
}
```

### Local Model Entry

Support the simple entry produced by setup:

```lua
{
  name = "owner/model-GGUF:Q4_K_M",
  hf_repo = "owner/model-GGUF:Q4_K_M",
  ctx_size = 8192,
  gpu_layers = "auto",
}
```

Support advanced entries for users who need more control:

```lua
{
  name = "local-coder",
  hf_repo = "owner/model-GGUF:Q4_K_M",
  hf_file = "model-q4_k_m.gguf",
  model_path = nil,
  ctx_size = 16384,
  gpu_layers = "auto",
  threads = 8,
  extra_args = { "--flash-attn", "on" },
}
```

Validation rules:

- `provider` must be `"openrouter"` or `"llama_cpp"`.
- `llama_cpp` must be a table.
- `llama_cpp.host` must be a string.
- `llama_cpp.port` must be `"auto"` or a number/string convertible to a valid TCP port.
- `llama_cpp.models` must be a table.
- A local model must have either `hf_repo` or `model_path`.
- A local model with `model_path` must point to a path ending in `.gguf` if possible to validate cheaply.
- `HF_TOKEN` should not be accepted as a config field.

## Provider Behavior

### OpenRouter Provider

Keep current behavior:

- Require `config.get_api_key()` or `$OPENROUTER_API_KEY`.
- Use `config.options.base_url`.
- Send OpenRouter headers.
- Support `:online` suffix for web search.
- Support embeddings/RAG.

### llama.cpp Provider

Provider behavior should differ as follows:

- Do not require an OpenRouter API key.
- Use computed local base URL: `http://<host>:<port>/v1`.
- Send only `Content-Type: application/json` unless a user explicitly configures local API auth later.
- Do not append `:online`.
- Hide or disable web search toggles.
- Ensure the local server is running before chat requests.
- Return a clear error from `api.embeddings()` such as `Local embeddings/RAG are not supported`.

## Local Server Management

Create `lua/sage-llm/local.lua`.

Responsibilities:

- Resolve configured local model.
- Install or locate `llama-server`.
- Build server arguments safely as argv lists.
- Start `llama-server` with `vim.fn.jobstart()`.
- Track process ownership.
- Poll `/v1/health`.
- Stop plugin-owned server process.
- Report status.
- Register `VimLeavePre` cleanup when configured.

### State

Track runtime state in memory:

```lua
{
  job_id = nil,
  owned = false,
  host = "127.0.0.1",
  port = nil,
  model = nil,
  binary = nil,
  log_path = nil,
  starting = false,
  ready = false,
}
```

### Server Arguments

For Hugging Face model strings:

```sh
llama-server \
  --hf-repo owner/model-GGUF:Q4_K_M \
  --alias owner/model-GGUF:Q4_K_M \
  --host 127.0.0.1 \
  --port <port> \
  --ctx-size 8192 \
  --n-gpu-layers auto \
  --no-webui
```

Use `--hf-file` if configured. Use `--model` if `model_path` is configured.

Do not pass `--hf-token`. llama.cpp reads `HF_TOKEN` from the environment.

Do not pass `--tools all` or any filesystem tools.

### Health Check

Poll:

```text
GET http://127.0.0.1:<port>/v1/health
```

Expected statuses:

| HTTP Status | Meaning | Handling |
| --- | --- | --- |
| `200` | Ready | Proceed |
| `503` | Loading model | Continue polling |
| Connection refused | Not listening yet | Continue until timeout |
| Other status | Error | Surface error with log path |

### Port Selection

When `port = "auto"`:

1. Try `8080` first if free.
2. If occupied, try incrementing ports up to a bounded range, for example `8081` through `8099`.
3. If all are busy, return a clear error.

If `port` is fixed and occupied, do not steal it. Check whether an existing server at that port is healthy. If it is healthy but not plugin-owned, allow external-server mode. If it is not healthy, show an actionable error.

### Process Ownership

Only plugin-started jobs should be stopped by `:SageLocalStop`.

Cases:

| Situation | Ownership | Stop Behavior |
| --- | --- | --- |
| Plugin starts `llama-server` | Owned | `:SageLocalStop` stops it |
| User started server externally | Not owned | `:SageLocalStop` warns and does not kill |
| Server found healthy before start | Not owned | Use it, do not stop it |

## Automated Binary Installation

Create `lua/sage-llm/local_install.lua` or keep install helpers inside `local.lua` if small. Prefer a separate module if the installer grows.

### Install Location

Default install location:

```text
stdpath("data")/sage-llm/llama.cpp/<release-tag>/
```

Default log/cache location:

```text
stdpath("cache")/sage-llm/llama.cpp/
```

### Binary Resolution Order

1. `config.options.llama_cpp.binary` if set.
2. Previously installed managed binary in `stdpath("data")`.
3. `llama-server` found on `$PATH`.
4. Auto-install from GitHub release if `auto_install = true`.
5. Error with manual setup instructions.

### Platform Asset Mapping

Use GitHub release assets from `ggml-org/llama.cpp`.

Initial supported mappings:

| OS | Arch | Preferred Asset Pattern |
| --- | --- | --- |
| macOS | arm64 | `llama-*-bin-macos-arm64.tar.gz` |
| macOS | x64 | `llama-*-bin-macos-x64.tar.gz` |
| Linux | x64 | `llama-*-bin-ubuntu-x64.tar.gz` |
| Linux | arm64 | `llama-*-bin-ubuntu-arm64.tar.gz` |
| Windows | x64 | `llama-*-bin-win-cpu-x64.zip` |
| Windows | arm64 | `llama-*-bin-win-cpu-arm64.zip` |

GPU-specific assets can be a later enhancement. The first version should prefer CPU or platform-default builds because they are more portable. On macOS, the release binary should still benefit from the platform's default acceleration if built that way upstream.

### Release Lookup

Use GitHub's latest release API:

```text
https://api.github.com/repos/ggml-org/llama.cpp/releases/latest
```

Implementation details:

- Parse `tag_name`.
- Match the platform asset by name.
- Use `browser_download_url`.
- Capture the `digest` field if present.
- Cache the downloaded archive under the release tag.

### Download and Extract

Use existing dependencies where possible:

- Use `plenary.curl` or `vim.system({ "curl", ... })` for downloads.
- Prefer `vim.system()` or `vim.fn.jobstart()` with argv lists.
- Use system `tar` for `.tar.gz` and system unzip tooling for `.zip` where available.
- If extraction tools are missing, show a manual installation error.

Do not shell-concatenate paths or model strings.

### Digest Verification

If the GitHub release asset provides `digest = "sha256:<hash>"`:

- Compute SHA-256 of the downloaded archive.
- Compare it before extraction.
- If digest verification cannot be performed on the platform, warn and continue only if this is acceptable for the project's security posture.

Preferred behavior is to fail closed when a digest exists but cannot be verified.

### Auto-Install Failure Message

Use one clear, actionable error:

```text
sage-llm: Could not auto-install llama-server for this platform.
Install llama-server and set llama_cpp.binary, then rerun :SageLocalSetup.
```

Include the detected platform and log path when available.

## Hugging Face Access

The plugin should not implement its own Hugging Face model downloader for the first version. It should pass the model string to `llama-server --hf-repo` and let llama.cpp handle download/cache behavior.

For public models, no token is needed.

For gated/private models, users must set:

```sh
export HF_TOKEN="hf_..."
```

Security requirements:

- Never store `HF_TOKEN` in `~/.config/sage-llm/config.lua`.
- Never pass `HF_TOKEN` as `--hf-token` because command-line args can leak through process listings.
- Never include `HF_TOKEN` in logs, notifications, debug output, or response buffers.
- If `llama-server` fails due to auth, surface a generic message that tells users to verify `HF_TOKEN` and Hugging Face model access.

## API Layer Changes

Refactor `lua/sage-llm/api.lua` around provider-specific request settings.

### Suggested Internal Helpers

```lua
local function current_provider()
  return config.options.provider or "openrouter"
end

local function is_local_provider()
  return current_provider() == "llama_cpp"
end

local function resolve_base_url()
  if is_local_provider() then
    return local_server.get_base_url()
  end
  return config.options.base_url
end

local function build_headers()
  if is_local_provider() then
    return {
      ["Content-Type"] = "application/json",
    }
  end

  local api_key = config.get_api_key()
  return {
    ["Authorization"] = "Bearer " .. api_key,
    ["Content-Type"] = "application/json",
    ["HTTP-Referer"] = "https://github.com/sage-llm/sage-llm.nvim",
    ["X-Title"] = "sage-llm.nvim",
  }
end
```

### Chat Request Flow

For `stream_chat()` and `chat()`:

1. Resolve provider.
2. If OpenRouter, keep existing API key validation.
3. If llama.cpp, call `local.ensure_ready()` before making HTTP request.
4. Build URL as `<base_url>/chat/completions`.
5. Use existing response parsing because llama.cpp is OpenAI-compatible.

### Embeddings Request Flow

For `embeddings()`:

1. If OpenRouter, keep current behavior.
2. If llama.cpp, immediately call back with `nil, "Local embeddings/RAG are not supported"`.

## Request Flow Changes

Update `lua/sage-llm/init.lua`.

### RAG Handling

If provider is `llama_cpp`:

- Force `use_rag = false` for local requests.
- Do not show RAG toggle in the input UI.
- If `config.options.rag.enabled` is true, notify once per session that local RAG is not supported and the request will continue without repository context.

### Search Handling

If provider is `llama_cpp`:

- Disable web search toggles.
- Do not pass `search = true` to local requests.
- Do not append `:online` in API request bodies.

### Infill Handling

`SageInfill` should work with local provider through the same `api.chat()` path. This is important because infill already uses a non-streaming chat completion and should not need a separate local implementation.

## UI Changes

### Input Window

Only show search controls when provider supports search.

Only show RAG controls when provider supports RAG.

This likely means adding booleans to the options passed to `ui.input.open()` or only setting callbacks when supported.

### Response Window

Only show `S search:on/off` in the footer when provider supports search. If the search callback is nil, omit the search footer segment.

Response title can continue displaying `config.options.model`, but local model strings may be long. Consider shortening display to the final repository segment while preserving the full model in status output.

## Model Picker Changes

Update `lua/sage-llm/models.lua`.

### Display Model Groups

The picker should display both provider groups:

```text
OpenRouter: openai/gpt-oss-20b
OpenRouter: anthropic/claude-sonnet-4.5
Local: owner/model-GGUF:Q4_K_M
Add custom OpenRouter model...
Remove OpenRouter model...
Local setup...
```

### Selection Behavior

Selecting an OpenRouter model:

- Set `provider = "openrouter"`.
- Set `model = <openrouter-model>`.
- Persist both fields.

Selecting a local model:

- Set `provider = "llama_cpp"`.
- Set `model = <local-model-name>`.
- Persist both fields.
- If `auto_start = true`, optionally start the selected local model immediately or defer until first request.

### Setup Shortcut

The picker can include `Local setup...`, which prompts for a model string and delegates to `:SageLocalSetup` behavior.

## Config File Persistence

Add helpers in `config.lua`:

- `set_provider(provider, persist)`
- `set_model(model, persist)` should remain, but provider changes need separate persistence.
- `add_llama_cpp_model(model_entry, persist)`
- `get_llama_cpp_model(name)`
- `is_local_provider()`
- `supports_search()`
- `supports_rag()`

Add nested config update support if needed. Current `config_file.update(key, value)` only updates top-level keys. Since `llama_cpp.models` is nested, either:

- Load full config, modify nested table, then save full config.
- Add `config_file.update_path(path, value)`.

Prefer loading and saving the full config from a config helper to keep `config_file.lua` simple.

When saving local setup, preserve existing `api_key` and existing OpenRouter model list.

## Logging and Status

### Log Files

Write local server logs to:

```text
stdpath("cache")/sage-llm/llama.cpp/server-<port>.log
```

Do not write secrets. Since `HF_TOKEN` is inherited from the environment, do not dump the process environment.

### Status Output

`:SageLocalStatus` should show:

```text
sage-llm local status
provider: llama_cpp
model: owner/model-GGUF:Q4_K_M
binary: /path/to/llama-server
server: running
owned: yes
url: http://127.0.0.1:8080/v1
health: ok
log: /path/to/server.log
```

If not running, show the configured model and binary resolution state.

## Error Handling

Use short, actionable errors.

### Missing HF Access

```text
sage-llm: llama.cpp could not download the model. Check HF_TOKEN and Hugging Face access for owner/model-GGUF:Q4_K_M. See :SageLocalStatus for logs.
```

### Missing Binary and Auto-Install Disabled

```text
sage-llm: llama-server not found. Install llama.cpp or enable llama_cpp.auto_install.
```

### Unsupported Platform

```text
sage-llm: No llama.cpp release asset found for <os>/<arch>. Install llama-server and set llama_cpp.binary.
```

### Local RAG Attempt

```text
sage-llm: Local RAG is not supported yet; continuing without repository context.
```

### Startup Timeout

```text
sage-llm: llama-server did not become ready before timeout. See :SageLocalStatus for logs.
```

## Security Considerations

- Bind managed servers to `127.0.0.1` by default.
- Do not expose server on `0.0.0.0` unless a user explicitly overrides host.
- Do not persist Hugging Face tokens.
- Do not pass Hugging Face tokens as process args.
- Do not log environment variables.
- Do not enable llama.cpp built-in tools.
- Do not kill non-owned server processes.
- Avoid shell string execution for model strings, paths, and URLs.
- Verify downloaded release artifacts when possible.
- Keep config examples free of real tokens.

## Implementation Phases

### Phase 1: Provider Config

Files:

- `lua/sage-llm/config.lua`
- `lua/sage-llm/config_file.lua`
- `tests/config_spec.lua`
- `tests/config_file_spec.lua`

Work:

1. Add `provider` default.
2. Add `llama_cpp` default table.
3. Add validation for provider and local config.
4. Add helpers for provider capability checks.
5. Update config template comments.
6. Add tests for defaults, validation, and persistence.

Acceptance criteria:

- Existing OpenRouter config tests still pass.
- `provider = "openrouter"` is default.
- `provider = "llama_cpp"` validates without requiring `api_key`.
- Invalid provider fails validation.

### Phase 2: Local Server Module

Files:

- `lua/sage-llm/local.lua`
- `tests/local_spec.lua`

Work:

1. Implement model resolution.
2. Implement port selection.
3. Implement argv construction.
4. Implement status state.
5. Implement `start()`, `stop()`, `status()`, `ensure_ready()`.
6. Implement health polling.
7. Add tests for argv construction and ownership rules.

Acceptance criteria:

- `--hf-repo` args are built correctly.
- `--model` args are built correctly for local GGUF paths.
- `HF_TOKEN` never appears in args.
- `stop()` only stops owned jobs.

### Phase 3: Auto Installer

Files:

- `lua/sage-llm/local_install.lua`
- `tests/local_install_spec.lua`

Work:

1. Detect OS and architecture.
2. Query latest llama.cpp release.
3. Select correct asset.
4. Download archive.
5. Verify digest when available.
6. Extract archive.
7. Locate `llama-server` binary.
8. Cache by release tag.

Acceptance criteria:

- Asset selection is tested for macOS arm64, macOS x64, Linux x64, Linux arm64, Windows x64, and Windows arm64.
- Existing managed install is reused.
- Unsupported platforms return a clear error.
- Digest mismatch fails.

### Phase 4: API Provider Refactor

Files:

- `lua/sage-llm/api.lua`
- `tests/api_spec.lua` if added

Work:

1. Separate provider-specific headers.
2. Separate provider-specific API key requirements.
3. Separate provider-specific base URL resolution.
4. Ensure local server readiness before local chat requests.
5. Disable `:online` suffix for local provider.
6. Return clear embeddings error for local provider.

Acceptance criteria:

- OpenRouter behavior is unchanged.
- Local chat does not require OpenRouter API key.
- Local chat targets `http://127.0.0.1:<port>/v1/chat/completions`.
- Local embeddings return unsupported error.

### Phase 5: Public Commands and Request Flow

Files:

- `lua/sage-llm/init.lua`
- `plugin/sage-llm.lua`
- `tests/init_spec.lua`

Work:

1. Add public functions for local setup/start/stop/status/install.
2. Register user commands.
3. Disable RAG for local provider.
4. Disable search for local provider.
5. Ensure local setup persists model and provider.

Acceptance criteria:

- `:SageLocalSetup` accepts a model string.
- Local provider requests do not call RAG retrieval.
- Local provider requests do not expose search toggle.
- Existing OpenRouter request behavior remains unchanged.

### Phase 6: Model Picker Integration

Files:

- `lua/sage-llm/models.lua`
- `tests/models_spec.lua`

Work:

1. Display local models in `:SageModel`.
2. Persist provider and model on selection.
3. Add local setup shortcut.
4. Keep OpenRouter custom add/remove behavior.

Acceptance criteria:

- Selecting OpenRouter model sets provider to `openrouter`.
- Selecting local model sets provider to `llama_cpp`.
- Existing custom OpenRouter model tests still pass.

### Phase 7: UI Cleanup

Files:

- `lua/sage-llm/ui/input.lua`
- `lua/sage-llm/ui/response.lua`
- `tests/response_spec.lua`

Work:

1. Omit search footer when no search callback exists.
2. Omit RAG title/footer when no RAG callback exists.
3. Consider shortening long local model titles.

Acceptance criteria:

- OpenRouter still shows search controls.
- Local provider hides search controls.
- Local provider hides RAG controls.

### Phase 8: Documentation

Files:

- `README.md`
- `LOCAL_MODELS_PLAN.md`

Work:

1. Document `:SageLocalSetup` happy path.
2. Document `HF_TOKEN` requirements for gated models.
3. Document managed start/stop/status commands.
4. Document manual `llama-server` fallback.
5. Document local RAG limitation.
6. Document supported platform auto-install matrix.

Acceptance criteria:

- User can configure local model from README without reading source.
- Security guidance around `HF_TOKEN` is explicit.

## Test Plan

Run the existing test suite:

```sh
make test
```

Run lint and format checks:

```sh
make lint
make format-check
```

Manual verification matrix:

| Scenario | Expected Result |
| --- | --- |
| Fresh OpenRouter config | Existing commands work unchanged |
| `:SageLocalSetup public/model-GGUF:Q4_K_M` | Binary installs, model starts, provider switches |
| Local `:SageAsk` | Response streams from local model |
| Local `:SageInfill` | Replacement preview appears and can be applied |
| Local follow-up | Follow-up uses same local server |
| Local with RAG enabled in config | Warn once, continue without RAG |
| Local with search toggle attempted | Search unavailable or hidden |
| `:SageLocalStop` after managed start | Server stops |
| `:SageLocalStop` with external server | Server is not killed |
| Missing `HF_TOKEN` for gated model | Clear auth/access error with log path |
| Unsupported auto-install platform | Clear manual install instructions |

## Open Questions

These should be resolved before implementation starts:

1. Should `:SageLocalSetup` always switch to local provider immediately, or should it ask before switching if an OpenRouter provider is currently configured?
2. Should auto-installed binaries prefer CPU-only assets for predictability, or platform-accelerated assets when available?
3. Should `port = "auto"` persist the selected runtime port, or should the port remain dynamic per session?
4. Should the plugin expose `:SageProvider` as a separate provider picker, or is `:SageModel` enough?
5. Should `:SageLocalInstall` install latest every time or only install when missing unless a bang form is used?

## Recommended Answers

Recommended defaults for the first implementation:

1. `:SageLocalSetup` should switch to local provider immediately because it is an explicit local setup command.
2. Prefer CPU or platform-default release assets first for portability. Add GPU-specific install options later.
3. Keep `port = "auto"` in config and compute runtime port per session. The status command can show the active port.
4. Use `:SageModel` for provider/model selection to avoid adding another picker.
5. Make `:SageLocalInstall` idempotent and non-upgrading by default. Add `:SageLocalInstall!` later if forced upgrades are needed.

## Rollout Strategy

Ship in one feature branch but keep changes segmented by phase. The minimal shippable version is complete when:

- `:SageLocalSetup <hf-repo[:quant]>` works on supported platforms.
- Local `:SageAsk` and `:SageInfill` work.
- OpenRouter behavior is unchanged.
- Local RAG is safely disabled.
- Tokens are not persisted or passed in process args.
- Tests cover provider branching, local server args, and config persistence.

If auto-install proves too brittle on a platform, keep managed start/stop and external binary support working. Auto-install can fail gracefully without blocking users who install `llama-server` themselves.
