defmodule Backend.Security.RateLimiter do
  @moduledoc false

  @table :backend_rate_limit

  def allow?(bucket, limit, window_ms)
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    ensure_table!()

    current_window = System.system_time(:millisecond) |> div(window_ms)
    key = {bucket, current_window}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    count <= limit
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
