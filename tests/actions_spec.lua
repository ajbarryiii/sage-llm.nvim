describe("actions", function()
  local actions

  before_each(function()
    package.loaded["sage-llm.actions"] = nil
    actions = require("sage-llm.actions")
  end)

  describe("get", function()
    it("returns explain action", function()
      local action = actions.get("explain")
      assert.is_not_nil(action)
      assert.equals("explain", action.name)
      assert.is_not_nil(action.prompt)
    end)

    it("returns fix action", function()
      local action = actions.get("fix")
      assert.is_not_nil(action)
      assert.equals("fix", action.name)
      assert.is_not_nil(action.prompt)
    end)

    it("returns nil for unknown action", function()
      local action = actions.get("unknown")
      assert.is_nil(action)
    end)
  end)

  describe("get_prompt", function()
    it("returns prompt for explain", function()
      local prompt = actions.get_prompt("explain")
      assert.is_not_nil(prompt)
      assert.is_true(type(prompt) == "string")
      assert.is_true(#prompt > 0)
    end)

    it("returns nil for unknown action", function()
      local prompt = actions.get_prompt("nonexistent")
      assert.is_nil(prompt)
    end)
  end)

  describe("list", function()
    it("returns array of action names", function()
      local names = actions.list()
      assert.is_true(type(names) == "table")
      assert.is_true(#names >= 2)

      -- Check that explain and fix are present
      local has_explain = false
      local has_fix = false
      for _, name in ipairs(names) do
        if name == "explain" then
          has_explain = true
        end
        if name == "fix" then
          has_fix = true
        end
      end
      assert.is_true(has_explain)
      assert.is_true(has_fix)
    end)
  end)
end)
