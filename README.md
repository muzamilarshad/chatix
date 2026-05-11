# Chatix Lite Backend (Elixir/Phoenix)

Elixir/Phoenix backend for a reliability-first realtime chat prototype.

## What This Backend Demonstrates

- Realtime channel messaging over Phoenix Channels.
- Idempotent sends using `(channel_id, sender_id, client_msg_id)`.
- Monotonic channel sequencing (`seq_no`) with replay after reconnect.
- Delivery/read acknowledgements and cursor persistence.
- Attachment metadata persistence in the message write path.

## Core Architecture

- `Backend.Chat` is the domain boundary used by channels/controllers.
- `Backend.Chat.ChannelServer` is one `GenServer` per channel for sequence coordination.
- Message writes run through a supervised async task (`Backend.ChatWriteTaskSupervisor`) so the channel process is not blocked by DB I/O.
- Storage is SQLite via `Ecto` for local development.

## API Authentication

Auth is implemented with `[Pow](https://hex.pm/packages/pow)` for API usage.
Protected API routes require a Bearer access token.

- Header format: `Authorization: Bearer <token>`
- Access tokens are issued by `POST /api/auth/register` and `POST /api/auth/login`
- Tokens are verified and resolved to a current user via `BackendWeb.APIAuthPlug`
- `DELETE /api/auth/logout` invalidates the current token

## Local Run

```bash
mix setup
mix phx.server
```

App runs at `http://localhost:4000`.

## Test

```bash
mix test
```

## CORS Configuration

This backend uses `[Corsica](https://hex.pm/packages/corsica)` as an endpoint plug.
Default CORS options are configured in `config/config.exs`:

- `:cors_allowed_origins`
- `:cors_allowed_methods`
- `:cors_allowed_headers`
- `:cors_allow_credentials`

For environment-specific policies, override these keys in `config/dev.exs` or `config/prod.exs`.

## Upload Guardrails

Upload validation currently enforces:

- max file size via `:max_upload_bytes`
- MIME allowlist via `:allowed_upload_content_types`
- extension allowlist via `:allowed_upload_extensions`

