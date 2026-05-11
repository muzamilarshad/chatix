defmodule BackendWeb.Router do
  use BackendWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug BackendWeb.Plugs.RateLimiter
    plug BackendWeb.APIAuthPlug, otp_app: :backend
  end

  pipeline :api_protected do
    plug Pow.Plug.RequireAuthenticated, error_handler: BackendWeb.APIAuthErrorHandler
  end

  scope "/api", BackendWeb do
    pipe_through :api

    post "/auth/register", AuthRegistrationController, :create
    post "/auth/login", AuthSessionController, :create
    delete "/auth/logout", AuthSessionController, :delete

    options "/uploads", UploadController, :create
    options "/channels", ChannelController, :create
    options "/channels/:channel_id/members", ChannelMemberController, :create
    options "/channels/:channel_id/messages", MessageController, :index
    options "/messages/:message_id/hide_for_me", MessageHideController, :create
    options "/channels/:channel_id/attachments", ChannelAssetController, :attachments
    options "/channels/:channel_id/links", ChannelAssetController, :links
  end

  scope "/api", BackendWeb do
    pipe_through [:api, :api_protected]

    post "/uploads", UploadController, :create
    get "/channels", ChannelController, :index
    post "/channels", ChannelController, :create
    post "/channels/:channel_id/members", ChannelMemberController, :create
    get "/channels/:channel_id/messages", MessageController, :index
    post "/messages/:message_id/hide_for_me", MessageHideController, :create
    get "/channels/:channel_id/attachments", ChannelAssetController, :attachments
    get "/channels/:channel_id/links", ChannelAssetController, :links
  end
end
