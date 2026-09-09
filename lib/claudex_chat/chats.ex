defmodule ClaudexChat.Chats do
  @moduledoc """
  Conversations and the messages in them.

  Adding a message touches its chat's `updated_at`, so the sidebar's
  most-recent-first order reflects activity rather than when a chat was
  created. The first user message also names an untitled chat.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias ClaudexChat.Chats.{Chat, Message}
  alias ClaudexChat.Repo

  @default_title "New chat"
  @title_length 60

  @doc "The title a chat starts with, before its first message names it."
  @spec default_title() :: String.t()
  def default_title, do: @default_title

  @doc "Lists chats, most recently active first."
  @spec list_chats() :: [Chat.t()]
  def list_chats do
    Repo.all(from c in Chat, order_by: [desc: c.updated_at, desc: c.id])
  end

  @doc "Fetches one chat."
  @spec fetch_chat(integer() | String.t()) :: {:ok, Chat.t()} | {:error, :not_found}
  def fetch_chat(id) do
    case Repo.get(Chat, id) do
      nil -> {:error, :not_found}
      chat -> {:ok, chat}
    end
  end

  @doc """
  Starts a chat.

  `attrs` needs a `:model`; the title defaults to `#{inspect(@default_title)}`
  until the first user message replaces it.
  """
  @spec create_chat(map()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t()}
  def create_chat(attrs) do
    %Chat{}
    |> Chat.changeset(Map.put_new(attrs, :title, @default_title))
    |> Repo.insert()
  end

  @doc "Updates a chat's title, model or thinking settings."
  @spec update_chat(Chat.t(), map()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t()}
  def update_chat(%Chat{} = chat, attrs) do
    chat
    |> Chat.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a chat and every message in it."
  @spec delete_chat(Chat.t()) :: {:ok, Chat.t()} | {:error, Ecto.Changeset.t()}
  def delete_chat(%Chat{} = chat), do: Repo.delete(chat)

  @doc "Builds a changeset for editing a chat, for forms."
  @spec change_chat(Chat.t(), map()) :: Ecto.Changeset.t()
  def change_chat(%Chat{} = chat, attrs \\ %{}), do: Chat.changeset(chat, attrs)

  @doc "Lists a chat's messages oldest first."
  @spec list_messages(Chat.t()) :: [Message.t()]
  def list_messages(%Chat{id: chat_id}) do
    Repo.all(from m in Message, where: m.chat_id == ^chat_id, order_by: [asc: m.id])
  end

  @doc """
  Records what the user sent.

  Names the chat after this message when it's still untitled, and returns the
  chat as it now stands so a caller doesn't have to reload it.
  """
  @spec add_user_message(Chat.t(), map()) ::
          {:ok, %{message: Message.t(), chat: Chat.t()}} | {:error, Ecto.Changeset.t()}
  def add_user_message(%Chat{} = chat, attrs) do
    attrs = Map.put(attrs, :role, "user")

    Multi.new()
    |> Multi.insert(:message, message_changeset(chat, attrs))
    |> Multi.update(:chat, fn %{message: message} -> touch(chat, title_from(chat, message)) end)
    |> transaction()
  end

  @doc "Records a reply from Claude, with its usage and timing."
  @spec add_assistant_message(Chat.t(), map()) ::
          {:ok, %{message: Message.t(), chat: Chat.t()}} | {:error, Ecto.Changeset.t()}
  def add_assistant_message(%Chat{} = chat, attrs) do
    attrs = Map.put(attrs, :role, "assistant")

    Multi.new()
    |> Multi.insert(:message, message_changeset(chat, attrs))
    |> Multi.update(:chat, fn _changes -> touch(chat, %{}) end)
    |> transaction()
  end

  @doc """
  Sends a user message again, as a new turn.

  The original stays where it is — this appends a copy, attachments included,
  so a reply that was stopped or went wrong can be asked for again without
  losing the record of the first attempt.
  """
  @spec replay_user_message(Chat.t(), Message.t()) ::
          {:ok, %{message: Message.t(), chat: Chat.t()}} | {:error, Ecto.Changeset.t()}
  def replay_user_message(%Chat{} = chat, %Message{role: "user"} = message) do
    add_user_message(chat, %{content: message.content, attachments: attachment_attrs(message)})
  end

  @doc "Fetches one message."
  @spec fetch_message(integer() | String.t()) :: {:ok, Message.t()} | {:error, :not_found}
  def fetch_message(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @doc """
  Deletes a message and everything after it in its chat.

  This is what a retry rewinds to: the reply being retried goes, and so does
  anything that followed it, because it was answering a turn that no longer
  exists.
  """
  @spec discard_from(Message.t()) :: {:ok, non_neg_integer()}
  def discard_from(%Message{chat_id: chat_id, id: id}) do
    {count, _deleted} =
      Repo.delete_all(from m in Message, where: m.chat_id == ^chat_id and m.id >= ^id)

    {:ok, count}
  end

  @doc """
  Replaces a message's tool calls, for recording what a human decided and what
  running the tool produced.
  """
  @spec update_tool_calls(Message.t(), [map()]) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def update_tool_calls(%Message{} = message, tool_calls) do
    message
    |> Message.changeset(%{tool_calls: tool_calls})
    |> Repo.update()
  end

  defp attachment_attrs(%Message{attachments: attachments}) do
    Enum.map(attachments, &Map.take(&1, [:file_id, :filename, :mime_type, :size_bytes]))
  end

  defp message_changeset(chat, attrs) do
    chat
    |> Ecto.build_assoc(:messages)
    |> Message.changeset(attrs)
  end

  defp transaction(multi) do
    case Repo.transaction(multi) do
      {:ok, changes} -> {:ok, Map.take(changes, [:message, :chat])}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp touch(chat, attrs) do
    chat
    |> Chat.changeset(attrs)
    |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now(:second))
  end

  defp title_from(%Chat{title: @default_title}, %Message{content: content}) do
    case summarize(content) do
      "" -> %{}
      title -> %{title: title}
    end
  end

  defp title_from(_chat, _message), do: %{}

  defp summarize(content) do
    content
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
    |> String.slice(0, @title_length)
  end
end
