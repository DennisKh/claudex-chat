defmodule ClaudexChat.CompletionsTest do
  use ClaudexChat.DataCase, async: true

  alias Claudex.Stream.{Event, SSE}
  alias Claudex.Usage
  alias ClaudexChat.Chats
  alias ClaudexChat.Completions
  alias ClaudexChat.Completions.{Params, Reply}
  alias ClaudexChat.Models.Model

  @opus %Model{
    id: "claude-opus-5",
    display_name: "Claude Opus 5",
    max_output_tokens: 128_000,
    thinking_modes: ~w(off adaptive),
    accepts_images: true,
    accepts_pdf: true,
    accepts_code_execution: true
  }

  @haiku %Model{
    id: "claude-haiku-4-5",
    display_name: "Claude Haiku 4.5",
    max_output_tokens: 64_000,
    thinking_modes: ~w(off enabled)
  }

  defp chat(attrs \\ %{}) do
    {:ok, chat} = Chats.create_chat(Map.merge(%{model: "claude-opus-5"}, attrs))
    chat
  end

  defp user(content, attrs \\ %{}) do
    struct!(ClaudexChat.Chats.Message, Map.merge(%{role: "user", content: content}, attrs))
  end

  defp assistant(content, attrs) do
    struct!(ClaudexChat.Chats.Message, Map.merge(%{role: "assistant", content: content}, attrs))
  end

  describe "params — thinking config" do
    test "off sends no thinking parameter at all" do
      params = Params.build(chat(), [user("Hi")], @opus)

      refute Map.has_key?(params, :thinking)
    end

    test "adaptive asks for a summary, because the default omits the text" do
      params = Params.build(chat(%{thinking_mode: "adaptive"}), [user("Hi")], @opus)

      assert params.thinking == %{type: "adaptive", display: "summarized"}
    end

    test "enabled sends the budget the model takes" do
      chat = chat(%{model: "claude-haiku-4-5", thinking_mode: "enabled", thinking_budget: 2048})

      params = Params.build(chat, [user("Hi")], @haiku)

      assert params.thinking == %{
               type: "enabled",
               budget_tokens: 2048,
               display: "summarized"
             }
    end

    test "keeps the budget under max_tokens" do
      chat =
        chat(%{model: "claude-haiku-4-5", thinking_mode: "enabled", thinking_budget: 999_999})

      params = Params.build(chat, [user("Hi")], @haiku)

      assert params.thinking.budget_tokens < params.max_tokens
    end

    test "drops a mode the chosen model doesn't support" do
      chat = chat(%{model: "claude-haiku-4-5", thinking_mode: "adaptive"})

      refute Map.has_key?(Params.build(chat, [user("Hi")], @haiku), :thinking)
    end
  end

  describe "params — history" do
    test "sends text as a content block" do
      params = Params.build(chat(), [user("Hello")], @opus)

      assert params.messages == [
               %{role: "user", content: [%{type: "text", text: "Hello"}]}
             ]
    end

    test "puts attachments before the text, typed by MIME" do
      message =
        user("Compare these", %{
          attachments: [
            %ClaudexChat.Chats.Attachment{
              file_id: "file_img",
              mime_type: "image/png",
              filename: "a.png"
            },
            %ClaudexChat.Chats.Attachment{
              file_id: "file_doc",
              mime_type: "application/pdf",
              filename: "b.pdf"
            }
          ]
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{content: content}] = params.messages

      assert [
               %{type: "image", source: %{type: "file", file_id: "file_img"}},
               %{type: "document", source: %{type: "file", file_id: "file_doc"}},
               %{type: "text", text: "Compare these"}
             ] = content
    end

    test "replays a thinking block when the model is unchanged" do
      message =
        assistant("Done", %{
          thinking: "reasoning",
          thinking_signature: "sig-abc",
          model: "claude-opus-5"
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{role: "assistant", content: content}] = params.messages
      assert %{type: "thinking", thinking: "reasoning", signature: "sig-abc"} = hd(content)
    end

    test "drops a thinking block produced by a different model" do
      message =
        assistant("Done", %{
          thinking: "reasoning",
          thinking_signature: "sig-abc",
          model: "claude-haiku-4-5"
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{content: [%{type: "text"}]}] = params.messages
    end

    test "drops a thinking block with no signature to send back" do
      message = assistant("Done", %{thinking: "reasoning", model: "claude-opus-5"})

      params = Params.build(chat(), [message], @opus)

      assert [%{content: [%{type: "text"}]}] = params.messages
    end

    test "leaves out a reply that never arrived" do
      history = [user("Hello"), assistant("", %{error: "overloaded_error"})]

      params = Params.build(chat(), history, @opus)

      assert [%{role: "user"}] = params.messages
    end
  end

  describe "apply_event/2" do
    test "accumulates text and thinking separately" do
      reply =
        Reply.new("claude-opus-5")
        |> Completions.apply_event(%Event.ContentBlockDelta{index: 0, delta: {:thinking, "hmm"}})
        |> Completions.apply_event(%Event.ContentBlockDelta{index: 0, delta: {:thinking, "..."}})
        |> Completions.apply_event(%Event.ContentBlockDelta{index: 1, delta: {:text, "Hello"}})
        |> Completions.apply_event(%Event.ContentBlockDelta{index: 1, delta: {:text, " there"}})

      assert reply.text == "Hello there"
      assert reply.thinking == "hmm..."
    end

    test "keeps the signature that closes a thinking block" do
      reply =
        Reply.new("claude-opus-5")
        |> Completions.apply_event(%Event.ContentBlockDelta{index: 0, delta: {:signature, "sig"}})

      assert reply.thinking_signature == "sig"
    end

    test "ignores events the chat has no use for" do
      reply = Reply.new("claude-opus-5")

      assert Completions.apply_event(reply, %Event.ContentBlockDelta{
               index: 0,
               delta: {:input_json, "{\"a\":"}
             }) == reply
    end

    test "merges the final usage over the initial one" do
      start = %Event.MessageStart{
        message: %Claudex.Message{
          model: "claude-opus-5",
          usage: %Usage{input_tokens: 42, output_tokens: 1, cache_read_input_tokens: 7}
        }
      }

      delta = %Event.MessageDelta{
        stop_reason: "end_turn",
        usage: %Usage{output_tokens: 118}
      }

      reply =
        Reply.new("claude-opus-5")
        |> Completions.apply_event(start)
        |> Completions.apply_event(delta)

      assert reply.usage.input_tokens == 42
      assert reply.usage.output_tokens == 118
      assert reply.usage.cache_read_input_tokens == 7
      assert reply.stop_reason == "end_turn"
    end
  end

  describe "params — tools" do
    test "offers the file tools and web search" do
      params = Params.build(chat(), [user("Hi")], @opus)

      names = params.tools |> Claudex.Tool.list() |> Enum.map(& &1.name)

      assert "read_file" in names
      assert "write_file" in names
      assert "edit_file" in names
      assert "web_search" in names
    end

    test "picks the web search variant the model can run" do
      search = fn model ->
        Enum.find(Params.tools(model), &(is_map(&1) and Map.get(&1, :name) == "web_search"))
      end

      assert search.(@opus).type == "web_search_20260209"
      assert search.(@haiku).type == "web_search_20250305"
    end
  end

  describe "params — tool calls in history" do
    defp tool_call(status, output) do
      %ClaudexChat.Chats.ToolCall{
        call_id: "toolu_1",
        name: "read_file",
        input: %{"path" => "a.txt"},
        status: status,
        output: output
      }
    end

    test "replays the request and its result" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          tool_calls: [tool_call("approved", "file contents")]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, assistant, results] = params.messages

      assert %{type: "tool_use", id: "toolu_1", name: "read_file", input: %{"path" => "a.txt"}} =
               List.last(assistant.content)

      assert results.role == "user"

      assert [
               %{
                 type: "tool_result",
                 tool_use_id: "toolu_1",
                 content: "file contents",
                 is_error: false
               }
             ] =
               results.content
    end

    test "marks a denied call as an error so Claude knows it refused" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          tool_calls: [tool_call("denied", "The user denied this tool call.")]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, _assistant, results] = params.messages
      assert [%{is_error: true}] = results.content
    end

    test "withholds results while a call is still waiting on a human" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{model: "claude-opus-5", tool_calls: [tool_call("pending", nil)]})
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, assistant] = params.messages
      assert %{type: "tool_use"} = List.last(assistant.content)
    end
  end

  describe "apply_event/2 against a recorded stream" do
    @fixture Path.expand("../fixtures/thinking_stream.sse", __DIR__)

    defp recorded_events do
      {events, decoder} = SSE.decode(SSE.new(), File.read!(@fixture))
      {trailing, _decoder} = SSE.flush(decoder)

      (events ++ trailing)
      |> Enum.map(&Event.from_sse/1)
      |> Enum.flat_map(fn
        {:ok, event} -> [event]
        _ping_or_error -> []
      end)
    end

    test "folds a real thinking stream into text, thinking and usage" do
      reply =
        Enum.reduce(
          recorded_events(),
          Reply.new("claude-haiku-4-5"),
          &Completions.apply_event(&2, &1)
        )

      assert reply.thinking =~ "On"
      assert reply.thinking_signature != nil
      assert reply.text =~ "multi-tap"
      assert reply.stop_reason == "end_turn"

      # output_tokens is only correct in message_delta; service_tier only ever
      # arrives in message_start. Both surviving proves the two were merged.
      assert reply.usage.output_tokens == 600
      assert reply.usage.service_tier == "standard"
    end
  end

  describe "finish/2" do
    test "stores the reply with its usage and duration" do
      chat = chat()

      reply =
        Reply.new("claude-opus-5")
        |> Completions.apply_event(%Event.ContentBlockDelta{index: 0, delta: {:text, "Hi"}})
        |> Completions.apply_event(%Event.MessageDelta{
          stop_reason: "end_turn",
          usage: %Usage{input_tokens: 10, output_tokens: 20}
        })

      assert {:ok, %{message: message}} = Completions.finish(chat, reply)
      assert message.content == "Hi"
      assert message.input_tokens == 10
      assert message.output_tokens == 20
      assert message.stop_reason == "end_turn"
      assert is_integer(message.duration_ms)
    end

    test "stores a failure so the chat shows what went wrong" do
      reply =
        "claude-opus-5"
        |> Reply.new()
        |> Completions.fail(%Claudex.Error{type: :overloaded, message: "overloaded"})

      assert {:ok, %{message: message}} = Completions.finish(chat(), reply)
      assert message.error =~ "overloaded"
      assert message.content == ""
    end

    test "drops a reply that arrived with nothing and no error" do
      assert :ignore = Completions.finish(chat(), Reply.new("claude-opus-5"))
    end
  end
end
