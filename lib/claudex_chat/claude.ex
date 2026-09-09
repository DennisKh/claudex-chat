defmodule ClaudexChat.Claude do
  @moduledoc """
  Builds the Claudex client the rest of the app talks to.

  Connection settings come from `config :claudex`, so the key is named once in
  `config/runtime.exs`. Returns an error instead of raising when no key is
  configured, so the app still boots and can say so in the UI.
  """

  alias Claudex.Client

  @doc "Builds a client from application config."
  @spec client() :: {:ok, Client.t()} | {:error, :missing_api_key}
  def client do
    {:ok, Claudex.new()}
  rescue
    ArgumentError -> {:error, :missing_api_key}
  end

  @doc "Whether an API key is configured at all."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _client}, client())
end
