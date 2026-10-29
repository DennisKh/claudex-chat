defmodule ClaudexChat.Models.Model do
  @moduledoc """
  One model the chat can use, reduced to what the composer needs: what to call
  it, which line it belongs to, how it takes thinking, what it accepts as
  input, and whether it is on its way out.
  """

  @family_order ~w(fable mythos opus sonnet haiku)

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          max_output_tokens: pos_integer(),
          thinking_modes: [String.t()],
          accepts_images: boolean(),
          accepts_pdf: boolean(),
          accepts_code_execution: boolean(),
          line: String.t() | nil,
          created_at: DateTime.t() | nil,
          lifecycle: String.t() | nil,
          retires_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :display_name, :max_output_tokens, :thinking_modes]
  defstruct [
    :id,
    :display_name,
    :max_output_tokens,
    :thinking_modes,
    :line,
    :created_at,
    :lifecycle,
    :retires_at,
    accepts_images: false,
    accepts_pdf: false,
    accepts_code_execution: false
  ]

  @doc "The model's line as the picker labels it, e.g. `\"Opus\"`."
  @spec family_label(t()) :: String.t()
  def family_label(%__MODULE__{line: nil}), do: "Other"
  def family_label(%__MODULE__{line: line}), do: String.capitalize(line)

  @doc """
  Sort key placing the most capable model first.

  Lines rank by tier, and within a line the most recently released model
  leads. A model the API gave no release date sorts last in its line.
  """
  @spec rank(t()) :: {non_neg_integer(), integer(), String.t()}
  def rank(%__MODULE__{} = model) do
    {line_rank(model.line), -released(model.created_at), model.id}
  end

  @doc """
  What the picker says about a model's lifecycle: when a deprecated model
  retires, or nil for one that is active.
  """
  @spec lifecycle_note(t()) :: String.t() | nil
  def lifecycle_note(%__MODULE__{lifecycle: "deprecated", retires_at: %DateTime{} = at}),
    do: "retires #{Calendar.strftime(at, "%Y-%m-%d")}"

  def lifecycle_note(%__MODULE__{lifecycle: "deprecated"}), do: "deprecated"
  def lifecycle_note(%__MODULE__{}), do: nil

  @doc "Whether the model can be asked to think in this mode."
  @spec supports_thinking?(t(), String.t()) :: boolean()
  def supports_thinking?(%__MODULE__{thinking_modes: modes}, mode), do: mode in modes

  @doc "The MIME types this model accepts as an attachment."
  @spec accepted_types(t()) :: [String.t()]
  def accepted_types(%__MODULE__{} = model) do
    images = if model.accepts_images, do: ~w(image/png image/jpeg image/gif image/webp), else: []
    documents = if model.accepts_pdf, do: ~w(application/pdf), else: []

    images ++ documents ++ ~w(text/plain text/markdown)
  end

  defp line_rank(line), do: Enum.find_index(@family_order, &(&1 == line)) || length(@family_order)

  defp released(nil), do: 0
  defp released(%DateTime{} = at), do: DateTime.to_unix(at)
end
