# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :backend,
  ecto_repos: [Backend.Repo],
  generators: [timestamp_type: :utc_datetime],
  cors_allowed_origins: ["http://localhost:5173"],
  cors_allowed_methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  cors_allowed_headers: ["content-type", "authorization", "x-requested-with"],
  cors_allow_credentials: false,
  max_upload_bytes: 10 * 1024 * 1024,
  allowed_upload_content_types: [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "application/pdf"
  ],
  allowed_upload_extensions: [".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf"]

config :backend, :pow,
  user: Backend.Users.User,
  repo: Backend.Repo,
  web_module: BackendWeb,
  cache_store_backend: Pow.Store.Backend.EtsCache

# Configure the endpoint
config :backend, BackendWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: BackendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backend.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
