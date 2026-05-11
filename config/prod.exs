import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# also known as HSTS. `:force_ssl` is required to be set at compile-time.
config :backend, BackendWeb.Endpoint, force_ssl: [rewrite_on: [:x_forwarded_proto]]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
