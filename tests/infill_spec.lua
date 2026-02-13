describe("infill", function()
  local infill
  local bufnr

  before_each(function()
    package.loaded["sage-llm.infill"] = nil
    infill = require("sage-llm.infill")
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  it("normalizes fenced responses", function()
    local text, err = infill.normalize_response("```lua\nprint('hi')\n```")
    assert.is_nil(err)
    assert.equals("print('hi')", text)
  end)

  it("rejects empty responses", function()
    local text, err = infill.normalize_response("   ")
    assert.is_nil(text)
    assert.is_string(err)
  end)

  it("applies character-wise replacement", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo bar baz" })

    local ok, err = infill.apply_selection({
      bufnr = bufnr,
      start_line = 1,
      end_line = 1,
      start_col = 4,
      end_col = 7,
      mode = "v",
    }, "qux")

    assert.is_true(ok)
    assert.is_nil(err)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "foo qux baz" }, lines)
  end)

  it("applies line-wise replacement", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four" })

    local ok, err = infill.apply_selection({
      bufnr = bufnr,
      start_line = 2,
      end_line = 3,
      start_col = 0,
      end_col = 0,
      mode = "V",
    }, "TWO\nTHREE")

    assert.is_true(ok)
    assert.is_nil(err)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.same({ "one", "TWO", "THREE", "four" }, lines)
  end)
end)
