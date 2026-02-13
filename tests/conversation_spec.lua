describe("conversation", function()
  local conversation

  before_each(function()
    package.loaded["sage-llm.conversation"] = nil
    conversation = require("sage-llm.conversation")
  end)

  describe("initial state", function()
    it("starts inactive with zero turns", function()
      assert.is_false(conversation.is_active())
      assert.equals(0, conversation.turn_count())
    end)
  end)

  describe("start", function()
    it("activates the conversation", function()
      conversation.start({
        { role = "system", content = "You are helpful." },
        { role = "user", content = "Hello" },
      })

      assert.is_true(conversation.is_active())
      assert.equals(0, conversation.turn_count())
    end)

    it("deep copies initial messages", function()
      local messages = {
        { role = "system", content = "You are helpful." },
        { role = "user", content = "Hello" },
      }

      conversation.start(messages)
      messages[1].content = "MUTATED"

      local snapshot = conversation.add_followup("next")
      assert.equals("You are helpful.", snapshot[1].content)
      assert.equals("next", snapshot[3].content)
    end)

    it("resets prior turn state when restarted", function()
      conversation.start({
        { role = "system", content = "first" },
        { role = "user", content = "q1" },
      })
      conversation.accumulate_token("response")
      conversation.finish_response()
      assert.equals(1, conversation.turn_count())

      conversation.start({
        { role = "system", content = "second" },
        { role = "user", content = "q2" },
      })

      assert.equals(0, conversation.turn_count())
      local snapshot = conversation.add_followup("q3")
      assert.equals("second", snapshot[1].content)
      assert.equals("q2", snapshot[2].content)
      assert.equals("q3", snapshot[3].content)
    end)
  end)

  describe("accumulate_token and finish_response", function()
    before_each(function()
      conversation.start({
        { role = "system", content = "sys" },
        { role = "user", content = "explain this" },
      })
    end)

    it("accumulates tokens into response text", function()
      conversation.accumulate_token("Hello ")
      conversation.accumulate_token("world")
      local response = conversation.finish_response()
      assert.equals("\nHello world", response)
      assert.equals(1, conversation.turn_count())
    end)

    it("returns newline-only response when no tokens arrive", function()
      local response = conversation.finish_response()
      assert.equals("\n", response)
      assert.equals(0, conversation.turn_count())
    end)

    it("starts clean after finishing a prior response", function()
      conversation.accumulate_token("first")
      conversation.finish_response()

      conversation.accumulate_token("second")
      local response = conversation.finish_response()
      assert.equals("\nsecond", response)
      assert.equals(2, conversation.turn_count())
    end)
  end)

  describe("add_followup", function()
    before_each(function()
      conversation.start({
        { role = "system", content = "sys" },
        { role = "user", content = "initial question" },
      })
      conversation.accumulate_token("initial answer")
      conversation.finish_response()
    end)

    it("appends a user message and returns a full snapshot", function()
      local messages = conversation.add_followup("follow-up question")
      assert.equals(4, #messages)
      assert.equals("system", messages[1].role)
      assert.equals("user", messages[2].role)
      assert.equals("assistant", messages[3].role)
      assert.equals("user", messages[4].role)
      assert.equals("follow-up question", messages[4].content)
    end)

    it("returns deep copies", function()
      local messages = conversation.add_followup("follow-up")
      messages[4].content = "MUTATED"

      local next_snapshot = conversation.add_followup("another")
      assert.equals("follow-up", next_snapshot[4].content)
      assert.equals("another", next_snapshot[5].content)
    end)

    it("supports multiple follow-ups", function()
      conversation.add_followup("follow-up 1")
      conversation.accumulate_token("answer 1")
      conversation.finish_response()

      local before_second_answer = conversation.add_followup("follow-up 2")
      assert.equals(6, #before_second_answer)

      conversation.accumulate_token("answer 2")
      conversation.finish_response()
      assert.equals(3, conversation.turn_count())
    end)
  end)

  describe("remove_last_user_message", function()
    before_each(function()
      conversation.start({
        { role = "system", content = "sys" },
        { role = "user", content = "initial question" },
      })
      conversation.accumulate_token("initial answer")
      conversation.finish_response()
    end)

    it("removes a pending follow-up message", function()
      conversation.add_followup("failed question")
      conversation.remove_last_user_message()

      local snapshot = conversation.add_followup("retry question")
      assert.equals("retry question", snapshot[#snapshot].content)
      assert.equals(4, #snapshot)
    end)

    it("does nothing when the last message is assistant", function()
      conversation.remove_last_user_message()
      local snapshot = conversation.add_followup("new follow-up")
      assert.equals(4, #snapshot)
      assert.equals("new follow-up", snapshot[4].content)
    end)

    it("does nothing on empty state", function()
      conversation.reset()
      conversation.remove_last_user_message()

      conversation.start({
        { role = "system", content = "sys" },
        { role = "user", content = "q" },
      })
      local snapshot = conversation.add_followup("after reset")
      assert.equals(3, #snapshot)
    end)
  end)

  describe("reset", function()
    it("clears activity and turn count", function()
      conversation.start({
        { role = "system", content = "sys" },
        { role = "user", content = "q" },
      })
      conversation.accumulate_token("response")
      conversation.finish_response()

      conversation.reset()

      assert.is_false(conversation.is_active())
      assert.equals(0, conversation.turn_count())
    end)

    it("clears in-progress token accumulation", function()
      conversation.start({
        { role = "system", content = "sys" },
        { role = "user", content = "q" },
      })

      conversation.accumulate_token("partial response...")
      conversation.reset()

      conversation.start({
        { role = "system", content = "sys2" },
        { role = "user", content = "q2" },
      })

      conversation.accumulate_token("fresh response")
      local response = conversation.finish_response()
      assert.equals("\nfresh response", response)
    end)
  end)

  describe("full conversation flow", function()
    it("handles multi-turn conversation with recovery", function()
      conversation.start({
        { role = "system", content = "You are a coding tutor." },
        { role = "user", content = "What does this do?" },
      })

      conversation.accumulate_token("This declares a variable.")
      local response1 = conversation.finish_response()
      assert.equals("\nThis declares a variable.", response1)
      assert.equals(1, conversation.turn_count())

      local with_followup = conversation.add_followup("What is the scope?")
      assert.equals(4, #with_followup)

      conversation.accumulate_token("`let` has block scope.")
      local response2 = conversation.finish_response()
      assert.equals("\n`let` has block scope.", response2)
      assert.equals(2, conversation.turn_count())

      conversation.add_followup("follow-up that will fail")
      conversation.remove_last_user_message()

      local retry = conversation.add_followup("retry follow-up")
      assert.equals("retry follow-up", retry[#retry].content)
    end)
  end)
end)
