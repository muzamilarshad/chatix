defmodule Backend.ChatTest do
  use Backend.DataCase, async: false

  alias Backend.Chat
  alias Backend.Repo

  setup do
    {:ok, single_member_channel_fixture()}
  end

  test "joins channel and persists messages with monotonic seq numbers", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    assert {:ok, %{channel_id: ^channel_id, last_acked_seq: 0}} =
             Chat.join_channel(channel_id, user_id, 0)

    assert {:ok, %{accepted: accepted_1, message: message_1, duplicate: false}} =
             Chat.send_message(channel_id, user_id, %{
               "client_msg_id" => "client-1",
               "body" => "first message"
             })

    assert accepted_1.seq_no == 1
    assert message_1.seq_no == 1

    assert {:ok, %{accepted: accepted_2, message: message_2, duplicate: false}} =
             Chat.send_message(channel_id, user_id, %{
               "client_msg_id" => "client-2",
               "body" => "second message"
             })

    assert accepted_2.seq_no == 2
    assert message_2.seq_no == 2

    %{rows: [[count]]} =
      Repo.query!("SELECT COUNT(*) FROM messages WHERE channel_id = ?1", [channel_id])

    assert count == 2
  end

  test "returns existing message for duplicate send by same client_msg_id", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    assert {:ok, _} = Chat.join_channel(channel_id, user_id, 0)

    payload = %{"client_msg_id" => "dup-1", "body" => "idempotent send"}

    assert {:ok, %{accepted: accepted_1, duplicate: false}} =
             Chat.send_message(channel_id, user_id, payload)

    assert {:ok, %{accepted: accepted_2, duplicate: true}} =
             Chat.send_message(channel_id, user_id, payload)

    assert accepted_1.server_msg_id == accepted_2.server_msg_id
    assert accepted_1.seq_no == accepted_2.seq_no
  end

  test "hide_message_for_me removes message from list for that user only", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    assert {:ok, _} = Chat.join_channel(channel_id, user_id, 0)

    assert {:ok, %{accepted: accepted}} =
             Chat.send_message(channel_id, user_id, %{"client_msg_id" => "hide-me-1", "body" => "x"})

    mid = accepted.server_msg_id
    assert {:ok, [_one]} = Chat.list_channel_messages(channel_id, user_id, 10)

    assert {:ok, :hidden} = Chat.hide_message_for_me(user_id, mid)
    assert {:ok, []} = Chat.list_channel_messages(channel_id, user_id, 10)
  end

  test "replay on join returns only messages after last acked seq", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    assert {:ok, _} = Chat.join_channel(channel_id, user_id, 0)

    assert {:ok, %{accepted: %{seq_no: 1}}} =
             Chat.send_message(channel_id, user_id, %{"client_msg_id" => "r-1", "body" => "one"})

    assert {:ok, %{accepted: %{seq_no: 2}}} =
             Chat.send_message(channel_id, user_id, %{"client_msg_id" => "r-2", "body" => "two"})

    assert {:ok, %{accepted: %{seq_no: 3}}} =
             Chat.send_message(channel_id, user_id, %{"client_msg_id" => "r-3", "body" => "three"})

    assert {:ok, 2} = Chat.ack_channel_seq(channel_id, user_id, 2)
    assert {:ok, join_state} = Chat.join_channel(channel_id, user_id, 2)

    assert join_state.replay.from_seq == 3
    assert join_state.replay.to_seq == 3
    assert Enum.map(join_state.replay.events, & &1.seq_no) == [3]
    assert Enum.map(join_state.replay.events, & &1.body) == ["three"]
  end
end
