defmodule BackendWeb.Plugs.RateLimiter do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias Backend.Security.RateLimiter, as: SharedRateLimiter

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    {scope, limit, window_ms} = resolve_rule(conn)
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    bucket = {:http, scope, ip}

    if SharedRateLimiter.allow?(bucket, limit, window_ms) do
      conn
    else
      conn
      |> put_status(:too_many_requests)
      |> Phoenix.Controller.json(%{
        error: "rate_limited",
        retry_after_seconds: div(window_ms, 1_000)
      })
      |> halt()
    end
  end

  defp resolve_rule(%Plug.Conn{request_path: "/api/auth/login"}), do: {:auth, 20, 60_000}
  defp resolve_rule(%Plug.Conn{request_path: "/api/auth/register"}), do: {:auth, 20, 60_000}

  defp resolve_rule(%Plug.Conn{request_path: "/api/uploads", method: "POST"}) do
    {:upload, 30, 60_000}
  end

  defp resolve_rule(_conn), do: {:default, 240, 60_000}
end
