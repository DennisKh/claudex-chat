defmodule ClaudexChat.Completions.Reply do
  @moduledoc """
  A reply as it arrives.

  The stream's own accumulator holds everything the API sent — text, thinking,
  tool calls, merged usage, the stop reason — so this only adds what the app
  knows and the API doesn't: which model was asked, how long it took, and why
  it ended early if it did.

  Every reader here goes through one snapshot of the accumulated message, so
  rendering a reply mid-stream rebuilds it once rather than once per field.
  """

  alias Claudex.ContentBlock
  alias Claudex.Message
  alias Claudex.Stream.Accumulator
  alias Claudex.Usage

  @type t :: %__MODULE__{
          model: String.t() | nil,
          error: String.t() | nil,
          started_at: integer(),
          duration_ms: non_neg_integer() | nil,
          cancelled: boolean(),
          acc: Accumulator.t()
        }

  defstruct [:model, :error, :started_at, :duration_ms, :acc, cancelled: false]

  @doc "Starts an empty reply and begins timing it."
  @spec new(String.t()) :: t()
  def new(model) do
    %__MODULE__{
      model: model,
      started_at: System.monotonic_time(:millisecond),
      acc: Accumulator.new()
    }
  end

  @doc "Stops the clock."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{duration_ms: nil} = reply) do
    %{reply | duration_ms: System.monotonic_time(:millisecond) - reply.started_at}
  end

  def finish(%__MODULE__{} = reply), do: reply

  @doc """
  Marks a reply the user stopped.

  A cancelled stream never delivers a stop reason of its own, so the app
  supplies one.
  """
  @spec cancelled(t()) :: t()
  def cancelled(%__MODULE__{} = reply), do: %{reply | cancelled: true}

  @doc "The reply text so far."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = reply), do: reply |> message() |> text_of()

  @doc """
  Claude's reasoning so far, if it was asked for and is being shown.

  A turn can think more than once — around a web search, say — and every pass
  is here, separated by a blank line.
  """
  @spec thinking(t()) :: String.t()
  def thinking(%__MODULE__{} = reply), do: reply |> message() |> thinking_of()

  @doc """
  The signature that closes the first thinking block.

  Replay goes through the stored content blocks, which carry one signature per
  block; this is what a message stored before those were kept falls back on.
  """
  @spec thinking_signature(t()) :: String.t() | nil
  def thinking_signature(%__MODULE__{} = reply), do: reply |> message() |> signature_of()

  @doc "The text and reasoning so far, for rendering a reply while it streams."
  @spec preview(t()) :: %{text: String.t(), thinking: String.t()}
  def preview(%__MODULE__{} = reply) do
    message = message(reply)

    %{text: text_of(message), thinking: thinking_of(message)}
  end

  @doc """
  Whether anything at all arrived.

  A turn that only asked for a web search has no text in it and is still a
  turn: the API pauses there and carries on once the history comes back. The
  SDK answers which blocks count, so a block type it adds later is kept here
  without this having to hear about it.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = reply) do
    case message(reply) do
      nil -> true
      message -> Message.empty?(message)
    end
  end

  @doc "The tools Claude asked to run, as `ClaudexChat.Chats.ToolCall` attributes."
  @spec tool_calls(t()) :: [map()]
  def tool_calls(%__MODULE__{} = reply), do: reply |> message() |> tool_uses_of()

  @doc """
  The reply as the SDK's own message, or `nil` before the stream has started
  one.

  This is what the accumulator has folded together so far — the same struct
  the API would have returned unstreamed.
  """
  @spec message(t()) :: Message.t() | nil
  def message(%__MODULE__{acc: nil}), do: nil
  def message(%__MODULE__{acc: acc}), do: Accumulator.message(acc)

  @doc "The attributes to persist this reply as an assistant message."
  @spec to_message_attrs(t()) :: map()
  def to_message_attrs(%__MODULE__{} = reply) do
    message = message(reply)
    usage = (message && message.usage) || %Usage{}

    %{
      content: text_of(message),
      thinking: presence(thinking_of(message)),
      thinking_signature: signature_of(message),
      content_blocks: content_blocks(message),
      model: (message && message.model) || reply.model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_input_tokens,
      cache_creation_tokens: usage.cache_creation_input_tokens,
      duration_ms: reply.duration_ms,
      stop_reason: stop_reason(reply, message),
      error: reply.error,
      tool_calls: tool_uses_of(message)
    }
  end

  defp text_of(nil), do: ""
  defp text_of(%Message{} = message), do: Message.text(message)

  defp thinking_of(nil), do: ""

  defp thinking_of(%Message{} = message) do
    message
    |> thinking_blocks()
    |> Enum.map_join("\n\n", &(&1.thinking || ""))
    |> String.trim()
  end

  defp signature_of(nil), do: nil

  defp signature_of(%Message{} = message) do
    case thinking_blocks(message) do
      [] -> nil
      [block | _rest] -> block.signature
    end
  end

  defp thinking_blocks(%Message{content: blocks}) do
    Enum.filter(blocks, &match?(%ContentBlock.Thinking{}, &1))
  end

  defp tool_uses_of(nil), do: []

  defp tool_uses_of(%Message{} = message) do
    for block <- Message.tool_uses(message) do
      %{call_id: block.id, name: block.name, input: block.input, status: "pending"}
    end
  end

  # The whole turn as the API sent it, so it can be replayed unchanged. A
  # search result's encrypted content and a thinking block's signature both
  # have to go back byte for byte, and neither survives being rebuilt from the
  # columns beside it.
  defp content_blocks(nil), do: []
  defp content_blocks(%Message{content: blocks}), do: Enum.map(blocks, &stored_block/1)

  # A block the API sent keeps its string keys, one Claudex rebuilds comes back
  # atom-keyed, and only one of those shapes is what a row reads back as.
  defp stored_block(block) do
    block
    |> ContentBlock.to_param()
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp stop_reason(%__MODULE__{cancelled: true}, _message), do: "cancelled"
  defp stop_reason(%__MODULE__{}, nil), do: nil
  defp stop_reason(%__MODULE__{}, %Message{stop_reason: reason}), do: reason

  defp presence(""), do: nil
  defp presence(value), do: value
end
