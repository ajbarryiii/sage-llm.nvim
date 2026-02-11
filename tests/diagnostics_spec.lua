describe("diagnostics", function()
  local diagnostics

  before_each(function()
    package.loaded["sage-llm.diagnostics"] = nil
    diagnostics = require("sage-llm.diagnostics")
  end)

  describe("format_for_prompt", function()
    it("returns empty string for empty diagnostics", function()
      local result = diagnostics.format_for_prompt({})
      assert.equals("", result)
    end)

    it("formats single diagnostic", function()
      local diags = {
        {
          line = 5,
          severity = "error",
          code = "E0382",
          message = "borrow of moved value",
          source = "rustc",
        },
      }

      local result = diagnostics.format_for_prompt(diags)

      assert.is_not_nil(result:match("Diagnostics:"))
      assert.is_not_nil(result:match("Line 5"))
      assert.is_not_nil(result:match("%[error E0382%]"))
      assert.is_not_nil(result:match("borrow of moved value"))
      assert.is_not_nil(result:match("%(rustc%)"))
    end)

    it("formats diagnostic without code", function()
      local diags = {
        {
          line = 10,
          severity = "warning",
          code = nil,
          message = "unused variable",
          source = "lua_ls",
        },
      }

      local result = diagnostics.format_for_prompt(diags)

      assert.is_not_nil(result:match("%[warning%]:"))
      assert.is_nil(result:match("nil"))
    end)

    it("formats multiple diagnostics", function()
      local diags = {
        {
          line = 1,
          severity = "error",
          message = "first error",
          source = "test",
        },
        {
          line = 2,
          severity = "warning",
          message = "second warning",
          source = "test",
        },
      }

      local result = diagnostics.format_for_prompt(diags)

      assert.is_not_nil(result:match("Line 1"))
      assert.is_not_nil(result:match("Line 2"))
      assert.is_not_nil(result:match("first error"))
      assert.is_not_nil(result:match("second warning"))
    end)
  end)
end)
