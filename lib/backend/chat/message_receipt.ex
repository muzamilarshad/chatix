defmodule Backend.Chat.MessageReceipt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_receipts" do
    field :message_id, :id
    field :user_id, :id
    field :delivered_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:message_id, :user_id, :delivered_at, :read_at])
    |> validate_required([:message_id, :user_id])
  end
end
