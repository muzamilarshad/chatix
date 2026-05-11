defmodule BackendWeb.ChatChannel do
  use BackendWeb, :channel

  alias Backend.Chat
  alias Backend.Security.RateLimiter

  @impl true
  def join("channel:" <> channel_id, %{"last_acked_seq" => last_acked_seq}, socket) do
    handle_join(channel_id, last_acked_seq, socket)
  end

  def join("channel:" <> channel_id, _params, socket) do
    handle_join(channel_id, 0, socket)
  end

  @impl true
  def handle_in("send_message", payload, socket) do
    with :ok <- enforce_rate_limit(socket, "send_message", 40, 60_000) do
      channel_id = socket.assigns.channel_id
      user_id = socket.assigns.user_id

      case Chat.send_message(channel_id, user_id, payload) do
        {:ok, %{duplicate: duplicate, accepted: accepted_payload, message: message_payload}} ->
          push(socket, "message_accepted", accepted_payload)

          unless duplicate do
            broadcast!(socket, "message_event", message_payload)
          end

          {:reply, :ok, socket}

        {:error, :invalid_payload} ->
          {:reply,
           {:error,
            %{
              code: "invalid_payload",
              reason: "client_msg_id and either non-empty body or attachments are required"
            }}, socket}

        {:error, :not_found_or_not_member} ->
          {:reply,
           {:error, %{code: "forbidden", reason: "channel not found or membership missing"}},
           socket}

        {:error, :persist_timeout} ->
          {:reply,
           {:error,
            %{code: "send_timeout", reason: "message persistence timed out; please retry"}},
           socket}

        {:error, _reason} ->
          {:reply, {:error, %{code: "send_failed", reason: "unable to persist message"}}, socket}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("ack_delivered", %{"seq_no" => seq_no}, socket) do
    with :ok <- enforce_rate_limit(socket, "ack_delivered", 300, 60_000) do
      handle_ack(seq_no, :delivered, socket)
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("ack_read", %{"seq_no" => seq_no}, socket) do
    with :ok <- enforce_rate_limit(socket, "ack_read", 300, 60_000) do
      handle_ack(seq_no, :read, socket)
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("typing", %{"is_typing" => is_typing}, socket) do
    with :ok <- enforce_rate_limit(socket, "typing", 240, 60_000) do
      case Chat.typing_event(socket.assigns.channel_id, socket.assigns.user_id, is_typing) do
        {:ok, payload} ->
          broadcast_from!(socket, "typing_event", payload)
          {:reply, :ok, socket}

        {:error, :not_found_or_not_member} ->
          {:reply,
           {:error, %{code: "forbidden", reason: "channel not found or membership missing"}},
           socket}

        {:error, _reason} ->
          {:reply, {:error, %{code: "typing_failed", reason: "unable to process typing state"}},
           socket}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("presence_ping", %{"status" => status}, socket) do
    with :ok <- enforce_rate_limit(socket, "presence_ping", 120, 60_000) do
      case Chat.presence_ping(socket.assigns.channel_id, socket.assigns.user_id, status) do
        {:ok, payload} ->
          broadcast!(socket, "presence_event", payload)
          {:reply, {:ok, payload}, socket}

        {:error, :not_found_or_not_member} ->
          {:reply,
           {:error, %{code: "forbidden", reason: "channel not found or membership missing"}},
           socket}

        {:error, _reason} ->
          {:reply, {:error, %{code: "presence_failed", reason: "unable to update presence"}},
           socket}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("presence_ping", _payload, socket) do
    handle_in("presence_ping", %{"status" => "online"}, socket)
  end

  def handle_in(_event, _payload, socket) do
    {:reply,
     {:error, %{code: "unsupported_event", reason: "event not implemented in this milestone"}},
     socket}
  end

  defp handle_join(channel_id, last_acked_seq, socket) do
    case Chat.join_channel(channel_id, socket.assigns.user_id, last_acked_seq) do
      {:ok, join_state} ->
        replay = Map.get(join_state, :replay, %{events: []})
        socket = assign(socket, :channel_id, join_state.channel_id)

        if replay.events != [] do
          send(self(), {:replay_batch, replay})
        end

        response =
          join_state
          |> Map.delete(:replay)
          |> Map.put(:status, "joined")

        {:ok, response, socket}

      {:error, :not_found_or_not_member} ->
        {:error, %{code: "forbidden", reason: "channel not found or membership missing"}}

      {:error, :invalid_id} ->
        {:error, %{code: "invalid_channel_id", reason: "channel_id must be an integer"}}

      {:error, _reason} ->
        {:error, %{code: "join_failed", reason: "unable to join channel"}}
    end
  end

  defp handle_ack(seq_no, kind, socket) do
    case Chat.ack_receipts(socket.assigns.channel_id, socket.assigns.user_id, seq_no, kind) do
      {:ok, %{seq_no: acked_seq, events: events}} ->
        Enum.each(events, fn event ->
          broadcast!(socket, "receipt_event", event)
        end)

        {:reply, {:ok, %{seq_no: acked_seq}}, socket}

      {:error, :not_found_or_not_member} ->
        {:reply,
         {:error, %{code: "forbidden", reason: "channel not found or membership missing"}},
         socket}

      {:error, _reason} ->
        {:reply, {:error, %{code: "ack_failed", reason: "unable to persist ack cursor"}}, socket}
    end
  end

  defp enforce_rate_limit(socket, event, limit, window_ms) do
    bucket = {:ws_event, socket.assigns.user_id, event}

    if RateLimiter.allow?(bucket, limit, window_ms) do
      :ok
    else
      {:error, %{code: "rate_limited", reason: "too many requests; please retry shortly"}}
    end
  end

  @impl true
  def handle_info({:replay_batch, replay}, socket) do
    push(socket, "replay_batch", replay)
    {:noreply, socket}
  end
end
