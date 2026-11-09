defmodule ContextArchiveWeb.IngestController do
  @moduledoc """
  Machine-facing intake used by the shipper. Not part of the public OpenAPI:
  Read tokens never reach these routes.

    GET  /ingest/v1/sources/:machine/streams?kind=K   latest generation per path
    POST /ingest/v1/sources/:machine/append           raw (gzip) body + X-Archive-* headers
  """
  use ContextArchiveWeb, :controller

  alias ContextArchive.Ingest

  # A single Pi session line has been seen at 2.6 MB; batches are capped at 8 MiB by
  # the shipper but one longer line is sent whole.
  @max_body 64 * 1024 * 1024

  def streams(conn, %{"machine" => machine} = params) do
    with :ok <- authorize_machine(conn, machine),
         {:ok, kind} <- fetch_param(params, "kind"),
         {:ok, streams} <- Ingest.stream_state(machine, kind, authorize?: false) do
      json(conn, %{streams: streams})
    else
      error -> error_response(conn, error)
    end
  end

  # The body is always read first, and every response uses the conn returned by
  # read_body: behind Tailscale Serve connections are kept alive, and a response on a
  # conn whose adapter state still has an unread body corrupts the next request.
  def append(conn, %{"machine" => machine}) do
    case read_body_data(conn) do
      {:ok, data, conn} -> do_append(conn, machine, data)
      {:error, reason, conn} -> error_response(conn, {:error, reason})
    end
  end

  defp do_append(conn, machine, data) do
    with :ok <- authorize_machine(conn, machine),
         {:ok, input} <- headers_input(conn, machine, data),
         {:ok, result} <- Ingest.append_bytes(input, authorize?: false) do
      case result do
        %{status: :ok} ->
          json(conn, %{generation: result.generation, offset: result.offset})

        %{status: :conflict} ->
          conn
          |> put_status(409)
          |> json(%{error: "conflict", generation: result.generation, offset: result.offset})
      end
    else
      error -> error_response(conn, error)
    end
  end

  defp authorize_machine(conn, machine) do
    if conn.assigns.api_token.kind == :ingest and conn.assigns.api_token.source_name == machine,
      do: :ok,
      else: {:error, :forbidden}
  end

  defp fetch_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:bad_request, "missing #{key}"}}
    end
  end

  defp read_body_data(conn) do
    case read_full_body(conn, "") do
      {:ok, body, conn} ->
        case get_req_header(conn, "content-encoding") do
          ["gzip"] ->
            try do
              {:ok, :zlib.gunzip(body), conn}
            rescue
              _ -> {:error, {:bad_request, "invalid gzip body"}, conn}
            end

          [] ->
            {:ok, body, conn}

          _ ->
            {:error, {:bad_request, "unsupported content-encoding"}, conn}
        end

      error ->
        error
    end
  end

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_timeout: 60_000) do
      {:ok, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) > @max_body,
          do: {:error, {:bad_request, "body too large"}, conn},
          else: {:ok, body, conn}

      {:more, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) > @max_body,
          do: {:error, {:bad_request, "body too large"}, conn},
          else: read_full_body(conn, body)

      {:error, reason} ->
        {:error, {:bad_request, "could not read body: #{inspect(reason)}"}, conn}
    end
  end

  defp headers_input(conn, machine, data) do
    h = fn name -> conn |> get_req_header("x-archive-" <> name) |> List.first() end

    with {:ok, generation} <- int(h.("generation")),
         {:ok, offset} <- int(h.("offset")),
         {:ok, length} <- int(h.("length")),
         true <- length == byte_size(data) || {:error, {:bad_request, "length mismatch"}},
         {:ok, mode} <- mode(h.("mode")),
         kind when is_binary(kind) <- h.("kind") || {:error, {:bad_request, "missing kind"}},
         path when is_binary(path) <- h.("path") || {:error, {:bad_request, "missing path"}},
         :ok <- safe_path(path),
         sha when is_binary(sha) <- h.("sha256") || {:error, {:bad_request, "missing sha256"}} do
      {:ok,
       %{
         machine: machine,
         kind: kind,
         path: path,
         mode: mode,
         generation: generation,
         offset: offset,
         sha256: sha,
         data: data
       }}
    end
  end

  defp mode("append"), do: {:ok, :append}
  defp mode("snapshot"), do: {:ok, :snapshot}
  defp mode(_), do: {:error, {:bad_request, "bad mode"}}

  defp int(nil), do: {:error, {:bad_request, "missing numeric header"}}

  defp int(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:bad_request, "bad numeric header"}}
    end
  end

  # Paths are relative to the shipper's root; they are identifiers here, never
  # filesystem paths on the server, but keep them boring anyway.
  defp safe_path(path) do
    cond do
      byte_size(path) > 1024 ->
        {:error, {:bad_request, "path too long"}}

      String.starts_with?(path, "/") or ".." in Path.split(path) ->
        {:error, {:bad_request, "path must be relative"}}

      true ->
        :ok
    end
  end

  defp error_response(conn, {:error, :forbidden}),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})

  defp error_response(conn, {:error, {:bad_request, message}}),
    do: conn |> put_status(400) |> json(%{error: message})

  defp error_response(conn, {:error, %Ash.Error.Invalid{} = error}),
    do: conn |> put_status(422) |> json(%{error: Exception.message(error)})

  defp error_response(conn, {:error, error}) when is_binary(error),
    do: conn |> put_status(422) |> json(%{error: error})

  defp error_response(conn, other) do
    require Logger
    Logger.error("ingest failed: #{inspect(other, limit: 5, printable_limit: 200)}")
    conn |> put_status(500) |> json(%{error: "internal error"})
  end
end
