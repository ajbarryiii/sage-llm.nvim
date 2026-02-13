describe("actions", function()
  local actions

  before_each(function()
    package.loaded["sage-llm.actions"] = nil
    actions = require("sage-llm.actions")
  end)

  describe("get_prompt", function()
    it("returns prompt for explain", function()
      local prompt = actions.get_prompt("explain")
      assert.is_not_nil(prompt)
      assert.is_true(type(prompt) == "string")
      assert.is_true(#prompt > 0)
    end)

    it("returns prompt for fix", function()
      local prompt = actions.get_prompt("fix")
      assert.is_not_nil(prompt)
      assert.is_true(type(prompt) == "string")
      assert.is_true(#prompt > 0)
    end)

    it("returns nil for unknown action", function()
      local prompt = actions.get_prompt("nonexistent")
      assert.is_nil(prompt)
    end)
  end)
end)
