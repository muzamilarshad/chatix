defmodule Backend.Chat.SyncCursor do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "sync_cursors" do
    field :id, :id
    field :user_id, :id
    field :channel_id, :id
    field :last_acked_seq, :integer
    field :updated_at, :utc_datetime_usec
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:user_id, :channel_id, :last_acked_seq, :updated_at])
    |> validate_required([:user_id, :channel_id, :last_acked_seq, :updated_at])
  end
end
