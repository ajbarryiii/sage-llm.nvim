---@class SageContext
---@field filetype string File type
---@field filepath string Relative file path
---@field dependencies string[]|nil Detected dependencies (if enabled)

local M = {}

---Find a file by walking up the directory tree
---@param filename string File to find (e.g., "Cargo.toml")
---@param start_path string Starting directory
---@return string|nil filepath Full path if found
local function find_file_upward(filename, start_path)
  local path = start_path
  local root = vim.fn.fnamemodify("/", ":p")

  while path ~= root do
    local candidate = path .. "/" .. filename
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    path = vim.fn.fnamemodify(path, ":h")
  end

  return nil
end

---Parse Cargo.toml for Rust dependencies
---@param filepath string Path to Cargo.toml
---@return string[]
local function parse_cargo_toml(filepath)
  local deps = {}
  local lines = vim.fn.readfile(filepath)
  local in_deps = false

  for _, line in ipairs(lines) do
    -- Check for dependency sections
    if line:match("^%[dependencies%]") or line:match("^%[dev%-dependencies%]") then
      in_deps = true
    elseif line:match("^%[") then
      in_deps = false
    elseif in_deps then
      -- Match "crate_name = ..." or "crate_name.workspace = true"
      local dep = line:match("^([%w_-]+)%s*=")
      if dep then
        table.insert(deps, dep)
      end
    end
  end

  return deps
end

---Parse package.json for JavaScript/TypeScript dependencies
---@param filepath string Path to package.json
---@return string[]
local function parse_package_json(filepath)
  local deps = {}
  local content = table.concat(vim.fn.readfile(filepath), "\n")

  -- Simple JSON parsing for dependencies
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return deps
  end

  -- Collect from dependencies and devDependencies
  for _, key in ipairs({ "dependencies", "devDependencies" }) do
    if decoded[key] and type(decoded[key]) == "table" then
      for dep, _ in pairs(decoded[key]) do
        table.insert(deps, dep)
      end
    end
  end

  table.sort(deps)
  return deps
end

---Parse go.mod for Go dependencies
---@param filepath string Path to go.mod
---@return string[]
local function parse_go_mod(filepath)
  local deps = {}
  local lines = vim.fn.readfile(filepath)
  local in_require = false

  for _, line in ipairs(lines) do
    -- Single-line require
    local single = line:match("^require%s+([^%s]+)")
    if single then
      -- Extract package name (last part of path)
      local name = single:match("([^/]+)$")
      if name then
        table.insert(deps, name)
      end
    end

    -- Multi-line require block
    if line:match("^require%s*%(") then
      in_require = true
    elseif line:match("^%)") then
      in_require = false
    elseif in_require then
      local dep = line:match("^%s*([^%s]+)")
      if dep then
        local name = dep:match("([^/]+)$")
        if name then
          table.insert(deps, name)
        end
      end
    end
  end

  return deps
end

---Parse pyproject.toml for Python dependencies
---@param filepath string Path to pyproject.toml
---@return string[]
local function parse_pyproject_toml(filepath)
  local deps = {}
  local lines = vim.fn.readfile(filepath)
  local in_deps = false

  for _, line in ipairs(lines) do
    if line:match("^dependencies%s*=") or line:match("^%[project.dependencies%]") then
      in_deps = true
    elseif line:match("^%[") and not line:match("dependencies") then
      in_deps = false
    elseif in_deps then
      -- Match "package-name" or 'package-name' in array
      local dep = line:match('"([^">=<~!]+)') or line:match("'([^'>=<~!]+)")
      if dep then
        -- Strip version specifiers
        dep = dep:match("^([%w_-]+)")
        if dep then
          table.insert(deps, dep)
        end
      end
    end
  end

  return deps
end

---Parse requirements.txt for Python dependencies
---@param filepath string Path to requirements.txt
---@return string[]
local function parse_requirements_txt(filepath)
  local deps = {}
  local lines = vim.fn.readfile(filepath)

  for _, line in ipairs(lines) do
    -- Skip comments and empty lines
    if not line:match("^%s*#") and not line:match("^%s*$") then
      -- Extract package name (before version specifier)
      local dep = line:match("^([%w_-]+)")
      if dep then
        table.insert(deps, dep)
      end
    end
  end

  return deps
end

---Detect dependencies based on filetype
---@param bufnr number Buffer number
---@return string[]|nil dependencies, string|nil manifest_type
function M.detect_dependencies(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return nil, nil
  end

  local dir = vim.fn.fnamemodify(filepath, ":h")
  local ft = vim.bo[bufnr].filetype

  -- Filetype to manifest mapping
  local strategies = {
    rust = { file = "Cargo.toml", parser = parse_cargo_toml },
    javascript = { file = "package.json", parser = parse_package_json },
    typescript = { file = "package.json", parser = parse_package_json },
    typescriptreact = { file = "package.json", parser = parse_package_json },
    javascriptreact = { file = "package.json", parser = parse_package_json },
    go = { file = "go.mod", parser = parse_go_mod },
    python = {
      -- Try pyproject.toml first, fall back to requirements.txt
      { file = "pyproject.toml", parser = parse_pyproject_toml },
      { file = "requirements.txt", parser = parse_requirements_txt },
    },
  }

  local strategy = strategies[ft]
  if not strategy then
    return nil, nil
  end

  -- Handle single strategy or array of fallbacks
  local attempts = strategy[1] and strategy or { strategy }

  for _, attempt in ipairs(attempts) do
    local manifest = find_file_upward(attempt.file, dir)
    if manifest then
      local deps = attempt.parser(manifest)
      if #deps > 0 then
        return deps, attempt.file
      end
    end
  end

  return nil, nil
end

---Format dependencies for inclusion in prompt
---@param dependencies string[]|nil
---@return string
function M.format_for_prompt(dependencies)
  if not dependencies or #dependencies == 0 then
    return ""
  end

  return "Dependencies: " .. table.concat(dependencies, ", ")
end

return M
