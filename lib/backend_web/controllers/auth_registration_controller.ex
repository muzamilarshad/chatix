defmodule BackendWeb.AuthRegistrationController do
  use BackendWeb, :controller

  alias Ecto.Changeset

  def create(conn, %{"email" => _, "password" => _, "name" => _} = params) do
    attrs = normalize_registration_params(params)

    conn
    |> Pow.Plug.create_user(attrs)
    |> case do
      {:ok, user, conn} ->
        conn
        |> put_status(:created)
        |> json(%{
          user: %{
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role
          },
          access_token: conn.private.api_access_token
        })

      {:error, changeset, conn} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "registration_failed",
          details: normalize_changeset_errors(changeset)
        })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "email, password, and name are required"})
  end

  defp normalize_registration_params(params) do
    params
    |> Map.take(["email", "password", "name"])
    |> Map.put("role", "operator")
    |> Map.put("password_confirmation", params["password_confirmation"] || params["password"])
  end

  defp normalize_changeset_errors(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
