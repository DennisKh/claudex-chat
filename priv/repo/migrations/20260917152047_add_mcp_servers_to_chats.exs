defmodule ClaudexChat.Repo.Migrations.AddMcpServersToChats do
  use Ecto.Migration

  def change do
    alter table(:chats) do
      add :mcp_servers, {:array, :string}, null: false, default: []
    end
  end
end
