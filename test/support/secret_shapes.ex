defmodule ContextArchive.SecretShapes do
  @moduledoc """
  Made-up values in the shapes of the credentials the shipper masks. They are
  assembled at run time, so no source file holds anything a secret scanner would flag.
  """

  @doc "A made-up value: `prefix` plus `n` characters cycling through `alphabet`."
  def fake(prefix, n, alphabet \\ "aB3"),
    do: prefix <> String.slice(String.duplicate(alphabet, n), 0, n)

  def gh, do: fake("gh" <> "o_", 36)
  def gh_pat, do: fake("github" <> "_pat_", 82, "a1_B")
  def sk_ant, do: fake("sk" <> "-ant-api03-", 90, "Xy9-")
  def sk, do: fake("sk" <> "-proj-", 48)
  def lin, do: fake("lin" <> "_api_", 40)
  def fw, do: fake("f" <> "w_", 24)
  def xoxb, do: fake("xo" <> "xb-", 50, "12-ab")
  def tg, do: "1234567890:" <> fake("", 35, "Ab_-9")
  def restic, do: "hunter2-" <> fake("", 20)

  @doc "The secret part of every shape: none of these may reach the archive."
  def secrets do
    [
      gh(),
      gh_pat(),
      sk_ant(),
      sk(),
      lin(),
      fw(),
      xoxb(),
      tg() |> String.split(":") |> List.last(),
      restic()
    ]
  end

  @doc "Every shape as it appears in real output."
  def in_context do
    [
      gh(),
      gh_pat(),
      sk_ant(),
      sk(),
      lin(),
      fw(),
      xoxb(),
      "https://api.telegram.org/bot" <> tg() <> "/getMe",
      "RESTIC_PASSWORD=" <> restic()
    ]
  end
end
