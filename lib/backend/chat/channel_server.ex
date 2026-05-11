defmodule Backend.Chat.ChannelServer do
  @moduledoc false
  use GenServer

  import Ecto.Query

  alias Backend.Chat.Message
  alias Backend.Chat.Attachment
  alias Backend.Chat.ChannelSupervisor
  alias Backend.Repo

  @persist_timeout_ms 5_000

  def start_link(channel_id) do
    GenServer.start_link(__MODULE__, channel_id, name: ChannelSupervisor.via(channel_id))
  end

  def join(channel_id, user_id, last_acked_seq) do
    GenServer.call(ChannelSupervisor.via(channel_id), {:join, user_id, last_acked_seq})
  end

  def send_message(channel_id, sender_id, attrs) do
    GenServer.call(ChannelSupervisor.via(channel_id), {:send_message, sender_id, attrs})
  end

  @impl true
  def init(channel_id) do
    last_seq =
      Repo.one(from m in Message, where: m.channel_id == ^channel_id, select: max(m.seq_no)) || 0

    {:ok,
     %{
       channel_id: channel_id,
       last_seq: last_seq,
       persist_timeout_ms: Application.get_env(:backend, :chat_persist_timeout_ms, @persist_timeout_ms),
       pending_persists: %{}
     }}
  end

  @impl true
  def handle_call({:join, _user_id, last_acked_seq}, _from, state) do
    {:reply,
     {:ok,
      %{channel_id: state.channel_id, last_seq: state.last_seq, last_acked_seq: last_acked_seq}},
     state}
  end

  def handle_call({:send_message, sender_id, attrs}, from, state) do
    client_msg_id = attrs |> get_value("client_msg_id") |> normalize_client_msg_id()
    body = attrs |> get_value("body") |> normalize_body()
    message_type = attrs |> get_value("message_type", "text") |> normalize_message_type()
    attachments = attrs |> get_value("attachments", []) |> normalize_attachments()

    with true <- is_binary(client_msg_id) and client_msg_id != "",
         true <- valid_message_payload?(body, attachments) do
      case find_existing_message(state.channel_id, sender_id, client_msg_id) do
        nil ->
          seq_no = state.last_seq + 1

          message_attrs = %{
            channel_id: state.channel_id,
            sender_id: sender_id,
            client_msg_id: client_msg_id,
            seq_no: seq_no,
            body: body || "",
            message_type: resolve_message_type(message_type, attachments),
            status: "sent"
          }

          task =
            Task.Supervisor.async_nolink(Backend.ChatWriteTaskSupervisor, fn ->
              persist_message_with_attachments(message_attrs, attachments)
            end)

          timer_ref =
            Process.send_after(self(), {:persist_timeout, task.ref}, state.persist_timeout_ms)

          pending = %{
            from: from,
            timer_ref: timer_ref,
            task_pid: task.pid,
            sender_id: sender_id,
            client_msg_id: client_msg_id
          }

          {:noreply,
           %{
             state
             | last_seq: seq_no,
               pending_persists: Map.put(state.pending_persists, task.ref, pending)
           }}

        message ->
          {:reply,
           {:ok,
            %{
              duplicate: true,
              accepted: accepted_payload(message),
              message: build_payload(message)
            }}, %{state | last_seq: max(state.last_seq, message.seq_no)}}
      end
    else
      _ -> {:reply, {:error, :invalid_payload}, state}
    end
  end

  @impl true
  def handle_info({ref, persist_result}, state) when is_reference(ref) do
    case Map.pop(state.pending_persists, ref) do
      {nil, _pending_persists} ->
        {:noreply, state}

      {pending, remaining} ->
        Process.cancel_timer(pending.timer_ref)
        Process.demonitor(ref, [:flush])

        case persist_result do
          {:ok, message} ->
            payload = build_payload(message)

            GenServer.reply(
              pending.from,
              {:ok, %{duplicate: false, accepted: accepted_payload(message), message: payload}}
            )

            {:noreply, %{state | pending_persists: remaining, last_seq: max(state.last_seq, message.seq_no)}}

          {:error, _reason} ->
            # If a duplicate raced through retries/reconnects, return the persisted message.
            case find_existing_message(state.channel_id, pending.sender_id, pending.client_msg_id) do
              nil ->
                GenServer.reply(pending.from, {:error, :persist_failed})

                {:noreply, %{state | pending_persists: remaining}}

              message ->
                GenServer.reply(
                  pending.from,
                  {:ok,
                   %{
                     duplicate: true,
                     accepted: accepted_payload(message),
                     message: build_payload(message)
                   }}
                )

                {:noreply,
                 %{state | pending_persists: remaining, last_seq: max(state.last_seq, message.seq_no)}}
            end
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    case Map.pop(state.pending_persists, ref) do
      {nil, _pending_persists} ->
        {:noreply, state}

      {pending, remaining} ->
        Process.cancel_timer(pending.timer_ref)
        GenServer.reply(pending.from, {:error, :persist_failed})
        {:noreply, %{state | pending_persists: remaining}}
    end
  end

  @impl true
  def handle_info({:persist_timeout, ref}, state) when is_reference(ref) do
    case Map.pop(state.pending_persists, ref) do
      {nil, _pending_persists} ->
        {:noreply, state}

      {pending, remaining} ->
        Process.exit(pending.task_pid, :kill)
        Process.demonitor(ref, [:flush])
        GenServer.reply(pending.from, {:error, :persist_timeout})
        {:noreply, %{state | pending_persists: remaining}}
    end
  end

  defp get_value(attrs, key), do: get_value(attrs, key, nil)

  defp get_value(attrs, "client_msg_id", default),
    do: Map.get(attrs, "client_msg_id", Map.get(attrs, :client_msg_id, default))

  defp get_value(attrs, "body", default),
    do: Map.get(attrs, "body", Map.get(attrs, :body, default))

  defp get_value(attrs, "message_type", default),
    do: Map.get(attrs, "message_type", Map.get(attrs, :message_type, default))

  defp get_value(attrs, "attachments", default),
    do: Map.get(attrs, "attachments", Map.get(attrs, :attachments, default))

  defp normalize_client_msg_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_client_msg_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_client_msg_id(_), do: nil

  defp normalize_body(value) when is_binary(value), do: String.trim(value)
  defp normalize_body(_), do: ""

  defp normalize_message_type(value) when is_binary(value) and value != "", do: value
  defp normalize_message_type(_), do: "text"

  defp valid_message_payload?(body, attachments) do
    (is_binary(body) and String.trim(body) != "") or attachments != []
  end

  defp resolve_message_type(_message_type, attachments) when attachments != [], do: "attachment"
  defp resolve_message_type(message_type, _attachments), do: message_type

  defp normalize_attachments(value) when is_list(value) do
    value
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_attachments(_), do: []

  defp normalize_attachment(raw) when is_map(raw) do
    storage_key = raw["storage_key"] || raw[:storage_key]
    filename = raw["filename"] || raw[:filename]
    content_type = raw["content_type"] || raw[:content_type]
    size = raw["size"] || raw[:size]

    with true <- is_binary(storage_key) and String.trim(storage_key) != "",
         true <- is_binary(filename) and String.trim(filename) != "",
         true <- is_binary(content_type) and String.trim(content_type) != "",
         parsed_size when is_integer(parsed_size) and parsed_size >= 0 <- normalize_size(size) do
      %{
        storage_key: String.trim(storage_key),
        filename: String.trim(filename),
        content_type: String.trim(content_type),
        size: parsed_size
      }
    else
      _ -> nil
    end
  end

  defp normalize_attachment(_), do: nil

  defp normalize_size(size) when is_integer(size) and size >= 0, do: size

  # Jason may decode JSON numbers as floats (e.g. 1234.0); rejecting them dropped all attachments
  # and made caption-only sends hit :invalid_payload (empty body + no attachments).
  defp normalize_size(size) when is_float(size) and size >= 0 do
    trunc(size)
  end

  defp normalize_size(size) when is_binary(size) do
    case Integer.parse(size) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> -1
    end
  end

  defp normalize_size(_), do: -1

  defp find_existing_message(channel_id, sender_id, client_msg_id) do
    Repo.one(
      from m in Message,
        where:
          m.channel_id == ^channel_id and m.sender_id == ^sender_id and
            m.client_msg_id == ^client_msg_id,
        limit: 1
    )
  end

  defp accepted_payload(message) do
    %{
      client_msg_id: message.client_msg_id,
      server_msg_id: message.id,
      seq_no: message.seq_no,
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end

  defp build_payload(message) do
    attachments = list_message_attachments(message.id)

    %{
      id: message.id,
      channel_id: message.channel_id,
      sender_id: message.sender_id,
      client_msg_id: message.client_msg_id,
      seq_no: message.seq_no,
      body: message.body,
      message_type: message.message_type,
      attachments: attachments,
      status: message.status,
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end

  defp list_message_attachments(message_id) do
    Repo.all(
      from a in Attachment,
        where: a.message_id == ^message_id,
        select: %{
          id: a.id,
          message_id: a.message_id,
          storage_key: a.storage_key,
          filename: a.filename,
          content_type: a.content_type,
          size: a.size
        }
    )
  end

  defp persist_message_with_attachments(message_attrs, attachments) do
    Repo.transaction(fn ->
      message =
        case %Message{} |> Message.create_changeset(message_attrs) |> Repo.insert() do
          {:ok, row} ->
            row

          {:error, changeset} ->
            Repo.rollback({:message_error, changeset})
        end

      Enum.each(attachments, fn attachment ->
        attrs = Map.put(attachment, :message_id, message.id)

        case %Attachment{} |> Attachment.changeset(attrs) |> Repo.insert() do
          {:ok, _row} -> :ok
          {:error, changeset} -> Repo.rollback({:attachment_error, changeset})
        end
      end)

      message
    end)
    |> case do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end
end
