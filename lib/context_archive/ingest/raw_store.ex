defmodule ContextArchive.Ingest.RawStore do
  @moduledoc """
  Byte-exact storage of stream generations: `<root>/<source_id>/<stream_id>.bin`.

  Writes happen inside the append transaction, before the database commit. If a
  commit fails after the bytes were written, the file is longer than the stream's
  `bytes_received`; the next write at that offset truncates the uncommitted tail
  first. A file shorter than the expected offset means lost data and is an error,
  never silently papered over.
  """

  @head_bytes 4096

  def head_bytes, do: @head_bytes

  def root do
    Application.fetch_env!(:context_archive, __MODULE__) |> Keyword.fetch!(:root)
  end

  def path(source_id, stream_id), do: Path.join([root(), source_id, "#{stream_id}.bin"])

  @doc "Writes `data` at `offset`, then fsyncs. Returns :ok or {:error, reason}."
  def write(source_id, stream_id, offset, data) when is_binary(data) do
    file = path(source_id, stream_id)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, io} <- :file.open(file, [:read, :write, :binary, :raw]) do
      try do
        with {:ok, size} <- :file.position(io, :eof),
             :ok <- ensure_offset(io, size, offset),
             :ok <- :file.pwrite(io, offset, data),
             :ok <- :file.datasync(io) do
          :ok
        end
      after
        :file.close(io)
      end
    end
  end

  defp ensure_offset(_io, size, offset) when size == offset, do: :ok

  defp ensure_offset(io, size, offset) when size > offset do
    with {:ok, _} <- :file.position(io, offset), do: :file.truncate(io)
  end

  defp ensure_offset(_io, size, offset) when size < offset,
    do: {:error, {:raw_store_behind, size, offset}}

  @doc "Reads `length` bytes at `offset`."
  def read(source_id, stream_id, offset, length) do
    with {:ok, io} <- :file.open(path(source_id, stream_id), [:read, :binary, :raw]) do
      try do
        case :file.pread(io, offset, length) do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          other -> other
        end
      after
        :file.close(io)
      end
    end
  end

  @doc "SHA-256 of the first min(#{@head_bytes}, size) bytes, as the shipper computes it."
  def head_sha256(source_id, stream_id, size) do
    with {:ok, head} <- read(source_id, stream_id, 0, min(@head_bytes, size)) do
      {:ok, sha256(head)}
    end
  end

  def sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
