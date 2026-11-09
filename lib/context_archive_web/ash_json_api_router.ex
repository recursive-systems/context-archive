defmodule ContextArchiveWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: [ContextArchive.Corpus],
    open_api: "/open_api",
    open_api_title: "Context Archive",
    open_api_version: "1.0.0"
end
