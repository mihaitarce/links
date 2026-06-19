defmodule LinksWeb.DashboardLiveTest do
  use LinksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Links.AccountsFixtures
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

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="collections-zone-root")
      assert html =~ ~s(data-collection-sortable)
      assert html =~ ~s(data-parent-id="root")
      assert html =~ ~s(id="bookmarks-sidebar")
      assert html =~ ~s(phx-hook="CollectionBookmarkSort")
      assert html =~ ~s(data-bookmark-sortable)
      assert html =~ ~s(data-collection-id="#{collection.id}")
      assert html =~ ~s(data-readonly="false")
      assert html =~ "bookmark-drag-handle"
      assert has_element?(lv, "#collection-#{collection.id} summary .badge.badge-ghost", "1")
    end

    test "reorders collections from the dashboard", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})

      {:ok, first} = Collections.create_collection(scope, %{title: "Alpha"})
      {:ok, second} = Collections.create_collection(scope, %{title: "Beta"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert render_reorder_collections(lv, %{
               "parent_id" => "root",
               "ordered_ids" => [to_string(second.id), to_string(first.id)]
             })

      assert Collections.get_collection!(second.id).position == 0
      assert Collections.get_collection!(first.id).position == 1
    end

    test "reorders read-only shared collection mounts from the dashboard", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)
      {:ok, own} = Collections.create_collection(collaborator_scope, %{title: "Mine"})

      conn = log_in_user(conn, collaborator)
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="collection-#{mount.id}" data-readonly="true" data-reorderable="true")

      assert render_reorder_collections(lv, %{
               "parent_id" => "root",
               "ordered_ids" => [to_string(mount.id), to_string(own.id)]
             })

      assert Collections.get_collection!(mount.id).position == 0
      assert Collections.get_collection!(own.id).position == 1
    end

    test "shows total bookmark counts including sub-collections", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, _} =
        Collections.create_bookmark(scope, %{
          title: "Parent link",
          url: "https://example.com/parent",
          collection_id: parent.id
        })

      {:ok, _} =
        Collections.create_bookmark(scope, %{
          title: "Child link",
          url: "https://example.com/child",
          collection_id: child.id
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#collection-#{parent.id} summary .badge.badge-ghost", "2")
      assert has_element?(lv, "#collection-#{child.id} summary .badge.badge-ghost", "1")
    end

    test "keeps collection trees collapsed on initial load", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ ~s(<details open)
    end

    test "collapsing a collection clears the detail panel", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#collection-#{parent.id} summary")
      |> render_click()

      assert has_element?(lv, "#collection-form")

      html =
        lv
        |> element("#collection-#{parent.id} summary")
        |> render_click()

      refute html =~ ~s(id="collection-form")
      assert html =~ "Select a collection or bookmark"
    end

    test "shows shared icon on owned collections shared with collaborators", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      collection = collection_fixture(owner_scope, %{title: "Shared Project"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, collection, collaborator.email, true)

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "#collection-#{collection.id} summary [aria-label='Shared with others']"
             )
    end

    test "shows collaboration icons only on shared root collections", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})

      collection_fixture(owner_scope, %{title: "Child Folder", parent_id: parent.id})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, parent, collaborator.email, true)

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#collection-#{mount.id} > details > summary")
      |> render_click()

      html = render(lv)

      assert html =~ "Shared Parent"
      assert html =~ "Child Folder"

      assert has_element?(
               lv,
               "#collection-#{mount.id} summary [aria-label='Read-only collaboration']"
             )

      assert Enum.count(:binary.matches(html, "Read-only collaboration")) == 1
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

  defp render_reorder_collections(view, params) do
    view
    |> element("#bookmarks-sidebar")
    |> render_hook("reorder_collections", params)
  end
end
