defmodule ClaudexChat.Chats.Attachment do
  @moduledoc """
  A file sent along with a user message, stored inline on the message.

  `file_id` is the id the Claude Files API gave the upload — the bytes live
  there, not here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          file_id: String.t(),
          filename: String.t(),
          mime_type: String.t() | nil,
          size_bytes: non_neg_integer() | nil
        }

  @primary_key false
  embedded_schema do
    field :file_id, :string
    field :filename, :string
    field :mime_type, :string
    field :size_bytes, :integer
  end

  @doc "Validates one attachment."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:file_id, :filename, :mime_type, :size_bytes])
    |> validate_required([:file_id, :filename])
  end
end
