defmodule ClaudexChat.Chats.Message do
  @moduledoc """
  One turn in a chat — what the user asked or what Claude replied, with the
  token counts and timing the reply cost.

  Token fields are nil when the API didn't report that counter, which is not
  the same as zero, so the UI can leave them out rather than show a made-up
  number. An assistant message may have blank content — a stream that was
  cancelled or failed before any text arrived still gets recorded.

  `content_blocks` is the assistant turn exactly as the API sent it, and is
  what goes back in the next request: a thinking signature and a search
  result's encrypted content are both rejected if they change on the way
  through, and neither can be rebuilt from the columns beside it.
  `thinking_signature` is what a message stored before those blocks were kept
  falls back on.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClaudexChat.Chats.{Attachment, Chat, ToolCall}

  @roles ~w(user assistant)

  @type t :: %__MODULE__{
          id: integer() | nil,
          role: String.t(),
          content: String.t(),
          thinking: String.t() | nil,
          thinking_signature: String.t() | nil,
          content_blocks: [map()],
          attachments: [Attachment.t()],
          tool_calls: [ToolCall.t()],
          model: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_creation_tokens: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          stop_reason: String.t() | nil,
          error: String.t() | nil,
          chat: Chat.t() | Ecto.Association.NotLoaded.t()
        }

  schema "messages" do
    field :role, :string
    field :content, :string, default: ""
    field :thinking, :string
    field :thinking_signature, :string
    field :content_blocks, {:array, :map}, default: []
    field :model, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cache_read_tokens, :integer
    field :cache_creation_tokens, :integer
    field :duration_ms, :integer
    field :stop_reason, :string
    field :error, :string

    embeds_many :attachments, Attachment, on_replace: :delete
    embeds_many :tool_calls, ToolCall, on_replace: :delete

    belongs_to :chat, Chat

    timestamps(type: :utc_datetime)
  end

  @doc "The roles a message may have."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc """
  Whether the tool calls in this message may be run.

  A turn that was refused or cut off can carry a call Claude never finished
  asking for — the arguments stop mid-JSON — and the API rejects a result for
  a call it never confirmed. Those calls are left alone and the turn is retried
  instead.
  """
  @spec tool_calls_runnable?(t()) :: boolean()
  def tool_calls_runnable?(%__MODULE__{stop_reason: reason}) do
    Claudex.Message.stop(reason) not in [:refusal, :truncated]
  end

  @doc "Validates a message and its attachments."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :role,
      :content,
      :thinking,
      :thinking_signature,
      :content_blocks,
      :model,
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_creation_tokens,
      :duration_ms,
      :stop_reason,
      :error
    ])
    |> cast_embed(:attachments)
    |> cast_embed(:tool_calls)
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
    |> validate_content_present()
  end

  defp validate_content_present(changeset) do
    if get_field(changeset, :role) == "user" and blank?(get_field(changeset, :content)) do
      add_error(changeset, :content, "can't be blank")
    else
      changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(content), do: String.trim(content) == ""
end
