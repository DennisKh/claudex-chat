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

  alias ClaudexChat.Chats
  alias ClaudexChat.Chats.{Message, ToolCall}
  alias ClaudexChat.Tools

  @denial "The user denied this tool call."

  @doc "The calls in this message still waiting on a human."
  @spec pending(Message.t()) :: [ToolCall.t()]
  def pending(%Message{tool_calls: tool_calls}), do: Enum.filter(tool_calls, &ToolCall.pending?/1)

  @doc "Whether this message is holding the conversation up."
  @spec awaiting?(Message.t()) :: boolean()
  def awaiting?(%Message{} = message), do: pending(message) != []

  @doc "Runs one tool call and records what it returned."
  @spec approve(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def approve(%Message{} = message, call_id),
    do: resolve(message, &(&1.call_id == call_id), &run/1)

  @doc "Refuses one tool call, telling Claude it was the user's decision."
  @spec deny(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def deny(%Message{} = message, call_id),
    do: resolve(message, &(&1.call_id == call_id), &denied/1)

  @doc "Runs every pending call in the message."
  @spec approve_all(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def approve_all(%Message{} = message), do: resolve(message, &ToolCall.pending?/1, &run/1)

  @doc "Refuses every pending call in the message."
  @spec deny_all(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def deny_all(%Message{} = message), do: resolve(message, &ToolCall.pending?/1, &denied/1)

  defp resolve(message, match?, decide) do
    tool_calls =
      Enum.map(message.tool_calls, fn call ->
        if ToolCall.pending?(call) and match?.(call), do: decided(call, decide), else: attrs(call)
      end)

    Chats.update_tool_calls(message, tool_calls)
  end

  defp decided(call, decide) do
    {status, output} = decide.(call)

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

  defp denied(_call), do: {"denied", @denial}

  defp run(%ToolCall{} = call) do
    case Claudex.Tool.call(Tools, call.name, call.input) do
      {:ok, output} -> {"approved", to_string(output)}
      {:error, reason} -> {"failed", describe(reason)}
    end
  end

  # Every branch has to end in a string: the reason is stored on the call and
  # sent back to Claude as the tool result, and `:missing_args` carries a list
  # rather than a message.
  defp describe({:missing_args, names}),
    do: "missing required argument(s): #{Enum.join(names, ", ")}"

  defp describe({:unknown_tool, name}), do: "no such tool: #{name}"
  defp describe({:tool_refused, message}), do: message
  defp describe({:tool_raised, message}), do: message
  defp describe(reason), do: inspect(reason)
end
