defmodule BackendWeb.WorkspaceControllerTest do
  use BackendWeb.ConnCase, async: false

  test "GET /api/workspaces lists available workspaces for authenticated user", %{conn: conn} do
    token = register_and_fetch_token(conn, "workspace-list")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/workspaces")

    payload = json_response(conn, 200)
    assert is_list(payload["workspaces"])
    assert length(payload["workspaces"]) >= 1
  end

  test "POST /api/workspaces creates a workspace", %{conn: conn} do
    token = register_and_fetch_token(conn, "workspace-create")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/api/workspaces", %{"name" => "Operations Core"})

    payload = json_response(conn, 201)
    assert payload["workspace"]["name"] == "Operations Core"
    assert is_integer(payload["workspace"]["id"])
  end

  defp register_and_fetch_token(conn, prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@chatix-lite.local"

    conn =
      post(conn, ~p"/api/auth/register", %{
        "email" => email,
        "password" => "S3curePass123!",
        "name" => "Workspace Tester"
      })

    payload = json_response(conn, 201)
    payload["access_token"]
  end
end
