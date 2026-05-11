defmodule BackendWeb.ChannelCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import BackendWeb.ChannelCase
      import Backend.ChatFixtures

      @endpoint BackendWeb.Endpoint
    end
  end

  setup tags do
    Backend.DataCase.setup_sandbox(tags)
    :ok
  end
end
