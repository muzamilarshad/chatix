defmodule BackendWeb.ChannelMemberController do
  use BackendWeb, :controller

  alias Backend.Chat

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def create(conn, %{"channel_id" => channel_id, "user_id" => member_user_id}) do
    actor_user_id = Pow.Plug.current_user(conn).id

    case Chat.add_channel_member(channel_id, actor_user_id, member_user_id) do
      {:ok, payload} ->
        status = if payload.added, do: :created, else: :ok

        conn
        |> put_status(status)
        |> json(%{
          channel_id: payload.channel_id,
          user_id: payload.user_id,
          added: payload.added
        })

      {:error, :not_found_or_not_member} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "channel not found or membership missing"})

      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid channel_id or user_id"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "unable to add member"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "user_id is required"})
  end
end
