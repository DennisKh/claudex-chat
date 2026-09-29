defmodule ClaudexChat.Completions do
  @moduledoc """
  Asks Claude for the next reply in a chat and folds the streamed answer back
  together.

  `start/1` hands the request to `Claudex.Messages.stream_to/3`, which runs it
  in its own process and posts events to the caller. Feed each one through
  `apply_event/2`, then persist the finished reply with `finish/2`.

      {:ok, handle} = Completions.start(chat)
      reply = Reply.new(chat.model)

      # in handle_info, for {:claudex, ref, {:event, event}}
      reply = Completions.apply_event(reply, event)

      # for {:claudex, ref, :done}
      {:ok, %{message: message}} = Completions.finish(chat, reply)
  """

  alias Claudex.Messages
  alias Claudex.Stream.{Accumulator, Event, Handle}

  alias ClaudexChat.Chats
  alias ClaudexChat.Chats.{Chat, Message}
  alias ClaudexChat.Claude
  alias ClaudexChat.Completions.{Params, Reply}
  alias ClaudexChat.{MCP, Models}

  @doc """
  Starts streaming the next reply for `chat`.

  The stream runs in a process linked to the caller, so it dies with the
  LiveView that asked for it.

  The chat's id goes along as the session, which is what groups every request
  in one conversation under a single trace in a tracing backend.
  """
  @spec start(Chat.t()) :: {:ok, Handle.t()} | {:error, term()}
  def start(%Chat{} = chat) do
    with {:ok, client} <- Claude.client(client_opts(chat)),
         {:ok, model} <- Models.fetch(chat.model) do
      Messages.stream_to(client, params(chat, model), session: to_string(chat.id))
    end
  end

  # The beta header is only needed once a chat has an MCP server enabled, so
  # a chat with none never sends it.
  defp client_opts(%Chat{mcp_servers: []}), do: []
  defp client_opts(%Chat{mcp_servers: [_ | _]}), do: [beta: MCP.beta()]

  @doc """
  Whether the API paused this turn part-way through its own tool loop.

  A server-side tool that runs long — web search, say — comes back with
  nothing for anyone to decide. The stored turn goes back unchanged and Claude
  carries on, so the app continues on its own rather than leaving a
  half-finished reply on screen.
  """
  @spec paused?(Message.t()) :: boolean()
  def paused?(%Message{stop_reason: reason}), do: Claudex.Message.stop(reason) == :paused

  @doc """
  Whether the reply was cut off rather than finished.

  Either ceiling counts: the one this request asked for, and the model's own
  context window.
  """
  @spec truncated?(Message.t()) :: boolean()
  def truncated?(%Message{stop_reason: reason}), do: Claudex.Message.stop(reason) == :truncated

  @doc "Cancels a stream that's still running."
  @spec cancel(Handle.t()) :: :ok
  def cancel(%Handle{} = handle), do: Claudex.Stream.cancel(handle)

  @doc "The request body that `start/1` would send."
  @spec params(Chat.t(), Models.Model.t()) :: map()
  def params(%Chat{} = chat, %Models.Model{} = model) do
    Params.build(chat, Chats.list_messages(chat), model)
  end

  @doc """
  Folds one stream event into the reply.

  Everything the API sends goes through the SDK's accumulator, which joins
  fragmented tool arguments and merges the usage that arrives in two pieces.
  """
  @spec apply_event(Reply.t(), Event.t()) :: Reply.t()
  def apply_event(%Reply{} = reply, event) do
    %{reply | acc: Accumulator.add(reply.acc, event)}
  end

  @doc "Records why a stream ended without finishing."
  @spec fail(Reply.t(), term()) :: Reply.t()
  def fail(%Reply{} = reply, reason), do: %{reply | error: describe(reason)}

  @doc """
  Persists the finished reply as an assistant message.

  A reply that arrived with nothing at all and no error to report is dropped
  rather than stored as an empty turn.
  """
  @spec finish(Chat.t(), Reply.t()) ::
          {:ok, %{message: Message.t(), chat: Chat.t()}}
          | {:error, Ecto.Changeset.t()}
          | :ignore
  def finish(%Chat{} = chat, %Reply{} = reply) do
    reply = Reply.finish(reply)

    if Reply.empty?(reply) and is_nil(reply.error) do
      :ignore
    else
      Chats.add_assistant_message(chat, Reply.to_message_attrs(reply))
    end
  end

  defp describe(%Claudex.Error{} = error), do: Exception.message(error)
  defp describe(:missing_api_key), do: "No ANTHROPIC_API_KEY is configured."
  defp describe(:not_found), do: "That model is no longer available."
  defp describe(reason), do: inspect(reason)
end
