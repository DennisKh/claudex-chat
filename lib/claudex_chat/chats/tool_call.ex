defmodule ClaudexChat.Chats.ToolCall do
  @moduledoc """
  One tool Claude asked to run, and what came of it.

  A call starts `"pending"` and stays that way until a human approves or
  denies it. `output` is what goes back to Claude as the `tool_result` — the
  tool's return value, or the reason it didn't run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending approved denied failed)

  @type t :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          input: map(),
          status: String.t(),
          output: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :call_id, :string
    field :name, :string
    field :input, :map, default: %{}
    field :status, :string, default: "pending"
    field :output, :string
  end

  @doc "The statuses a call can be in."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Whether the call is still waiting on a human."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: status}), do: status == "pending"

  @doc "Whether the result should go back to Claude flagged as an error."
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{status: status}), do: status in ~w(denied failed)

  @doc "Validates one tool call."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, [:call_id, :name, :input, :status, :output])
    |> validate_required([:call_id, :name, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
