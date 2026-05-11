defmodule Backend.Chat.Message do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :channel_id, :id
    field :sender_id, :id
    field :client_msg_id, :string
    field :seq_no, :integer
    field :body, :string
    field :message_type, :string, default: "text"
    field :status, :string, default: "sent"
    field :edited_at, :utc_datetime_usec

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def create_changeset(message, attrs) do
    message
    # Default cast treats "" as empty → nil, but DB has NOT NULL on body; attachment-only
    # messages legitimately use an empty string caption.
    |> cast(
      attrs,
      [
        :channel_id,
        :sender_id,
        :client_msg_id,
        :seq_no,
        :body,
        :message_type,
        :status,
        :edited_at
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :channel_id,
      :sender_id,
      :client_msg_id,
      :seq_no,
      :message_type,
      :status
    ])
    |> unique_constraint([:channel_id, :sender_id, :client_msg_id],
      name: :messages_channel_id_sender_id_client_msg_id_index
    )
    |> unique_constraint([:channel_id, :seq_no], name: :messages_channel_id_seq_no_index)
  end
end
