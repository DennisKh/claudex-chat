defmodule ClaudexChat.Chats.Chat do
  @moduledoc """
  One conversation: its title, the model it last used, and how thinking is
  configured for it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClaudexChat.Chats.Message

  @thinking_modes ~w(off adaptive enabled)
  @min_thinking_budget 1024

  @type t :: %__MODULE__{
          id: integer() | nil,
          title: String.t(),
          model: String.t(),
          thinking_mode: String.t(),
          thinking_budget: pos_integer() | nil,
          messages: [Message.t()] | Ecto.Association.NotLoaded.t()
        }

  schema "chats" do
    field :title, :string
    field :model, :string
    field :thinking_mode, :string, default: "off"
    field :thinking_budget, :integer

    has_many :messages, Message, preload_order: [asc: :id]

    timestamps(type: :utc_datetime)
  end

  @doc "The thinking modes a chat may be set to."
  @spec thinking_modes() :: [String.t()]
  def thinking_modes, do: @thinking_modes

  @doc """
  Validates a chat.

  A chat in `"enabled"` thinking mode needs a budget of at least
  #{@min_thinking_budget} tokens — the API rejects anything smaller.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [:title, :model, :thinking_mode, :thinking_budget])
    |> validate_required([:title, :model, :thinking_mode])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:thinking_mode, @thinking_modes)
    |> validate_thinking_budget()
  end

  defp validate_thinking_budget(changeset) do
    case get_field(changeset, :thinking_mode) do
      "enabled" ->
        changeset
        |> validate_required([:thinking_budget])
        |> validate_number(:thinking_budget, greater_than_or_equal_to: @min_thinking_budget)

      _mode ->
        put_change(changeset, :thinking_budget, nil)
    end
  end
end
