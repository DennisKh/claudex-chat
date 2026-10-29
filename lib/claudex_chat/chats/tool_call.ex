defmodule ClaudexChat.Chats.ToolCall do
  @moduledoc """
  One tool Claude asked to run, and what came of it.

  A call starts `"pending"`. A human's decision makes it `"approved"` or
  `"denied"`, and `Claudex.ToolRunner` answers it when the conversation
  resumes: an approved call that raised ends up `"failed"`.

  `result` is the `tool_result` exactly as it went back to Claude, image and
  document blocks included, so the history replays it unchanged. It is nil
  until the call has been answered. `output` is the same result as text, for
  the approval card.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(pending approved denied failed)

  @type t :: %__MODULE__{
          call_id: String.t(),
          name: String.t(),
          input: map(),
          status: String.t(),
          output: String.t() | nil,
          result: map() | nil
        }

  @primary_key false
  embedded_schema do
    field :call_id, :string
    field :name, :string
    field :input, :map, default: %{}
    field :status, :string, default: "pending"
    field :output, :string
    field :result, :map
  end

  @doc "The statuses a call can be in."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Whether the call is still waiting on a human."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: status}), do: status == "pending"

  @doc "Whether Claude has been sent an answer to this call."
  @spec answered?(t()) :: boolean()
  def answered?(%__MODULE__{result: result}), do: not is_nil(result)

  @doc "Validates one tool call."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, [:call_id, :name, :input, :status, :output, :result])
    |> validate_required([:call_id, :name, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
