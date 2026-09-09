defmodule ClaudexChat.Repo.Migrations.CreateChats do
  use Ecto.Migration

  def change do
    create table(:chats) do
      add :title, :string, null: false
      add :model, :string, null: false
      add :thinking_mode, :string, null: false, default: "off"
      add :thinking_budget, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:chats, [:updated_at])
  end
end
