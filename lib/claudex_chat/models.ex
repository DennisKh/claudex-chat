defmodule ClaudexChat.Models do
  @moduledoc """
  The model catalogue behind the composer's picker.

  Asks the Models API once at startup for every model that can still be
  used, active or deprecated, across as many pages as there are, and holds
  the answer. Until that lands —
  and if it fails, or no API key is configured — a built-in list is served
  instead, so the UI always has something to show. `source/0` says which one
  you're looking at.

  Set `config :claudex_chat, ClaudexChat.Models, refresh: false` to skip the
  startup request; the test suite does, so it never touches the network.
  """

  use GenServer

  alias Claudex.Models, as: API
  alias ClaudexChat.Claude
  alias ClaudexChat.Models.{Capabilities, Model}

  @default_id "claude-opus-5"

  @fallback [
    %Model{
      id: "claude-opus-5",
      line: "opus",
      display_name: "Claude Opus 5",
      max_output_tokens: 128_000,
      thinking_modes: ~w(off adaptive),
      accepts_images: true,
      accepts_pdf: true,
      accepts_code_execution: true
    },
    %Model{
      id: "claude-sonnet-5",
      line: "sonnet",
      display_name: "Claude Sonnet 5",
      max_output_tokens: 128_000,
      thinking_modes: ~w(off adaptive),
      accepts_images: true,
      accepts_pdf: true,
      accepts_code_execution: true
    },
    %Model{
      id: "claude-haiku-4-5",
      line: "haiku",
      display_name: "Claude Haiku 4.5",
      max_output_tokens: 64_000,
      thinking_modes: ~w(off enabled),
      accepts_images: true,
      accepts_pdf: true,
      accepts_code_execution: false
    }
  ]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every model the picker offers, most capable first."
  @spec list() :: [Model.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  The same models, split into the picker's family groups.

  Groups run from the most capable family down, and each holds its own models
  newest first.
  """
  @spec grouped() :: [{String.t(), [Model.t()]}]
  def grouped do
    list()
    |> Enum.chunk_by(&Model.family_label/1)
    |> Enum.map(fn [model | _rest] = models -> {Model.family_label(model), models} end)
  end

  @doc "Whether the catalogue came from the API or from the built-in list."
  @spec source() :: :api | :fallback
  def source, do: GenServer.call(__MODULE__, :source)

  @doc "Looks up one model by id."
  @spec fetch(String.t()) :: {:ok, Model.t()} | {:error, :not_found}
  def fetch(id) do
    case Enum.find(list(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @doc """
  The model a new chat starts on.

  Opus 5 unless it isn't on offer, in which case the most capable model that
  is. The top of the list is the Fable tier, which is deliberately not a
  default — it costs more and is meant to be chosen.
  """
  @spec default() :: Model.t()
  def default do
    models = list()

    Enum.find(models, hd(models), &(&1.id == @default_id))
  end

  @doc "The built-in catalogue, used when the API can't be reached."
  @spec fallback() :: [Model.t()]
  def fallback, do: @fallback

  @impl GenServer
  def init(_opts) do
    state = %{models: order(@fallback), source: :fallback}

    if refresh?(), do: {:ok, state, {:continue, :refresh}}, else: {:ok, state}
  end

  @impl GenServer
  def handle_continue(:refresh, state) do
    case fetch_from_api() do
      {:ok, []} -> {:noreply, state}
      {:ok, models} -> {:noreply, %{models: models, source: :api}}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:list, _from, state), do: {:reply, state.models, state}
  def handle_call(:source, _from, state), do: {:reply, state.source, state}

  defp order(models), do: Enum.sort_by(models, &Model.rank/1)

  defp refresh? do
    :claudex_chat
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:refresh, true)
  end

  defp fetch_from_api do
    with {:ok, client} <- Claude.client() do
      models =
        client
        |> API.stream!(lifecycle: ~w(active deprecated))
        |> Enum.map(&Capabilities.to_entry/1)

      {:ok, order(models)}
    end
  rescue
    error in Claudex.Error -> {:error, error}
  end
end
