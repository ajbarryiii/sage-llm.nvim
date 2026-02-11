.PHONY: test lint format check all

# Run tests using plenary
# Note: Requires plenary.nvim to be installed in your Neovim setup
test:
	nvim --headless --clean -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"

# Lint with luacheck
lint:
	luacheck lua/ --no-unused-args

# Format with stylua
format:
	stylua lua/ plugin/ tests/

# Check formatting without modifying
format-check:
	stylua --check lua/ plugin/ tests/

# Run all checks
check: lint format-check

# Run everything
all: format lint test
