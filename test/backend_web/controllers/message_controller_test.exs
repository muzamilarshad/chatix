defmodule BackendWeb.MessageControllerTest do
  use BackendWeb.ConnCase, async: false

  alias Backend.Repo
  alias Backend.Users.User
  alias Pow.Store.CredentialsCache

  test "GET /api/channels/:channel_id/messages returns ordered persisted messages", %{conn: conn} do
    %{channel_id: channel_id, user_id: user_id} = insert_channel_fixture()
    insert_message(channel_id, user_id, "m1", 1, "hello")
    insert_message(channel_id, user_id, "m2", 2, "hi")

    conn =
      conn
      |> authorize_as(user_id)
      |> get(~p"/api/channels/#{channel_id}/messages")

    payload = json_response(conn, 200)

    assert length(payload["messages"]) == 2
    assert Enum.map(payload["messages"], & &1["seq_no"]) == [1, 2]
    assert Enum.map(payload["messages"], & &1["body"]) == ["hello", "hi"]
  end

  test "GET /api/channels/:channel_id/messages rejects non-members", %{conn: conn} do
    %{channel_id: channel_id, outsider_user_id: outsider_user_id} = insert_channel_fixture()

    conn =
      conn
      |> authorize_as(outsider_user_id)
      |> get(~p"/api/channels/#{channel_id}/messages")

    assert json_response(conn, 403)["error"] =~ "membership missing"
  end

  defp insert_channel_fixture do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO workspaces (name, inserted_at) VALUES (?1, ?2)",
      ["WS #{System.unique_integer([:positive])}", now]
    )

    %{rows: [[workspace_id]]} = Repo.query!("SELECT id FROM workspaces ORDER BY id DESC LIMIT 1")

    Repo.query!(
      "INSERT INTO users (email, name, role, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      [
        "hist-#{System.unique_integer([:positive])}@chatix-lite.local",
        "History User",
        "operator",
        now
      ]
    )

    %{rows: [[user_id]]} = Repo.query!("SELECT id FROM users ORDER BY id DESC LIMIT 1")

    Repo.query!(
      "INSERT INTO channels (workspace_id, name, kind, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      [workspace_id, "history-#{System.unique_integer([:positive])}", "group", now]
    )

    %{rows: [[channel_id]]} = Repo.query!("SELECT id FROM channels ORDER BY id DESC LIMIT 1")

    Repo.query!(
      "INSERT INTO channel_members (channel_id, user_id, last_read_seq, joined_at) VALUES (?1, ?2, 0, ?3)",
      [channel_id, user_id, now]
    )

    Repo.query!(
      "INSERT INTO users (email, name, role, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      [
        "outsider-#{System.unique_integer([:positive])}@chatix-lite.local",
        "Outsider User",
        "operator",
        now
      ]
    )

    %{rows: [[outsider_user_id]]} = Repo.query!("SELECT id FROM users ORDER BY id DESC LIMIT 1")

    %{channel_id: channel_id, user_id: user_id, outsider_user_id: outsider_user_id}
  end

  defp insert_message(channel_id, sender_id, client_msg_id, seq_no, body) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    Repo.query!(
      """
      INSERT INTO messages (channel_id, sender_id, client_msg_id, seq_no, body, message_type, status, inserted_at)
      VALUES (?1, ?2, ?3, ?4, ?5, 'text', 'sent', ?6)
      """,
      [channel_id, sender_id, client_msg_id, seq_no, body, now]
    )
  end

  defp authorize_as(conn, user_id) do
    pow_config = [otp_app: :backend]
    store_config = [backend: Pow.Store.Backend.EtsCache, pow_config: pow_config]
    token = Pow.UUID.generate()
    conn = %{conn | secret_key_base: BackendWeb.Endpoint.config(:secret_key_base)}

    signed_token =
      Pow.Plug.sign_token(conn, Atom.to_string(BackendWeb.APIAuthPlug), token, pow_config)

    user = %User{
      id: user_id,
      email: "test-#{user_id}@chatix-lite.local",
      name: "Test User",
      role: "operator"
    }

    CredentialsCache.put(store_config, token, {user, []})

    put_req_header(conn, "authorization", "Bearer #{signed_token}")
  end
end
