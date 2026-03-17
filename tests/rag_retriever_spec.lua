describe("rag.retriever", function()
  local retriever

  before_each(function()
    package.loaded["sage-llm.rag.retriever"] = nil
    retriever = require("sage-llm.rag.retriever")
  end)

  it("ranks chunks by cosine similarity", function()
    local chunks = {
      {
        id = "a",
        path = "a.lua",
        start_line = 1,
        end_line = 5,
        text = "alpha",
        embedding = { 1, 0 },
      },
      {
        id = "b",
        path = "b.lua",
        start_line = 1,
        end_line = 5,
        text = "beta",
        embedding = { 0, 1 },
      },
      {
        id = "c",
        path = "c.lua",
        start_line = 1,
        end_line = 5,
        text = "gamma",
        embedding = { 0.6, 0.8 },
      },
    }

    local ranked = retriever.rank_chunks(chunks, { 1, 0 })

    assert.equals("a", ranked[1].id)
    assert.equals("c", ranked[2].id)
    assert.equals("b", ranked[3].id)
  end)

  it("limits selected snippets by file and top_k", function()
    local ranked = {
      {
        id = "a1",
        path = "a.lua",
        start_line = 1,
        end_line = 3,
        text = "chunk-a1",
        score = 0.95,
      },
      {
        id = "a2",
        path = "a.lua",
        start_line = 4,
        end_line = 6,
        text = "chunk-a2",
        score = 0.92,
      },
      {
        id = "b1",
        path = "b.lua",
        start_line = 1,
        end_line = 3,
        text = "chunk-b1",
        score = 0.9,
      },
    }

    local selected = retriever.select_snippets(ranked, {
      top_k = 2,
      min_similarity = 0,
      max_chunks_per_file = 1,
      max_context_chars = 1000,
    })

    assert.equals(2, #selected)
    assert.equals("a1", selected[1].id)
    assert.equals("b1", selected[2].id)
  end)
end)
