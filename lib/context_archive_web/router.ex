defmodule ContextArchiveWeb.Router do
  use ContextArchiveWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContextArchiveWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :ingest do
    plug ContextArchiveWeb.Plugs.ApiTokenAuth, kinds: [:ingest]
  end

  pipeline :read_api do
    plug ContextArchiveWeb.Plugs.ApiTokenAuth, kinds: [:read, :admin]
  end

  scope "/", ContextArchiveWeb do
    get "/health", HealthController, :show
  end

  # Machine-facing intake (shipper). Not in the public OpenAPI.
  scope "/ingest/v1", ContextArchiveWeb do
    pipe_through [:ingest]

    get "/sources/:machine/streams", IngestController, :streams
    post "/sources/:machine/append", IngestController, :append
  end

  # Read API (search, documents, context, status) and its OpenAPI document at
  # /api/open_api. Every request needs a read or admin token.
  scope "/api" do
    pipe_through [:api, :read_api]

    forward "/", ContextArchiveWeb.AshJsonApiRouter
  end

  # Other scopes may use custom stacks.
  # scope "/api", ContextArchiveWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:context_archive, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ContextArchiveWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
