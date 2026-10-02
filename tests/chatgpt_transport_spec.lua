describe("ChatGPT request storage recovery", function()
  local transport
  local auth_dir
  local originals
  local stores
  local uv = vim.uv or vim.loop

  local function secrets(store)
    for _, name in ipairs({ "headers", "body" }) do
      local fd = assert(uv.fs_open(store.path .. "/" .. name, "wx", 384))
      assert(uv.fs_write(fd, "synthetic private " .. name, 0))
      uv.fs_close(fd)
    end
  end

  local function create()
    local store = assert(transport.create())
    stores[#stores + 1] = store
    secrets(store)
    return store
  end

  before_each(function()
    auth_dir = vim.fn.tempname()
    stores = {}
    originals = {}
    for _, name in ipairs({ "sage-llm.config", "sage-llm.chatgpt_transport" }) do
      originals[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    package.loaded["sage-llm.config"] = { options = { chatgpt = { auth_dir = auth_dir } } }
    transport = require("sage-llm.chatgpt_transport")
  end)

  after_each(function()
    for _, store in ipairs(stores) do
      if store.owner_fd then
        store.release()
      end
    end
    for _, name in ipairs({ "sage-llm.config", "sage-llm.chatgpt_transport" }) do
      package.loaded[name] = originals[name]
    end
    vim.fn.delete(auth_dir, "rf")
  end)

  it("preserves live requests and protects their directory and lock", function()
    local store = create()
    assert.equals(448, uv.fs_stat(auth_dir .. "/requests").mode % 512)
    assert.equals(448, uv.fs_stat(store.path).mode % 512)
    assert.equals(384, uv.fs_stat(store.path .. "/owner.lock").mode % 512)
    assert.is_true(transport.cleanup_orphans())
    assert.is_not_nil(uv.fs_stat(store.path .. "/headers"))
    assert.is_not_nil(uv.fs_stat(store.path .. "/body"))
    assert.is_true(store.release())
    assert.is_nil(uv.fs_stat(store.path))
    assert.is_true(store.release())
  end)

  it("removes a dead owner's secrets without deleting a competing live request", function()
    local dead = create()
    local live = create()
    uv.fs_close(dead.owner_fd)
    dead.owner_fd = nil
    assert.is_true(transport.cleanup_orphans())
    assert.is_nil(uv.fs_stat(dead.path))
    assert.is_not_nil(uv.fs_stat(live.path .. "/headers"))
    assert.is_not_nil(uv.fs_stat(live.path .. "/body"))
  end)

  it("cleans abandoned files before allocating the next request", function()
    local dead = create()
    uv.fs_close(dead.owner_fd)
    dead.owner_fd = nil
    local next_request = create()
    assert.is_nil(uv.fs_stat(dead.path))
    assert.is_not_nil(uv.fs_stat(next_request.path .. "/headers"))
  end)

  it("preserves unrelated entries and never follows an abandoned directory link", function()
    local store = create()
    local note = auth_dir .. "/requests/keep.txt"
    vim.fn.writefile({ "unrelated metadata" }, note)
    local link = auth_dir .. "/requests/request-linked"
    assert(uv.fs_symlink(store.path, link))
    assert.is_true(transport.cleanup_orphans())
    assert.is_nil(uv.fs_lstat(link))
    assert.is_not_nil(uv.fs_stat(store.path .. "/headers"))
    assert.is_not_nil(uv.fs_stat(note))
  end)

  it("leaves absent storage untouched during startup recovery", function()
    assert.is_true(transport.cleanup_orphans())
    assert.is_nil(uv.fs_stat(auth_dir))
  end)
end)
