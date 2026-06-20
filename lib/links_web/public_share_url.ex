defmodule LinksWeb.PublicShareUrl do
  @moduledoc false

  @share_segment "/share/"

  @doc """
  Returns `{:ok, token}` when `url` points at this app's public share route.
  """
  def parse(url) when is_binary(url) do
    with %URI{path: path} when is_binary(path) <- URI.parse(String.trim(url)),
         true <- String.starts_with?(path, share_path_prefix()),
         token when is_binary(token) <- extract_token(path),
         true <- valid_token?(token) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp share_path_prefix do
    case base_path() do
      "/" -> @share_segment
      base -> base <> @share_segment
    end
  end

  defp base_path do
    :links
    |> Application.get_env(LinksWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:path, "/")
    |> LinksWeb.BaseUrl.normalize_path()
    |> case do
      nil -> "/"
      path -> path
    end
  end

  defp extract_token(path) do
    case String.split(path, share_path_prefix(), parts: 2) do
      [_, rest] ->
        rest
        |> String.trim_leading("/")
        |> String.split(["/", "?", "#"], parts: 2)
        |> List.first()

      _ ->
        nil
    end
  end

  defp valid_token?(token) when is_binary(token) do
    String.length(token) >= 24 and String.length(token) <= 128
  end
end
