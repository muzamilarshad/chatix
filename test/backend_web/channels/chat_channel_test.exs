defmodule BackendWeb.ChatChannelTest do
  use BackendWeb.ChannelCase, async: false

  alias Backend.Chat
  alias Backend.Users.User
  alias BackendWeb.UserSocket
  alias Pow.Store.CredentialsCache

  setup do
    {:ok, single_member_channel_fixture()}
  end

  test "socket connect rejects raw user_id without access token", %{user_id: user_id} do
    assert :error == connect(UserSocket, %{"user_id" => user_id})
  end

  test "join_channel and send_message emit accepted + message_event", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(user_id)})

    {:ok, join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}", %{
        "last_acked_seq" => 0
      })

    assert field(join_response, :status) == "joined"
    assert field(join_response, :channel_id) == channel_id

    ref =
      push(socket, "send_message", %{
        "client_msg_id" => "ws-1",
        "body" => "hello from channel"
      })

    assert_reply ref, :ok

    assert_push "message_accepted", accepted
    assert field(accepted, :client_msg_id) == "ws-1"
    assert field(accepted, :seq_no) == 1

    assert_broadcast "message_event", message
    assert field(message, :body) == "hello from channel"
    assert field(message, :seq_no) == 1
  end

  test "send_message with empty body and attachments succeeds (captionless media)", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(user_id)})

    {:ok, _join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}", %{
        "last_acked_seq" => 0
      })

    ref =
      push(socket, "send_message", %{
        "client_msg_id" => "att-only-ws-1",
        "body" => "",
        "message_type" => "attachment",
        "attachments" => [
          %{
            "storage_key" => "/uploads/ws-test-key.jpg",
            "filename" => "photo.jpg",
            "content_type" => "image/jpeg",
            "size" => 2048
          }
        ]
      })

    assert_reply ref, :ok
    assert_push "message_accepted", accepted
    assert field(accepted, :client_msg_id) == "att-only-ws-1"
    assert field(accepted, :seq_no) == 1
  end

  test "send_message accepts attachment size as float (JSON number edge case)", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(user_id)})

    {:ok, _join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}", %{
        "last_acked_seq" => 0
      })

    ref =
      push(socket, "send_message", %{
        "client_msg_id" => "att-float-size-1",
        "body" => "",
        "message_type" => "attachment",
        "attachments" => [
          %{
            "storage_key" => "/uploads/ws-float-key.jpg",
            "filename" => "photo.jpg",
            "content_type" => "image/jpeg",
            "size" => 2048.0
          }
        ]
      })

    assert_reply ref, :ok
    assert_push "message_accepted", accepted
    assert field(accepted, :client_msg_id) == "att-float-size-1"
  end

  test "duplicate send_message only emits accepted without duplicate broadcast", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(user_id)})

    {:ok, _join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}")

    payload = %{"client_msg_id" => "same-client-id", "body" => "idempotent body"}

    ref_1 = push(socket, "send_message", payload)
    assert_reply ref_1, :ok
    assert_push "message_accepted", accepted_1
    assert_broadcast "message_event", event_1

    ref_2 = push(socket, "send_message", payload)
    assert_reply ref_2, :ok
    assert_push "message_accepted", accepted_2
    refute_broadcast "message_event", ^event_1

    assert field(accepted_1, :server_msg_id) == field(accepted_2, :server_msg_id)
    assert field(accepted_1, :seq_no) == field(accepted_2, :seq_no)
  end

  test "join emits replay_batch for missed messages and supports ack events", %{
    channel_id: channel_id,
    user_id: user_id
  } do
    assert {:ok, _} = Chat.join_channel(channel_id, user_id, 0)

    assert {:ok, %{accepted: %{seq_no: 1}}} =
             Chat.send_message(channel_id, user_id, %{
               "client_msg_id" => "replay-1",
               "body" => "first"
             })

    assert {:ok, %{accepted: %{seq_no: 2}}} =
             Chat.send_message(channel_id, user_id, %{
               "client_msg_id" => "replay-2",
               "body" => "second"
             })

    assert {:ok, 1} = Chat.ack_channel_seq(channel_id, user_id, 1)

    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(user_id)})

    {:ok, _join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}")

    assert_push "replay_batch", replay
    assert field(replay, :from_seq) == 2
    assert field(replay, :to_seq) == 2
    assert Enum.map(field(replay, :events), &field(&1, :seq_no)) == [2]

    ref = push(socket, "ack_read", %{"seq_no" => 2})
    assert_reply ref, :ok, ack_reply
    assert field(ack_reply, :seq_no) == 2
  end

  test "ack_delivered and ack_read broadcast receipt events" do
    %{channel_id: channel_id, user_id: sender_id, other_user_id: receiver_id} =
      two_member_channel_fixture()

    assert {:ok, _} = Chat.join_channel(channel_id, sender_id, 0)
    assert {:ok, _} = Chat.join_channel(channel_id, receiver_id, 0)

    assert {:ok, %{accepted: %{seq_no: 1}}} =
             Chat.send_message(channel_id, sender_id, %{
               "client_msg_id" => "receipt-1",
               "body" => "needs receipts"
             })

    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(receiver_id)})

    {:ok, _join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}")

    ref_1 = push(socket, "ack_delivered", %{"seq_no" => 1})
    assert_reply ref_1, :ok
    assert_broadcast "receipt_event", delivered
    assert field(delivered, :event) == "delivered"

    ref_2 = push(socket, "ack_read", %{"seq_no" => 1})
    assert_reply ref_2, :ok
    assert_broadcast "receipt_event", read
    assert field(read, :event) == "read"
  end

  test "typing and presence events are broadcast", %{channel_id: channel_id, user_id: user_id} do
    {:ok, socket} = connect(UserSocket, %{"access_token" => auth_token_for_user(user_id)})

    {:ok, _join_response, socket} =
      subscribe_and_join(socket, BackendWeb.ChatChannel, "channel:#{channel_id}")

    typing_ref = push(socket, "typing", %{"is_typing" => true})
    assert_reply typing_ref, :ok
    assert_broadcast "typing_event", typing
    assert field(typing, :is_typing) == true

    presence_ref = push(socket, "presence_ping", %{"status" => "online"})
    assert_reply presence_ref, :ok
    assert_broadcast "presence_event", presence
    assert field(presence, :status) == "online"
  end

  defp auth_token_for_user(user_id) do
    pow_config = [otp_app: :backend]
    store_config = [backend: Pow.Store.Backend.EtsCache, pow_config: pow_config]
    token = Pow.UUID.generate()
    conn = Plug.Test.conn(:get, "/") |> Map.put(:secret_key_base, BackendWeb.Endpoint.config(:secret_key_base))
    signed_token = Pow.Plug.sign_token(conn, Atom.to_string(BackendWeb.APIAuthPlug), token, pow_config)

    user = %User{id: user_id, email: "ws-#{user_id}@chatix-lite.local", name: "WS User", role: "operator"}
    CredentialsCache.put(store_config, token, {user, []})

    signed_token
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
