defmodule ClaudexChat.Approvals do
  @moduledoc """
  The gate between Claude asking to run a tool and the tool running.

  A tool call is recorded `"pending"` and does nothing until a human calls
  `approve/2` or `deny/2`. Either way the call ends up with an `output` — the
  tool's result, the reason it failed, or the fact that it was refused — which
  is what goes back to Claude.

  Web search isn't here: it runs on Anthropic's servers during the turn, so
  there's no moment at which this app could hold it.
  """

  alias Claudex.Tool.CallError

  alias ClaudexChat.Chats
  alias ClaudexChat.Chats.{Message, ToolCall}
  alias ClaudexChat.Tools

  @denial "The user denied this tool call."

  @doc """
  The calls in this message still waiting on a human.

  A turn Claude never finished asking on has none: its calls can't be run and
  can't be answered, so there is nothing to decide.
  """
  @spec pending(Message.t()) :: [ToolCall.t()]
  def pending(%Message{} = message) do
    if Message.tool_calls_runnable?(message) do
      Enum.filter(message.tool_calls, &ToolCall.pending?/1)
    else
      []
    end
  end

  @doc "Whether this message is holding the conversation up."
  @spec awaiting?(Message.t()) :: boolean()
  def awaiting?(%Message{} = message), do: pending(message) != []

  @doc "Runs one tool call and records what it returned."
  @spec approve(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def approve(%Message{} = message, call_id),
    do: resolve(message, &(&1.call_id == call_id), &run/2)

  @doc "Refuses one tool call, telling Claude it was the user's decision."
  @spec deny(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def deny(%Message{} = message, call_id),
    do: resolve(message, &(&1.call_id == call_id), &denied/2)

  @doc "Runs every pending call in the message."
  @spec approve_all(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def approve_all(%Message{} = message), do: resolve(message, &ToolCall.pending?/1, &run/2)

  @doc "Refuses every pending call in the message."
  @spec deny_all(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def deny_all(%Message{} = message), do: resolve(message, &ToolCall.pending?/1, &denied/2)

  defp resolve(message, match?, decide) do
    if Message.tool_calls_runnable?(message) do
      decide_calls(message, match?, decide)
    else
      {:ok, message}
    end
  end

  defp decide_calls(message, match?, decide) do
    tool_calls =
      Enum.map(message.tool_calls, fn call ->
        if ToolCall.pending?(call) and match?.(call),
          do: decided(call, decide, message.chat_id),
          else: attrs(call)
      end)

    Chats.update_tool_calls(message, tool_calls)
  end

  defp decided(call, decide, chat_id) do
    {status, output} = decide.(call, chat_id)

    call |> attrs() |> Map.merge(%{status: status, output: output})
  end

  defp attrs(%ToolCall{} = call) do
    %{
      call_id: call.call_id,
      name: call.name,
      input: call.input,
      status: call.status,
      output: call.output
    }
  end

  defp denied(_call, _chat_id), do: {"denied", @denial}

  # The chat is the conversation this call belongs to, which is what puts the
  # tool's span in the same trace as the request that asked for it.
  defp run(%ToolCall{} = call, chat_id) do
    case Claudex.Tool.call(Tools, call.name, call.input, session: to_string(chat_id)) do
      {:ok, output} -> {"approved", to_string(output)}
      {:error, %CallError{message: message}} -> {"failed", message}
    end
  end
end
