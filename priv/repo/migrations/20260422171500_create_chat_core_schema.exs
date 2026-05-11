defmodule Backend.Repo.Migrations.CreateChatCoreSchema do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :name, :string, null: false
      add :role, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:workspaces) do
      add :name, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:channels) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :kind, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:channels, [:workspace_id])

    create table(:channel_members) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :last_read_seq, :bigint, null: false, default: 0
      add :joined_at, :utc_datetime_usec, null: false
    end

    create unique_index(:channel_members, [:channel_id, :user_id])
    create index(:channel_members, [:user_id])

    create table(:messages) do
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :sender_id, references(:users, on_delete: :nothing), null: false
      add :client_msg_id, :string, null: false
      add :seq_no, :bigint, null: false
      add :body, :text, null: false
      add :message_type, :string, null: false, default: "text"
      add :status, :string, null: false, default: "sent"
      add :edited_at, :utc_datetime_usec

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:messages, [:channel_id, :sender_id, :client_msg_id])
    create unique_index(:messages, [:channel_id, :seq_no])

    create table(:attachments) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :storage_key, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :integer, null: false
    end

    create index(:attachments, [:message_id])

    create table(:message_receipts) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :delivered_at, :utc_datetime_usec
      add :read_at, :utc_datetime_usec
    end

    create unique_index(:message_receipts, [:message_id, :user_id])
    create index(:message_receipts, [:user_id, :message_id])

    create table(:presence_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :status, :string, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create index(:presence_sessions, [:workspace_id, :status])
    create index(:presence_sessions, [:user_id])

    create table(:sync_cursors) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :channel_id, references(:channels, on_delete: :delete_all), null: false
      add :last_acked_seq, :bigint, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:sync_cursors, [:user_id, :channel_id])
  end
end
