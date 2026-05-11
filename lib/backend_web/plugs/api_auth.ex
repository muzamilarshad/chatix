defmodule BackendWeb.APIAuthPlug do
  @moduledoc false
  use Pow.Plug.Base

  alias Plug.Conn
  alias Pow.{Config, Plug, Store.CredentialsCache}

  @impl true
  @spec fetch(Conn.t(), Config.t()) :: {Conn.t(), map() | nil}
  def fetch(conn, config) do
    with {:ok, signed_token} <- fetch_access_token(conn),
         {:ok, user} <- user_from_signed_token(conn, signed_token, config) do
      {conn, user}
    else
      _ -> {conn, nil}
    end
  end

  @impl true
  @spec create(Conn.t(), map(), Config.t()) :: {Conn.t(), map()}
  def create(conn, user, config) do
    token = Pow.UUID.generate()

    conn =
      conn
      |> Conn.put_private(:api_access_token, sign_token(conn, token, config))
      |> Conn.register_before_send(fn conn ->
        CredentialsCache.put(store_config(config), token, {user, []})
        conn
      end)

    {conn, user}
  end

  @impl true
  @spec delete(Conn.t(), Config.t()) :: Conn.t()
  def delete(conn, config) do
    with {:ok, signed_token} <- fetch_access_token(conn),
         {:ok, token} <- verify_token(conn, signed_token, config) do
      Conn.register_before_send(conn, fn conn ->
        CredentialsCache.delete(store_config(config), token)
        conn
      end)
    else
      _ -> conn
    end
  end

  @spec user_from_signed_token(Conn.t(), binary(), Config.t()) :: {:ok, map()} | :error
  def user_from_signed_token(conn, signed_token, config) when is_binary(signed_token) do
    with {:ok, token} <- verify_token(conn, signed_token, config),
         {user, _metadata} <- CredentialsCache.get(store_config(config), token) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def user_from_signed_token(_conn, _signed_token, _config), do: :error

  defp sign_token(conn, token, config) do
    Plug.sign_token(conn, signing_salt(), token, config)
  end

  defp fetch_access_token(conn) do
    case Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 -> {:ok, token}
      _ -> :error
    end
  end

  defp verify_token(conn, token, config) do
    Plug.verify_token(conn, signing_salt(), token, config)
  end

  defp signing_salt, do: Atom.to_string(__MODULE__)

  defp store_config(config) do
    backend = Config.get(config, :cache_store_backend, Pow.Store.Backend.EtsCache)
    [backend: backend, pow_config: config]
  end
end
