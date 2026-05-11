defmodule Backend.Chat.Attachment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "attachments" do
    field :message_id, :id
    field :storage_key, :string
    field :filename, :string
    field :content_type, :string
    field :size, :integer
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:message_id, :storage_key, :filename, :content_type, :size])
    |> validate_required([:message_id, :storage_key, :filename, :content_type, :size])
  end
end
