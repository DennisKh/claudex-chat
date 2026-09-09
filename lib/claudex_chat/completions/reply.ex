defmodule ClaudexChat.Completions.Reply do
  @moduledoc """
  A reply as it arrives, folded together from the stream's events.

  Usage arrives in two pieces — `message_start` carries the input counts and
  `message_delta` the final output counts — so `merge_usage/2` combines them
  rather than letting the later one replace the earlier.
  """

  alias Claudex.ContentBlock
  alias Claudex.Stream.Accumulator
  alias Claudex.Usage

  @type t :: %__MODULE__{
          text: String.t(),
          thinking: String.t(),
          thinking_signature: String.t() | nil,
          model: String.t() | nil,
          usage: Usage.t() | nil,
          stop_reason: String.t() | nil,
          error: String.t() | nil,
          started_at: integer(),
          duration_ms: non_neg_integer() | nil,
          acc: Accumulator.t()
        }

  defstruct text: "",
            thinking: "",
            thinking_signature: nil,
            model: nil,
            usage: nil,
            stop_reason: nil,
            error: nil,
            started_at: nil,
            duration_ms: nil,
            acc: nil

  @doc "Starts an empty reply and begins timing it."
  @spec new(String.t()) :: t()
  def new(model) do
    %__MODULE__{
      model: model,
      started_at: System.monotonic_time(:millisecond),
      acc: Accumulator.new()
    }
  end

  @doc """
  The tools Claude asked to run, as attributes for `ClaudexChat.Chats.ToolCall`.

  Read off the accumulated message rather than the text buffer, because a
  tool call's arguments arrive as JSON fragments that are only valid once
  joined.
  """
  @spec tool_calls(t()) :: [map()]
  def tool_calls(%__MODULE__{acc: nil}), do: []

  def tool_calls(%__MODULE__{acc: acc}) do
    case Accumulator.message(acc) do
      nil ->
        []

      message ->
        for %ContentBlock.ToolUse{} = block <- message.content do
          %{call_id: block.id, name: block.name, input: block.input, status: "pending"}
        end
    end
  end

  @doc "Stops the clock."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{duration_ms: nil} = reply) do
    %{reply | duration_ms: System.monotonic_time(:millisecond) - reply.started_at}
  end

  def finish(%__MODULE__{} = reply), do: reply

  @doc "Whether anything at all arrived — text, thinking, or a tool call."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{text: "", thinking: ""} = reply), do: tool_calls(reply) == []
  def empty?(%__MODULE__{}), do: false

  @doc """
  Combines two usage objects, keeping whichever side reported a counter.

  A `message_delta` only carries the fields the API chose to send, so anything
  missing there keeps the value `message_start` gave it.
  """
  @spec merge_usage(Usage.t() | nil, Usage.t() | nil) :: Usage.t() | nil
  def merge_usage(nil, usage), do: usage
  def merge_usage(usage, nil), do: usage

  def merge_usage(%Usage{} = current, %Usage{} = incoming) do
    incoming
    |> Map.from_struct()
    |> Enum.reduce(current, fn
      {_field, nil}, acc -> acc
      {field, value}, acc -> Map.put(acc, field, value)
    end)
  end

  @doc "The attributes to persist this reply as an assistant message."
  @spec to_message_attrs(t()) :: map()
  def to_message_attrs(%__MODULE__{} = reply) do
    usage = reply.usage || %Usage{}

    %{
      content: reply.text,
      thinking: presence(reply.thinking),
      thinking_signature: reply.thinking_signature,
      model: reply.model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_input_tokens,
      cache_creation_tokens: usage.cache_creation_input_tokens,
      duration_ms: reply.duration_ms,
      stop_reason: reply.stop_reason,
      error: reply.error,
      tool_calls: tool_calls(reply)
    }
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
