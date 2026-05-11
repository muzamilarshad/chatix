defmodule Backend.Users.User do
  @moduledoc false
  use Ecto.Schema
  use Pow.Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :role, :string, default: "operator"

    pow_user_fields()

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 120)
    |> default_role()
    |> pow_changeset(attrs)
  end

  defp default_role(changeset) do
    role = get_field(changeset, :role)
    if is_binary(role) and role != "", do: changeset, else: put_change(changeset, :role, "operator")
  end
end
