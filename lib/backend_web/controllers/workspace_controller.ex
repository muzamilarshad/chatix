defmodule BackendWeb.WorkspaceController do
  use BackendWeb, :controller

  alias Backend.Chat

  def options(conn, _params) do
    send_resp(conn, 204, "")
  end

  def index(conn, params) do
    with {:ok, workspaces} <- Chat.list_workspaces(Map.get(params, "limit", 100)) do
      conn
      |> put_status(:ok)
      |> json(%{workspaces: Enum.map(workspaces, &serialize_workspace/1)})
    end
  end

  def create(conn, %{"name" => _} = params) do
    with {:ok, workspace} <- Chat.create_workspace(params) do
      conn
      |> put_status(:created)
      |> json(%{workspace: serialize_workspace(workspace)})
    else
      {:error, :invalid_workspace_name} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid workspace name"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "name is required"})
  end

  defp serialize_workspace(workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      inserted_at: timestamp_to_iso8601(workspace.inserted_at)
    }
  end

  defp timestamp_to_iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_to_iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp timestamp_to_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _ -> value
    end
  end

  defp timestamp_to_iso8601(value), do: to_string(value)
end
