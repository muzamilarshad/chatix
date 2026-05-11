defmodule Backend.Repo.Migrations.CreateMessageUserHides do
  use Ecto.Migration

  def change do
    create table(:message_user_hides) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :message_id, references(:messages, on_delete: :delete_all), null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:message_user_hides, [:user_id, :message_id])
    create index(:message_user_hides, [:user_id])
    create index(:message_user_hides, [:message_id])
  end
end
