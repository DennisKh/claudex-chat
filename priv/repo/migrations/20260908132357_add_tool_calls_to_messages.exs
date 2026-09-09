defmodule ClaudexChat.Repo.Migrations.AddToolCallsToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :tool_calls, :map, null: false, default: "[]"
    end
  end
end
