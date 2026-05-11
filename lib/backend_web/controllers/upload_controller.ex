defmodule BackendWeb.UploadController do
  use BackendWeb, :controller

  alias Backend.Chat
  alias Backend.Uploads.Storage

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def create(conn, params) do
    user_id = Pow.Plug.current_user(conn).id

    with %{"channel_id" => channel_id, "file" => upload} <- params,
         true <- Chat.can_access_channel?(channel_id, user_id),
         {:ok, asset} <- Storage.save_upload(upload) do
      conn
      |> put_status(:created)
      |> json(asset)
    else
      %{} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "channel_id and file are required"})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "channel not found or membership missing"})

      {:error, :file_too_large} ->
        conn
        |> put_status(:payload_too_large)
        |> json(%{
          error: "file exceeds max upload size",
          max_bytes: Storage.max_upload_bytes()
        })

      {:error, :unsupported_media_type} ->
        conn
        |> put_status(:unsupported_media_type)
        |> json(%{
          error: "unsupported file type",
          allowed_extensions: Storage.allowed_extensions(),
          allowed_content_types: Storage.allowed_content_types()
        })

      {:error, :invalid_upload} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid upload payload"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "unable to store upload"})
    end
  end
end
