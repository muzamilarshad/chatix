defmodule Backend.Chat.MessageUserHide do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_user_hides" do
    field :user_id, :id
    field :message_id, :id

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(hide, attrs) do
    hide
    |> cast(attrs, [:user_id, :message_id])
    |> validate_required([:user_id, :message_id])
    |> unique_constraint([:user_id, :message_id])
  end
end
