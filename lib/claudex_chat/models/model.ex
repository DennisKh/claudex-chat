defmodule ClaudexChat.Models.Model do
  @moduledoc """
  One model the chat can use, reduced to what the composer needs: what to call
  it, how it takes thinking, and what it accepts as input.
  """

  @family_order ~w(fable mythos opus sonnet haiku)

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          max_output_tokens: pos_integer(),
          thinking_modes: [String.t()],
          accepts_images: boolean(),
          accepts_pdf: boolean(),
          accepts_code_execution: boolean()
        }

  @enforce_keys [:id, :display_name, :max_output_tokens, :thinking_modes]
  defstruct [
    :id,
    :display_name,
    :max_output_tokens,
    :thinking_modes,
    accepts_images: false,
    accepts_pdf: false,
    accepts_code_execution: false
  ]

  @doc """
  The model's family and version, read off its id.

  `"claude-opus-4-5-20251101"` is `{"opus", {4, 5}}` — a dated snapshot suffix
  is part of the id, not the version.
  """
  @spec identify(t()) :: {String.t(), {integer(), integer()}}
  def identify(%__MODULE__{id: id}) do
    case id |> String.replace_prefix("claude-", "") |> String.split("-") do
      [family | rest] -> {family, version(rest)}
      [] -> {"other", {0, 0}}
    end
  end

  @doc "The family as the picker labels it, e.g. `\"Opus\"`."
  @spec family_label(t()) :: String.t()
  def family_label(%__MODULE__{} = model) do
    model |> identify() |> elem(0) |> String.capitalize()
  end

  @doc """
  Sort key placing the most capable model first.

  Families rank by tier, and within a family the newest version leads.
  """
  @spec rank(t()) :: {non_neg_integer(), integer(), integer(), String.t()}
  def rank(%__MODULE__{} = model) do
    {family, {major, minor}} = identify(model)

    {family_rank(family), -major, -minor, model.id}
  end

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

  defp family_rank(family) do
    Enum.find_index(@family_order, &(&1 == family)) || length(@family_order)
  end

  defp version(segments) do
    case segments |> Enum.flat_map(&number/1) |> Enum.reject(&(&1 >= 10_000)) do
      [major, minor | _rest] -> {major, minor}
      [major] -> {major, 0}
      [] -> {0, 0}
    end
  end

  defp number(segment) do
    case Integer.parse(segment) do
      {number, ""} -> [number]
      _not_a_number -> []
    end
  end
end
