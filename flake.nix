{
  description = "sage-llm.nvim - Ask LLMs about your code in Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Lua 5.1 for Neovim compatibility
        lua = pkgs.lua5_1;
        luaPackages = pkgs.lua51Packages;

        # Development dependencies
        devDeps = with pkgs; [

          # Lua tooling
          lua
          luaPackages.luacheck      # Linter
          luaPackages.busted        # Test framework
          luaPackages.luacov        # Code coverage
          stylua                    # Formatter

          # LSP for development
          lua-language-server

          # Git
          git

          # For plenary.nvim HTTP (curl backend)
          curl

          # Documentation generation (optional)
          lemmy-help                # Generate vimdoc from Lua annotations
        ];

        # Minimal Neovim config for testing
        testInitLua = pkgs.writeText "minimal_init.lua" ''
          -- Minimal init for testing sage-llm.nvim
          vim.opt.runtimepath:append(".")
          vim.opt.runtimepath:append("${pkgs.vimPlugins.plenary-nvim}")
          
          -- Optional: treesitter for markdown highlighting
          -- vim.opt.runtimepath:append("${pkgs.vimPlugins.nvim-treesitter}")
        '';

      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = devDeps;

          shellHook = ''
            echo "sage-llm.nvim development environment"
            echo ""
            echo "Available commands:"
            echo "  nvim              - Neovim with plugin loaded"
            echo "  luacheck lua/     - Lint Lua files"
            echo "  stylua lua/       - Format Lua files"
            echo "  make test         - Run tests (requires Makefile)"
            echo ""
            echo "Environment:"
            echo "  Neovim: $(nvim --version | head -1)"
            echo "  Lua:    $(lua -v)"
            echo "  StyLua: $(stylua --version)"
            echo ""
            
            # Set up test init path for convenience
            export SAGE_TEST_INIT="${testInitLua}"
          '';
        };

        # Package the plugin (for use in other flakes)
        packages.default = pkgs.vimUtils.buildVimPlugin {
          pname = "sage-llm-nvim";
          version = "0.1.0";
          src = ./.;

          # Plugin dependencies
          dependencies = with pkgs.vimPlugins; [
            plenary-nvim
          ];

          meta = with pkgs.lib; {
            description = "Ask LLMs about your code in Neovim";
            homepage = "https://github.com/sage-llm/sage-llm.nvim";
            license = licenses.mit;
            platforms = platforms.all;
          };
        };

        # Quick check/lint
        checks.default = pkgs.runCommand "sage-llm-check" {
          buildInputs = [ pkgs.luaPackages.luacheck pkgs.stylua ];
          src = ./.;
        } ''
          cd $src
          echo "Running luacheck..."
          luacheck lua/ --no-unused-args --no-max-line-length || true
          echo "Checking stylua formatting..."
          stylua --check lua/ || echo "Run 'stylua lua/' to fix formatting"
          touch $out
        '';
      }
    );
}
