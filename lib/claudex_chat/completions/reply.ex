defmodule ClaudexChat.Completions.Reply do
  @moduledoc """
  The reply being written right now.

  `Claudex.ToolRunner.stream_to/3` sends events in batches as they arrive and
  each turn once it is finished. The events fold into an accumulator, which is
  what the page shows while a reply streams and what is stored when a request
  fails before its turn arrives. A turn, a cancelled one included, is stored
  from the turn's own message instead.

  This adds what the app knows and the API doesn't: which model was asked,
  how long the reply took, and why it ended early if it did.
  """

  alias Claudex.ContentBlock
  alias Claudex.Message
  alias Claudex.Stream.Accumulator
  alias Claudex.Usage

  @type t :: %__MODULE__{
          model: String.t() | nil,
          error: String.t() | nil,
          started_at: integer(),
          cancelled: boolean(),
          acc: Accumulator.t()
        }

  defstruct [:model, :error, :started_at, :acc, cancelled: false]

  @doc "Starts an empty reply and begins timing it."
  @spec new(String.t()) :: t()
  def new(model) do
    %__MODULE__{
      model: model,
      started_at: System.monotonic_time(:millisecond),
      acc: Accumulator.new()
    }
  end

  @doc "Folds one stream event in."
  @spec add(t(), Claudex.Stream.Event.t()) :: t()
  def add(%__MODULE__{} = reply, event), do: %{reply | acc: Accumulator.add(reply.acc, event)}

  @doc "Folds a batch of stream events in, in the order they arrived."
  @spec add_events(t(), [Claudex.Stream.Event.t()]) :: t()
  def add_events(%__MODULE__{} = reply, events), do: Enum.reduce(events, reply, &add(&2, &1))

  @doc """
  Marks a reply the user stopped.

  A cancelled stream never delivers a stop reason of its own, so the app
  supplies one.
  """
  @spec cancelled(t()) :: t()
  def cancelled(%__MODULE__{} = reply), do: %{reply | cancelled: true}

  @doc "Records why the reply ended without finishing."
  @spec failed(t(), String.t()) :: t()
  def failed(%__MODULE__{} = reply, error), do: %{reply | error: error}

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

  @doc "The text and reasoning so far, for rendering a reply while it streams."
  @spec preview(t()) :: %{text: String.t(), thinking: String.t()}
  def preview(%__MODULE__{} = reply) do
    message = message(reply)

    %{text: text_of(message), thinking: thinking_of(message)}
  end

  @doc """
  Whether anything worth keeping arrived.

  A turn that only ran a web search has no text in it and is still a turn. The
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

  @doc """
  The reply as the SDK's own message, folded from the events so far, or `nil`
  before the stream has started one.
  """
  @spec message(t()) :: Message.t() | nil
  def message(%__MODULE__{acc: acc}), do: Accumulator.message(acc)

  @doc """
  The attributes to store `message` as an assistant message, timed by this
  reply.

  `message` is the finished turn's message, or the accumulated one for a reply
  that was cut off.
  """
  @spec to_message_attrs(t(), Message.t() | nil) :: map()
  def to_message_attrs(%__MODULE__{} = reply, message) do
    usage = (message && message.usage) || %Usage{}

    %{
      content: text_of(message),
      thinking: presence(thinking_of(message)),
      content_blocks: content_blocks(message),
      model: (message && message.model) || reply.model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_tokens: usage.cache_read_input_tokens,
      cache_creation_tokens: usage.cache_creation_input_tokens,
      duration_ms: System.monotonic_time(:millisecond) - reply.started_at,
      stop_reason: stop_reason(reply, message),
      error: reply.error
    }
  end

  defp text_of(nil), do: ""
  defp text_of(%Message{} = message), do: Message.text(message)

  defp thinking_of(nil), do: ""

  defp thinking_of(%Message{content: blocks}) do
    blocks
    |> Enum.filter(&match?(%ContentBlock.Thinking{}, &1))
    |> Enum.map_join("\n\n", &(&1.thinking || ""))
    |> String.trim()
  end

  # The whole turn as the API sent it, so it can be replayed unchanged. A
  # search result's encrypted content and a thinking block's signature both
  # have to go back byte for byte. The SDK leaves out what a reply cut off
  # part-way can't send back: an unsigned thinking block, an empty text block,
  # and a call it never finished asking for.
  defp content_blocks(nil), do: []

  defp content_blocks(%Message{} = message) do
    %{content: blocks} = Message.to_param(message)

    Enum.map(blocks, &stored_block/1)
  end

  # A block the API sent keeps its string keys, one Claudex rebuilds comes back
  # atom-keyed, and only one of those shapes is what a row reads back as.
  defp stored_block(block), do: block |> Jason.encode!() |> Jason.decode!()

  defp stop_reason(%__MODULE__{cancelled: true}, _message), do: "cancelled"
  defp stop_reason(%__MODULE__{}, nil), do: nil
  defp stop_reason(%__MODULE__{}, %Message{stop_reason: reason}), do: reason

  defp presence(""), do: nil
  defp presence(value), do: value
end
