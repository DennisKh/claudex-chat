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
  alias ClaudexChat.Models

  @doc """
  Starts streaming the next reply for `chat`.

  The stream runs in a process linked to the caller, so it dies with the
  LiveView that asked for it.
  """
  @spec start(Chat.t()) :: {:ok, Handle.t()} | {:error, term()}
  def start(%Chat{} = chat) do
    with {:ok, client} <- Claude.client(),
         {:ok, model} <- Models.fetch(chat.model) do
      Messages.stream_to(client, params(chat, model))
    end
  end

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

  Events the app has no use for — tool calls, unknown block types — leave the
  reply untouched.
  """
  @spec apply_event(Reply.t(), Event.t()) :: Reply.t()
  def apply_event(%Reply{} = reply, event) do
    reply
    |> Map.put(:acc, Accumulator.add(reply.acc, event))
    |> fold(event)
  end

  defp fold(%Reply{} = reply, %Event.MessageStart{message: message}) do
    %{reply | model: message.model || reply.model, usage: message.usage}
  end

  defp fold(%Reply{} = reply, %Event.ContentBlockDelta{delta: {:text, chunk}}) do
    %{reply | text: reply.text <> chunk}
  end

  defp fold(%Reply{} = reply, %Event.ContentBlockDelta{delta: {:thinking, chunk}}) do
    %{reply | thinking: reply.thinking <> chunk}
  end

  defp fold(%Reply{} = reply, %Event.ContentBlockDelta{delta: {:signature, signature}}) do
    %{reply | thinking_signature: signature}
  end

  defp fold(%Reply{} = reply, %Event.MessageDelta{} = event) do
    %{
      reply
      | stop_reason: event.stop_reason || reply.stop_reason,
        usage: Reply.merge_usage(reply.usage, event.usage)
    }
  end

  defp fold(%Reply{} = reply, _event), do: reply

  @doc "Records why a stream ended without finishing."
  @spec fail(Reply.t(), term()) :: Reply.t()
  def fail(%Reply{} = reply, reason), do: %{reply | error: describe(reason)}

  @doc "Marks a reply the user stopped."
  @spec cancelled(Reply.t()) :: Reply.t()
  def cancelled(%Reply{} = reply), do: %{reply | stop_reason: "cancelled"}

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
