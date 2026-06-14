defmodule LinksWeb.BookmarkFaviconController do
  use LinksWeb, :controller

  alias Links.Collections

  def show(conn, %{"id" => id}) do
    bookmark = Collections.get_bookmark!(id)

    if Collections.can_view_bookmark?(conn.assigns.current_scope, bookmark) &&
         bookmark.favicon_data do
      conn
      |> put_resp_content_type(bookmark.favicon_content_type || "application/octet-stream")
      |> put_resp_header("cache-control", "private, max-age=86400")
      |> send_resp(200, bookmark.favicon_data)
    else
      send_resp(conn, 404, "Not found")
    end
  end
end
