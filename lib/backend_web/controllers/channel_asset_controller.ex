defmodule BackendWeb.ChannelAssetController do
  use BackendWeb, :controller

  alias Backend.Chat

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def attachments(conn, %{"channel_id" => channel_id} = params) do
    user_id = Pow.Plug.current_user(conn).id

    with {:ok, attachments} <-
           Chat.list_channel_attachments(channel_id, user_id, Map.get(params, "limit", 50)) do
      conn
      |> put_status(:ok)
      |> json(%{
        channel_id: channel_id,
        attachments: Enum.map(attachments, &serialize_attachment/1)
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

  def links(conn, %{"channel_id" => channel_id} = params) do
    user_id = Pow.Plug.current_user(conn).id

    with {:ok, links} <-
           Chat.list_channel_links(channel_id, user_id, Map.get(params, "limit", 100)) do
      conn
      |> put_status(:ok)
      |> json(%{
        channel_id: channel_id,
        links: Enum.map(links, &serialize_link/1)
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

  defp serialize_attachment(attachment) do
    caption =
      case attachment.message_body do
        nil -> ""
        body -> body |> to_string() |> String.trim()
      end

    %{
      id: attachment.id,
      message_id: attachment.message_id,
      storage_key: attachment.storage_key,
      filename: attachment.filename,
      content_type: attachment.content_type,
      size: attachment.size,
      seq_no: attachment.seq_no,
      inserted_at: DateTime.to_iso8601(attachment.inserted_at),
      caption: caption
    }
  end

  defp serialize_link(link) do
    body =
      case Map.get(link, :message_body) do
        nil -> ""
        b -> b |> to_string()
      end

    %{
      url: link.url,
      host: link.host,
      message_id: link.message_id,
      sender_id: link.sender_id,
      seq_no: link.seq_no,
      inserted_at: DateTime.to_iso8601(link.inserted_at),
      body: body
    }
  end
end
