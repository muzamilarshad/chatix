defmodule BackendWeb.Plugs.RuntimeCors do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cors_opts =
      [
        origins: Application.get_env(:backend, :cors_allowed_origins, ["http://localhost:5173"]),
        allow_methods:
          Application.get_env(:backend, :cors_allowed_methods, [
            "GET",
            "POST",
            "PUT",
            "PATCH",
            "DELETE",
            "OPTIONS"
          ]),
        allow_headers:
          Application.get_env(:backend, :cors_allowed_headers, [
            "content-type",
            "authorization",
            "x-requested-with"
          ]),
        allow_credentials: Application.get_env(:backend, :cors_allow_credentials, false),
        max_age: 86_400
      ]

    Corsica.call(conn, Corsica.init(cors_opts))
  end
end
