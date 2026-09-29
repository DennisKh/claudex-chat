defmodule ClaudexChat.MCPTest do
  use ExUnit.Case, async: true

  alias ClaudexChat.MCP

  describe "request_params/1" do
    test "empty for no servers enabled" do
      assert MCP.request_params([]) == %{}
    end

    test "ignores a name that isn't in the catalogue" do
      assert MCP.request_params(["not-a-real-server"]) == %{}
    end

    test "pairs each enabled server with exactly one mcp_toolset" do
      params = MCP.request_params(["deepwiki"])

      assert [%Claudex.MCP.Server{name: "deepwiki", url: "https://mcp.deepwiki.com/mcp"}] =
               params.mcp_servers

      assert params.tools == [%{type: "mcp_toolset", mcp_server_name: "deepwiki"}]
    end
  end

  describe "enabled/1" do
    test "ignores an unknown name rather than raising" do
      assert MCP.enabled(["deepwiki", "not-a-real-server"]) == MCP.enabled(["deepwiki"])
    end
  end
end
