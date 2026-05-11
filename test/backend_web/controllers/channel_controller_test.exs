defmodule BackendWeb.ChannelControllerTest do
  use BackendWeb.ConnCase, async: false

  alias Backend.Repo
  alias Backend.Users.User
  alias Pow.Store.CredentialsCache

  test "POST /api/channels creates channel and auto-adds creator", %{conn: conn} do
    now = now_iso()
    user_id = insert_user("creator", now)
    workspace_id = insert_workspace("ws-create", now)

    conn =
      conn
      |> authorize_as(user_id)
      |> post(~p"/api/channels", %{
        "workspace_id" => workspace_id,
        "name" => "backend-team",
        "kind" => "group"
      })

    payload = json_response(conn, 201)
    channel = payload["channel"]

    assert channel["workspace_id"] == workspace_id
    assert channel["name"] == "backend-team"
    assert channel["kind"] == "group"

    member_rows =
      Repo.query!(
        "SELECT user_id FROM channel_members WHERE channel_id = ?1 AND user_id = ?2",
        [channel["id"], user_id]
      ).rows

    assert member_rows == [[user_id]]
  end

  test "GET /api/channels lists only channels the user belongs to", %{conn: conn} do
    now = now_iso()
    workspace_id = insert_workspace("ws-list", now)
    user_id = insert_user("list-user", now)
    outsider_id = insert_user("outsider", now)
    user_channel_id = insert_channel(workspace_id, "mine", now)
    other_channel_id = insert_channel(workspace_id, "other", now)

    insert_channel_member(user_channel_id, user_id, now)
    insert_channel_member(other_channel_id, outsider_id, now)

    conn =
      conn
      |> authorize_as(user_id)
      |> get(~p"/api/channels")

    payload = json_response(conn, 200)
    channel_ids = Enum.map(payload["channels"], & &1["id"])

    assert user_channel_id in channel_ids
    refute other_channel_id in channel_ids
  end

  test "POST /api/channels/:channel_id/members adds member for existing member only", %{conn: conn} do
    now = now_iso()
    workspace_id = insert_workspace("ws-members", now)
    owner_id = insert_user("owner", now)
    target_id = insert_user("target", now)
    outsider_id = insert_user("outsider-actor", now)
    channel_id = insert_channel(workspace_id, "membership", now)
    insert_channel_member(channel_id, owner_id, now)

    added_conn =
      conn
      |> authorize_as(owner_id)
      |> post(~p"/api/channels/#{channel_id}/members", %{"user_id" => target_id})

    added_payload = json_response(added_conn, 201)
    assert added_payload["added"] == true
    assert added_payload["user_id"] == target_id

    forbidden_conn =
      build_conn()
      |> authorize_as(outsider_id)
      |> post(~p"/api/channels/#{channel_id}/members", %{"user_id" => target_id})

    assert json_response(forbidden_conn, 403)["error"] =~ "membership missing"
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp insert_workspace(prefix, now) do
    Repo.query!(
      "INSERT INTO workspaces (name, inserted_at) VALUES (?1, ?2)",
      ["#{prefix}-#{System.unique_integer([:positive])}", now]
    )

    %{rows: [[workspace_id]]} = Repo.query!("SELECT id FROM workspaces ORDER BY id DESC LIMIT 1")
    workspace_id
  end

  defp insert_user(prefix, now) do
    Repo.query!(
      "INSERT INTO users (email, name, role, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      ["#{prefix}-#{System.unique_integer([:positive])}@chatix-lite.local", "Test #{prefix}", "operator", now]
    )

    %{rows: [[user_id]]} = Repo.query!("SELECT id FROM users ORDER BY id DESC LIMIT 1")
    user_id
  end

  defp insert_channel(workspace_id, prefix, now) do
    Repo.query!(
      "INSERT INTO channels (workspace_id, name, kind, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      [workspace_id, "#{prefix}-#{System.unique_integer([:positive])}", "group", now]
    )

    %{rows: [[channel_id]]} = Repo.query!("SELECT id FROM channels ORDER BY id DESC LIMIT 1")
    channel_id
  end

  defp insert_channel_member(channel_id, user_id, now) do
    Repo.query!(
      "INSERT INTO channel_members (channel_id, user_id, last_read_seq, joined_at) VALUES (?1, ?2, 0, ?3)",
      [channel_id, user_id, now]
    )
  end

  defp authorize_as(conn, user_id) do
    pow_config = [otp_app: :backend]
    store_config = [backend: Pow.Store.Backend.EtsCache, pow_config: pow_config]
    token = Pow.UUID.generate()
    conn = %{conn | secret_key_base: BackendWeb.Endpoint.config(:secret_key_base)}
    signed_token = Pow.Plug.sign_token(conn, Atom.to_string(BackendWeb.APIAuthPlug), token, pow_config)

    user =
      %User{
        id: user_id,
        email: "test-#{user_id}@chatix-lite.local",
        name: "Test User",
        role: "operator"
      }

    CredentialsCache.put(store_config, token, {user, []})

    put_req_header(conn, "authorization", "Bearer #{signed_token}")
  end
end
