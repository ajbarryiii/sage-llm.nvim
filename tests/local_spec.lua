describe("local llama.cpp", function()
  local config
  local local_server
  local original_env

  before_each(function()
    original_env = vim.env.XDG_CONFIG_HOME
    vim.env.XDG_CONFIG_HOME = "/nonexistent/test/path"
    package.loaded["sage-llm.config_file"] = nil
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.local_install"] = nil
    package.loaded["sage-llm.local"] = nil
    config = require("sage-llm.config")
    config.setup({
      provider = "llama_cpp",
      model = "owner/model-GGUF:Q4_K_M",
    })
    local_server = require("sage-llm.local")
  end)

  after_each(function()
    vim.env.XDG_CONFIG_HOME = original_env
    package.loaded["sage-llm.config_file"] = nil
    package.loaded["sage-llm.config"] = nil
    package.loaded["sage-llm.local_install"] = nil
    package.loaded["sage-llm.local"] = nil
  end)

  it("builds hf_repo server args without Hugging Face token", function()
    local args = local_server.build_args({
      name = "local-coder",
      hf_repo = "owner/model-GGUF:Q4_K_M",
      ctx_size = 4096,
      gpu_layers = "auto",
    }, "llama-server", "127.0.0.1", 8080)

    assert.same({
      "llama-server",
      "--hf-repo",
      "owner/model-GGUF:Q4_K_M",
      "--alias",
      "local-coder",
      "--host",
      "127.0.0.1",
      "--port",
      "8080",
      "--no-webui",
      "--ctx-size",
      "4096",
      "--n-gpu-layers",
      "auto",
    }, args)
  end)

  it("builds model_path server args", function()
    local args = local_server.build_args({
      name = "disk-model",
      model_path = "/models/coder.gguf",
    }, "/bin/llama-server", "127.0.0.1", 8081)

    assert.equals("--model", args[2])
    assert.equals("/models/coder.gguf", args[3])
    assert.equals("--alias", args[4])
    assert.equals("disk-model", args[5])
  end)
end)
