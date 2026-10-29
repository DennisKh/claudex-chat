defmodule ClaudexChat.Completions do
  @moduledoc """
  Runs a chat's conversation with `Claudex.ToolRunner` and stores what it
  produces.

  `start/1` asks for the next reply and `resume/2` carries on once every call
  of a halted reply has been decided. Both hand the conversation to
  `Claudex.ToolRunner.stream_to/3`, which runs it in its own process and
  posts its events in batches and each finished turn to the caller:

      {:ok, handle} = Completions.start(chat)
      reply = Reply.new(chat.model)

      # {:claudex, ref, {:events, events}}
      reply = Reply.add_events(reply, events)

      # {:claudex, ref, {:turn, turn}}
      {:ok, %{message: message}} = Completions.record_turn(chat, reply, awaiting, turn)

  The runner resumes a turn the API paused and stops after ten requests.
  The approval gate is `ClaudexChat.Approvals.gate/1`: no file tool runs
  until a human has decided on it.
  """

  alias Claudex.{Client, ToolRunner, Usage}
  alias Claudex.Stream.Handle
  alias Claudex.ToolRunner.Turn

  alias ClaudexChat.{Approvals, Chats, Claude, MCP, Models}
  alias ClaudexChat.Chats.{Chat, Message}
  alias ClaudexChat.Completions.{Params, Reply}

  @max_turns 10
  @batch_window_ms 50

  @doc """
  Starts the conversation from the chat's latest message.

  The run halts on the first tool call Claude asks for, since nobody has
  decided on it yet. It stops with the process that started it, so closing
  the page stops paying for a reply nobody will read. Events are collected
  over #{@batch_window_ms} ms, so the page renders once per batch rather than
  once per token.

  The chat's id goes along as the session, which groups every run of one
  conversation in a tracing backend.
  """
  @spec start(Chat.t()) :: {:ok, Handle.t()} | {:error, term()}
  def start(%Chat{} = chat), do: run(chat, before_call: Approvals.gate([]))

  @doc """
  Carries on from `message`, a reply whose calls have all been decided.

  The runner answers those calls from the decisions, runs the approved ones,
  and sends the results on. Its first turn is `message` itself, with those
  results, and makes no request.
  """
  @spec resume(Chat.t(), Message.t()) :: {:ok, Handle.t()} | {:error, term()}
  def resume(%Chat{} = chat, %Message{} = message) do
    run(chat, before_call: Approvals.gate(message.tool_calls), tool_results: [])
  end

  @doc """
  Stores a finished turn, a cancelled one included.

  The first turn of a run started by `resume/2` is `awaiting`, the stored
  reply it answers, and records its results there. Any other turn is a new
  reply, stored with its usage and timing. Its calls are kept only when it
  ended asking for tools: a reply cancelled, cut off or refused part-way never
  sends them back.
  """
  @spec record_turn(Chat.t(), Reply.t(), Message.t() | nil, Turn.t()) ::
          {:ok, %{message: Message.t(), chat: Chat.t()}} | {:error, Ecto.Changeset.t()}
  def record_turn(%Chat{} = chat, %Reply{} = reply, awaiting, %Turn{} = turn) do
    if resumes?(awaiting, turn) do
      with {:ok, message} <- Approvals.record_results(awaiting, turn.tool_results) do
        {:ok, %{message: message, chat: chat}}
      end
    else
      attrs =
        reply
        |> marked(turn)
        |> Reply.to_message_attrs(turn.message)
        |> Map.put(:tool_calls, calls(turn))

      Chats.add_assistant_message(chat, attrs)
    end
  end

  @doc """
  Stores a reply whose request failed before its turn finished.

  What arrived is kept and its tool calls are not, since Claude never
  finished asking for them. A reply that never got started and has no error
  to show is dropped.
  """
  @spec record_failure(Chat.t(), Reply.t()) ::
          {:ok, %{message: Message.t(), chat: Chat.t()}} | {:error, Ecto.Changeset.t()} | :ignore
  def record_failure(%Chat{} = chat, %Reply{} = reply) do
    if Reply.empty?(reply) and is_nil(reply.error) do
      :ignore
    else
      Chats.add_assistant_message(chat, Reply.to_message_attrs(reply, Reply.message(reply)))
    end
  end

  @doc "Describes why a run couldn't start or failed part-way."
  @spec describe(term()) :: String.t()
  def describe(%Claudex.Error{} = error), do: Exception.message(error)
  def describe(:missing_api_key), do: "No ANTHROPIC_API_KEY is configured."
  def describe(:not_found), do: "That model is no longer available."
  def describe(reason), do: inspect(reason)

  @doc """
  Whether the reply was cut off rather than finished.

  Either ceiling counts: the one this request asked for, and the model's own
  context window.
  """
  @spec truncated?(Message.t()) :: boolean()
  def truncated?(%Message{stop_reason: reason}), do: Claudex.Message.stop(reason) == :truncated

  @doc """
  Whether the API reported both cache counters for this reply and both were
  zero.

  Every request asks for caching, so this is how a prefix below the model's
  minimum shows up: the request succeeds and nothing is written or read. A
  reply missing either counter is not reported as uncached.
  """
  @spec uncached?(Message.t()) :: boolean()
  def uncached?(%Message{cache_creation_tokens: written, cache_read_tokens: read})
      when is_integer(written) and is_integer(read) do
    not Usage.cached?(%Usage{cache_creation_input_tokens: written, cache_read_input_tokens: read})
  end

  def uncached?(%Message{}), do: false

  @doc "Cancels a run that's still going."
  @spec cancel(Handle.t()) :: :ok
  def cancel(%Handle{} = handle), do: Claudex.Stream.cancel(handle)

  @doc "The request body a run for `chat` starts from."
  @spec params(Chat.t(), Models.Model.t()) :: map()
  def params(%Chat{} = chat, %Models.Model{} = model) do
    Params.build(chat, Chats.list_messages(chat), model)
  end

  defp run(chat, opts) do
    with {:ok, client} <- client(chat),
         {:ok, model} <- Models.fetch(chat.model) do
      ToolRunner.stream_to(
        client,
        params(chat, model),
        [
          session: to_string(chat.id),
          max_turns: @max_turns,
          monitor: true,
          every: @batch_window_ms
        ] ++ opts
      )
    end
  end

  # The beta header is only needed once a chat has an MCP server enabled, so
  # a chat with none never sends it.
  defp client(%Chat{mcp_servers: servers}) do
    with {:ok, client} <- Claude.client() do
      {:ok, if(servers == [], do: client, else: Client.put_beta(client, MCP.beta()))}
    end
  end

  # A run given :tool_results yields the reply it resumes as its first turn,
  # and only a resumed run is started while a reply is awaited.
  defp resumes?(%Message{}, %Turn{index: 1}), do: true
  defp resumes?(_awaiting, %Turn{}), do: false

  defp marked(reply, %Turn{stop: :cancelled}), do: Reply.cancelled(reply)
  defp marked(reply, %Turn{}), do: reply

  defp calls(%Turn{message: message} = turn) do
    if Claudex.Message.stop(message) == :tool_use,
      do: Approvals.new_calls(turn.tool_uses, turn.tool_results),
      else: []
  end
end
