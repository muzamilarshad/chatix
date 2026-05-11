defmodule BackendWeb.APIAuthErrorHandler do
  use BackendWeb, :controller

  @spec call(Plug.Conn.t(), :not_authenticated) :: Plug.Conn.t()
  def call(conn, :not_authenticated) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized", code: "auth_required"})
  end
end
