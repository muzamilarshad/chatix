defmodule BackendWeb.UserSocket do
  use Phoenix.Socket

  alias Backend.Security.RateLimiter

  channel "channel:*", BackendWeb.ChatChannel

  @impl true
  def connect(params, socket, connect_info) do
    with {:ok, signed_token} <- fetch_access_token(params),
         {:ok, user} <- verify_access_token(signed_token),
         :ok <- check_connect_rate_limit(user.id, connect_info) do
      {:ok,
       socket
       |> assign(:current_user, user)
       |> assign(:user_id, user.id)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  defp fetch_access_token(%{"access_token" => token})
       when is_binary(token) and byte_size(token) > 0 do
    {:ok, token}
  end

  defp fetch_access_token(%{"token" => token}) when is_binary(token) and byte_size(token) > 0 do
    {:ok, token}
  end

  defp fetch_access_token(_params), do: :error

  defp verify_access_token(signed_token) do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:secret_key_base, BackendWeb.Endpoint.config(:secret_key_base))

    BackendWeb.APIAuthPlug.user_from_signed_token(conn, signed_token, pow_config())
  end

  defp pow_config do
    Keyword.merge([otp_app: :backend], Application.get_env(:backend, :pow, []))
  end

  defp check_connect_rate_limit(user_id, connect_info) do
    address = extract_remote_ip(connect_info)
    bucket = {:ws_connect, user_id, address}

    if RateLimiter.allow?(bucket, 60, 60_000) do
      :ok
    else
      :error
    end
  end

  defp extract_remote_ip(%{peer_data: %{address: address}}) when is_tuple(address) do
    :inet.ntoa(address) |> to_string()
  end

  defp extract_remote_ip(_), do: "unknown"
end
