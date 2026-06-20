defmodule Links.Workers.FetchBookmarkMetadataWorker do
  @moduledoc """
  Fetches page metadata for a bookmark after it is created.
  """

  use Oban.Worker, queue: :metadata, max_attempts: 3

  alias Links.Collections

  @html_limit 1_000_000
  @favicon_limit 100_000
  @allowed_favicon_types [
    "image/x-icon",
    "image/vnd.microsoft.icon",
    "image/png",
    "image/svg+xml",
    "image/jpeg",
    "image/gif",
    "image/webp"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bookmark_id" => bookmark_id}} = job) do
    result =
      with {:ok, bookmark} <- fetch_bookmark(bookmark_id),
           {:ok, html_response} <- fetch(bookmark.url),
           :ok <- validate_html_response(html_response),
           {:ok, html} <- bounded_body(html_response.body, @html_limit) do
        title = extract_title(html)

        favicon_attrs =
          html
          |> favicon_url(bookmark.url)
          |> fetch_favicon_attrs()

        {:ok, _bookmark} =
          Collections.update_bookmark_metadata(
            bookmark,
            favicon_attrs
            |> Map.put(:page_title, title)
            |> Map.put(:metadata_fetched_at, DateTime.utc_now(:second))
          )

        Phoenix.PubSub.broadcast(
          Links.PubSub,
          "bookmarks",
          {:bookmark_metadata_updated, bookmark.id}
        )

        Collections.broadcast_bookmark_list_changed(bookmark)

        :ok
      else
        {:cancel, reason} ->
          broadcast_metadata_finished(bookmark_id)
          {:cancel, reason}

        {:error, reason} ->
          if job.attempt >= job.max_attempts do
            broadcast_metadata_finished(bookmark_id)
          end

          {:error, reason}
      end

    result
  end

  defp broadcast_metadata_finished(bookmark_id) do
    Phoenix.PubSub.broadcast(
      Links.PubSub,
      "bookmarks",
      {:bookmark_metadata_failed, bookmark_id}
    )
  end

  defp fetch(url) do
    fetch(url, 3)
  end

  defp fetch(url, redirects_left) do
    with :ok <- validate_url(url),
         {:ok, response} <-
           Req.get(
             url,
             [
               redirect: false,
               receive_timeout: 5_000,
               connect_options: [timeout: 5_000],
               headers: [{"user-agent", "LinksBot/0.1"}]
             ]
             |> Keyword.merge(metadata_req_options())
           ) do
      maybe_follow_redirect(response, url, redirects_left)
    end
  end

  defp maybe_follow_redirect(response, _url, _redirects_left)
       when response.status not in 300..399 do
    {:ok, response}
  end

  defp maybe_follow_redirect(_response, _url, 0), do: {:error, :too_many_redirects}

  defp maybe_follow_redirect(response, url, redirects_left) do
    location =
      response.headers
      |> Map.get("location", [])
      |> List.first()

    if location do
      url
      |> URI.parse()
      |> URI.merge(location)
      |> URI.to_string()
      |> fetch(redirects_left - 1)
    else
      {:error, :redirect_without_location}
    end
  end

  defp fetch_bookmark(bookmark_id) do
    case Collections.get_bookmark(bookmark_id) do
      nil -> {:cancel, :bookmark_not_found}
      bookmark -> {:ok, bookmark}
    end
  end

  defp validate_html_response(%Req.Response{status: status, headers: headers})
       when status in 200..299 do
    content_type = response_content_type(headers)

    if content_type == "" or String.starts_with?(content_type, "text/html") do
      :ok
    else
      {:cancel, :not_html}
    end
  end

  defp validate_html_response(%Req.Response{status: status}), do: {:error, {:bad_status, status}}

  defp bounded_body(body, limit) when is_binary(body) do
    if byte_size(body) <= limit do
      {:ok, body}
    else
      {:cancel, :response_too_large}
    end
  end

  defp bounded_body(_body, _limit), do: {:cancel, :invalid_response_body}

  defp extract_title(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("title")
    |> Floki.text()
    |> String.trim()
    |> decode_page_title()
    |> case do
      nil -> nil
      "" -> nil
      title -> String.slice(title, 0, 240)
    end
  rescue
    _ -> nil
  end

  defp decode_page_title(title) when is_binary(title), do: HtmlEntities.decode(title)
  defp decode_page_title(_), do: nil

  defp metadata_req_options do
    Application.get_env(:links, :metadata_req_options, [])
  end

  defp favicon_url(html, page_url) do
    document = Floki.parse_document!(html)

    icon_href =
      document
      |> Floki.find("link[rel]")
      |> Enum.find_value(fn node ->
        rel =
          node
          |> Floki.attribute("rel")
          |> List.first()
          |> to_string()
          |> String.downcase()

        if String.contains?(rel, "icon") do
          node
          |> Floki.attribute("href")
          |> List.first()
        end
      end)

    icon_href = icon_href || "/favicon.ico"

    page_url
    |> URI.parse()
    |> URI.merge(icon_href)
    |> URI.to_string()
  rescue
    _ ->
      page_url
      |> URI.parse()
      |> URI.merge("/favicon.ico")
      |> URI.to_string()
  end

  defp fetch_favicon_attrs(nil), do: %{}

  defp fetch_favicon_attrs(url) do
    with :ok <- validate_url(url),
         {:ok, response} <- fetch(url),
         :ok <- validate_favicon_response(response),
         {:ok, data} <- bounded_body(response.body, @favicon_limit) do
      %{
        favicon_data: data,
        favicon_content_type: response_content_type(response.headers),
        favicon_byte_size: byte_size(data),
        favicon_source_url: url
      }
    else
      _ -> %{}
    end
  end

  defp validate_favicon_response(%Req.Response{status: status, headers: headers})
       when status in 200..299 do
    content_type = response_content_type(headers)

    if content_type in @allowed_favicon_types do
      :ok
    else
      {:cancel, :unsupported_favicon_type}
    end
  end

  defp validate_favicon_response(%Req.Response{status: status}),
    do: {:error, {:bad_status, status}}

  defp response_content_type(headers) do
    headers
    |> Map.get("content-type", [])
    |> List.first()
    |> to_string()
    |> String.split(";")
    |> List.first()
    |> String.downcase()
    |> String.trim()
  end

  defp validate_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:cancel, :unsupported_scheme}

      not is_binary(uri.host) or uri.host == "" ->
        {:cancel, :missing_host}

      unsafe_host?(uri.host) ->
        {:cancel, :unsafe_host}

      true ->
        :ok
    end
  end

  defp unsafe_host?(host) do
    host = String.downcase(host)

    host in ["localhost"] or String.ends_with?(host, ".localhost") or private_ip_host?(host) or
      resolved_private_host?(host)
  end

  defp private_ip_host?(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> private_ip?(address)
      {:error, :einval} -> false
    end
  end

  defp resolved_private_host?(host) do
    host
    |> String.to_charlist()
    |> :inet.getaddrs(:inet)
    |> case do
      {:ok, addresses} -> Enum.any?(addresses, &private_ip?/1)
      {:error, _reason} -> true
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({_, _, _, _}), do: false
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_ip?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp private_ip?({_, _, _, _, _, _, _, _}), do: false
end
