defmodule BackendWeb.ChannelController do
  use BackendWeb, :controller

  alias Backend.Chat

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def index(conn, params) do
    user_id = Pow.Plug.current_user(conn).id

    with {:ok, channels} <- Chat.list_user_channels(user_id, Map.get(params, "limit", 100)) do
      conn
      |> put_status(:ok)
      |> json(%{channels: Enum.map(channels, &serialize_channel/1)})
    else
      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid user id"})
    end
  end

  def create(conn, %{"workspace_id" => workspace_id, "name" => _} = params) do
    user_id = Pow.Plug.current_user(conn).id

    case Chat.create_channel(workspace_id, user_id, params) do
      {:ok, channel} ->
        conn
        |> put_status(:created)
        |> json(%{channel: serialize_channel(channel)})

      {:error, :workspace_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "workspace not found"})

      {:error, :invalid_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid workspace_id"})

      {:error, :invalid_channel_name} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "channel name is required and must be <= 120 chars"})

      {:error, :invalid_channel_kind} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "channel kind must be one of: group, dm"})

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "unable to create channel"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "workspace_id and name are required"})
  end

  defp serialize_channel(channel) do
    %{
      id: channel.id,
      workspace_id: channel.workspace_id,
      name: channel.name,
      kind: channel.kind,
      inserted_at: serialize_inserted_at(channel.inserted_at)
    }
  end

  defp serialize_inserted_at(%DateTime{} = ts), do: DateTime.to_iso8601(ts)

  defp serialize_inserted_at(%NaiveDateTime{} = ts) do
    ts
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp serialize_inserted_at(ts) when is_binary(ts), do: ts
end
