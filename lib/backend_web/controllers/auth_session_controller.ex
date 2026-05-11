defmodule BackendWeb.AuthSessionController do
  use BackendWeb, :controller

  def create(conn, %{"email" => _, "password" => _} = params) do
    credentials = %{"email" => params["email"], "password" => params["password"]}

    conn
    |> Pow.Plug.authenticate_user(credentials)
    |> case do
      {:ok, conn} ->
        user = Pow.Plug.current_user(conn)

        conn
        |> put_status(:ok)
        |> json(%{
          user: %{
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role
          },
          access_token: conn.private.api_access_token
        })

      {:error, conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid email or password"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "email and password are required"})
  end

  def delete(conn, _params) do
    conn
    |> Pow.Plug.delete()
    |> put_status(:ok)
    |> json(%{status: "logged_out"})
  end
end
