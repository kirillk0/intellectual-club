defmodule IntellectualClubWeb.Router do
  use IntellectualClubWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IntellectualClubWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_session do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :load_from_session
    plug :set_actor, :user
    plug IntellectualClubWeb.Locale
  end

  pipeline :api_mixed_session do
    plug :fetch_session
    plug :protect_from_forgery
    plug :load_from_session
    plug :set_actor, :user
    plug IntellectualClubWeb.Locale
  end

  pipeline :ash_json_api do
    plug :accepts, ["jsonapi", "json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :load_from_session
    plug :set_actor, :user
    plug IntellectualClubWeb.Locale
  end

  scope "/", IntellectualClubWeb do
    pipe_through :browser

    auth_routes AuthController, IntellectualClub.Accounts.User, path: "/auth"
    sign_out_route AuthController

    sign_in_route(
      auth_routes_prefix: "/auth",
      on_mount: [{IntellectualClubWeb.LiveUserAuth, :live_no_user}]
    )

    get "/login", SpaController, :index
    get "/", SpaController, :index
    get "/bookmarks", SpaController, :index
    get "/settings", SpaController, :index
    get "/settings/*path", SpaController, :index
    get "/administration", SpaController, :index
    get "/administration/*path", SpaController, :index
    get "/chats/*path", SpaController, :index
    get "/catalogs/*path", SpaController, :index
    get "/outlets/*path", SpaController, :index
  end

  scope "/api/outlet", IntellectualClubWeb do
    pipe_through :api

    get "/metadata/", OutletController, :metadata
    post "/poll/", OutletController, :poll
    post "/complete/", OutletController, :complete
    post "/calls/:call_id/files", OutletController, :upload_file
    get "/calls/:call_id/files/:file_id", OutletController, :download_file

    post "/pair/start/", OutletController, :pair_start
    post "/pair/poll/", OutletController, :pair_poll
  end

  scope "/api/outlet", IntellectualClubWeb do
    pipe_through :api_session

    post "/pair/approve/", OutletController, :pair_approve
  end

  scope "/api/bff", IntellectualClubWeb.Bff do
    pipe_through :api_session

    get "/auth/me", SessionController, :show
    post "/auth/login", SessionController, :create
    post "/auth/logout", SessionController, :delete

    get "/me", MeController, :show
    patch "/me", MeController, :update
    get "/me/groups", MeController, :groups
    post "/me/change-password", MeController, :change_password
    get "/bookmarks", BookmarksController, :index

    get "/web-push/config", WebPushController, :config
    post "/web-push/subscriptions", WebPushController, :upsert_subscription
    delete "/web-push/subscriptions", WebPushController, :delete_subscription

    get "/admin/users", AdminUsersController, :index
    get "/admin/users/:id", AdminUsersController, :show
    post "/admin/users", AdminUsersController, :create
    patch "/admin/users/:id", AdminUsersController, :update
    delete "/admin/users/:id", AdminUsersController, :delete
    post "/admin/users/:id/reset-password", AdminUsersController, :reset_password

    get "/admin/user-groups", AdminUserGroupsController, :index
    get "/admin/user-groups/:id", AdminUserGroupsController, :show
    post "/admin/user-groups", AdminUserGroupsController, :create
    patch "/admin/user-groups/:id", AdminUserGroupsController, :update
    delete "/admin/user-groups/:id", AdminUserGroupsController, :delete

    get "/admin/web-push-settings", AdminWebPushSettingsController, :show
    patch "/admin/web-push-settings", AdminWebPushSettingsController, :update

    post "/admin/web-push-settings/regenerate-keys",
         AdminWebPushSettingsController,
         :regenerate_keys

    get "/chat-list", ChatListController, :index
    get "/chat-list/search", ChatListController, :search
    get "/chat-list/idle-state", ChatListController, :idle_state
    get "/chat-list/:id/summary", ChatListController, :summary

    get "/chat-state/:id", ChatStateController, :state
    get "/chat-state/:id/settings", ChatStateController, :settings
    get "/chat-state/:id/prompt-context", ChatStateController, :prompt_context
    get "/chat-state/:id/idle-state", ChatStateController, :idle_state

    get "/chat-search/:id/messages", ChatSearchController, :messages

    post "/chat-branches/:id/switch", ChatBranchesController, :switch
    post "/chat-branches/:id/activate", ChatBranchesController, :activate
    post "/chat-branches/:id/move-to-new-chat", ChatBranchesController, :move_to_new_chat

    post "/chat-generation/:id/send", ChatGenerationController, :send
    post "/chat-generation/:id/generate", ChatGenerationController, :generate
    post "/chat-generation/:id/branch-to-new-chat", ChatGenerationController, :branch_to_new_chat
    post "/chat-generation/:id/handoff", ChatGenerationController, :handoff

    get "/chat-shares/:id", ChatSharesController, :show
    put "/chat-shares/:id", ChatSharesController, :update

    post "/chat-uploads/:chat_id", ChatUploadsController, :create
    get "/chat-uploads/:chat_id/:upload_id", ChatUploadsController, :show
    put "/chat-uploads/:chat_id/:upload_id/chunk", ChatUploadsController, :append_chunk
    delete "/chat-uploads/:chat_id/:upload_id", ChatUploadsController, :delete

    post "/chat-messages/:id/cancel", ChatMessagesController, :cancel
    post "/chat-messages/:id/retry-last-step", ChatMessagesController, :retry_last_step

    post "/chat-messages/:message_id/steps/:step_id/retry-from-step",
         ChatMessagesController,
         :retry_from_step

    post "/chat-messages/:id/delete", ChatMessagesController, :delete
    post "/chat-messages/:id/bookmark", BookmarksController, :toggle_message
    patch "/chat-messages/:id", ChatMessagesController, :update
    get "/chat-messages/:id/poll", ChatMessagesController, :poll
    get "/chat-messages/:id/working", ChatMessagesController, :working

    get "/chat-messages/:message_id/steps/:step_id/raw", ChatMessagesController, :step_raw

    get "/chat-messages/:message_id/contents/:content_id/full",
        ChatMessagesController,
        :content_full

    get "/chat-messages/:message_id/contents/:content_id/file",
        ChatMessagesController,
        :content_file

    post "/knowledge-blocks/markdown-import/preview", KnowledgeBlocksMarkdownController, :preview
    post "/knowledge-blocks/markdown-import", KnowledgeBlocksMarkdownController, :import

    get "/tools/types", ToolsController, :types
    get "/llm-provider-types", LlmProvidersController, :types
    post "/tools/:id/discover", ToolsController, :discover
    patch "/tools/:id/fixed-functions/:name", ToolsController, :update_fixed_function
    patch "/tool-functions/:id", ToolsController, :update_function
    get "/llm-usage", LlmUsageController, :index
    get "/llm-providers/:id/models", LlmProvidersController, :models
    get "/bots/:id/shares", BotSharesController, :show
    put "/bots/:id/shares", BotSharesController, :update
    get "/llm-configurations/:id/shares", LlmConfigurationSharesController, :show
    put "/llm-configurations/:id/shares", LlmConfigurationSharesController, :update
  end

  scope "/api/bff", IntellectualClubWeb.Bff do
    pipe_through :api_mixed_session

    get "/bots/:id/image", BotImagesController, :show
    post "/bots/:id/image", BotImagesController, :update
    delete "/bots/:id/image", BotImagesController, :delete

    get "/knowledge-blocks/:id/image", KnowledgeBlockImagesController, :show
    post "/knowledge-blocks/:id/image", KnowledgeBlockImagesController, :update
    delete "/knowledge-blocks/:id/image", KnowledgeBlockImagesController, :delete
    get "/knowledge-blocks/:id/files", KnowledgeBlockFilesController, :index
    post "/knowledge-blocks/:id/files", KnowledgeBlockFilesController, :create
    get "/knowledge-blocks/:id/files/:attachment_id", KnowledgeBlockFilesController, :show
    patch "/knowledge-blocks/:id/files/:attachment_id", KnowledgeBlockFilesController, :update
    delete "/knowledge-blocks/:id/files/:attachment_id", KnowledgeBlockFilesController, :delete

    post "/knowledge-blocks/markdown-export", KnowledgeBlocksMarkdownController, :export
  end

  scope "/api/ash" do
    pipe_through :ash_json_api
    forward "/", IntellectualClubWeb.AshJsonApiRouter
  end

  scope "/" do
    pipe_through :browser

    import AshAdmin.Router

    ash_admin "/admin",
      on_mount: [
        AshAuthentication.Phoenix.LiveSession,
        {IntellectualClubWeb.LiveUserAuth, :admin_required}
      ],
      session: [{AshAuthentication.Phoenix.LiveSession, :generate_session, []}]
  end

  # Other scopes may use custom stacks.
  # scope "/api", IntellectualClubWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:intellectual_club, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IntellectualClubWeb.Telemetry
    end
  end
end
