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
end

create_commands()
