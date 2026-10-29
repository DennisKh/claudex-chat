defmodule ClaudexChat.Approvals do
  @moduledoc """
  The gate between Claude asking to run a tool and the tool running.

  `Claudex.ToolRunner` asks `gate/1` about every call before it runs one. A
  call nobody has decided on halts the run, and the reply is stored with its
  calls `"pending"`. `approve/2` and `deny/2` only record what a human
  decided; the conversation resumes once no call is left pending, and the
  runner runs the approved calls then. `record_results/2` stores what came
  back.

  Web search and MCP calls aren't here: they run on Anthropic's servers during
  the turn, so there's no moment at which this app could hold them.
  """

  alias Claudex.ContentBlock.ToolUse

  alias ClaudexChat.Chats
  alias ClaudexChat.Chats.{Message, ToolCall}

  @halt :awaiting_approval
  @denial "The user denied this tool call."

  @doc "The `stop` a run halted on to wait for a human carries."
  @spec halt() :: atom()
  def halt, do: @halt

  @doc """
  The calls in this message still waiting on a human.

  Only a reply that ended asking for tools has any. A reply that was refused or
  cut off part-way never sends its calls back, so there is nothing to decide.
  """
  @spec pending(Message.t()) :: [ToolCall.t()]
  def pending(%Message{} = message) do
    if asked_for_tools?(message),
      do: Enum.filter(message.tool_calls, &ToolCall.pending?/1),
      else: []
  end

  @doc "Whether this message is holding the conversation up."
  @spec awaiting?(Message.t()) :: boolean()
  def awaiting?(%Message{} = message), do: pending(message) != []

  @doc "Records that a human approved one call. It runs when the conversation resumes."
  @spec approve(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def approve(%Message{} = message, call_id), do: decide(message, call_id, "approved")

  @doc "Records that a human refused one call. Claude is told it was their decision."
  @spec deny(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def deny(%Message{} = message, call_id), do: decide(message, call_id, "denied")

  @doc """
  The `:before_call` for a run, built from the decisions recorded on
  `tool_calls`.

  An approved call runs, a denied one is answered with the denial, and any
  other call halts the run with `halt/0` as its stop. A new reply's calls are
  in no list yet, so its first call always halts.
  """
  @spec gate([ToolCall.t()]) :: (ToolUse.t() -> :ok | {:deny, String.t()} | {:halt, atom()})
  def gate(tool_calls) do
    decisions = Map.new(tool_calls, &{&1.call_id, &1.status})

    fn %ToolUse{id: id} ->
      case decisions[id] do
        "approved" -> :ok
        "denied" -> {:deny, @denial}
        _undecided -> {:halt, @halt}
      end
    end
  end

  @doc """
  Stores the results the runner sent back for this message's calls.

  An approved call whose result is an error failed while running.
  """
  @spec record_results(Message.t(), [map()]) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def record_results(%Message{} = message, results) do
    by_id = Map.new(results, &{&1.tool_use_id, &1})

    message.tool_calls
    |> Enum.map(fn call -> answered(call, by_id[call.call_id]) end)
    |> then(&Chats.update_tool_calls(message, &1))
  end

  @doc """
  Puts every decided call that never got a result back to pending.

  A run that was cancelled or failed while resuming leaves its calls decided
  but unanswered, and the next run needs a human to decide them again.
  """
  @spec reopen(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def reopen(%Message{} = message) do
    if Enum.any?(message.tool_calls, &unanswered_decision?/1) do
      message.tool_calls
      |> Enum.map(fn call ->
        if unanswered_decision?(call), do: %{attrs(call) | status: "pending"}, else: attrs(call)
      end)
      |> then(&Chats.update_tool_calls(message, &1))
    else
      {:ok, message}
    end
  end

  @doc """
  The attributes to store a reply's calls with, answered from `results`
  where the runner already answered them, as it does for a call whose input
  never parsed.
  """
  @spec new_calls([ToolUse.t()], [map()]) :: [map()]
  def new_calls(tool_uses, results) do
    by_id = Map.new(results, &{&1.tool_use_id, &1})

    for %ToolUse{} = use <- tool_uses do
      call = %ToolCall{call_id: use.id, name: use.name, input: use.input}
      answered(call, by_id[use.id])
    end
  end

  defp decide(message, call_id, status) do
    if Enum.any?(pending(message), &(&1.call_id == call_id)) do
      message.tool_calls
      |> Enum.map(fn call ->
        if call.call_id == call_id, do: %{attrs(call) | status: status}, else: attrs(call)
      end)
      |> then(&Chats.update_tool_calls(message, &1))
    else
      {:ok, message}
    end
  end

  defp answered(call, nil), do: attrs(call)

  defp answered(call, result) do
    %{
      attrs(call)
      | status: outcome(call.status, result),
        output: output_text(result.content),
        result: stored(result)
    }
  end

  defp outcome("denied", _result), do: "denied"
  defp outcome(_status, %{is_error: true}), do: "failed"
  defp outcome(_status, _result), do: "approved"

  defp output_text(content) when is_binary(content), do: content
  defp output_text(blocks) when is_list(blocks), do: Enum.map_join(blocks, "\n", &block_text/1)

  defp block_text(%{type: "text", text: text}), do: text
  defp block_text(%{type: type, source: %{type: "file", file_id: id}}), do: "[#{type} #{id}]"
  defp block_text(%{type: type}), do: "[#{type}]"

  # Stored the way a row reads back, with string keys, so a result written
  # now and one loaded later replay alike.
  defp stored(result), do: result |> Jason.encode!() |> Jason.decode!()

  defp unanswered_decision?(%ToolCall{} = call),
    do: call.status in ~w(approved denied) and not ToolCall.answered?(call)

  defp asked_for_tools?(%Message{stop_reason: reason}),
    do: Claudex.Message.stop(reason) == :tool_use

  defp attrs(%ToolCall{} = call) do
    %{
      call_id: call.call_id,
      name: call.name,
      input: call.input,
      status: call.status,
      output: call.output,
      result: call.result
    }
  end
end
