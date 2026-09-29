defmodule ClaudexChat.ApprovalsTest do
  use ClaudexChat.DataCase, async: false

  alias ClaudexChat.{Approvals, Chats}

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
        Map.merge(%{content: "on it", tool_calls: calls}, attrs)
      )

    message
  end

  defp call(name, input, id \\ "toolu_1") do
    %{call_id: id, name: name, input: input, status: "pending"}
  end

  test "a call starts pending and blocks the turn", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{"path" => "a.txt"})])

    assert Approvals.awaiting?(message)
    assert [pending] = Approvals.pending(message)
    assert pending.status == "pending"
  end

  test "a call from a turn that was cut off is never offered", %{chat: chat} do
    message =
      with_calls(chat, [call("read_file", %{})], %{stop_reason: "max_tokens"})

    assert Approvals.pending(message) == []
    refute Approvals.awaiting?(message)
  end

  test "approving a call the turn never confirmed does nothing", %{chat: chat, root: root} do
    message =
      with_calls(chat, [call("write_file", %{"path" => "new.txt", "content" => "x"})], %{
        stop_reason: "refusal"
      })

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert [untouched] = message.tool_calls
    assert untouched.status == "pending"
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "approving runs the tool and records the output", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{"path" => "a.txt"})])

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert [resolved] = message.tool_calls
    assert resolved.status == "approved"
    assert resolved.output == "file contents"
    refute Approvals.awaiting?(message)
  end

  test "denying records the refusal and never runs the tool", %{chat: chat, root: root} do
    message = with_calls(chat, [call("write_file", %{"path" => "new.txt", "content" => "x"})])

    assert {:ok, message} = Approvals.deny(message, "toolu_1")
    assert [resolved] = message.tool_calls
    assert resolved.status == "denied"
    assert resolved.output =~ "denied"
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "an approved call to a denied location is recorded as failed", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{"path" => "/etc/hosts"})])

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert [resolved] = message.tool_calls
    assert resolved.status == "failed"
    assert resolved.output =~ "never readable or writable"
  end

  test "an argument name Claude got wrong is reported, not crashed on", %{chat: chat} do
    message = with_calls(chat, [call("read_file", %{"wrong_name" => "a.txt"})])

    assert {:ok, message} = Approvals.approve(message, "toolu_1")
    assert [resolved] = message.tool_calls
    assert resolved.status == "failed"
    assert resolved.output =~ "missing required argument"
  end

  test "approve_all resolves every pending call", %{chat: chat} do
    message =
      with_calls(chat, [
        call("read_file", %{"path" => "a.txt"}, "toolu_1"),
        call("write_file", %{"path" => "b.txt", "content" => "hi"}, "toolu_2")
      ])

    assert {:ok, message} = Approvals.approve_all(message)
    assert Enum.map(message.tool_calls, & &1.status) == ~w(approved approved)
    refute Approvals.awaiting?(message)
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
end
