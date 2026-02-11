-- Minimal init for running tests
-- Disable swapfile for tests
vim.opt.swapfile = false

-- Add plugin to runtimepath
vim.opt.runtimepath:append(".")

-- Try common plenary locations
local plenary_paths = {
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/*/start/plenary.nvim"),
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  -- Nix store path (will be set via environment)
  vim.env.PLENARY_PATH,
}

for _, path in ipairs(plenary_paths) do
  if path and vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:append(path)
    break
  end
end

-- Load plenary
vim.cmd("runtime plugin/plenary.vim")
