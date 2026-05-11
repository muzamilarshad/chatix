defmodule Backend.Chat.ChannelSupervisor do
  @moduledoc false
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def ensure_started(channel_id) when is_integer(channel_id) do
    case GenServer.whereis(via(channel_id)) do
      nil ->
        spec = {Backend.Chat.ChannelServer, channel_id}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:already_present, _}} -> {:ok, GenServer.whereis(via(channel_id))}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  def via(channel_id) do
    {:via, Registry, {Backend.Chat.ChannelRegistry, channel_id}}
  end
end
