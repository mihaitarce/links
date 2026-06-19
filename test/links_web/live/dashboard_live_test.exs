defmodule LinksWeb.DashboardLiveTest do
  use LinksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Links.CollectionsFixtures

  alias Links.Collections

  describe "dashboard access" do
    test "redirects anonymous users to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
    end

    test "renders the full-width dashboard for signed-in users", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      collection_fixture(scope, %{title: "Reading"})
      bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Paste a new link"
      assert html =~ "Inbox"
      assert html =~ "Projects"
      assert html =~ "Reading"
      assert html =~ "Inbox link"
    end

    test "creates new links in the inbox", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> form("#new-link-form", bookmark: %{url: "https://example.com/new"})
        |> render_submit()

      assert html =~ "https://example.com/new"
    end

    test "inbox bookmark lists are sortable", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="bookmarks-sidebar")
      assert html =~ ~s(id="bookmarks-zone-inbox")
      assert html =~ ~s(phx-hook="CollectionBookmarkSort")
      assert html =~ ~s(data-collection-id="inbox")
      assert html =~ "bookmark-drag-handle"
    end

    test "moves bookmarks between inbox and collections from the dashboard", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      collection = collection_fixture(scope, %{title: "Reading"})

      inbox_bookmark =
        bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert render_click_move_bookmark(lv, %{
               "id" => to_string(inbox_bookmark.id),
               "collection_id" => to_string(collection.id),
               "ordered_ids" => [to_string(inbox_bookmark.id)]
             })

      assert Collections.get_bookmark!(inbox_bookmark.id).collection_id == collection.id

      {:ok, collection_bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Collection link",
          url: "https://example.com/collection",
          collection_id: collection.id
        })

      assert render_click_move_bookmark(lv, %{
               "id" => to_string(collection_bookmark.id),
               "collection_id" => nil,
               "ordered_ids" => [to_string(collection_bookmark.id)]
             })

      assert Collections.get_bookmark!(collection_bookmark.id).collection_id == nil
    end

    test "collection bookmark lists are sortable", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      collection = collection_fixture(scope, %{title: "Reading"})

      {:ok, _bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Docs",
          url: "https://example.com/docs",
          collection_id: collection.id
        })

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="collections-zone-root")
      assert html =~ ~s(id="bookmarks-sidebar")
      assert html =~ ~s(phx-hook="CollectionBookmarkSort")
      assert html =~ ~s(data-bookmark-sortable)
      assert html =~ ~s(data-collection-id="#{collection.id}")
      assert html =~ "bookmark-drag-handle"
    end

    test "shows a new sub-collection in the tree after creation", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#collection-#{parent.id} summary")
      |> render_click()

      html =
        lv
        |> form("#child-collection-form", child_collection: %{title: "Child Folder"})
        |> render_submit()

      assert html =~ "Child Folder"
      assert has_element?(lv, "#collection-#{parent.id}")
    end

    test "renders fetched page title after metadata is stored", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})

      bookmark =
        bookmark_fixture(scope, %{title: "https://example.com", url: "https://example.com"})

      {:ok, _bookmark} =
        Collections.update_bookmark_metadata(bookmark, %{
          page_title: "Example Domain",
          favicon_data: <<0, 1, 2>>,
          favicon_content_type: "image/png",
          favicon_byte_size: 3,
          favicon_source_url: "https://example.com/favicon.ico",
          metadata_fetched_at: DateTime.utc_now(:second)
        })

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Example Domain"
      assert html =~ ~s(/bookmarks/#{bookmark.id}/favicon)
    end
  end

  defp render_click_move_bookmark(view, params) do
    view
    |> element("#bookmarks-sidebar")
    |> render_hook("move_bookmark", params)
  end
end
