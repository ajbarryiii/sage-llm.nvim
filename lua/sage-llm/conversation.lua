---@mod sage-llm.conversation Conversation state management
---@brief [[
---Manages multi-turn conversation history for follow-up questions.
---This module is a pure state machine with no UI dependencies,
---making it fully testable.
---@brief ]]

local M = {}

---@class SageConversationState
---@field messages table[] Array of {role, content} message tables
---@field active boolean Whether a conversation is in progress
---@field current_response string Accumulates tokens for the current streaming response

---@type SageConversationState
local state = {
  messages = {},
  active = false,
  current_response = "\n",
}

---Start a new conversation with initial messages
---@param messages table[] Initial messages array (system + first user message)
function M.start(messages)
  state.messages = vim.deepcopy(messages)
  state.active = true
  state.current_response = "\n"
end

---Accumulate a token from the streaming response
---@param token string
function M.accumulate_token(token)
  state.current_response = state.current_response .. token
end

---Finish the current response: store accumulated tokens as an assistant message
---and reset the accumulator. Returns the full response text.
---@return string response The complete assistant response
function M.finish_response()
  local response = state.current_response
  if response ~= "\n" then
    table.insert(state.messages, {
      role = "assistant",
      content = response,
    })
  end
  state.current_response = "\n"
  return response
end

---Add a follow-up user message to the conversation.
---Returns the full messages array (including the new message) for the API call.
---@param question string The follow-up question
---@return table[] messages The complete messages array for the API
function M.add_followup(question)
  table.insert(state.messages, {
    role = "user",
    content = question,
  })
  return vim.deepcopy(state.messages)
end

---Remove the last user message from the conversation.
---Used when a follow-up request fails and we want to let the user retry.
function M.remove_last_user_message()
  if #state.messages > 0 and state.messages[#state.messages].role == "user" then
    table.remove(state.messages)
  end
end

---Check if a conversation is currently active
---@return boolean
function M.is_active()
  return state.active
end

---Get the number of turns (user/assistant pairs) in the conversation
---@return number
function M.turn_count()
  local count = 0
  for _, msg in ipairs(state.messages) do
    if msg.role == "assistant" then
      count = count + 1
    end
  end
  return count
end

---Reset all conversation state
function M.reset()
  state.messages = {}
  state.active = false
  state.current_response = "\n"
end

return M
