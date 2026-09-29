defmodule ClaudexChat.Repo.Migrations.AddContentBlocksToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :content_blocks, :map, null: false, default: "[]"
    end
  end
end
