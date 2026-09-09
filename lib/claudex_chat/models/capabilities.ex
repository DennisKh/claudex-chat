defmodule ClaudexChat.Models.Capabilities do
  @moduledoc """
  Reads the `capabilities` map the Models API returns into the handful of
  facts the composer needs.

  The map is deep and grows over time, so every lookup treats a missing branch
  as unsupported rather than assuming a shape.
  """

  alias Claudex.Model
  alias ClaudexChat.Models.Model, as: Entry

  @default_max_output_tokens 8_192

  @doc """
  Turns a model from the Models API into the entry the composer uses.

  `"off"` is always offered: it means the request carries no `thinking`
  parameter at all, which every model accepts.
  """
  @spec to_entry(Model.t()) :: Entry.t()
  def to_entry(%Model{} = model) do
    capabilities = model.capabilities || %{}

    %Entry{
      id: model.id,
      display_name: model.display_name || model.id,
      max_output_tokens: model.max_tokens || @default_max_output_tokens,
      thinking_modes: thinking_modes(capabilities),
      accepts_images: supported?(capabilities, ["image_input"]),
      accepts_pdf: supported?(capabilities, ["pdf_input"]),
      accepts_code_execution: supported?(capabilities, ["code_execution"])
    }
  end

  defp thinking_modes(capabilities) do
    ["off"] ++
      Enum.filter(~w(adaptive enabled), fn type ->
        supported?(capabilities, ["thinking", "types", type])
      end)
  end

  defp supported?(capabilities, path) do
    case get_in(capabilities, path) do
      %{"supported" => supported} -> supported == true
      _missing -> false
    end
  end
end
