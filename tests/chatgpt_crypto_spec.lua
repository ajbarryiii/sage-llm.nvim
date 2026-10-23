describe("chatgpt_crypto", function()
  local crypto
  local uv = vim.uv or vim.loop
  local fixture_dir, private_key_path, jwks, claims
  local original_system = vim.system
  local original_executable = vim.fn.executable
  local original_random = uv.random
  local original_mkdtemp = uv.fs_mkdtemp
  local original_write = uv.fs_write

  local function command(args, input)
    local result = original_system(args, { stdin = input, text = false }):wait()
    assert.equals(0, result.code, result.stderr)
    return result.stdout
  end

  local function encode(bytes)
    return vim.base64.encode(bytes):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
  end

  local function signed(payload, header)
    header = header or { alg = "RS256", kid = "test-key", typ = "JWT" }
    local input = encode(vim.json.encode(header)) .. "." .. encode(vim.json.encode(payload))
    local signature = command({ "openssl", "dgst", "-sha256", "-sign", private_key_path }, input)
    return input .. "." .. encode(signature)
  end

  local function payload()
    return {
      iss = claims.issuer,
      aud = claims.audience,
      sub = "test-account",
      nonce = claims.nonce,
      iat = claims.time - 20,
      exp = claims.time + 3600,
    }
  end

  before_each(function()
    package.loaded["sage-llm.chatgpt_crypto"] = nil
    crypto = require("sage-llm.chatgpt_crypto")
    fixture_dir = assert(uv.fs_mkdtemp(vim.fn.tempname() .. "-crypto-spec-XXXXXX"))
    private_key_path = fixture_dir .. "/private.pem"
    -- Generate a disposable key locally; never use credentials or network access.
    local key =
      command({ "openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048" })
    local fd = assert(uv.fs_open(private_key_path, "wx", 384))
    assert.equals(#key, uv.fs_write(fd, key, 0))
    uv.fs_close(fd)
    local modulus =
      command({ "openssl", "rsa", "-in", private_key_path, "-noout", "-modulus" }):match(
        "Modulus=([A-Fa-f0-9]+)"
      )
    assert.is_truthy(modulus)
    local bytes = modulus:gsub("..", function(hex)
      return string.char(tonumber(hex, 16))
    end)
    jwks = {
      keys = {
        {
          kty = "RSA",
          kid = "test-key",
          alg = "RS256",
          use = "sig",
          n = encode(bytes),
          e = "AQAB",
        },
      },
    }
    claims = {
      issuer = "https://auth.openai.com",
      audience = "oaiapp_test",
      nonce = "test-nonce",
      time = 1700000000,
    }
  end)

  after_each(function()
    vim.system = original_system
    vim.fn.executable = original_executable
    uv.random = original_random
    uv.fs_mkdtemp = original_mkdtemp
    uv.fs_write = original_write
    if private_key_path then
      uv.fs_unlink(private_key_path)
    end
    if fixture_dir then
      uv.fs_rmdir(fixture_dir)
    end
  end)

  it("generates secure unpadded OAuth tokens and UUIDv4 host IDs", function()
    local first = assert(crypto.random_token())
    local second = assert(crypto.random_token())
    assert.equals(43, #first)
    assert.is_nil(first:find("[^A-Za-z0-9_-]"))
    assert.is_not.equals(first, second)
    local uuid = assert(crypto.random_uuid())
    assert.is_truthy(
      uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
    )
  end)

  it("falls back to OpenSSL when libuv secure randomness is unavailable", function()
    uv.random = nil
    local calls = {}
    vim.system = function(args, opts)
      calls[#calls + 1] = { args = args, opts = opts }
      return original_system(args, opts)
    end
    assert.equals(43, #assert(crypto.random_token()))
    assert.same({ "openssl", "rand", "32" }, calls[1].args)
  end)

  it("computes the RFC 7636 S256 example without putting the verifier in argv", function()
    local verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    vim.system = function(args, opts)
      assert.same({ "openssl", "dgst", "-sha256", "-binary" }, args)
      assert.equals(verifier, opts.stdin)
      return original_system(args, opts)
    end
    assert.equals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", crypto.challenge(verifier))
    assert.is_nil(crypto.challenge("too-short"))
    assert.is_nil(crypto.challenge(string.rep("!", 43)))
    assert.is_nil(crypto.challenge(string.rep("a", 129)))
  end)

  it("reports a useful error if OpenSSL is unavailable", function()
    vim.fn.executable = function(name)
      if name == "openssl" then
        return 0
      end
      return original_executable(name)
    end
    local value, err = crypto.challenge(string.rep("a", 43))
    assert.is_nil(value)
    assert.is_truthy(err:find("Install openssl", 1, true))
    uv.random = nil
    value, err = crypto.random_token()
    assert.is_nil(value)
    assert.is_truthy(err:find("Install openssl", 1, true))
  end)

  it("verifies a real RS256 signature and binds the expected identity", function()
    claims.subject = "test-account"
    local expected = payload()
    local verified, err = crypto.verify_id_token(signed(expected), jwks, claims)
    assert.is_nil(err)
    assert.same(expected, verified)
    expected.aud = { "oaiapp_other", claims.audience }
    expected.azp = claims.audience
    assert.same(expected, crypto.verify_id_token(signed(expected), jwks, claims))
  end)

  it("requires the existing subject when verifying a refresh without a nonce", function()
    local token = signed(payload())
    claims.nonce = nil
    assert.is_nil(crypto.verify_id_token(token, jwks, claims))
    claims.subject = "test-account"
    assert.is_table(crypto.verify_id_token(token, jwks, claims))
    claims.subject = "other-account"
    local value, err = crypto.verify_id_token(token, jwks, claims)
    assert.is_nil(value)
    assert.is_truthy(err:find("identity did not match", 1, true))
  end)

  it("rejects tampered payloads and signatures", function()
    local token = signed(payload())
    local header, _, signature = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    local changed = payload()
    changed.sub = "attacker"
    local value, err = crypto.verify_id_token(
      header .. "." .. encode(vim.json.encode(changed)) .. "." .. signature,
      jwks,
      claims
    )
    assert.is_nil(value)
    assert.is_truthy(err:find("signature", 1, true))
    local first = signature:sub(1, 1) == "A" and "B" or "A"
    value, err = crypto.verify_id_token(
      header .. "." .. encode(vim.json.encode(payload())) .. "." .. first .. signature:sub(2),
      jwks,
      claims
    )
    assert.is_nil(value)
    assert.is_truthy(err:find("signature", 1, true))
  end)

  it("rejects unsigned, symmetric, alternate algorithm, and critical-extension tokens", function()
    for _, algorithm in ipairs({ "none", "HS256", "RS512", "PS256" }) do
      local value, err = crypto.verify_id_token(
        signed(payload(), { alg = algorithm, kid = "test-key" }),
        jwks,
        claims
      )
      assert.is_nil(value)
      assert.is_truthy(err:find("unsupported signing", 1, true))
    end
    assert.is_nil(
      crypto.verify_id_token(
        signed(payload(), { alg = "RS256", kid = "test-key", crit = { "foo" } }),
        jwks,
        claims
      )
    )
    assert.is_nil(
      crypto.verify_id_token(
        signed(payload(), { alg = "RS256", kid = "test-key", b64 = false }),
        jwks,
        claims
      )
    )
  end)

  it("rejects unknown or ambiguous key IDs and incompatible JWKs", function()
    local token = signed(payload())
    assert.is_nil(
      crypto.verify_id_token(signed(payload(), { alg = "RS256", kid = "other-key" }), jwks, claims)
    )
    local duplicate = vim.deepcopy(jwks)
    duplicate.keys[2] = vim.deepcopy(duplicate.keys[1])
    assert.is_nil(crypto.verify_id_token(token, duplicate, claims))
    for _, change in ipairs({
      { "kty", "oct" },
      { "alg", "HS256" },
      { "use", "enc" },
      { "n", "AA" },
      { "e", "Ag" },
      { "key_ops", { "sign" } },
    }) do
      local changed = vim.deepcopy(jwks)
      changed.keys[1][change[1]] = change[2]
      assert.is_nil(crypto.verify_id_token(token, changed, claims))
    end
  end)

  it("rejects mismatched and invalid required OIDC claims", function()
    local changes = {
      { "iss", "https://attacker.example" },
      { "aud", "oaiapp_other" },
      { "aud", { "oaiapp_other" } },
      { "aud", { claims.audience, 17 } },
      { "aud", { claims.audience, "oaiapp_other" } },
      { "azp", "oaiapp_other" },
      { "nonce", "other-nonce" },
      { "nonce", vim.NIL },
      { "sub", "" },
      { "sub", 17 },
      { "exp", claims.time },
      { "exp", tostring(claims.time + 3600) },
      { "exp", vim.NIL },
      { "iat", vim.NIL },
      { "iat", claims.time + 60 },
      { "nbf", claims.time + 60 },
    }
    for _, change in ipairs(changes) do
      local changed = payload()
      changed[change[1]] = change[2]
      local value, err = crypto.verify_id_token(signed(changed), jwks, claims)
      assert.is_nil(value, change[1])
      assert.is_string(err)
    end
  end)

  it("rejects malformed JWT segments, invalid JSON, and oversized tokens", function()
    local token = signed(payload())
    local header, body, signature = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    for _, invalid in ipairs({
      "",
      "a.b.c",
      token .. ".extra",
      header .. "=." .. body .. "." .. signature,
      header .. "." .. body .. ".A",
      header .. "." .. body .. ".AB",
      header .. "." .. body .. ".AA ",
      encode("not-json") .. "." .. body .. "." .. signature,
      encode("null") .. "." .. body .. "." .. signature,
      header .. "." .. encode("[]") .. "." .. signature,
      string.rep("a", 45001),
    }) do
      local value, err = crypto.verify_id_token(invalid, jwks, claims)
      assert.is_nil(value)
      assert.is_string(err)
    end
  end)

  it("creates owner-only temporary files and removes them after verification", function()
    local token = signed(payload())
    local directories = {}
    uv.fs_mkdtemp = function(template)
      local directory = original_mkdtemp(template)
      directories[#directories + 1] = directory
      return directory
    end
    vim.system = function(args, opts)
      assert.equals("-verify", args[4])
      assert.equals(448, uv.fs_stat(vim.fn.fnamemodify(args[5], ":h")).mode % 512)
      assert.equals(384, uv.fs_stat(args[5]).mode % 512)
      assert.equals(384, uv.fs_stat(args[7]).mode % 512)
      assert.is_nil(table.concat(args, " "):find(token, 1, true))
      assert.equals(token:match("^(.+)%.([^.]+)$"), opts.stdin)
      return original_system(args, opts)
    end
    assert.is_table(crypto.verify_id_token(token, jwks, claims))
    assert.is_nil(uv.fs_stat(directories[1]))
    local header, body, signature = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    local first = signature:sub(1, 1) == "A" and "B" or "A"
    assert.is_nil(
      crypto.verify_id_token(
        header .. "." .. body .. "." .. first .. signature:sub(2),
        jwks,
        claims
      )
    )
    assert.is_nil(uv.fs_stat(directories[2]))
  end)

  it("cleans temporary files after a write failure or subprocess exception", function()
    local token = signed(payload())
    local directories = {}
    uv.fs_mkdtemp = function(template)
      local directory = original_mkdtemp(template)
      directories[#directories + 1] = directory
      return directory
    end
    uv.fs_write = function()
      return nil, "simulated write failure"
    end
    assert.is_nil(crypto.verify_id_token(token, jwks, claims))
    assert.is_nil(uv.fs_stat(directories[1]))
    uv.fs_write = original_write
    vim.system = function()
      error("simulated subprocess failure")
    end
    assert.is_nil(crypto.verify_id_token(token, jwks, claims))
    assert.is_nil(uv.fs_stat(directories[2]))
  end)
end)
