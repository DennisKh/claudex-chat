defmodule ClaudexChat.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :chat_id, references(:chats, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false, default: ""
      add :thinking, :text
      add :thinking_signature, :text
      add :attachments, :map, null: false, default: "[]"
      add :model, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cache_read_tokens, :integer
      add :cache_creation_tokens, :integer
      add :duration_ms, :integer
      add :stop_reason, :string
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:chat_id, :id])
  end
end
