defmodule LinksWeb.BookmarkFaviconControllerTest do
  use LinksWeb.ConnCase

  import Links.AccountsFixtures
  import Links.CollectionsFixtures

  alias Links.Collections

  test "serves stored favicon data for visible bookmarks", %{conn: conn} do
    %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
    bookmark = bookmark_fixture(scope)

    {:ok, bookmark} =
      Collections.update_bookmark_metadata(bookmark, %{
        favicon_data: <<1, 2, 3>>,
        favicon_content_type: "image/png",
        favicon_byte_size: 3
      })

    conn = get(conn, ~p"/bookmarks/#{bookmark.id}/favicon")

    assert response(conn, 200) == <<1, 2, 3>>
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
  end

  test "does not serve favicon data to another user", %{conn: conn} do
    owner_scope = user_scope_fixture()
    bookmark = bookmark_fixture(owner_scope)

    {:ok, bookmark} =
      Collections.update_bookmark_metadata(bookmark, %{
        favicon_data: <<1, 2, 3>>,
        favicon_content_type: "image/png",
        favicon_byte_size: 3
      })

    other_user = user_fixture()

    conn =
      conn
      |> log_in_user(other_user)
      |> get(~p"/bookmarks/#{bookmark.id}/favicon")

    assert response(conn, 404) == "Not found"
  end
end
