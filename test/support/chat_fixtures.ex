defmodule Backend.ChatFixtures do
  @moduledoc false

  alias Backend.Chat.ChannelSupervisor
  alias Backend.Repo

  def single_member_channel_fixture do
    now = now_iso()
    workspace_id = insert_workspace(now)
    user_id = insert_user("Channel User", "operator", "ch", now)
    channel_id = insert_channel(workspace_id, "group", "ch", now)

    insert_channel_member(channel_id, user_id, now)
    restart_channel_process(channel_id)

    %{channel_id: channel_id, user_id: user_id}
  end

  def two_member_channel_fixture do
    now = now_iso()
    workspace_id = insert_workspace(now)
    sender_id = insert_user("Sender", "operator", "sender", now)
    receiver_id = insert_user("Receiver", "operator", "receiver", now)
    channel_id = insert_channel(workspace_id, "group", "ch", now)

    insert_channel_member(channel_id, sender_id, now)
    insert_channel_member(channel_id, receiver_id, now)
    restart_channel_process(channel_id)

    %{channel_id: channel_id, user_id: sender_id, other_user_id: receiver_id}
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp insert_workspace(now) do
    Repo.query!("INSERT INTO workspaces (name, inserted_at) VALUES (?1, ?2)", [
      "WS #{System.unique_integer([:positive])}",
      now
    ])

    %{rows: [[workspace_id]]} = Repo.query!("SELECT id FROM workspaces ORDER BY id DESC LIMIT 1")
    workspace_id
  end

  defp insert_user(name, role, prefix, now) do
    Repo.query!(
      "INSERT INTO users (email, name, role, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      ["#{prefix}-#{System.unique_integer([:positive])}@chatix-lite.local", name, role, now]
    )

    %{rows: [[user_id]]} = Repo.query!("SELECT id FROM users ORDER BY id DESC LIMIT 1")
    user_id
  end

  defp insert_channel(workspace_id, kind, prefix, now) do
    Repo.query!(
      "INSERT INTO channels (workspace_id, name, kind, inserted_at) VALUES (?1, ?2, ?3, ?4)",
      [workspace_id, "#{prefix}-#{System.unique_integer([:positive])}", kind, now]
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

  defp restart_channel_process(channel_id) do
    if pid = GenServer.whereis(ChannelSupervisor.via(channel_id)) do
      Process.exit(pid, :kill)
    end

    :ok
  end
end
