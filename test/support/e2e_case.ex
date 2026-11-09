defmodule ContextArchive.E2ECase do
  @moduledoc """
  The test case for every archive test. Machines send files with the real shipper and
  the real ingest API, the server parses them on its real Oban queues, and readers use
  the real read API, all over HTTP to the running server (`ContextArchive.Archive`).
  The test database and the run's raw directory are emptied before each test
  (`ContextArchive.DataCase.reset!/0`). Tests are serial: they share one server.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import ContextArchive.Archive
      import ContextArchive.DataCase, only: [eventually: 1, eventually: 2]
      alias ContextArchiveWeb.HTTP
    end
  end

  setup _tags do
    ContextArchive.DataCase.reset!()
    :ok
  end
end
