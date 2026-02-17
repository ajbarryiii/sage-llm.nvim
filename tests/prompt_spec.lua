describe("prompt formatting", function()
  local prompt

  before_each(function()
    package.loaded["sage-llm.prompt"] = nil
    prompt = require("sage-llm.prompt")
  end)

  it("formats code headers as copied line count", function()
    local sel = {
      filetype = "lua",
      start_line = 10,
      end_line = 12,
      text = "a\nb\nc",
    }

    local header = prompt.format_code_header(sel)
    assert.equals("[3 lines copied]\n", header)
  end)

  it("uses singular form for one line", function()
    local sel = {
      filetype = "lua",
      start_line = 5,
      end_line = 5,
      text = "single",
    }

    local header = prompt.format_code_header(sel)
    assert.equals("[1 line copied]\n", header)
  end)
end)
