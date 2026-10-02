describe("ChatGPT subscription authentication", function()
  local auth
  local auth_dir
  local original_open
  local originals
  local opened
  local requests
  local token_response
  local token_status
  local jwks_status
  local jwks_body
  local discovery
  local deferred_refresh
  local peers
  local peer_locks
  local verification_claims
  local revocation_statuses
  local uv = vim.uv or vim.loop
  local ffi = require("ffi")
  pcall(ffi.cdef, "int flock(int fd, int operation);")

  local function hold_session_lock()
    local fd = assert(uv.fs_open(auth_dir .. "/session.lock", "a", 384))
    assert.equals(0, ffi.C.flock(fd, 6))
    local released = false
    local function release()
      if not released then
        released = true
        ffi.C.flock(fd, 8)
        uv.fs_close(fd)
      end
    end
    peer_locks[#peer_locks + 1] = release
    return release
  end

  local function assert_session_unlocked()
    if not uv.fs_stat(auth_dir .. "/session.lock") then
      return
    end
    assert.equals(384, uv.fs_stat(auth_dir .. "/session.lock").mode % 512)
    hold_session_lock()()
  end

  local function decode(value)
    return (
      value:gsub("+", " "):gsub("%%([%da-fA-F][%da-fA-F])", function(hex)
        return string.char(tonumber(hex, 16))
      end)
    )
  end

  local function query(value)
    local fields = {}
    for key, part in value:gmatch("([^&=?]+)=([^&]*)") do
      fields[decode(key)] = decode(part)
    end
    return fields
  end

  local function encode(value)
    return (
      value:gsub("([^%w%-%.%_~])", function(byte)
        return string.format("%%%02X", byte:byte())
      end)
    )
  end

  local function write_credentials(record)
    vim.fn.mkdir(auth_dir, "p", 448)
    vim.fn.writefile({ vim.json.encode(record) }, auth_dir .. "/credentials.json")
    uv.fs_chmod(auth_dir .. "/credentials.json", 384)
  end

  local function saved_credentials()
    return vim.json.decode(table.concat(vim.fn.readfile(auth_dir .. "/credentials.json"), "\n"))
  end

  local function record()
    return {
      issuer = "https://auth.openai.com",
      subject = "account-a",
      email = "a@example.test",
      client_id = "oaiapp_existing",
      ext_agent_host_id = "urn:uuid:12345678-1234-4123-8123-123456789abc",
      access_token = "old-access",
      refresh_token = "old-refresh",
      id_token = "account-a",
      token_type = "Bearer",
      expires_at = os.time() + 3600,
      scopes = { "resource.invoke", "chatgpt.tokens.use.direct", "offline_access" },
    }
  end

  local function wait_for(predicate)
    assert.is_true(vim.wait(2000, predicate, 5), "Timed out waiting for auth callback")
  end

  local function callback_request(fields)
    local params = query(opened)
    fields = fields
      or { code = "code-value", state = params.state, client_id = "oaiapp_registered" }
    local entries = {}
    for key, value in pairs(fields) do
      entries[#entries + 1] = encode(key) .. "=" .. encode(value)
    end
    local callback_uri = params.redirect_uri
    local port = tonumber(callback_uri:match(":(%d+)/"))
    local peer = uv.new_tcp()
    peers[#peers + 1] = peer
    local response = ""
    peer:connect("127.0.0.1", port, function(err)
      assert.is_nil(err)
      peer:read_start(function(_, chunk)
        if chunk then
          response = response .. chunk
        elseif not peer:is_closing() then
          peer:close()
        end
      end)
      peer:write(
        "GET /auth/callback?"
          .. table.concat(entries, "&")
          .. " HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      )
    end)
    wait_for(function()
      return response ~= ""
    end)
    return response
  end

  before_each(function()
    auth_dir = vim.fn.tempname()
    original_open = vim.ui.open
    originals = {}
    for _, name in ipairs({
      "sage-llm.config",
      "plenary.curl",
      "sage-llm.chatgpt_crypto",
      "sage-llm.chatgpt_auth",
    }) do
      originals[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    opened = nil
    requests = {}
    peers = {}
    peer_locks = {}
    verification_claims = {}
    revocation_statuses = { 200 }
    deferred_refresh = nil
    token_status = 200
    token_response = {
      access_token = "new-access",
      refresh_token = "new-refresh",
      id_token = "account-a",
      token_type = "Bearer",
      expires_in = 3600,
      scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
    }
    jwks_status = 200
    jwks_body = { keys = {} }
    discovery = {
      issuer = "https://auth.openai.com",
      revocation_endpoint = "https://auth.openai.com/api/accounts/oauth/revoke",
    }
    package.loaded["sage-llm.config"] = {
      options = {
        chatgpt = { auth_dir = auth_dir, login_timeout_ms = 2000, request_timeout_ms = 1000 },
      },
    }
    local random_count = 0
    package.loaded["sage-llm.chatgpt_crypto"] = {
      random_token = function()
        random_count = random_count + 1
        return "secure-random-" .. random_count
      end,
      random_uuid = function()
        return "12345678-1234-4123-8123-123456789abc"
      end,
      challenge = function(verifier)
        return "sha256-" .. verifier
      end,
      verify_id_token = function(token, _, claims)
        verification_claims[#verification_claims + 1] = claims
        if token == "forged" or claims.subject and token ~= claims.subject then
          return nil, "invalid identity"
        end
        return { sub = token, email = "a@example.test" }
      end,
    }
    local function request(url, opts)
      local entry = { url = url, options = opts }
      if opts.body then
        entry.form = query(table.concat(vim.fn.readfile(opts.body), "\n"))
      end
      requests[#requests + 1] = entry
      if url:match("/oauth/token$") then
        if entry.form.grant_type == "refresh_token" and deferred_refresh then
          deferred_refresh.options = opts
        else
          opts.callback({ status = token_status, body = vim.json.encode(token_response) })
        end
      elseif url:match("/jwks.json$") then
        opts.callback({
          status = jwks_status,
          body = type(jwks_body) == "string" and jwks_body or vim.json.encode(jwks_body),
        })
      elseif url:match("/openid%-configuration$") then
        opts.callback({
          status = 200,
          body = type(discovery) == "string" and discovery or vim.json.encode(discovery),
        })
      elseif url:match("/oauth/revoke$") then
        opts.callback({ status = table.remove(revocation_statuses, 1) or 200, body = "" })
      else
        error("Unexpected HTTP request")
      end
      return {
        shutdown = function()
          entry.cancelled = true
        end,
      }
    end
    package.loaded["plenary.curl"] = { get = request, post = request }
    vim.ui.open = function(url)
      opened = url
      return {}
    end
    auth = require("sage-llm.chatgpt_auth")
  end)

  after_each(function()
    auth.cancel_login()
    vim.wait(50, function()
      return true
    end)
    for _, peer in ipairs(peers) do
      if not peer:is_closing() then
        peer:close()
      end
    end
    for _, release in ipairs(peer_locks) do
      release()
    end
    vim.ui.open = original_open
    for name, value in pairs(originals) do
      package.loaded[name] = value
    end
    -- Nil originals are not present in the table above.
    for _, name in ipairs({
      "sage-llm.config",
      "plenary.curl",
      "sage-llm.chatgpt_crypto",
      "sage-llm.chatgpt_auth",
    }) do
      if originals[name] == nil then
        package.loaded[name] = nil
      end
    end
    vim.fn.delete(auth_dir, "rf")
  end)

  it("keeps account status free of secrets and reuses a valid token without HTTP", function()
    assert.is_false(auth.status().connected)
    write_credentials(record())
    local status = auth.status()
    assert.is_true(status.connected)
    assert.is_nil(status.access_token)
    assert.is_nil(status.refresh_token)
    assert.is_nil(status.id_token)
    local token
    auth.get_access_token(function(value)
      token = value
    end)
    assert.equals("old-access", token)
    assert.equals(0, #requests)
  end)

  it(
    "reads a complete credential snapshot when another instance replaces the path before open",
    function()
      write_credentials(record())
      local replacement = record()
      replacement.access_token = "renewed-access-with-a-longer-value-than-the-previous-token"
      replacement.refresh_token = "renewed-refresh-with-a-longer-value-than-the-previous-token"
      local temporary = auth_dir .. "/replacement.json"
      vim.fn.writefile({ vim.json.encode(replacement) }, temporary)
      uv.fs_chmod(temporary, 384)
      local original = uv.fs_open
      local replaced = false
      uv.fs_open = function(path, flags, mode)
        if path == auth_dir .. "/credentials.json" and flags == "r" and not replaced then
          replaced = true
          assert(uv.fs_rename(temporary, path))
        end
        return original(path, flags, mode)
      end
      local token, failure
      local ok, err = pcall(function()
        auth.get_access_token(function(value, message)
          token, failure = value, message
        end)
      end)
      uv.fs_open = original
      assert.is_true(ok, err)
      assert.is_true(replaced)
      assert.equals(replacement.access_token, token)
      assert.is_nil(failure)
      assert.equals(0, #requests)
    end
  )

  it("registers with PKCE, verifies identity, and saves owner-only credentials", function()
    local result
    auth.login(function(ok, err)
      result = { ok, err }
    end)
    local params = query(opened)
    assert.equals("dynamic_agent_client", params.client_id)
    assert.equals("sage-llm.nvim", params.agent_name_hint)
    assert.equals("S256", params.code_challenge_method)
    assert.equals("https://api.openai.com/v1", params.resource)
    assert.matches("^http://127.0.0.1:%d+/auth/callback$", params.redirect_uri)
    assert.is_nil(params.id_token_hint)
    callback_request()
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ true }, result)
    local saved = saved_credentials()
    assert.equals("oaiapp_registered", saved.client_id)
    assert.equals("account-a", saved.subject)
    assert.equals("new-access", saved.access_token)
    assert.equals(params.nonce, verification_claims[1].nonce)
    assert.equals("oaiapp_registered", verification_claims[1].audience)
    assert.equals(384, uv.fs_stat(auth_dir .. "/credentials.json").mode % 512)
    assert.equals(448, uv.fs_stat(auth_dir).mode % 512)
    assert.equals("oaiapp_registered", requests[1].form.client_id)
    assert.equals(params.redirect_uri, requests[1].form.redirect_uri)
    assert.is_nil(uv.fs_stat(requests[1].options.body))
    assert_session_unlocked()
  end)

  it("rejects a mismatched callback state without consuming a valid attempt", function()
    local result
    auth.login(function(ok, err)
      result = { ok, err }
    end)
    local response =
      callback_request({ code = "wrong", state = "wrong", client_id = "oaiapp_attacker" })
    assert.matches("400 Bad Request", response)
    assert.equals(0, #requests)
    assert.is_nil(result)
    callback_request()
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result[1])
  end)

  it("requires both plan scopes before saving a connection", function()
    token_response.scope = "openid profile email chatgpt.tokens.use.direct"
    local result
    auth.login(function(ok, err)
      result = { ok, err }
    end)
    callback_request()
    wait_for(function()
      return result ~= nil
    end)
    assert.is_false(result[1])
    assert.matches("not granted", result[2])
    assert.is_false(auth.status().connected)
    assert.equals(1, #requests)
  end)

  it("preserves an active connection when returning identity verification fails", function()
    write_credentials(record())
    token_response.id_token = "account-b"
    local result
    auth.login(function(ok, err)
      result = { ok, err }
    end)
    local params = query(opened)
    assert.equals("oaiapp_existing", params.client_id)
    assert.is_nil(params.agent_name_hint)
    callback_request({ code = "new-code", state = params.state })
    wait_for(function()
      return result ~= nil
    end)
    assert.is_false(result[1])
    assert.equals("old-access", saved_credentials().access_token)
    assert.equals("account-a", verification_claims[1].subject)
  end)

  it("allows an explicit new-account login only after a verified connection", function()
    write_credentials(record())
    token_response.id_token = "account-b"
    local result
    auth.login(function(ok, err)
      result = { ok, err }
    end, { new_account = true })
    assert.equals("dynamic_agent_client", query(opened).client_id)
    assert.equals("old-access", saved_credentials().access_token)
    callback_request()
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result[1])
    assert.equals("account-b", saved_credentials().subject)
    assert.is_nil(verification_claims[1].subject)
  end)

  it("rejects malformed JWKS and releases the session lock", function()
    jwks_body = "not JSON"
    local result
    auth.login(function(ok, err)
      result = { ok, err }
    end)
    callback_request()
    wait_for(function()
      return result ~= nil
    end)
    assert.is_false(result[1])
    assert.matches("invalid ChatGPT identity", result[2])
    assert.equals(0, #verification_claims)
    assert_session_unlocked()
  end)

  it("rejects unsupported token types, invalid expiry, and malformed identity fields", function()
    local defaults = vim.deepcopy(token_response)
    for _, malformed in ipairs({
      { token_type = "Basic" },
      { expires_in = 0 },
      { expires_in = 3600.5 },
      { id_token = {} },
    }) do
      token_response = vim.tbl_extend("force", defaults, malformed)
      local result
      auth.login(function(ok, err)
        result = { ok, err }
      end)
      callback_request()
      wait_for(function()
        return result ~= nil
      end)
      assert.is_false(result[1])
      assert.is_string(result[2])
      assert.is_false(auth.status().connected)
      assert_session_unlocked()
    end
  end)

  it("serializes callers and rotates refresh tokens atomically", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    deferred_refresh = {}
    local results = {}
    auth.get_access_token(function(token, err)
      results[#results + 1] = { token, err }
    end)
    auth.get_access_token(function(token, err)
      results[#results + 1] = { token, err }
    end)
    wait_for(function()
      return deferred_refresh.options ~= nil
    end)
    assert.equals(1, #requests)
    assert.equals("old-refresh", requests[1].form.refresh_token)
    assert.is_nil(requests[1].form.scope)
    deferred_refresh.options.callback({ status = 200, body = vim.json.encode(token_response) })
    wait_for(function()
      return #results == 2
    end)
    assert.same({ { "new-access" }, { "new-access" } }, results)
    assert.equals("new-refresh", saved_credentials().refresh_token)
    assert.equals("account-a", verification_claims[1].subject)
    assert.is_nil(verification_claims[1].nonce)
    assert.is_nil(uv.fs_stat(requests[1].options.body))
    assert_session_unlocked()
  end)

  it("retains rotated credentials across a transient JWKS failure and process restart", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    jwks_status = 503
    local result
    auth.get_access_token(function(token, err)
      result = { token, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_nil(result[1])
    local staged = saved_credentials()
    assert.equals("old-access", staged.access_token)
    assert.equals("new-refresh", staged.pending_refresh.tokens.refresh_token)
    assert.equals(384, uv.fs_stat(auth_dir .. "/credentials.json").mode % 512)
    assert_session_unlocked()

    package.loaded["sage-llm.chatgpt_auth"] = nil
    auth = require("sage-llm.chatgpt_auth")
    jwks_status = 200
    result = nil
    auth.get_access_token(function(token, err)
      result = { token, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ "new-access" }, result)
    local exchanges = 0
    for _, entry in ipairs(requests) do
      if entry.url:match("/oauth/token$") then
        exchanges = exchanges + 1
      end
    end
    assert.equals(1, exchanges)
    assert.equals("new-refresh", saved_credentials().refresh_token)
    assert.is_nil(saved_credentials().pending_refresh)
  end)

  it("never activates a staged refresh with an invalid identity", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    token_response.id_token = "account-b"
    for _ = 1, 2 do
      local result
      auth.get_access_token(function(token, err)
        result = { token, err }
      end)
      wait_for(function()
        return result ~= nil
      end)
      assert.is_nil(result[1])
      assert.matches("invalid ChatGPT identity", result[2])
      assert.equals("old-access", saved_credentials().access_token)
    end
    assert.equals(3, #requests) -- One exchange, two verification attempts.
    assert.equals("new-refresh", saved_credentials().pending_refresh.tokens.refresh_token)
  end)

  it("renews an expired staged token using its verified replacement refresh token", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    expired.pending_refresh = {
      received_at = os.time() - 7200,
      tokens = vim.deepcopy(token_response),
    }
    write_credentials(expired)
    local result
    auth.get_access_token(function(token, err)
      result = { token, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ "new-access" }, result)
    assert.equals("new-refresh", requests[2].form.refresh_token)
    assert.equals(expired.pending_refresh.received_at, verification_claims[1].time)
    assert.is_nil(saved_credentials().pending_refresh)
  end)

  it("revokes and removes the staged replacement when signing out", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    expired.pending_refresh = {
      received_at = os.time(),
      tokens = vim.deepcopy(token_response),
    }
    write_credentials(expired)
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ true }, result)
    assert.equals("new-refresh", requests[2].form.token)
    assert.is_nil(saved_credentials().pending_refresh)
    assert.is_false(auth.status().connected)
  end)

  it("waits for another instance and reuses its renewed credentials", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    local release = hold_session_lock()
    local result
    auth.get_access_token(function(token, err)
      result = { token, err }
    end)
    assert.is_nil(result)
    local renewed = record()
    renewed.access_token = "other-access"
    renewed.refresh_token = "other-refresh"
    write_credentials(renewed)
    release()
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ "other-access" }, result)
    assert.equals(0, #requests)
  end)

  it("serializes competing instances even when an old lock file contains a dead owner", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    vim.fn.writefile({ '{"owner":"abandoned","pid":99999999}' }, auth_dir .. "/session.lock")
    deferred_refresh = {}
    local first
    auth.get_access_token(function(token)
      first = token
    end)
    wait_for(function()
      return deferred_refresh.options ~= nil
    end)
    local original_inode = uv.fs_stat(auth_dir .. "/session.lock").ino
    package.loaded["sage-llm.chatgpt_auth"] = nil
    local other = require("sage-llm.chatgpt_auth")
    local second
    other.get_access_token(function(token)
      second = token
    end)
    vim.wait(150, function()
      return false
    end, 5)
    assert.equals(1, #requests)
    assert.is_nil(second)
    assert.equals(original_inode, uv.fs_stat(auth_dir .. "/session.lock").ino)
    deferred_refresh.options.callback({ status = 200, body = vim.json.encode(token_response) })
    wait_for(function()
      return first ~= nil and second ~= nil
    end)
    assert.equals("new-access", first)
    assert.equals("new-access", second)
    assert.equals(original_inode, uv.fs_stat(auth_dir .. "/session.lock").ino)
    assert_session_unlocked()
  end)

  it("does not let cancelled refresh callers stop other callers", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    deferred_refresh = {}
    local cancelled_result
    local result
    local handle = auth.get_access_token(function(value)
      cancelled_result = value
    end)
    auth.get_access_token(function(value)
      result = value
    end)
    handle.cancel()
    wait_for(function()
      return deferred_refresh.options ~= nil
    end)
    deferred_refresh.options.callback({ status = 200, body = vim.json.encode(token_response) })
    wait_for(function()
      return result ~= nil
    end)
    assert.equals("new-access", result)
    assert.is_nil(cancelled_result)
  end)

  it("clears unusable renewable access when OpenAI rejects the refresh grant", function()
    local expired = record()
    expired.expires_at = os.time() - 5
    write_credentials(expired)
    token_status = 400
    token_response = { error = "invalid_grant", error_description = "sensitive details" }
    local result
    auth.get_access_token(function(token, err)
      result = { token, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_nil(result[1])
    assert.matches("Sign in again", result[2])
    assert.is_nil(result[2]:find("sensitive", 1, true))
    assert.is_false(auth.status().connected)
    assert.equals("oaiapp_existing", saved_credentials().client_id)
  end)

  it("removes crash-orphaned OAuth forms and credential copies before local sign-out", function()
    write_credentials(record())
    local orphan = auth_dir .. "/.request-crashed-process"
    local temporary = auth_dir .. "/credentials.json.crashed-process"
    vim.fn.writefile({ "refresh_token=old-refresh" }, orphan)
    vim.fn.writefile({ vim.json.encode(record()) }, temporary)
    uv.fs_chmod(orphan, 384)
    uv.fs_chmod(temporary, 384)
    vim.fn.writefile({ "unrelated metadata" }, auth_dir .. "/keep.txt")
    discovery = "unavailable"
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    assert.is_nil(uv.fs_stat(orphan))
    assert.is_nil(uv.fs_stat(temporary))
    assert.is_nil(saved_credentials().refresh_token)
    assert.is_not_nil(uv.fs_stat(auth_dir .. "/keep.txt"))
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result[1])
    assert.matches("not confirmed", result[2])
  end)

  it(
    "preserves another instance's active request file and removes it only after lock recovery",
    function()
      local expired = record()
      expired.expires_at = os.time() - 5
      write_credentials(expired)
      local release = hold_session_lock()
      local orphan = auth_dir .. "/.request-other-process"
      vim.fn.writefile({ "refresh_token=old-refresh" }, orphan)
      uv.fs_chmod(orphan, 384)
      local post = package.loaded["plenary.curl"].post
      package.loaded["plenary.curl"].post = function(url, opts)
        assert.is_nil(uv.fs_stat(orphan))
        assert.is_not_nil(uv.fs_stat(opts.body))
        return post(url, opts)
      end
      local result
      auth.get_access_token(function(token, err)
        result = { token, err }
      end)
      assert.is_not_nil(uv.fs_stat(orphan))
      assert.equals(0, #requests)
      release()
      wait_for(function()
        return result ~= nil
      end)
      assert.same({ "new-access" }, result)
      assert.is_nil(uv.fs_stat(orphan))
      assert_session_unlocked()
    end
  )

  it("reports failed secret-file removal instead of claiming successful local sign-out", function()
    write_credentials(record())
    local orphan = auth_dir .. "/.request-crashed-process"
    vim.fn.writefile({ "refresh_token=old-refresh" }, orphan)
    uv.fs_chmod(orphan, 384)
    local unlink = uv.fs_unlink
    uv.fs_unlink = function(path)
      if path == orphan then
        return nil, "unlink denied"
      end
      return unlink(path)
    end
    local result
    local ok, err = pcall(function()
      auth.logout(function(signed_out, message)
        result = { signed_out, message }
      end)
    end)
    uv.fs_unlink = unlink
    assert.is_true(ok, err)
    assert.is_false(result[1])
    assert.matches("Could not remove abandoned", result[2])
    assert.equals(0, #requests)
    assert_session_unlocked()
  end)

  it("revokes logout and retains the account registration and host", function()
    write_credentials(record())
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ true }, result)
    assert.equals(2, #requests)
    assert.equals("old-refresh", requests[2].form.token)
    assert.equals("refresh_token", requests[2].form.token_type_hint)
    local saved = saved_credentials()
    assert.is_nil(saved.access_token)
    assert.is_nil(saved.refresh_token)
    assert.is_nil(saved.id_token)
    assert.equals("oaiapp_existing", saved.client_id)
    assert.equals("account-a", saved.subject)
    assert.equals(record().ext_agent_host_id, saved.ext_agent_host_id)
  end)

  it("clears local credentials before network logout and preserves this on editor exit", function()
    write_credentials(record())
    package.loaded["plenary.curl"].get = function(url, opts)
      local entry = { url = url, options = opts }
      requests[#requests + 1] = entry
      return {
        shutdown = function()
          entry.cancelled = true
        end,
      }
    end
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    -- No scheduled callbacks or network completion are needed to remove local tokens.
    assert.equals(1, #requests)
    assert.is_nil(saved_credentials().access_token)
    assert.is_nil(saved_credentials().refresh_token)
    assert.is_nil(saved_credentials().id_token)
    assert.is_nil(result)
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "SageChatGPTAuth" })
    assert.is_true(requests[1].cancelled)
    assert_session_unlocked()
    assert.is_false(auth.status().connected)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result[1])
    assert.matches("remote revocation was not confirmed", result[2])
  end)

  it(
    "completes logout waiting on its own refresh lock before exit and ignores late refresh",
    function()
      local expired = record()
      expired.expires_at = os.time() - 5
      write_credentials(expired)
      deferred_refresh = {}
      auth.get_access_token(function() end)
      wait_for(function()
        return deferred_refresh.options ~= nil
      end)
      local result
      auth.logout(function(ok, err)
        result = { ok, err }
      end)
      assert.is_nil(result)
      local blocked
      auth.get_access_token(function(token, err)
        blocked = { token, err }
      end)
      assert.is_nil(blocked[1])
      assert.matches("sign%-out is in progress", blocked[2])
      assert.equals(1, #requests)
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "SageChatGPTAuth" })
      assert.is_false(auth.status().connected)
      assert.is_true(result[1])
      assert.matches("remote revocation was not confirmed", result[2])
      assert_session_unlocked()
      deferred_refresh.options.callback({ status = 200, body = vim.json.encode(token_response) })
      vim.wait(150, function()
        return false
      end, 5)
      assert.is_nil(saved_credentials().refresh_token)
      assert.is_nil(saved_credentials().pending_refresh)
      assert.equals(1, #requests)
    end
  )

  it(
    "preserves an already received rotating grant on exit and verifies it after restart",
    function()
      local expired = record()
      expired.expires_at = os.time() - 5
      write_credentials(expired)
      deferred_refresh = {}
      local delivered
      auth.get_access_token(function(token)
        delivered = token
      end)
      wait_for(function()
        return deferred_refresh.options ~= nil
      end)
      deferred_refresh.options.callback({ status = 200, body = vim.json.encode(token_response) })
      assert.is_nil(saved_credentials().pending_refresh)
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "SageChatGPTAuth" })
      local staged = saved_credentials()
      assert.equals("old-access", staged.access_token)
      assert.equals("new-refresh", staged.pending_refresh.tokens.refresh_token)
      assert.equals(0, #verification_claims)
      assert_session_unlocked()
      vim.wait(100, function()
        return false
      end, 5)
      assert.is_nil(delivered)
      assert.equals(1, #requests)

      package.loaded["sage-llm.chatgpt_auth"] = nil
      auth = require("sage-llm.chatgpt_auth")
      local result
      auth.get_access_token(function(token, err)
        result = { token, err }
      end)
      wait_for(function()
        return result ~= nil
      end)
      assert.same({ "new-access" }, result)
      assert.equals(2, #requests)
      assert.matches("/jwks.json$", requests[2].url)
      assert.equals(1, #verification_claims)
      assert.is_nil(saved_credentials().pending_refresh)
      assert.equals("new-refresh", saved_credentials().refresh_token)
    end
  )

  it(
    "suppresses a successful refresh callback already queued when exiting with pending logout",
    function()
      local expired = record()
      expired.expires_at = os.time() - 5
      write_credentials(expired)
      deferred_refresh = {}
      auth.get_access_token(function() end)
      wait_for(function()
        return deferred_refresh.options ~= nil
      end)
      auth.logout(function() end)
      deferred_refresh.options.callback({ status = 200, body = vim.json.encode(token_response) })
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = "SageChatGPTAuth" })
      assert.is_false(auth.status().connected)
      vim.wait(150, function()
        return false
      end, 5)
      assert.is_nil(saved_credentials().refresh_token)
      assert.is_nil(saved_credentials().pending_refresh)
      assert.equals(1, #requests)
    end
  )

  it("reports local logout storage failure before attempting remote revocation", function()
    write_credentials(record())
    local original_rename = uv.fs_rename
    uv.fs_rename = function(source, destination)
      if destination == auth_dir .. "/credentials.json" then
        return nil, "write failed"
      end
      return original_rename(source, destination)
    end
    local result
    local invoked = pcall(function()
      auth.logout(function(ok, err)
        result = { ok, err }
      end)
    end)
    uv.fs_rename = original_rename
    assert.is_true(invoked)
    assert.is_false(result[1])
    assert.matches("Could not securely save", result[2])
    assert.equals(0, #requests)
    assert.equals("old-refresh", saved_credentials().refresh_token)
    assert_session_unlocked()
  end)

  it("stops revocation backoff on editor exit", function()
    write_credentials(record())
    revocation_statuses = { 503, 200 }
    auth.logout(function() end)
    wait_for(function()
      return #requests == 2
    end)
    vim.wait(10, function()
      return false
    end)
    vim.api.nvim_exec_autocmds("VimLeavePre", { group = "SageChatGPTAuth" })
    vim.wait(300, function()
      return false
    end)
    assert.equals(2, #requests)
    assert.is_nil(saved_credentials().refresh_token)
    assert_session_unlocked()
  end)

  it("rejects platforms without the required owner-only filesystem permissions", function()
    local original_uname = uv.os_uname
    uv.os_uname = function()
      return { sysname = "Windows_NT" }
    end
    local ok, result = pcall(function()
      local response
      auth.login(function(connected, err)
        response = { connected, err }
      end)
      return response
    end)
    uv.os_uname = original_uname
    assert.is_true(ok)
    assert.is_false(result[1])
    assert.matches("Unix filesystem with owner%-only permissions", result[2])
    assert.is_nil(opened)
    assert.is_nil(uv.fs_stat(auth_dir))
  end)

  it("rejects foreign revocation endpoints and reports unconfirmed remote logout", function()
    write_credentials(record())
    discovery.revocation_endpoint = "https://attacker.example/revoke"
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result[1])
    assert.matches("remote revocation was not confirmed", result[2])
    assert.equals(1, #requests)
    assert.is_false(auth.status().connected)
  end)

  it("retries temporary revocation failures before clearing renewable access", function()
    write_credentials(record())
    revocation_statuses = { 503, 200 }
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.same({ true }, result)
    assert.equals(3, #requests)
    assert.equals("old-refresh", requests[2].form.token)
    assert.equals("old-refresh", requests[3].form.token)
    assert.is_nil(saved_credentials().refresh_token)
  end)

  it("clears local credentials even if discovery is malformed", function()
    write_credentials(record())
    discovery = "malformed"
    local result
    auth.logout(function(ok, err)
      result = { ok, err }
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result[1])
    assert.matches("not confirmed", result[2])
    assert.is_false(auth.status().connected)
    assert_session_unlocked()
  end)

  it("cancels a pending exchange and immediately removes its private form body", function()
    -- Defer an authorization-code exchange to exercise cancellation while HTTP is active.
    package.loaded["plenary.curl"].post = function(url, opts)
      requests[#requests + 1] = { url = url, options = opts }
      return {
        shutdown = function()
          requests[#requests].cancelled = true
        end,
      }
    end
    local result
    local handle = auth.login(function(ok, err)
      result = { ok, err }
    end)
    callback_request()
    wait_for(function()
      return #requests == 1
    end)
    assert.is_not_nil(uv.fs_stat(requests[1].options.body))
    handle.cancel()
    assert.is_false(result[1])
    assert.is_true(requests[1].cancelled)
    assert.is_nil(uv.fs_stat(requests[1].options.body))
    assert_session_unlocked()
  end)
end)
