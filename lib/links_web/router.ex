defmodule LinksWeb.Router do
  use LinksWeb, :router

  import LinksWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LinksWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", LinksWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:links, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LinksWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  pipeline :local_authentication do
    plug :reject_when_forward_auth_enabled
  end

  ## Authentication routes

  scope "/", LinksWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{LinksWeb.UserAuth, :require_authenticated}] do
      live "/", DashboardLive, :index
    end

    get "/bookmarks/:id/favicon", BookmarkFaviconController, :show
  end

  scope "/", LinksWeb do
    pipe_through [:browser, :local_authentication, :require_authenticated_user]

    live_session :user_settings,
      on_mount: [{LinksWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", LinksWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{LinksWeb.UserAuth, :mount_current_scope}] do
      # Public share links must work with or without authentication.
      live "/share/:token", PublicShareLive, :show
    end
  end

  scope "/", LinksWeb do
    pipe_through [:browser, :local_authentication]

    live_session :local_authentication,
      on_mount: [{LinksWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
