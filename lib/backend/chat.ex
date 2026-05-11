defmodule Backend.Chat do
  @moduledoc false
  import Ecto.Query

  alias Backend.Chat.Message
  alias Backend.Chat.Attachment
  alias Backend.Chat.ChannelServer
  alias Backend.Chat.ChannelSupervisor
  alias Backend.Chat.MessageReceipt
  alias Backend.Chat.MessageUserHide
  alias Backend.Chat.SyncCursor
  alias Backend.Repo

  def join_channel(channel_id, user_id, last_acked_seq) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_exists?(channel_id),
         true <- channel_member?(channel_id, user_id),
         {:ok, _pid} <- ChannelSupervisor.ensure_started(channel_id) do
      stored_acked_seq = get_stored_ack_seq(user_id, channel_id)
      effective_acked_seq = max(stored_acked_seq, normalize_ack_seq(last_acked_seq))
      :ok = upsert_ack_seq(user_id, channel_id, effective_acked_seq)

      with {:ok, join_state} <- ChannelServer.join(channel_id, user_id, effective_acked_seq),
           replay_events <- list_replay_events(channel_id, user_id, effective_acked_seq) do
        replay_to_seq =
          case replay_events do
            [] -> effective_acked_seq
            _ -> List.last(replay_events).seq_no
          end

        {:ok,
         Map.merge(join_state, %{
           last_acked_seq: effective_acked_seq,
           replay: %{
             channel_id: channel_id,
             from_seq: effective_acked_seq + 1,
             to_seq: replay_to_seq,
             events: Enum.map(replay_events, &serialize_message/1)
           }
         })}
      end
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_message(channel_id, user_id, attrs) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id),
         {:ok, _pid} <- ChannelSupervisor.ensure_started(channel_id) do
      ChannelServer.send_message(channel_id, user_id, attrs)
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def can_access_channel?(channel_id, user_id) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id) do
      channel_member?(channel_id, user_id)
    else
      _ -> false
    end
  end

  def list_user_channels(user_id, limit \\ 100) do
    with {:ok, user_id} <- parse_id(user_id) do
      safe_limit = normalize_limit(limit)

      channels =
        Repo.all(
          from c in "channels",
            join: cm in "channel_members",
            on: cm.channel_id == c.id,
            where: cm.user_id == ^user_id,
            order_by: [desc: c.id],
            limit: ^safe_limit,
            select: %{
              id: c.id,
              workspace_id: c.workspace_id,
              name: c.name,
              kind: c.kind,
              inserted_at: c.inserted_at
            }
        )

      {:ok, channels}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def list_workspaces(limit \\ 100) do
    safe_limit = normalize_limit(limit)

    workspaces =
      Repo.all(
        from w in "workspaces",
          order_by: [desc: w.id],
          limit: ^safe_limit,
          select: %{
            id: w.id,
            name: w.name,
            inserted_at: w.inserted_at
          }
      )

    {:ok, workspaces}
  end

  def create_workspace(attrs) when is_map(attrs) do
    with {:ok, name} <- validate_workspace_name(Map.get(attrs, "name", Map.get(attrs, :name))) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      now_iso = DateTime.to_iso8601(now)

      Repo.query!(
        "INSERT INTO workspaces (name, inserted_at) VALUES (?1, ?2)",
        [name, now_iso]
      )

      %{rows: [[workspace_id]]} =
        Repo.query!("SELECT id FROM workspaces ORDER BY id DESC LIMIT 1")

      {:ok,
       %{
         id: workspace_id,
         name: name,
         inserted_at: now
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_default_workspace_for_user(user_name) do
    create_workspace(%{"name" => default_workspace_name(user_name)})
  end

  def create_channel(workspace_id, creator_user_id, attrs) do
    with {:ok, workspace_id} <- parse_id(workspace_id),
         {:ok, creator_user_id} <- parse_id(creator_user_id),
         true <- workspace_exists?(workspace_id),
         {:ok, name} <- validate_channel_name(Map.get(attrs, "name", Map.get(attrs, :name))),
         {:ok, kind} <-
           validate_channel_kind(Map.get(attrs, "kind", Map.get(attrs, :kind, "group"))) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        Repo.query!(
          "INSERT INTO channels (workspace_id, name, kind, inserted_at) VALUES (?1, ?2, ?3, ?4)",
          [workspace_id, name, kind, DateTime.to_iso8601(now)]
        )

        %{rows: [[channel_id]]} =
          Repo.query!("SELECT id FROM channels ORDER BY id DESC LIMIT 1")

        Repo.query!(
          """
          INSERT INTO channel_members (channel_id, user_id, last_read_seq, joined_at)
          VALUES (?1, ?2, 0, ?3)
          """,
          [channel_id, creator_user_id, DateTime.to_iso8601(now)]
        )

        %{
          id: channel_id,
          workspace_id: workspace_id,
          name: name,
          kind: kind,
          inserted_at: now
        }
      end)
      |> case do
        {:ok, channel} -> {:ok, channel}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :workspace_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def add_channel_member(channel_id, actor_user_id, member_user_id) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, actor_user_id} <- parse_id(actor_user_id),
         {:ok, member_user_id} <- parse_id(member_user_id),
         true <- channel_member?(channel_id, actor_user_id),
         true <- user_exists?(member_user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

      {rows_changed, _} =
        Repo.query!(
          """
          INSERT INTO channel_members (channel_id, user_id, last_read_seq, joined_at)
          VALUES (?1, ?2, 0, ?3)
          ON CONFLICT(channel_id, user_id) DO NOTHING
          """,
          [channel_id, member_user_id, now]
        )
        |> then(fn result -> {result.num_rows, result} end)

      {:ok,
       %{
         channel_id: channel_id,
         user_id: member_user_id,
         added: rows_changed > 0
       }}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_channel_messages(channel_id, user_id, limit \\ 100) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id) do
      safe_limit =
        limit
        |> normalize_limit()

      messages =
        Repo.all(
          from m in Message,
            as: :message,
            where: m.channel_id == ^channel_id,
            where:
              not exists(
                from h in MessageUserHide,
                  where: h.message_id == parent_as(:message).id and h.user_id == ^user_id,
                  select: 1
              ),
            order_by: [asc: m.seq_no],
            limit: ^safe_limit
        )

      receipt_state_by_message_id = receipt_state_by_message_id(messages, user_id)
      attachments_by_message_id = attachments_by_message_id(messages)

      hydrated_messages =
        Enum.map(messages, fn message ->
          message
          |> Map.put(
            :send_state,
            send_state_for_message(message, user_id, receipt_state_by_message_id)
          )
          |> Map.put(:attachments, Map.get(attachments_by_message_id, message.id, []))
        end)

      {:ok, hydrated_messages}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_channel_attachments(channel_id, user_id, limit \\ 50) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id) do
      safe_limit = normalize_limit(limit)

      attachments =
        Repo.all(
          from a in Attachment,
            join: m in Message,
            as: :message,
            on: m.id == a.message_id,
            where: m.channel_id == ^channel_id,
            where:
              not exists(
                from h in MessageUserHide,
                  where: h.message_id == parent_as(:message).id and h.user_id == ^user_id,
                  select: 1
              ),
            order_by: [desc: m.seq_no],
            limit: ^safe_limit,
            select: %{
              id: a.id,
              message_id: a.message_id,
              storage_key: a.storage_key,
              filename: a.filename,
              content_type: a.content_type,
              size: a.size,
              seq_no: m.seq_no,
              inserted_at: m.inserted_at,
              message_body: m.body
            }
        )

      {:ok, attachments}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_channel_links(channel_id, user_id, limit \\ 100) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id) do
      safe_limit = normalize_limit(limit)

      messages =
        Repo.all(
          from m in Message,
            as: :message,
            where: m.channel_id == ^channel_id and like(m.body, ^"%http%"),
            where:
              not exists(
                from h in MessageUserHide,
                  where: h.message_id == parent_as(:message).id and h.user_id == ^user_id,
                  select: 1
              ),
            order_by: [desc: m.seq_no],
            limit: ^(safe_limit * 3)
        )

      links =
        messages
        |> Enum.reduce({MapSet.new(), []}, fn message, {seen, acc} ->
          urls = extract_urls(message.body)

          Enum.reduce(urls, {seen, acc}, fn url, {seen_urls, url_acc} ->
            if MapSet.member?(seen_urls, url) do
              {seen_urls, url_acc}
            else
              link = %{
                url: url,
                host: extract_host(url),
                message_id: message.id,
                sender_id: message.sender_id,
                seq_no: message.seq_no,
                inserted_at: message.inserted_at,
                message_body: message.body || ""
              }

              {MapSet.put(seen_urls, url), [link | url_acc]}
            end
          end)
        end)
        |> elem(1)
        |> Enum.reverse()
        |> Enum.take(safe_limit)

      {:ok, links}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def ack_channel_seq(channel_id, user_id, seq_no) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id) do
      normalized_seq = normalize_ack_seq(seq_no)
      :ok = upsert_ack_seq(user_id, channel_id, normalized_seq)
      {:ok, normalized_seq}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def ack_receipts(channel_id, user_id, seq_no, kind) when kind in [:delivered, :read] do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id) do
      normalized_seq = normalize_ack_seq(seq_no)
      :ok = upsert_ack_seq(user_id, channel_id, normalized_seq)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      messages =
        Repo.all(
          from m in Message,
            where:
              m.channel_id == ^channel_id and m.seq_no <= ^normalized_seq and
                m.sender_id != ^user_id,
            select: %{id: m.id, seq_no: m.seq_no}
        )

      message_ids = Enum.map(messages, & &1.id)

      existing_receipts =
        if message_ids == [] do
          %{}
        else
          Repo.all(
            from r in MessageReceipt,
              where: r.user_id == ^user_id and r.message_id in ^message_ids,
              select: %{
                message_id: r.message_id,
                delivered_at: r.delivered_at,
                read_at: r.read_at
              }
          )
          |> Map.new(fn row -> {row.message_id, row} end)
        end

      events =
        Enum.reduce(messages, [], fn message, acc ->
          current = Map.get(existing_receipts, message.id, %{delivered_at: nil, read_at: nil})
          update_kind = receipt_update_kind(kind, current)

          case update_kind do
            :noop ->
              acc

            :delivered ->
              upsert_message_receipt(message.id, user_id, now, nil)

              [
                %{
                  message_id: message.id,
                  user_id: user_id,
                  event: "delivered",
                  ts: DateTime.to_iso8601(now)
                }
                | acc
              ]

            :read ->
              delivered_at = current.delivered_at || now
              upsert_message_receipt(message.id, user_id, delivered_at, now)

              [
                %{
                  message_id: message.id,
                  user_id: user_id,
                  event: "read",
                  ts: DateTime.to_iso8601(now)
                }
                | acc
              ]
          end
        end)
        |> Enum.reverse()

      {:ok, %{seq_no: normalized_seq, events: events}}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def presence_ping(channel_id, user_id, status) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id),
         {:ok, workspace_id} <- get_workspace_id_for_channel(channel_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      normalized_status = normalize_status(status)

      Repo.query!(
        "DELETE FROM presence_sessions WHERE user_id = ?1 AND workspace_id = ?2",
        [user_id, workspace_id]
      )

      Repo.query!(
        "INSERT INTO presence_sessions (user_id, workspace_id, status, last_seen_at) VALUES (?1, ?2, ?3, ?4)",
        [user_id, workspace_id, normalized_status, DateTime.to_iso8601(now)]
      )

      {:ok,
       %{
         user_id: user_id,
         status: normalized_status,
         last_seen_at: DateTime.to_iso8601(now)
       }}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  def typing_event(channel_id, user_id, is_typing) do
    with {:ok, channel_id} <- parse_id(channel_id),
         {:ok, user_id} <- parse_id(user_id),
         true <- channel_member?(channel_id, user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok,
       %{
         channel_id: channel_id,
         user_id: user_id,
         is_typing: !!is_typing,
         ts: DateTime.to_iso8601(now)
       }}
    else
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  defp channel_exists?(channel_id) do
    Repo.exists?(from c in "channels", where: c.id == ^channel_id)
  end

  defp workspace_exists?(workspace_id) do
    Repo.exists?(from w in "workspaces", where: w.id == ^workspace_id)
  end

  defp user_exists?(user_id) do
    Repo.exists?(from u in "users", where: u.id == ^user_id)
  end

  defp channel_member?(channel_id, user_id) do
    Repo.exists?(
      from cm in "channel_members",
        where: cm.channel_id == ^channel_id and cm.user_id == ^user_id
    )
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_id}

  defp normalize_ack_seq(nil), do: 0
  defp normalize_ack_seq(value) when is_integer(value) and value >= 0, do: value

  defp normalize_ack_seq(value) when is_binary(value) do
    case Integer.parse(value) do
      {seq, ""} when seq >= 0 -> seq
      _ -> 0
    end
  end

  defp normalize_ack_seq(_), do: 0

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(200)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed_limit, ""} -> normalize_limit(parsed_limit)
      _ -> 100
    end
  end

  defp normalize_limit(_), do: 100

  defp validate_channel_name(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or String.length(trimmed) > 120 do
      {:error, :invalid_channel_name}
    else
      {:ok, trimmed}
    end
  end

  defp validate_channel_name(_), do: {:error, :invalid_channel_name}

  defp validate_channel_kind(nil), do: {:ok, "group"}

  defp validate_channel_kind(value) when is_binary(value) do
    kind = String.trim(value)
    if kind in ["group", "dm"], do: {:ok, kind}, else: {:error, :invalid_channel_kind}
  end

  defp validate_channel_kind(_), do: {:error, :invalid_channel_kind}

  defp validate_workspace_name(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" or String.length(trimmed) > 120 do
      {:error, :invalid_workspace_name}
    else
      {:ok, trimmed}
    end
  end

  defp validate_workspace_name(_), do: {:error, :invalid_workspace_name}

  defp default_workspace_name(user_name) when is_binary(user_name) do
    trimmed_name =
      user_name
      |> String.trim()
      |> case do
        "" -> "Personal"
        value -> value
      end

    "#{trimmed_name}'s Workspace"
  end

  defp default_workspace_name(_), do: "Personal Workspace"

  defp normalize_status(status) when is_binary(status) do
    trimmed = String.trim(status)
    if trimmed == "", do: "online", else: trimmed
  end

  defp normalize_status(_), do: "online"

  defp get_stored_ack_seq(user_id, channel_id) do
    Repo.one(
      from sc in SyncCursor,
        where: sc.user_id == ^user_id and sc.channel_id == ^channel_id,
        select: sc.last_acked_seq,
        limit: 1
    ) || 0
  end

  defp upsert_ack_seq(user_id, channel_id, acked_seq) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset =
      SyncCursor.changeset(%SyncCursor{}, %{
        user_id: user_id,
        channel_id: channel_id,
        last_acked_seq: acked_seq,
        updated_at: now
      })

    Repo.insert(
      changeset,
      on_conflict: [set: [last_acked_seq: acked_seq, updated_at: now]],
      conflict_target: [:user_id, :channel_id]
    )

    :ok
  end

  def hide_message_for_me(user_id, message_id) do
    with {:ok, user_id} <- parse_id(user_id),
         {:ok, message_id} <- parse_id(message_id),
         %Message{} = message <- Repo.get(Message, message_id),
         true <- channel_member?(message.channel_id, user_id) do
      %MessageUserHide{}
      |> MessageUserHide.changeset(%{user_id: user_id, message_id: message_id})
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:user_id, :message_id]
      )
      |> case do
        {:ok, _} -> {:ok, :hidden}
        {:error, changeset} -> {:error, changeset}
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found_or_not_member}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_replay_events(channel_id, user_id, acked_seq) do
    Repo.all(
      from m in Message,
        as: :message,
        where: m.channel_id == ^channel_id and m.seq_no > ^acked_seq,
        where:
          not exists(
            from h in MessageUserHide,
              where: h.message_id == parent_as(:message).id and h.user_id == ^user_id,
              select: 1
          ),
        order_by: [asc: m.seq_no],
        limit: 200
    )
  end

  defp receipt_update_kind(:delivered, %{delivered_at: nil}), do: :delivered
  defp receipt_update_kind(:delivered, _), do: :noop
  defp receipt_update_kind(:read, %{read_at: nil}), do: :read
  defp receipt_update_kind(:read, _), do: :noop

  defp upsert_message_receipt(message_id, user_id, delivered_at, read_at) do
    changeset =
      MessageReceipt.changeset(%MessageReceipt{}, %{
        message_id: message_id,
        user_id: user_id,
        delivered_at: delivered_at,
        read_at: read_at
      })

    Repo.insert(
      changeset,
      on_conflict: [
        set: [
          delivered_at: delivered_at,
          read_at: read_at
        ]
      ],
      conflict_target: [:message_id, :user_id]
    )
  end

  defp get_workspace_id_for_channel(channel_id) do
    case Repo.one(
           from c in "channels", where: c.id == ^channel_id, select: c.workspace_id, limit: 1
         ) do
      nil -> {:error, :not_found_or_not_member}
      workspace_id -> {:ok, workspace_id}
    end
  end

  defp receipt_state_by_message_id(messages, user_id) do
    message_ids = Enum.map(messages, & &1.id)

    if message_ids == [] do
      %{}
    else
      Repo.all(
        from r in MessageReceipt,
          where: r.message_id in ^message_ids and r.user_id != ^user_id,
          select: %{message_id: r.message_id, delivered_at: r.delivered_at, read_at: r.read_at}
      )
      |> Enum.reduce(%{}, fn row, acc ->
        current = Map.get(acc, row.message_id, %{delivered: false, read: false})

        next = %{
          delivered: current.delivered || not is_nil(row.delivered_at),
          read: current.read || not is_nil(row.read_at)
        }

        Map.put(acc, row.message_id, next)
      end)
    end
  end

  defp send_state_for_message(message, user_id, receipt_state_by_message_id) do
    if message.sender_id != user_id do
      "sent"
    else
      receipt_state =
        Map.get(receipt_state_by_message_id, message.id, %{delivered: false, read: false})

      cond do
        receipt_state.read -> "read"
        receipt_state.delivered -> "delivered"
        true -> "sent"
      end
    end
  end

  defp serialize_message(message) do
    attachments =
      case Map.fetch(message, :attachments) do
        {:ok, rows} when is_list(rows) -> rows
        _ -> list_message_attachments(message.id)
      end

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
      send_state: Map.get(message, :send_state, "sent"),
      inserted_at: DateTime.to_iso8601(message.inserted_at)
    }
  end

  defp attachments_by_message_id(messages) do
    message_ids = Enum.map(messages, & &1.id)

    if message_ids == [] do
      %{}
    else
      Repo.all(
        from a in Attachment,
          where: a.message_id in ^message_ids,
          select: %{
            id: a.id,
            message_id: a.message_id,
            storage_key: a.storage_key,
            filename: a.filename,
            content_type: a.content_type,
            size: a.size
          }
      )
      |> Enum.group_by(& &1.message_id)
    end
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

  defp extract_urls(body) when is_binary(body) do
    Regex.scan(~r/https?:\/\/[^\s]+/i, body)
    |> Enum.map(&List.first/1)
    |> Enum.map(&Regex.replace(~r/[),.;!?]+$/, &1, ""))
  end

  defp extract_urls(_), do: []

  defp extract_host(url) do
    uri = URI.parse(url)
    uri.host || "external"
  end
end
