defmodule BackendWeb.MessageHideController do
  use BackendWeb, :controller

  alias Backend.Chat

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def create(conn, %{"message_id" => message_id}) do
    user_id = Pow.Plug.current_user(conn).id

    with {:ok, _} <- Chat.hide_message_for_me(user_id, message_id) do
      conn
      |> put_status(:ok)
      |> json(%{status: "hidden", message_id: message_id})
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "message not found"})

      {:error, :not_found_or_not_member} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "not allowed to hide this message"})

      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid message_id"})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "could not record hide"})
    end
  end
end
