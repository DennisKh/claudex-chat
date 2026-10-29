defmodule ClaudexChat.ApprovalsTest do
  use ClaudexChat.DataCase, async: false

  alias Claudex.ContentBlock.ToolUse
  alias Claudex.ToolRunner.Turn
  alias ClaudexChat.{Approvals, Chats, Completions}
  alias ClaudexChat.Completions.{Params, Reply}

  @fixture Path.expand("../fixtures/thinking_stream.sse", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "approvals-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "file contents")
    previous = Application.get_env(:claudex_chat, :default_root)
    Application.put_env(:claudex_chat, :default_root, root)

    on_exit(fn ->
      Application.put_env(:claudex_chat, :default_root, previous)
      File.rm_rf!(root)
    end)

    {:ok, chat} = Chats.create_chat(%{model: "claude-opus-5"})

    {:ok, chat: chat, root: root}
  end

  defp with_calls(chat, calls, attrs \\ %{}) do
    {:ok, %{message: message}} =
      Chats.add_assistant_message(
        chat,
        Map.merge(%{content: "on it", stop_reason: "tool_use", tool_calls: calls}, attrs)
      )

    message
  end

  defp call(name, input, id \\ "toolu_1", status \\ "pending") do
    %{call_id: id, name: name, input: input, status: status}
  end

  defp tool_use(id), do: %ToolUse{id: id, name: "read_file", input: %{"path" => "a.txt"}}

  test "a call starts pending and holds the conversation up", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{"path" => "a.txt"})])

    assert Approvals.awaiting?(message)
    assert [pending] = Approvals.pending(message)
    assert pending.status == "pending"
  end

  test "a call from a reply that was cut off is never offered", %{chat: chat} do
    for reason <- ["max_tokens", "refusal", "cancelled"] do
      message = with_calls(chat, [call("read_file", %{})], %{stop_reason: reason})

      assert Approvals.pending(message) == [], "expected #{reason} to offer nothing"
      refute Approvals.awaiting?(message)
    end
  end

  test "approving records the decision and runs nothing", %{chat: chat, root: root} do
    message = with_calls(chat, [call("write_file", %{"path" => "new.txt", "content" => "x"})])

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert [decided] = message.tool_calls
    assert decided.status == "approved"
    assert decided.result == nil
    refute Approvals.awaiting?(message)
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "denying records the decision", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{"path" => "a.txt"})])

    assert {:ok, message} = Approvals.deny(message, "toolu_1")
    assert [%{status: "denied", result: nil}] = message.tool_calls
  end

  test "deciding one call leaves the others pending", %{chat: chat} do
    message =
      with_calls(chat, [
        call("read_file", %{"path" => "a.txt"}, "toolu_1"),
        call("read_file", %{"path" => "a.txt"}, "toolu_2")
      ])

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert Enum.map(message.tool_calls, & &1.status) == ~w(approved pending)
    assert Approvals.awaiting?(message)
  end

  test "a call of a cut-off reply can't be decided", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{})], %{stop_reason: "refusal"})

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert [%{status: "pending"}] = message.tool_calls
  end

  describe "gate/1" do
    test "runs an approved call, refuses a denied one, and halts on anything else" do
      gate =
        Approvals.gate([
          %Chats.ToolCall{call_id: "toolu_1", name: "read_file", status: "approved"},
          %Chats.ToolCall{call_id: "toolu_2", name: "read_file", status: "denied"},
          %Chats.ToolCall{call_id: "toolu_3", name: "read_file", status: "pending"}
        ])

      assert gate.(tool_use("toolu_1")) == :ok
      assert {:deny, reason} = gate.(tool_use("toolu_2"))
      assert reason =~ "denied"
      assert gate.(tool_use("toolu_3")) == {:halt, Approvals.halt()}
      assert gate.(tool_use("toolu_new")) == {:halt, Approvals.halt()}
    end

    test "halts every call of a reply nobody has seen yet" do
      assert Approvals.gate([]).(tool_use("toolu_1")) == {:halt, Approvals.halt()}
    end
  end

  describe "record_results/2" do
    test "stores each result, and a result that is an error as a failure", %{chat: chat} do
      message =
        with_calls(chat, [
          call("read_file", %{"path" => "a.txt"}, "toolu_1", "approved"),
          call("read_file", %{"path" => "/etc/hosts"}, "toolu_2", "approved"),
          call("read_file", %{"path" => "a.txt"}, "toolu_3", "denied")
        ])

      results = [
        %{type: "tool_result", tool_use_id: "toolu_1", content: "file contents", is_error: false},
        %{type: "tool_result", tool_use_id: "toolu_2", content: "refused", is_error: true},
        %{type: "tool_result", tool_use_id: "toolu_3", content: "denied", is_error: true}
      ]

      assert {:ok, message} = Approvals.record_results(message, results)
      assert Enum.map(message.tool_calls, & &1.status) == ~w(approved failed denied)
      assert hd(message.tool_calls).output == "file contents"

      assert hd(message.tool_calls).result == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_1",
               "content" => "file contents",
               "is_error" => false
             }
    end

    test "describes a block result as text for the card and keeps the block", %{chat: chat} do
      message =
        with_calls(chat, [call("read_file", %{"path" => "shot.png"}, "toolu_1", "approved")])

      image = Claudex.Tool.result("toolu_1", [Claudex.ContentBlock.Image.file("file_1")])

      assert {:ok, message} = Approvals.record_results(message, [image])
      assert [%{output: "[image file_1]", result: result}] = message.tool_calls
      assert [%{"type" => "image", "source" => %{"file_id" => "file_1"}}] = result["content"]
    end
  end

  describe "reopen/1" do
    test "puts a decided call with no result back to pending", %{chat: chat} do
      message =
        with_calls(chat, [
          call("read_file", %{"path" => "a.txt"}, "toolu_1", "approved"),
          call("read_file", %{"path" => "a.txt"}, "toolu_2", "denied")
        ])

      assert {:ok, message} = Approvals.reopen(message)
      assert Enum.map(message.tool_calls, & &1.status) == ~w(pending pending)
      assert Approvals.awaiting?(message)
    end

    test "leaves an answered call alone", %{chat: chat} do
      message = with_calls(chat, [call("read_file", %{"path" => "a.txt"}, "toolu_1", "approved")])

      result = %{type: "tool_result", tool_use_id: "toolu_1", content: "ok", is_error: false}
      {:ok, message} = Approvals.record_results(message, [result])

      assert {:ok, message} = Approvals.reopen(message)
      assert [%{status: "approved"}] = message.tool_calls
    end
  end

  describe "an approved call when the conversation resumes" do
    setup do
      sse = File.read!(@fixture)

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end)

      previous = Application.get_all_env(:claudex)
      Application.put_env(:claudex, :api_key, "test-key")
      Application.put_env(:claudex, :req_options, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        Application.delete_env(:claudex, :api_key)
        Application.delete_env(:claudex, :req_options)
        Enum.each(previous, fn {key, value} -> Application.put_env(:claudex, key, value) end)
      end)
    end

    test "is run by the runner, and its result answers the stored reply", %{chat: chat} do
      {:ok, %{message: _prompt}} = Chats.add_user_message(chat, %{content: "Read a.txt"})
      message = with_calls(chat, [call("read_file", %{"path" => "a.txt"})])
      {:ok, message} = Approvals.approve(message, "toolu_1")

      assert {:ok, handle} = Completions.resume(chat, message)

      ref = handle.ref
      assert_receive {:claudex, ^ref, {:turn, %Turn{} = resumed}}, 5_000
      assert_receive {:claudex, ^ref, {:turn, %Turn{stop: :completed}}}, 5_000
      assert_receive {:claudex, ^ref, :done}, 5_000

      assert {:ok, %{message: answered}} =
               Completions.record_turn(chat, Reply.new(chat.model), message, resumed)

      assert [%{status: "approved", output: "file contents"}] = answered.tool_calls

      {:ok, model} = ClaudexChat.Models.fetch(chat.model)
      history = Params.build(chat, Chats.list_messages(chat), model)

      assert [_user, _assistant, %{role: "user", content: [result]}] = history.messages
      assert %{"tool_use_id" => "toolu_1", "content" => "file contents"} = result
    end
  end
end
