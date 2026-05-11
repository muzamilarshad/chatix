defmodule BackendWeb.MessageController do
  use BackendWeb, :controller

  alias Backend.Chat

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def index(conn, %{"channel_id" => channel_id} = params) do
    user_id = Pow.Plug.current_user(conn).id

    with {:ok, messages} <-
           Chat.list_channel_messages(channel_id, user_id, Map.get(params, "limit", 100)) do
      conn
      |> put_status(:ok)
      |> json(%{
        channel_id: channel_id,
        messages: Enum.map(messages, &serialize_message/1)
      })
    else
      {:error, :not_found_or_not_member} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "channel not found or membership missing"})

      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid channel_id"})
    end
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      channel_id: message.channel_id,
      sender_id: message.sender_id,
      client_msg_id: message.client_msg_id,
      seq_no: message.seq_no,
      body: message.body,
      message_type: message.message_type,
      attachments: Map.get(message, :attachments, []),
      status: message.status,
      send_state: Map.get(message, :send_state, "sent"),
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end
end
