defmodule LinksWeb.BaseUrl do
  @moduledoc false

  @doc """
  Normalizes `PHOENIX_BASE_URL` to an endpoint `:url` path.

  The reverse proxy should strip this path prefix before forwarding requests
  to Phoenix. The path is used for URL generation and client socket paths.
  """
  def normalize_path(nil), do: nil
  def normalize_path(""), do: nil

  def normalize_path(path) when is_binary(path) do
    path =
      path
      |> String.trim()
      |> case do
        "" -> "/"
        trimmed -> ensure_leading_slash(trimmed)
      end

    path
    |> String.trim_trailing("/")
    |> case do
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
