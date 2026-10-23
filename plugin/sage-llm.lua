-- sage-llm.nvim plugin initialization
-- Commands are registered here; keymaps are left to the user

if vim.g.loaded_sage_llm then
  return
end
vim.g.loaded_sage_llm = true

-- Check Neovim version
if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("sage-llm.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

-- Create user commands
local function create_commands()
  vim.api.nvim_create_user_command("SageT3Ask", function()
    require("sage-llm").t3_ask()
  end, {
    range = true,
    desc = "Ask an existing T3 Code thread about visual selection",
  })

  vim.api.nvim_create_user_command("SageT3Thread", function()
    require("sage-llm").t3_select_thread()
  end, {
    desc = "Select the T3 Code thread that receives Sage questions",
  })

  -- :SageAsk - Open input to ask about visual selection
  vim.api.nvim_create_user_command("SageAsk", function()
    require("sage-llm").ask()
  end, {
    range = true,
    desc = "Ask LLM about visual selection",
  })

  -- :SageExplain - Explain visual selection
  vim.api.nvim_create_user_command("SageExplain", function()
    require("sage-llm").explain()
  end, {
    range = true,
    desc = "Explain visual selection",
  })

  -- :SageFix - Explain how to fix diagnostics
  vim.api.nvim_create_user_command("SageFix", function()
    require("sage-llm").fix()
  end, {
    range = true,
    desc = "Explain how to fix diagnostics in selection",
  })

  -- :SageInfill - Inline edit selected code
  vim.api.nvim_create_user_command("SageInfill", function()
    require("sage-llm").infill()
  end, {
    range = true,
    desc = "Inline edit visual selection",
  })

  -- :SageView - Show latest hidden response window
  vim.api.nvim_create_user_command("SageView", function()
    require("sage-llm").show_conversation()
  end, {
    desc = "View the current sage-llm conversation",
  })

  -- :SageModel - Open model picker
  vim.api.nvim_create_user_command("SageModel", function()
    require("sage-llm").select_model()
  end, {
    desc = "Select LLM model",
  })

  -- :SageModelRemove - Open model removal picker
  vim.api.nvim_create_user_command("SageModelRemove", function()
    require("sage-llm").remove_model()
  end, {
    desc = "Remove model from picker",
  })

  -- :SageDepsOn - Enable dependency detection
  vim.api.nvim_create_user_command("SageDepsOn", function()
    require("sage-llm").deps_on()
  end, {
    desc = "Enable dependency detection",
  })

  -- :SageDepsOff - Disable dependency detection
  vim.api.nvim_create_user_command("SageDepsOff", function()
    require("sage-llm").deps_off()
  end, {
    desc = "Disable dependency detection",
  })

  -- :SageConfig - Open config file for editing
  vim.api.nvim_create_user_command("SageConfig", function()
    require("sage-llm").edit_config()
  end, {
    desc = "Edit sage-llm config file",
  })

  vim.api.nvim_create_user_command("SageChatGPTLogin", function(opts)
    require("sage-llm").chatgpt_login(opts.bang)
  end, {
    bang = true,
    desc = "Continue with ChatGPT to use your subscription",
  })

  vim.api.nvim_create_user_command("SageChatGPTLogout", function()
    require("sage-llm").chatgpt_logout()
  end, {
    desc = "Remove Sage's saved ChatGPT credentials",
  })

  vim.api.nvim_create_user_command("SageChatGPTStatus", function()
    require("sage-llm").chatgpt_status()
  end, {
    desc = "Show ChatGPT subscription connection status",
  })

  vim.api.nvim_create_user_command("SageLocalSetup", function(opts)
    require("sage-llm").local_setup(opts.args)
  end, {
    nargs = 1,
    desc = "Set up and start a local llama.cpp model",
  })

  vim.api.nvim_create_user_command("SageLocalStart", function(opts)
    require("sage-llm").local_start(opts.args)
  end, {
    nargs = "?",
    desc = "Start the configured local llama.cpp server",
  })

  vim.api.nvim_create_user_command("SageLocalStop", function()
    require("sage-llm").local_stop()
  end, {
    desc = "Stop the plugin-owned local llama.cpp server",
  })

  vim.api.nvim_create_user_command("SageLocalStatus", function()
    require("sage-llm").local_status()
  end, {
    desc = "Show local llama.cpp server status",
  })

  vim.api.nvim_create_user_command("SageLocalInstall", function()
    require("sage-llm").local_install()
  end, {
    desc = "Install or locate llama-server for local models",
  })
end

create_commands()
