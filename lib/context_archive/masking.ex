defmodule ContextArchive.Masking do
  @moduledoc """
  Masks secret-looking strings in text returned by the API. The archive keeps the
  original bytes; masking only applies to responses. Unmasked output is available to
  admin tokens only and never through a tool gateway.

  Patterns favour recall for well-known credential shapes over catching everything;
  arbitrary high-entropy strings are not masked (they would destroy hashes and IDs).
  """

  @patterns [
    {"private_key",
     ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/s},
    {"anthropic_key", ~r/sk-ant-[A-Za-z0-9_\-]{20,}/},
    {"openai_key", ~r/sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}/},
    {"stripe_key", ~r/(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}/},
    {"github_token", ~r/(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}/},
    {"gitlab_token", ~r/glpat-[A-Za-z0-9_\-]{20,}/},
    {"slack_token", ~r/xox[abposr]-[A-Za-z0-9\-]{10,}/},
    {"aws_key", ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/},
    {"google_key", ~r/AIza[0-9A-Za-z_\-]{35}/},
    {"npm_token", ~r/npm_[A-Za-z0-9]{30,}/},
    {"tailscale_key", ~r/tskey-[A-Za-z0-9\-]{20,}/},
    {"context_archive_token", ~r/\bca_[A-Za-z0-9_\-]{30,}/},
    {"jwt", ~r/\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}/},
    {"bearer", ~r/(?i:bearer)\s+[A-Za-z0-9._~+\/\-]{20,}=*/},
    {"url_credentials", ~r/(?<=:\/\/)[^\s:@\/]+:[^\s@\/]{6,}(?=@)/},
    {"assignment",
     ~r/(?i:(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|client[_-]?secret)["']?\s*[:=]\s*["']?)[A-Za-z0-9_\-.\/+=]{12,}/}
  ]

  @doc "Masks known secret shapes in `text`."
  def mask(text) when is_binary(text) do
    Enum.reduce(@patterns, text, fn {name, regex}, acc ->
      Regex.replace(regex, acc, fn match ->
        if name == "assignment", do: keep_key(match), else: "[masked:#{name}]"
      end)
    end)
  end

  def mask(other), do: other

  # For `password: value` keep the key so the text stays readable.
  defp keep_key(match) do
    case Regex.run(~r/^(.*?[:=]\s*["']?)/s, match) do
      [_, key] -> key <> "[masked:secret]"
      _ -> "[masked:secret]"
    end
  end

  @doc "Masks every string inside a JSON-like term."
  def mask_deep(value) when is_binary(value), do: mask(value)
  def mask_deep(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, mask_deep(v)} end)
  def mask_deep(value) when is_list(value), do: Enum.map(value, &mask_deep/1)
  def mask_deep(value), do: value
end
