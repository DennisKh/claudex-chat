defmodule ClaudexChat.CompletionsTest do
  use ClaudexChat.DataCase, async: true

  alias Claudex.ContentBlock
  alias Claudex.Stream.Accumulator
  alias Claudex.Stream.{Event, SSE}
  alias Claudex.Usage
  alias ClaudexChat.{Approvals, Chats}
  alias ClaudexChat.Completions
  alias ClaudexChat.Completions.{Params, Reply}
  alias ClaudexChat.Models.Model
  alias Claudex.ToolRunner.Turn

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

  # The two blocks a hosted web search leaves in a reply, as the API sends
  # them. The search's encrypted content is what has to survive the round trip
  # into the next request.
  @web_search_use %{
    "type" => "server_tool_use",
    "id" => "srvtoolu_1",
    "name" => "web_search",
    "input" => %{"query" => "claudex sdk"}
  }

  @web_search_result %{
    "type" => "web_search_tool_result",
    "tool_use_id" => "srvtoolu_1",
    "content" => [
      %{
        "type" => "web_search_result",
        "url" => "https://hexdocs.pm/claudex",
        "title" => "Claudex",
        "encrypted_content" => "EuUBCioIAhgCIiQ4ZDNhNzY5"
      }
    ]
  }

  # The two blocks an MCP tool call leaves in a reply, as the API sends them —
  # a call the API ran on a remote server and paired result.
  @mcp_use %{
    "type" => "mcp_tool_use",
    "id" => "mcptoolu_01",
    "name" => "ask_question",
    "server_name" => "deepwiki",
    "input" => %{"repoName" => "elixir-lang/elixir", "question" => "How do protocols work?"}
  }

  @mcp_result %{
    "type" => "mcp_tool_result",
    "tool_use_id" => "mcptoolu_01",
    "is_error" => false,
    "content" => [%{"type" => "text", "text" => "Protocols are..."}]
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

  # What a request carries once encoded, so a block the SDK rebuilt with atom
  # keys compares equal to the stored one it came from.
  defp wire(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp turn(reply, opts) do
    message = Reply.message(reply)

    %Turn{
      message: message,
      index: 1,
      tool_uses: Claudex.Message.tool_uses(message),
      tool_results: Keyword.get(opts, :results, []),
      stop: Keyword.get(opts, :stop)
    }
  end

  defp record(chat, reply, opts \\ []) do
    Completions.record_turn(chat, reply, nil, turn(reply, opts))
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

    test "replays a thinking block stored in its columns, with its signature" do
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

    test "sends a thinking block from another model as it was, for the API to drop" do
      message =
        assistant("Done", %{
          thinking: "reasoning",
          thinking_signature: "sig-abc",
          model: "claude-haiku-4-5"
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{content: [%{type: "thinking"}, %{type: "text"}]}] = params.messages
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

  describe "params — tools" do
    test "offers the file tools and web search" do
      params = Params.build(chat(), [user("Hi")], @opus)

      names = params.tools |> Claudex.Tool.list() |> Enum.map(& &1.name)

      assert "read_file" in names
      assert "write_file" in names
      assert "edit_file" in names
      assert "list_files" in names
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

  describe "params — mcp servers" do
    test "sends mcp_servers and one mcp_toolset per enabled server, alongside the other tools" do
      params = Params.build(chat(%{mcp_servers: ["deepwiki"]}), [user("Hi")], @opus)

      assert [%Claudex.MCP.Server{name: "deepwiki", url: "https://mcp.deepwiki.com/mcp"}] =
               params.mcp_servers

      assert ClaudexChat.Tools in params.tools
      assert Enum.any?(params.tools, &(is_map(&1) and Map.get(&1, :name) == "web_search"))
      assert %{type: "mcp_toolset", mcp_server_name: "deepwiki"} in params.tools
    end

    test "sends no mcp_servers key at all for a chat with none enabled" do
      params = Params.build(chat(), [user("Hi")], @opus)

      refute Map.has_key?(params, :mcp_servers)
    end
  end

  describe "params — the cached prefix" do
    test "asks for caching" do
      params = Params.build(chat(), [user("Hi")], @opus)

      assert params.cache_control == %{type: "ephemeral"}
    end

    test "is identical when nothing about the chat changed" do
      chat = chat(%{mcp_servers: ["deepwiki"]})
      history = [user("Hi"), assistant("Hello", %{model: "claude-opus-5"})]

      assert Params.build(chat, history, @opus) == Params.build(chat, history, @opus)
    end

    test "survives a turn being appended, which is what makes a cache read possible" do
      chat = chat(%{mcp_servers: ["deepwiki"]})
      history = [user("Hi"), assistant("Hello", %{model: "claude-opus-5"})]

      earlier = Params.build(chat, history, @opus)
      later = Params.build(chat, history ++ [user("And again")], @opus)

      assert later.tools == earlier.tools
      assert later.system == earlier.system
      assert later.mcp_servers == earlier.mcp_servers
      assert Enum.take(later.messages, length(earlier.messages)) == earlier.messages
      assert length(later.messages) == length(earlier.messages) + 1
    end
  end

  describe "params — tool calls in history" do
    defp tool_call(status, output, id \\ "toolu_1") do
      result =
        if output,
          do: %{
            "type" => "tool_result",
            "tool_use_id" => id,
            "content" => output,
            "is_error" => status in ~w(denied failed)
          }

      %ClaudexChat.Chats.ToolCall{
        call_id: id,
        name: "read_file",
        input: %{"path" => "a.txt"},
        status: status,
        output: output,
        result: result
      }
    end

    test "replays the request and its result" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          stop_reason: "tool_use",
          tool_calls: [tool_call("approved", "file contents")]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, assistant, results] = params.messages

      assert %{type: "tool_use", id: "toolu_1", name: "read_file", input: %{"path" => "a.txt"}} =
               List.last(assistant.content)

      assert results.role == "user"

      assert wire(results.content) == [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_1",
                 "content" => "file contents",
                 "is_error" => false
               }
             ]
    end

    test "marks a denied call as an error so Claude knows it refused" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          stop_reason: "tool_use",
          tool_calls: [tool_call("denied", "The user denied this tool call.")]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, _assistant, results] = params.messages
      assert [%{"is_error" => true}] = wire(results.content)
    end

    test "withholds results while a call is still waiting on a human" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          stop_reason: "tool_use",
          tool_calls: [tool_call("pending", nil)]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, assistant] = params.messages
      assert %{type: "tool_use"} = List.last(assistant.content)
    end

    test "leaves out a tool call the turn never confirmed" do
      tool_use = %{
        "type" => "tool_use",
        "id" => "toolu_1",
        "name" => "read_file",
        "input" => %{}
      }

      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          stop_reason: "max_tokens",
          content_blocks: [%{"type" => "text", "text" => "Reading it"}, tool_use],
          tool_calls: [tool_call("pending", nil)]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, assistant] = params.messages
      assert wire(assistant.content) == [%{"type" => "text", "text" => "Reading it"}]
    end

    test "ends on the reply until every call has a result, which is where a resume picks up" do
      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          stop_reason: "tool_use",
          tool_calls: [tool_call("approved", nil), tool_call("denied", "no", "toolu_2")]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, %{role: "assistant"}] = params.messages
    end

    test "withholds results when the turn was stored as content blocks" do
      tool_use = %{
        "type" => "tool_use",
        "id" => "toolu_1",
        "name" => "read_file",
        "input" => %{"path" => "a.txt"}
      }

      history = [
        user("Read a.txt"),
        assistant("Reading it", %{
          model: "claude-opus-5",
          stop_reason: "tool_use",
          content_blocks: [%{"type" => "text", "text" => "Reading it"}, tool_use],
          tool_calls: [tool_call("pending", nil)]
        })
      ]

      params = Params.build(chat(), history, @opus)

      assert [_user, assistant] = params.messages
      assert tool_use in wire(assistant.content)
    end
  end

  describe "params — a turn stored as content blocks" do
    test "replays the blocks exactly as the API sent them" do
      message =
        assistant("Here", %{
          model: "claude-opus-5",
          content_blocks: [
            @web_search_use,
            @web_search_result,
            %{"type" => "text", "text" => "Here"}
          ]
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{role: "assistant", content: content}] = params.messages

      assert wire(content) == [
               @web_search_use,
               @web_search_result,
               %{"type" => "text", "text" => "Here"}
             ]
    end

    test "keeps a stored thinking block from another model, for the API to drop" do
      thinking = %{"type" => "thinking", "thinking" => "reasoning", "signature" => "sig"}

      message =
        assistant("Here", %{
          model: "claude-haiku-4-5",
          content_blocks: [thinking, %{"type" => "text", "text" => "Here"}]
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{content: [first, _text]}] = params.messages
      assert wire(first) == thinking
    end

    test "drops a stored thinking block the stream never signed" do
      message =
        assistant("Here", %{
          model: "claude-opus-5",
          content_blocks: [
            %{"type" => "thinking", "thinking" => "reasoning", "signature" => nil},
            %{"type" => "text", "text" => "Here"}
          ]
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{content: content}] = params.messages
      assert wire(content) == [%{"type" => "text", "text" => "Here"}]
    end

    test "drops a text block with nothing in it" do
      message =
        assistant("", %{
          model: "claude-opus-5",
          stop_reason: "pause_turn",
          content_blocks: [%{"type" => "text", "text" => ""}, @web_search_use]
        })

      params = Params.build(chat(), [message], @opus)

      assert [%{content: content}] = params.messages
      assert wire(content) == [@web_search_use]
    end
  end

  describe "Reply.add/2" do
    defp start_event do
      %Event.MessageStart{
        message: %Claudex.Message{
          model: "claude-opus-5",
          content: [],
          usage: %Usage{input_tokens: 42, output_tokens: 1, cache_read_input_tokens: 7}
        }
      }
    end

    defp block_start(index, block) do
      %Event.ContentBlockStart{index: index, content_block: block}
    end

    defp delta(index, delta), do: %Event.ContentBlockDelta{index: index, delta: delta}

    defp fold(events) do
      Enum.reduce(events, Reply.new("claude-opus-5"), &Reply.add(&2, &1))
    end

    test "accumulates text and thinking separately" do
      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(0, {:thinking, "hmm"}),
          delta(0, {:thinking, "..."}),
          block_start(1, %ContentBlock.Text{text: ""}),
          delta(1, {:text, "Hello"}),
          delta(1, {:text, " there"})
        ])

      assert Reply.text(reply) == "Hello there"
      assert Reply.thinking(reply) == "hmm..."
    end

    test "keeps the signature that closes a thinking block" do
      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(0, {:thinking, "reasoning"}),
          delta(0, {:signature, "sig"})
        ])

      %{content_blocks: [block]} = Reply.to_message_attrs(reply, Reply.message(reply))

      assert block["signature"] == "sig"
    end

    test "ignores events the chat has no use for" do
      reply = fold([start_event(), delta(0, {:input_json, "{\"a\":"})])

      assert Reply.text(reply) == ""
      assert Reply.thinking(reply) == ""
    end

    test "merges the final usage over the initial one" do
      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.Text{text: ""}),
          delta(0, {:text, "hi"}),
          %Event.MessageDelta{stop_reason: "end_turn", usage: %Usage{output_tokens: 118}}
        ])

      attrs = Reply.to_message_attrs(reply, Reply.message(reply))

      assert attrs.input_tokens == 42
      assert attrs.output_tokens == 118
      assert attrs.cache_read_tokens == 7
      assert attrs.stop_reason == "end_turn"
    end
  end

  describe "Reply.add/2 against a recorded stream" do
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
          &Reply.add(&2, &1)
        )

      attrs = Reply.to_message_attrs(reply, Reply.message(reply))

      assert Reply.thinking(reply) =~ "On"

      assert Enum.any?(
               attrs.content_blocks,
               &(&1["type"] == "thinking" and &1["signature"] != "")
             )

      assert Reply.text(reply) =~ "multi-tap"
      assert attrs.stop_reason == "end_turn"

      # output_tokens is only correct in message_delta; service_tier only ever
      # arrives in message_start. Both surviving proves the two were merged.
      assert attrs.output_tokens == 600
      assert Accumulator.message(reply.acc).usage.service_tier == "standard"
    end
  end

  describe "a turn the API ran a tool in" do
    defp search_events(stop_reason) do
      [
        start_event(),
        block_start(0, ContentBlock.decode(@web_search_use)),
        %Event.ContentBlockStop{index: 0},
        block_start(1, ContentBlock.decode(@web_search_result)),
        %Event.ContentBlockStop{index: 1},
        %Event.MessageDelta{stop_reason: stop_reason, usage: %Usage{output_tokens: 12}}
      ]
    end

    test "a reply that only ran a search is not empty" do
      refute Reply.empty?(fold(search_events("pause_turn")))
    end

    test "is stored, so the history the runner resumed from is the one kept" do
      chat = chat()

      assert {:ok, %{message: message}} = record(chat, fold(search_events("pause_turn")))

      assert message.stop_reason == "pause_turn"
      assert message.content == ""
    end

    test "goes back into the next request with its encrypted results intact" do
      chat = chat()

      {:ok, %{chat: chat}} = record(chat, fold(search_events("pause_turn")))

      params = Params.build(chat, Chats.list_messages(chat), @opus)

      assert [%{role: "assistant", content: content}] = params.messages
      assert wire(content) == [@web_search_use, @web_search_result]
    end

    test "keeps every thinking block, not just the first" do
      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(0, {:thinking, "first"}),
          delta(0, {:signature, "sig-1"}),
          block_start(1, ContentBlock.decode(@web_search_use)),
          %Event.ContentBlockStop{index: 1},
          block_start(2, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(2, {:thinking, "second"}),
          delta(2, {:signature, "sig-2"})
        ])

      assert Reply.thinking(reply) == "first\n\nsecond"

      signatures =
        Reply.to_message_attrs(reply, Reply.message(reply)).content_blocks
        |> Enum.filter(&(&1["type"] == "thinking"))
        |> Enum.map(& &1["signature"])

      assert signatures == ["sig-1", "sig-2"]
    end
  end

  describe "a turn where the API called an MCP tool" do
    defp mcp_events(stop_reason) do
      [
        start_event(),
        block_start(0, ContentBlock.decode(@mcp_use)),
        %Event.ContentBlockStop{index: 0},
        block_start(1, ContentBlock.decode(@mcp_result)),
        %Event.ContentBlockStop{index: 1},
        %Event.MessageDelta{stop_reason: stop_reason, usage: %Usage{output_tokens: 12}}
      ]
    end

    test "a reply that only called an MCP tool is not empty" do
      refute Reply.empty?(fold(mcp_events("pause_turn")))
    end

    test "never becomes a call anyone is asked to approve" do
      chat = chat()

      assert {:ok, %{message: message}} = record(chat, fold(mcp_events("pause_turn")))

      assert message.tool_calls == []
      refute Approvals.awaiting?(message)
    end

    test "is stored and replays into the next request with its content and is_error intact" do
      chat = chat()

      {:ok, %{chat: chat}} = record(chat, fold(mcp_events("pause_turn")))

      params = Params.build(chat, Chats.list_messages(chat), @opus)

      assert [%{role: "assistant", content: content}] = params.messages
      assert wire(content) == [@mcp_use, @mcp_result]
    end
  end

  describe "a turn carrying every kind of block" do
    test "replays thinking, text, a search and an MCP call in the order they arrived" do
      chat = chat()

      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(0, {:thinking, "weighing it up"}),
          delta(0, {:signature, "sig-1"}),
          %Event.ContentBlockStop{index: 0},
          block_start(1, %ContentBlock.Text{text: ""}),
          delta(1, {:text, "Here is what I found."}),
          %Event.ContentBlockStop{index: 1},
          block_start(2, ContentBlock.decode(@web_search_use)),
          %Event.ContentBlockStop{index: 2},
          block_start(3, ContentBlock.decode(@web_search_result)),
          %Event.ContentBlockStop{index: 3},
          block_start(4, ContentBlock.decode(@mcp_use)),
          %Event.ContentBlockStop{index: 4},
          block_start(5, ContentBlock.decode(@mcp_result)),
          %Event.ContentBlockStop{index: 5},
          %Event.MessageDelta{stop_reason: "end_turn", usage: %Usage{output_tokens: 30}}
        ])

      {:ok, %{chat: chat}} = record(chat, reply)

      params = Params.build(chat, Chats.list_messages(chat), @opus)

      assert [%{role: "assistant", content: content}] = params.messages

      assert Enum.map(wire(content), & &1["type"]) == [
               "thinking",
               "text",
               "server_tool_use",
               "web_search_tool_result",
               "mcp_tool_use",
               "mcp_tool_result"
             ]
    end
  end

  describe "a stream the user stopped" do
    test "keeps the text that had already arrived, marked cancelled" do
      chat = chat()

      reply =
        [
          start_event(),
          block_start(0, %ContentBlock.Text{text: ""}),
          delta(0, {:text, "Half a th"})
        ]
        |> fold()

      assert {:ok, %{message: message}} = record(chat, reply, stop: :cancelled)

      assert message.content == "Half a th"
      assert message.stop_reason == "cancelled"
    end
  end

  describe "truncated?/1" do
    test "a reply that ran out of room is truncated, whichever ceiling it hit" do
      for reason <- ~w(max_tokens model_context_window_exceeded) do
        assert Completions.truncated?(%ClaudexChat.Chats.Message{stop_reason: reason}),
               "expected #{reason} to count as truncated"
      end

      refute Completions.truncated?(%ClaudexChat.Chats.Message{stop_reason: "end_turn"})
      refute Completions.truncated?(%ClaudexChat.Chats.Message{stop_reason: "tool_use"})
    end
  end

  describe "record_turn/4 and record_failure/2" do
    test "stores a finished turn with its usage and duration" do
      chat = chat()

      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.Text{text: ""}),
          delta(0, {:text, "Hi"}),
          %Event.MessageDelta{
            stop_reason: "end_turn",
            usage: %Usage{input_tokens: 10, output_tokens: 20}
          }
        ])

      assert {:ok, %{message: message}} = record(chat, reply)
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
        |> Reply.failed(
          Completions.describe(%Claudex.Error{type: :overloaded, message: "overloaded"})
        )

      assert {:ok, %{message: message}} = Completions.record_failure(chat(), reply)
      assert message.error =~ "overloaded"
      assert message.content == ""
    end

    test "drops a reply that arrived with nothing and no error" do
      assert :ignore = Completions.record_failure(chat(), Reply.new("claude-opus-5"))
    end

    test "stores the calls of a reply that halted for approval as pending" do
      chat = chat()

      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.ToolUse{id: "toolu_1", name: "read_file", input: %{}}),
          delta(0, {:input_json, ~s({"path":)}),
          delta(0, {:input_json, ~s( "mix.exs"})}),
          %Event.ContentBlockStop{index: 0},
          %Event.MessageDelta{stop_reason: "tool_use", usage: %Usage{output_tokens: 9}}
        ])

      assert {:ok, %{message: message}} = record(chat, reply, stop: Approvals.halt())

      assert [%{call_id: "toolu_1", name: "read_file", status: "pending", result: nil} = call] =
               message.tool_calls

      assert call.input == %{"path" => "mix.exs"}
      assert Approvals.awaiting?(message)
    end

    test "stores a call the runner already answered, and never offers it" do
      chat = chat()

      reply =
        fold([
          start_event(),
          block_start(0, %ContentBlock.ToolUse{id: "toolu_1", name: "read_file", input: %{}}),
          %Event.ContentBlockStop{index: 0},
          %Event.MessageDelta{stop_reason: "tool_use", usage: %Usage{output_tokens: 9}}
        ])

      invalid = %{
        type: "tool_result",
        tool_use_id: "toolu_1",
        content: ~s({"INVALID_JSON":"{\\"path\\":"}),
        is_error: true
      }

      assert {:ok, %{message: message}} = record(chat, reply, results: [invalid])

      assert [%{status: "failed", result: %{"is_error" => true}}] = message.tool_calls
      refute Approvals.awaiting?(message)
    end

    test "a reply cut off inside a call keeps none of it" do
      chat = chat()

      reply =
        [
          start_event(),
          block_start(0, %ContentBlock.Text{text: ""}),
          delta(0, {:text, "Let me look"}),
          block_start(1, %ContentBlock.ToolUse{id: "toolu_1", name: "write_file", input: %{}}),
          delta(1, {:input_json, ~s({"path":)})
        ]
        |> fold()

      assert {:ok, %{message: message}} = record(chat, reply, stop: :cancelled)

      assert message.tool_calls == []
      assert Enum.map(message.content_blocks, & &1["type"]) == ["text"]
    end
  end

  describe "Reply.add_events/2" do
    test "folds a batch in the order it arrived" do
      reply =
        Reply.add_events(Reply.new("claude-opus-5"), [
          start_event(),
          block_start(0, %ContentBlock.Text{text: ""}),
          delta(0, {:text, "Hel"}),
          delta(0, {:text, "lo"})
        ])

      assert Reply.text(reply) == "Hello"
    end
  end

  describe "a resumed turn a cancel ended" do
    test "still records the results of the tools that ran" do
      chat = chat()

      {:ok, %{message: awaiting}} =
        Chats.add_assistant_message(chat, %{
          content: "Reading it",
          stop_reason: "tool_use",
          tool_calls: [
            %{call_id: "toolu_1", name: "read_file", input: %{"path" => "a"}, status: "approved"}
          ]
        })

      resumed = %Turn{
        index: 1,
        stop: :cancelled,
        message: %Claudex.Message{role: "assistant", content: []},
        tool_results: [
          %{type: "tool_result", tool_use_id: "toolu_1", content: "contents", is_error: false}
        ]
      }

      assert {:ok, %{message: message}} =
               Completions.record_turn(chat, Reply.new(chat.model), awaiting, resumed)

      assert message.id == awaiting.id
      assert [%{status: "approved", output: "contents"}] = message.tool_calls
    end
  end

  describe "uncached?/1" do
    test "is true when both cache counters came back zero" do
      assert Completions.uncached?(%ClaudexChat.Chats.Message{
               cache_creation_tokens: 0,
               cache_read_tokens: 0
             })
    end

    test "is false when the cache was written or read" do
      refute Completions.uncached?(%ClaudexChat.Chats.Message{
               cache_creation_tokens: 5_650,
               cache_read_tokens: 0
             })

      refute Completions.uncached?(%ClaudexChat.Chats.Message{
               cache_creation_tokens: 0,
               cache_read_tokens: 5_650
             })
    end

    test "is false when either counter was never reported" do
      refute Completions.uncached?(%ClaudexChat.Chats.Message{
               cache_creation_tokens: nil,
               cache_read_tokens: 0
             })

      refute Completions.uncached?(%ClaudexChat.Chats.Message{})
    end
  end

  describe "storing a stream cut off part-way" do
    test "leaves the unsigned thinking block out of the stored turn" do
      reply =
        [
          start_event(),
          block_start(0, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(0, {:thinking, "reasoning"}),
          block_start(1, %ContentBlock.Text{text: ""}),
          delta(1, {:text, "Half"})
        ]
        |> fold()

      assert {:ok, %{message: message}} = record(chat(), reply, stop: :cancelled)

      assert Enum.map(message.content_blocks, & &1["type"]) == ["text"]
      assert message.thinking == "reasoning"
    end

    test "replays nothing for a turn that only thought before it stopped" do
      chat = chat()

      reply =
        [
          start_event(),
          block_start(0, %ContentBlock.Thinking{thinking: "", signature: ""}),
          delta(0, {:thinking, "reasoning"})
        ]
        |> fold()

      assert {:ok, %{message: message}} = record(chat, reply, stop: :cancelled)

      params = Params.build(chat, [user("Hello"), message], @opus)

      assert [%{role: "user"}] = params.messages
    end
  end
end
