defmodule ClaudexChat.Models.Capabilities do
  @moduledoc """
  Reads the `capabilities` map the Models API returns into the handful of
  facts the composer needs.
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
    %Entry{
      id: model.id,
      display_name: model.display_name || model.id,
      max_output_tokens: model.max_tokens || @default_max_output_tokens,
      thinking_modes: thinking_modes(model),
      accepts_images: Model.supports?(model, "image_input"),
      accepts_pdf: Model.supports?(model, "pdf_input"),
      accepts_code_execution: Model.supports?(model, "code_execution")
    }
  end

  defp thinking_modes(%Model{} = model) do
    ["off"] ++
      Enum.filter(~w(adaptive enabled), &Model.supports?(model, ["thinking", "types", &1]))
  end
end
