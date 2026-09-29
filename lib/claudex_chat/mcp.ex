defmodule ClaudexChat.MCP do
  @moduledoc """
  The remote MCP servers this app offers, and the one place the beta string
  lives.

  A server here runs on Anthropic's own infrastructure during the reply —
  the API connects to it, calls its tools, and comes back with the result —
  so nothing in this app executes anything and there is no approval gate,
  unlike the local file tools.
  """

  alias Claudex.MCP.Server

  @beta "mcp-client-2025-11-20"

  @servers [
    %{
      name: "deepwiki",
      label: "DeepWiki",
      url: "https://mcp.deepwiki.com/mcp",
      description: "Documentation and answers about any public GitHub repository."
    }
  ]

  @type server :: %{name: String.t(), label: String.t(), url: String.t(), description: String.t()}

  @doc "The catalogue of servers a chat can enable."
  @spec servers() :: [server()]
  def servers, do: @servers

  @doc "The beta header Anthropic's MCP connector needs on the request."
  @spec beta() :: String.t()
  def beta, do: @beta

  @doc """
  The catalogue entries named in `names`.

  A name that isn't in the catalogue is left out rather than raising, so a
  chat that enabled a server before it was removed from the list doesn't
  break — it just stops sending it.
  """
  @spec enabled([String.t()]) :: [server()]
  def enabled(names) when is_list(names) do
    Enum.filter(@servers, &(&1.name in names))
  end

  @doc """
  The request parameters for the servers named in `names`.

  Empty for `[]`, so a chat with nothing enabled sends no `mcp_servers` key
  at all. Otherwise pairs every server with exactly one `mcp_toolset`, which
  is what tells the API which tools on that server it may call.
  """
  @spec request_params([String.t()]) :: map()
  def request_params([]), do: %{}

  def request_params(names) when is_list(names) do
    case enabled(names) do
      [] ->
        %{}

      servers ->
        %{
          mcp_servers: Enum.map(servers, &to_server_struct/1),
          tools: Enum.map(servers, &to_toolset/1)
        }
    end
  end

  defp to_server_struct(%{name: name, url: url}) do
    %Server{name: name, url: url}
  end

  defp to_toolset(%{name: name}), do: %{type: "mcp_toolset", mcp_server_name: name}
end
