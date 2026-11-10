defmodule ContextArchive.Build do
  @moduledoc """
  What this running instance was started from, so a deployment can say what it runs.
  `/health` and `/api/v1/status` report it.

  The revision is the commit, taken once when the application starts:

    * `CONTEXT_ARCHIVE_REVISION` when set (a Docker image has no checkout, so the image
      build passes it; see the Dockerfile);
    * otherwise, when the app runs from the root of its own checkout, that checkout's
      `HEAD`, with `-dirty` appended when the working tree differs from that commit;
    * `nil` when neither is available, or git does not answer cleanly and promptly.
      Unknown is reported as unknown, never guessed, and never keeps the app from starting.

  It describes the start, not the present: an instance running from a checkout in dev
  mode reloads code that changes under it, so move such a checkout only as part of a
  restart (docs/operations.md, "Deploying to the VM").
  """
  @key {__MODULE__, :info}
  @git_timeout :timer.seconds(5)

  @doc "Records the revision and start time. Called once, when the application starts."
  def record do
    :persistent_term.put(@key, %{revision: revision(), started_at: DateTime.utc_now(:second)})
  end

  @doc "The revision (or `nil`) and start time recorded by `record/0`."
  def info, do: :persistent_term.get(@key)

  defp revision do
    case Application.get_env(:context_archive, :revision) do
      nil -> checkout_revision()
      configured -> configured
    end
  end

  defp checkout_revision do
    task =
      Task.async(fn ->
        try do
          read_checkout()
        rescue
          _ -> nil
        end
      end)

    case Task.yield(task, @git_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, revision} -> revision
      _ -> nil
    end
  end

  # Git answers for whichever repository encloses the working directory, so only a
  # checkout whose root is where the app runs (mix.exs beside it) counts as its own.
  defp read_checkout do
    with git when is_binary(git) <- System.find_executable("git"),
         true <- File.regular?("mix.exs"),
         {:ok, root} <- git(git, ["rev-parse", "--show-toplevel"]),
         true <- root == File.cwd!(),
         {:ok, commit} <- git(git, ["rev-parse", "--verify", "HEAD"]),
         true <- commit_id?(commit),
         {:ok, changes} <- git(git, ["--no-optional-locks", "status", "--porcelain"]) do
      if changes == "", do: commit, else: commit <> "-dirty"
    else
      _ -> nil
    end
  end

  # A SHA-1 or SHA-256 object name, as git prints it.
  defp commit_id?(text),
    do: byte_size(text) in [40, 64] and match?({:ok, _}, Base.decode16(text, case: :lower))

  # Warnings git prints land in the output too: on `status` they read as a dirty tree, on
  # `rev-parse` they fail the commit check. Both err towards not vouching for a commit.
  defp git(git, args) do
    case System.cmd(git, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  end
end
