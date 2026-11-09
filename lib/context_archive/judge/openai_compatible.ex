defmodule ContextArchive.Judge.OpenAICompatible do
  @moduledoc """
  Any OpenAI-compatible chat completions API: `url` is the API base (for example
  `https://api.openai.com/v1`, `https://openrouter.ai/api/v1` or a local
  `http://127.0.0.1:11434/v1`), `api_key` is sent as a bearer token when set, and
  `model` is required. The model answers yes or no in JSON; yes scores 1.0, no 0.0.
  """
  @behaviour ContextArchive.Judge.Adapter
  alias ContextArchive.Judge
  alias ContextArchive.Judge.Adapter

  @impl true
  def default_model, do: nil

  @impl true
  def ask(request, opts, timeout) do
    with {:ok, base} <- Adapter.url(opts),
         {:ok, model} <- Adapter.model(opts) do
      body = %{
        model: model,
        temperature: 0,
        messages: [
          %{role: "system", content: system_prompt()},
          %{role: "user", content: Jason.encode!(request)}
        ]
      }

      headers =
        case opts[:api_key] do
          key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
          _ -> []
        end

      case Req.post(base <> "/chat/completions",
             json: body,
             headers: headers,
             receive_timeout: timeout,
             retry: false
           ) do
        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => content}} | _]} = resp
         }}
        when is_binary(content) ->
          case answer(content) do
            {:ok, yes?} -> {:ok, if(yes?, do: 1.0, else: 0.0), resp["model"] || model}
            :error -> {:error, "judge reply was not a yes or no"}
          end

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, e} ->
          {:error, Exception.message(e)}
      end
    end
  end

  defp system_prompt do
    criteria = Judge.criteria()

    """
    #{Judge.instructions()}
    The user message is JSON with `question` and `passage`.
    Answer true when: #{criteria.true}
    Answer false when: #{criteria.false}
    Reply with only this JSON and nothing else: {"answer": true} or {"answer": false}
    """
  end

  # The JSON reply, or a bare true/false when a model wraps or skips the JSON.
  defp answer(content) do
    case Jason.decode(String.trim(content)) do
      {:ok, %{"answer" => yes?}} when is_boolean(yes?) ->
        {:ok, yes?}

      _ ->
        case Regex.run(~r/"answer"\s*:\s*(true|false)|^\s*(true|false)\s*$/i, content) do
          [_, word] -> {:ok, String.downcase(word) == "true"}
          [_, "", word] -> {:ok, String.downcase(word) == "true"}
          _ -> :error
        end
    end
  end
end
