-- Cryptographic helpers for the public Sign in with ChatGPT client.
-- OpenAI's discovery document currently permits only RS256 ID tokens.
local M = {}
local uv = vim.uv or vim.loop
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local values = {}
for index = 1, #alphabet do
  values[alphabet:sub(index, index)] = index - 1
end

local function encode(bytes)
  local output = {}
  for index = 1, #bytes, 3 do
    local a, b, c = bytes:byte(index, index + 2)
    local number = a * 65536 + (b or 0) * 256 + (c or 0)
    local count = c and 4 or (b and 3 or 2)
    for position = 1, count do
      local value = math.floor(number / 64 ^ (4 - position)) % 64
      output[#output + 1] = alphabet:sub(value + 1, value + 1)
    end
  end
  return table.concat(output)
end

local function decode(segment, limit)
  if type(segment) ~= "string" or #segment == 0 or #segment > limit then
    return nil
  end
  if segment:find("[^A-Za-z0-9_-]") or #segment % 4 == 1 then
    return nil
  end
  local output = {}
  for index = 1, #segment, 4 do
    local length = math.min(4, #segment - index + 1)
    local number = 0
    for position = 0, 3 do
      number = number * 64 + (values[segment:sub(index + position, index + position)] or 0)
    end
    if length == 2 and number % 65536 ~= 0 then
      return nil
    end
    if length == 3 and number % 256 ~= 0 then
      return nil
    end
    output[#output + 1] = string.char(math.floor(number / 65536))
    if length >= 3 then
      output[#output + 1] = string.char(math.floor(number / 256) % 256)
    end
    if length == 4 then
      output[#output + 1] = string.char(number % 256)
    end
  end
  return table.concat(output)
end

local function openssl(args, stdin)
  if vim.fn.executable("openssl") ~= 1 then
    return nil, "Sign in with ChatGPT requires OpenSSL. Install openssl and ensure it is on PATH."
  end
  local command = { "openssl" }
  vim.list_extend(command, args)
  local ok, result = pcall(function()
    return vim.system(command, { stdin = stdin, text = false, timeout = 10000 }):wait()
  end)
  if not ok or result.code ~= 0 then
    -- Never include subprocess input, output, or a token in an error message.
    return nil, "OpenSSL could not complete the ChatGPT cryptographic operation."
  end
  return result.stdout or ""
end

local function random_bytes(length)
  if uv.random then
    local ok, bytes = pcall(uv.random, length)
    if ok and type(bytes) == "string" and #bytes == length then
      return bytes
    end
  end
  local bytes, err = openssl({ "rand", tostring(length) })
  if not bytes then
    return nil, err
  end
  if #bytes ~= length then
    return nil, "Could not generate secure randomness for ChatGPT sign-in."
  end
  return bytes
end

---Generate a 256-bit, unpadded base64url value for OAuth state, nonce, or PKCE.
---@return string? token
---@return string? error
function M.random_token()
  local bytes, err = random_bytes(32)
  if not bytes then
    return nil, err
  end
  return encode(bytes)
end

---Generate a secure UUIDv4 for the stable agent host identifier.
---@return string? uuid
---@return string? error
function M.random_uuid()
  local bytes, err = random_bytes(16)
  if not bytes then
    return nil, err
  end
  local hex = {}
  for index = 1, 16 do
    local value = bytes:byte(index)
    if index == 7 then
      value = value % 16 + 64
    elseif index == 9 then
      value = value % 64 + 128
    end
    hex[index] = string.format("%02x", value)
  end
  return table.concat(hex, "", 1, 4)
    .. "-"
    .. table.concat(hex, "", 5, 6)
    .. "-"
    .. table.concat(hex, "", 7, 8)
    .. "-"
    .. table.concat(hex, "", 9, 10)
    .. "-"
    .. table.concat(hex, "", 11, 16)
end

---Compute the S256 PKCE challenge without exposing the verifier in argv.
---@param verifier string
---@return string? challenge
---@return string? error
function M.challenge(verifier)
  vim.validate({ verifier = { verifier, "string" } })
  if #verifier < 43 or #verifier > 128 or verifier:find("[^A-Za-z0-9._~-]") then
    return nil, "Invalid PKCE verifier."
  end
  local digest, err = openssl({ "dgst", "-sha256", "-binary" }, verifier)
  if not digest then
    return nil, err
  end
  if #digest ~= 32 then
    return nil, "OpenSSL returned an invalid SHA-256 digest."
  end
  return encode(digest)
end

local function der(tag, contents)
  local length = #contents
  local prefix
  if length < 128 then
    prefix = string.char(length)
  else
    local bytes = {}
    while length > 0 do
      table.insert(bytes, 1, string.char(length % 256))
      length = math.floor(length / 256)
    end
    prefix = string.char(128 + #bytes) .. table.concat(bytes)
  end
  return string.char(tag) .. prefix .. contents
end

local function integer(bytes)
  if bytes:byte(1) >= 128 then
    bytes = "\0" .. bytes
  end
  return der(2, bytes)
end

local function public_key(jwk)
  if jwk.kty ~= "RSA" or (jwk.alg ~= nil and jwk.alg ~= "RS256") then
    return nil, "The ChatGPT signing key is not an RS256 RSA key."
  end
  if jwk.use ~= nil and jwk.use ~= "sig" then
    return nil, "The ChatGPT signing key is not intended for signatures."
  end
  if jwk.key_ops ~= nil then
    if type(jwk.key_ops) ~= "table" or not vim.tbl_contains(jwk.key_ops, "verify") then
      return nil, "The ChatGPT signing key is not intended for verification."
    end
  end
  local modulus, exponent = decode(jwk.n, 1366), decode(jwk.e, 12)
  if not modulus or not exponent then
    return nil, "The ChatGPT RSA signing key is malformed."
  end
  if #modulus < 256 or #modulus > 1024 or modulus:byte(1) == 0 then
    return nil, "The ChatGPT RSA signing key has an unsupported size."
  end
  if (#modulus == 256 and modulus:byte(1) < 128) or modulus:byte(-1) % 2 == 0 then
    return nil, "The ChatGPT RSA signing key is invalid."
  end
  if #exponent > 8 or exponent:byte(1) == 0 or exponent:byte(-1) % 2 == 0 then
    return nil, "The ChatGPT RSA exponent is invalid."
  end
  if #exponent == 1 and exponent:byte(1) < 3 then
    return nil, "The ChatGPT RSA exponent is invalid."
  end
  local rsa = der(48, integer(modulus) .. integer(exponent))
  -- rsaEncryption OID (1.2.840.113549.1.1.1) plus NULL parameters.
  local algorithm = "\48\13\6\9\42\134\72\134\247\13\1\1\1\5\0"
  local spki = der(48, algorithm .. der(3, "\0" .. rsa))
  local base64 = encode(spki):gsub("-", "+"):gsub("_", "/")
  base64 = base64 .. string.rep("=", (4 - #base64 % 4) % 4)
  local lines = {}
  for index = 1, #base64, 64 do
    lines[#lines + 1] = base64:sub(index, index + 63)
  end
  return "-----BEGIN PUBLIC KEY-----\n"
    .. table.concat(lines, "\n")
    .. "\n-----END PUBLIC KEY-----\n",
    #modulus
end

local function write_private(path, contents)
  local fd = uv.fs_open(path, "wx", 384) -- 0600 from the moment of creation.
  if not fd then
    return false
  end
  local ok, written = pcall(uv.fs_write, fd, contents, 0)
  uv.fs_close(fd)
  return ok and written == #contents
end

local function verify_signature(key, signature, input)
  local directory = uv.fs_mkdtemp(vim.fn.tempname() .. "-sage-llm-XXXXXX")
  if not directory then
    return nil, "Could not create protected temporary files for ChatGPT token verification."
  end
  local key_path, signature_path = directory .. "/key.pem", directory .. "/signature.bin"
  local ok, result, err = pcall(function()
    if not uv.fs_chmod(directory, 448) then -- 0700
      return nil, "Could not protect temporary files for ChatGPT token verification."
    end
    if not write_private(key_path, key) or not write_private(signature_path, signature) then
      return nil, "Could not write temporary files for ChatGPT token verification."
    end
    local output, crypto_err = openssl({
      "dgst",
      "-sha256",
      "-verify",
      key_path,
      "-signature",
      signature_path,
    }, input)
    if not output then
      if vim.fn.executable("openssl") ~= 1 then
        return nil, crypto_err
      end
      return nil, "The ChatGPT ID token signature could not be verified."
    end
    return true
  end)
  uv.fs_unlink(key_path)
  uv.fs_unlink(signature_path)
  uv.fs_rmdir(directory)
  if not ok then
    return nil, "Could not verify the ChatGPT ID token."
  end
  return result, err
end

local function finite_number(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validate_claims(payload, claims)
  local now = claims.time or os.time()
  if not finite_number(now) then
    return nil, "Invalid time for ChatGPT ID token verification."
  end
  if payload.iss ~= claims.issuer then
    return nil, "The ChatGPT ID token issuer did not match."
  end
  local audience_matches = payload.aud == claims.audience
  if type(payload.aud) == "table" and #payload.aud > 0 then
    audience_matches = false
    for _, audience in ipairs(payload.aud) do
      if type(audience) ~= "string" or audience == "" then
        return nil, "The ChatGPT ID token audience is invalid."
      end
      audience_matches = audience_matches or audience == claims.audience
    end
    if #payload.aud > 1 and payload.azp ~= claims.audience then
      return nil, "The ChatGPT ID token authorized party did not match."
    end
  end
  if not audience_matches then
    return nil, "The ChatGPT ID token audience did not match."
  end
  if payload.azp ~= nil and payload.azp ~= claims.audience then
    return nil, "The ChatGPT ID token authorized party did not match."
  end
  if not finite_number(payload.exp) or payload.exp <= now then
    return nil, "The ChatGPT ID token is expired or has no valid expiration."
  end
  if not finite_number(payload.iat) or payload.iat > now + 5 or payload.iat > payload.exp then
    return nil, "The ChatGPT ID token has an invalid issue time."
  end
  if payload.nbf ~= nil and (not finite_number(payload.nbf) or payload.nbf > now + 5) then
    return nil, "The ChatGPT ID token is not valid yet."
  end
  if claims.nonce ~= nil and payload.nonce ~= claims.nonce then
    return nil, "The ChatGPT ID token nonce did not match."
  end
  if type(payload.sub) ~= "string" or payload.sub == "" then
    return nil, "The ChatGPT ID token did not contain an account identity."
  end
  if claims.subject ~= nil and payload.sub ~= claims.subject then
    return nil, "The ChatGPT ID token account identity did not match."
  end
  return payload
end

---@class SageChatGPTTokenClaims
---@field issuer string Expected discovery issuer.
---@field audience string Issued OAuth client ID.
---@field nonce? string Original authorization nonce; required for new sign-in.
---@field subject? string Existing account subject; required when nonce is omitted on refresh.
---@field time? number Current Unix time, defaults to os.time().

---Verify an ID token's signature before trusting its identity claims.
---@param token string
---@param jwks table Issuer-provided JWKS { keys = { ... } }.
---@param claims SageChatGPTTokenClaims
---@return table? payload
---@return string? error
function M.verify_id_token(token, jwks, claims)
  vim.validate({
    token = { token, "string" },
    jwks = { jwks, "table" },
    claims = { claims, "table" },
  })
  if type(claims.issuer) ~= "string" or claims.issuer == "" then
    return nil, "An expected issuer is required for ChatGPT token verification."
  end
  if type(claims.audience) ~= "string" or claims.audience == "" then
    return nil, "An expected client ID is required for ChatGPT token verification."
  end
  if claims.nonce ~= nil and (type(claims.nonce) ~= "string" or claims.nonce == "") then
    return nil, "An expected nonce is required for ChatGPT token verification."
  end
  if claims.subject ~= nil and (type(claims.subject) ~= "string" or claims.subject == "") then
    return nil, "An expected account identity is required for ChatGPT token verification."
  end
  if claims.nonce == nil and claims.subject == nil then
    return nil, "A nonce or existing account identity is required for ChatGPT token verification."
  end
  if #token > 45000 then
    return nil, "The ChatGPT ID token is too large."
  end
  local header_segment, payload_segment, signature_segment =
    token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
  local header_bytes = decode(header_segment, 4096)
  local payload_bytes = decode(payload_segment, 32768)
  local signature = decode(signature_segment, 2048)
  if not header_bytes or not payload_bytes or not signature then
    return nil, "The ChatGPT ID token is malformed."
  end
  local header_ok, header = pcall(vim.json.decode, header_bytes)
  local payload_ok, payload = pcall(vim.json.decode, payload_bytes)
  if not header_ok or not payload_ok or type(header) ~= "table" or type(payload) ~= "table" then
    return nil, "The ChatGPT ID token contains invalid JSON."
  end
  if header.alg ~= "RS256" or header.crit ~= nil or header.b64 ~= nil then
    return nil, "The ChatGPT ID token uses an unsupported signing algorithm or extension."
  end
  if type(header.kid) ~= "string" or header.kid == "" or #header.kid > 256 then
    return nil, "The ChatGPT ID token has no valid signing key ID."
  end
  if type(jwks.keys) ~= "table" or #jwks.keys > 128 then
    return nil, "The ChatGPT signing key set is invalid."
  end
  local signing_key
  for _, key in ipairs(jwks.keys) do
    if type(key) == "table" and key.kid == header.kid then
      if signing_key then
        return nil, "The ChatGPT signing key ID is ambiguous."
      end
      signing_key = key
    end
  end
  if not signing_key then
    return nil, "The ChatGPT ID token signing key was not found."
  end
  local pem, size_or_err = public_key(signing_key)
  if not pem then
    return nil, size_or_err
  end
  if #signature ~= size_or_err then
    return nil, "The ChatGPT ID token signature has an invalid size."
  end
  local valid, err = verify_signature(pem, signature, header_segment .. "." .. payload_segment)
  if not valid then
    return nil, err
  end
  return validate_claims(payload, claims)
end

return M
