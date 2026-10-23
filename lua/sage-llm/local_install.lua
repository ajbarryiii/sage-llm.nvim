local curl = require("plenary.curl")

local M = {}

local uv = vim.uv or vim.loop

---@return string
local function data_dir()
  return vim.fn.stdpath("data") .. "/sage-llm/llama.cpp"
end

---@return string
local function archive_dir()
  return vim.fn.stdpath("cache") .. "/sage-llm/llama.cpp/downloads"
end

---@return string
local function os_name()
  local sys = uv and uv.os_uname and uv.os_uname() or {}
  local name = (sys.sysname or ""):lower()
  if name:find("darwin", 1, true) then
    return "macos"
  elseif name:find("linux", 1, true) then
    return "ubuntu"
  elseif name:find("windows", 1, true) or name:find("mingw", 1, true) then
    return "win"
  end
  return name
end

---@return string
local function arch_name()
  local sys = uv and uv.os_uname and uv.os_uname() or {}
  local machine = (sys.machine or ""):lower()
  if machine == "x86_64" or machine == "amd64" then
    return "x64"
  elseif machine == "aarch64" or machine == "arm64" then
    return "arm64"
  end
  return machine
end

---@param asset_name string
---@return boolean
local function asset_matches_platform(asset_name)
  local os = os_name()
  local arch = arch_name()
  if os == "" or arch == "" then
    return false
  end

  if os == "win" then
    return asset_name:match("llama%-.*%-bin%-win%-cpu%-" .. arch .. "%.zip$") ~= nil
  end

  return asset_name:match("llama%-.*%-bin%-" .. os .. "%-" .. arch .. "%.tar%.gz$") ~= nil
end

---@param dir string
---@return string|nil
local function find_llama_server(dir)
  local candidates = vim.fn.glob(dir .. "/**/llama-server", false, true)
  if #candidates == 0 then
    candidates = vim.fn.glob(dir .. "/**/llama-server.exe", false, true)
  end
  for _, candidate in ipairs(candidates) do
    if vim.fn.executable(candidate) == 1 or vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

---@param path string
---@return string|nil
local function sha256_file(path)
  if vim.fn.executable("shasum") == 1 then
    local result = vim.fn.systemlist({ "shasum", "-a", "256", path })
    if vim.v.shell_error == 0 and result[1] then
      return result[1]:match("^(%x+)")
    end
  end
  if vim.fn.executable("sha256sum") == 1 then
    local result = vim.fn.systemlist({ "sha256sum", path })
    if vim.v.shell_error == 0 and result[1] then
      return result[1]:match("^(%x+)")
    end
  end
  return nil
end

---@param asset table
---@param archive_path string
---@return boolean, string|nil
local function verify_digest(asset, archive_path)
  if not asset.digest or asset.digest == "" then
    return true, nil
  end

  local expected = asset.digest:match("^sha256:(%x+)$")
  if not expected then
    return true, nil
  end

  local actual = sha256_file(archive_path)
  if not actual then
    return false, "Unable to verify llama.cpp archive digest: no sha256 tool found"
  end

  if actual:lower() ~= expected:lower() then
    return false, "llama.cpp archive digest mismatch"
  end

  return true, nil
end

---@param archive_path string
---@param target_dir string
---@return boolean, string|nil
local function extract_archive(archive_path, target_dir)
  vim.fn.mkdir(target_dir, "p")

  local cmd
  if archive_path:match("%.tar%.gz$") then
    if vim.fn.executable("tar") ~= 1 then
      return false, "tar is required to extract llama.cpp"
    end
    cmd = { "tar", "-xzf", archive_path, "-C", target_dir }
  elseif archive_path:match("%.zip$") then
    if vim.fn.executable("unzip") ~= 1 then
      return false, "unzip is required to extract llama.cpp"
    end
    cmd = { "unzip", "-oq", archive_path, "-d", target_dir }
  else
    return false, "Unsupported llama.cpp archive format"
  end

  vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false, "Failed to extract llama.cpp archive"
  end

  return true, nil
end

---@param release table
---@return table|nil
function M.select_asset(release)
  for _, asset in ipairs(release.assets or {}) do
    if asset.name and asset.browser_download_url and asset_matches_platform(asset.name) then
      return asset
    end
  end
  return nil
end

---@param opts SageLlamaCppConfig
---@return string|nil binary, string|nil err
function M.managed_binary(opts)
  local root = opts.install_dir or data_dir()
  local binaries = vim.fn.glob(root .. "/**/llama-server*", false, true)
  for _, binary in ipairs(binaries) do
    if binary:match("llama%-server%.?e?x?e?$") and vim.fn.executable(binary) == 1 then
      return binary, nil
    end
  end
  return nil, nil
end

---@param opts SageLlamaCppConfig
---@return string|nil binary, string|nil err
function M.install(opts)
  local existing = M.managed_binary(opts)
  if existing then
    return existing, nil
  end

  local response = curl.get("https://api.github.com/repos/ggml-org/llama.cpp/releases/latest", {
    headers = { ["Accept"] = "application/vnd.github+json" },
  })
  if not response or response.status ~= 200 then
    return nil, "Failed to query latest llama.cpp release"
  end

  local ok, release = pcall(vim.json.decode, response.body)
  if not ok or type(release) ~= "table" then
    return nil, "Failed to parse llama.cpp release metadata"
  end

  local asset = M.select_asset(release)
  if not asset then
    return nil, "No llama.cpp release asset found for " .. os_name() .. "/" .. arch_name()
  end

  local tag = release.tag_name or "latest"
  local target_dir = (opts.install_dir or data_dir()) .. "/" .. tag
  local archive_path = archive_dir() .. "/" .. asset.name
  vim.fn.mkdir(archive_dir(), "p")
  vim.fn.mkdir(target_dir, "p")

  local download = curl.get(asset.browser_download_url, { output = archive_path })
  if not download or (download.status ~= 200 and download.status ~= 226) then
    return nil, "Failed to download llama.cpp release asset"
  end

  local verified, verify_err = verify_digest(asset, archive_path)
  if not verified then
    return nil, verify_err
  end

  local extracted, extract_err = extract_archive(archive_path, target_dir)
  if not extracted then
    return nil, extract_err
  end

  local binary = find_llama_server(target_dir)
  if not binary then
    return nil, "llama-server binary not found after extraction"
  end

  pcall(vim.fn.setfperm, binary, "rwxr-xr-x")
  return binary, nil
end

return M
