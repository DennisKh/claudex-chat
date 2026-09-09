defmodule ClaudexChat.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    attach_claudex_logger()

    children = [
      ClaudexChatWeb.Telemetry,
      ClaudexChat.Repo,
      {DNSCluster, query: Application.get_env(:claudex_chat, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClaudexChat.PubSub},
      ClaudexChat.Models,
      ClaudexChatWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClaudexChat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp attach_claudex_logger do
    if Application.get_env(:claudex_chat, :claudex_logging, false) do
      Claudex.Telemetry.attach_default_logger()
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClaudexChatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
