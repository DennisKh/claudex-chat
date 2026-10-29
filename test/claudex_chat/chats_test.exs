defmodule ClaudexChat.ChatsTest do
  use ClaudexChat.DataCase, async: true

  alias ClaudexChat.Chats
  alias ClaudexChat.Chats.{Chat, Message}
  alias ClaudexChat.Repo

  @model "claude-opus-5"

  defp chat(attrs \\ %{}) do
    {:ok, chat} = Chats.create_chat(Map.merge(%{model: @model}, attrs))
    chat
  end

  defp backdate(%Chat{} = chat, seconds) do
    at = DateTime.add(DateTime.utc_now(:second), -seconds, :second)
    {1, _} = Repo.update_all(from(c in Chat, where: c.id == ^chat.id), set: [updated_at: at])
    %{chat | updated_at: at}
  end

  describe "create_chat/1" do
    test "starts untitled and off" do
      chat = chat()

      assert chat.title == Chats.default_title()
      assert chat.model == @model
      assert chat.thinking_mode == "off"
      assert chat.thinking_budget == nil
    end

    test "requires a model" do
      assert {:error, changeset} = Chats.create_chat(%{})
      assert %{model: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an unknown thinking mode" do
      assert {:error, changeset} = Chats.create_chat(%{model: @model, thinking_mode: "maybe"})
      assert %{thinking_mode: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects an mcp server that isn't in the catalogue" do
      assert {:error, changeset} =
               Chats.create_chat(%{model: @model, mcp_servers: ["not-a-real-server"]})

      assert %{mcp_servers: [message]} = errors_on(changeset)
      assert message =~ "not-a-real-server"
    end

    test "accepts a known mcp server" do
      assert chat = chat(%{mcp_servers: ["deepwiki"]})
      assert chat.mcp_servers == ["deepwiki"]
    end
  end

  describe "thinking settings" do
    test "enabled mode needs a budget the API will accept" do
      assert {:error, changeset} =
               Chats.create_chat(%{model: @model, thinking_mode: "enabled"})

      assert %{thinking_budget: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Chats.create_chat(%{model: @model, thinking_mode: "enabled", thinking_budget: 512})

      assert %{thinking_budget: [_too_small]} = errors_on(changeset)

      assert {:ok, chat} =
               Chats.create_chat(%{
                 model: @model,
                 thinking_mode: "enabled",
                 thinking_budget: 1024
               })

      assert chat.thinking_budget == 1024
    end

    test "adaptive mode carries no budget" do
      assert {:ok, chat} =
               Chats.create_chat(%{
                 model: @model,
                 thinking_mode: "adaptive",
                 thinking_budget: 4096
               })

      assert chat.thinking_budget == nil
    end

    test "leaving enabled mode clears the budget" do
      chat = chat(%{thinking_mode: "enabled", thinking_budget: 2048})

      assert {:ok, updated} = Chats.update_chat(chat, %{thinking_mode: "off"})
      assert updated.thinking_budget == nil
    end
  end

  describe "list_chats/0" do
    test "returns the most recently active first" do
      older = chat() |> backdate(60)
      newer = chat()

      assert [first, second] = Chats.list_chats()
      assert first.id == newer.id
      assert second.id == older.id
    end
  end

  describe "fetch_chat/1" do
    test "finds a chat" do
      chat = chat()
      assert {:ok, found} = Chats.fetch_chat(chat.id)
      assert found.id == chat.id
    end

    test "reports a missing one" do
      assert {:error, :not_found} = Chats.fetch_chat(-1)
    end
  end

  describe "add_user_message/2" do
    test "names an untitled chat after the first message" do
      assert {:ok, %{message: message, chat: chat}} =
               Chats.add_user_message(chat(), %{content: "  What is OTP?  "})

      assert message.role == "user"
      assert chat.title == "What is OTP?"
    end

    test "truncates a long first message" do
      {:ok, %{chat: chat}} =
        Chats.add_user_message(chat(), %{content: String.duplicate("word ", 40)})

      assert String.length(chat.title) == 60
    end

    test "keeps a title the chat already has" do
      {:ok, %{chat: chat}} = Chats.add_user_message(chat(), %{content: "First"})
      {:ok, %{chat: chat}} = Chats.add_user_message(chat, %{content: "Second"})

      assert chat.title == "First"
    end

    test "requires content" do
      assert {:error, changeset} = Chats.add_user_message(chat(), %{content: "   "})
      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "stores attachments alongside the message" do
      {:ok, %{message: message}} =
        Chats.add_user_message(chat(), %{
          content: "Summarise this",
          attachments: [
            %{
              file_id: "file_123",
              filename: "report.pdf",
              mime_type: "application/pdf",
              size_bytes: 900
            }
          ]
        })

      assert [attachment] = Repo.get!(Message, message.id).attachments
      assert attachment.file_id == "file_123"
      assert attachment.filename == "report.pdf"
    end

    test "moves the chat to the top of the list" do
      chat = chat() |> backdate(60)
      was = chat.updated_at

      {:ok, %{chat: touched}} = Chats.add_user_message(chat, %{content: "Hello"})

      assert DateTime.after?(touched.updated_at, was)
    end
  end

  describe "add_assistant_message/2" do
    test "records the reply with its usage and timing" do
      {:ok, %{chat: chat}} = Chats.add_user_message(chat(), %{content: "Hello"})

      assert {:ok, %{message: message}} =
               Chats.add_assistant_message(chat, %{
                 content: "Hi there",
                 thinking: "considering",
                 model: @model,
                 input_tokens: 12,
                 output_tokens: 30,
                 cache_read_tokens: 4,
                 duration_ms: 815,
                 stop_reason: "end_turn"
               })

      assert message.role == "assistant"
      assert message.output_tokens == 30
      assert message.cache_read_tokens == 4
      assert message.cache_creation_tokens == nil
      assert message.duration_ms == 815
    end

    test "records a stream that failed before any text arrived" do
      assert {:ok, %{message: message}} =
               Chats.add_assistant_message(chat(), %{content: "", error: "overloaded_error"})

      assert message.content == ""
      assert message.error == "overloaded_error"
    end
  end

  describe "list_messages/1" do
    test "returns them oldest first" do
      chat = chat()
      {:ok, %{chat: chat}} = Chats.add_user_message(chat, %{content: "One"})
      {:ok, %{chat: chat}} = Chats.add_assistant_message(chat, %{content: "Two"})
      {:ok, _} = Chats.add_user_message(chat, %{content: "Three"})

      assert ["One", "Two", "Three"] = Enum.map(Chats.list_messages(chat), & &1.content)
    end
  end

  describe "replay_user_message/2" do
    test "appends a copy and keeps the original" do
      chat = chat()

      {:ok, %{message: original, chat: chat}} =
        Chats.add_user_message(chat, %{content: "Ask again"})

      {:ok, %{chat: chat}} =
        Chats.add_assistant_message(chat, %{content: "half", stop_reason: "cancelled"})

      assert {:ok, %{message: replayed, chat: chat}} = Chats.replay_user_message(chat, original)

      assert replayed.id != original.id
      assert replayed.content == original.content
      assert {:ok, _still_there} = Chats.fetch_message(original.id)

      assert ["Ask again", "half", "Ask again"] =
               Enum.map(Chats.list_messages(chat), & &1.content)
    end

    test "carries the attachments over" do
      chat = chat()

      {:ok, %{message: original, chat: chat}} =
        Chats.add_user_message(chat, %{
          content: "Summarise this",
          attachments: [
            %{file_id: "file_1", filename: "a.pdf", mime_type: "application/pdf", size_bytes: 12}
          ]
        })

      assert {:ok, %{message: replayed}} = Chats.replay_user_message(chat, original)
      assert [attachment] = replayed.attachments
      assert attachment.file_id == "file_1"
      assert attachment.filename == "a.pdf"
    end
  end

  describe "discard_from/1" do
    test "removes the message and everything after it" do
      chat = chat()
      {:ok, %{chat: chat}} = Chats.add_user_message(chat, %{content: "One"})
      {:ok, %{message: reply, chat: chat}} = Chats.add_assistant_message(chat, %{content: "Two"})
      {:ok, %{chat: chat}} = Chats.add_user_message(chat, %{content: "Three"})
      {:ok, _} = Chats.add_assistant_message(chat, %{content: "Four"})

      assert {:ok, discarded} = Chats.discard_from(reply)
      assert discarded |> Enum.map(& &1.content) |> Enum.sort() == ~w(Four Three Two)
      assert ["One"] = Enum.map(Chats.list_messages(chat), & &1.content)
    end

    test "leaves other chats alone" do
      other = chat()
      {:ok, %{message: kept}} = Chats.add_user_message(other, %{content: "Keep me"})

      chat = chat()
      {:ok, %{message: message}} = Chats.add_user_message(chat, %{content: "Drop me"})

      assert {:ok, [%{id: id}]} = Chats.discard_from(message)
      assert id == message.id
      assert {:ok, _} = Chats.fetch_message(kept.id)
    end
  end

  describe "delete_chat/1" do
    test "takes its messages with it" do
      chat = chat()
      {:ok, _} = Chats.add_user_message(chat, %{content: "Hello"})

      assert {:ok, _} = Chats.delete_chat(chat)
      assert {:error, :not_found} = Chats.fetch_chat(chat.id)
      assert Repo.aggregate(Message, :count) == 0
    end
  end
end
