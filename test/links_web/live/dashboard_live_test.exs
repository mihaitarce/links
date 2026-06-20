defmodule LinksWeb.DashboardLiveTest do
  use LinksWeb.ConnCase

  import Phoenix.LiveViewTest
  import Links.AccountsFixtures
  import Links.CollectionsFixtures

  alias Links.Bookmarks.Bookmark
  alias Links.Collections
  alias Links.Collections.Collection
  alias Links.Repo

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
      assert html =~ "Collections"
      assert html =~ "Reading"
      assert html =~ "Inbox link"
    end

    test "creates new links in the inbox", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> form("#new-link-form", new_bookmark: %{url: "https://example.com/new"})
        |> render_submit()

      assert html =~ "https://example.com/new"
      assert html =~ ~s(aria-label="Fetching link metadata")
      assert has_element?(lv, "#new-link-form input[type=\"url\"][value=\"\"]")
    end

    test "removes metadata spinner after background fetch completes", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> form("#new-link-form", new_bookmark: %{url: "https://example.com/spinner"})
      |> render_submit()

      bookmark = Repo.get_by!(Bookmark, url: "https://example.com/spinner")

      assert render(lv) =~ ~s(aria-label="Fetching link metadata")

      send(lv.pid, {:bookmark_metadata_updated, bookmark.id})

      html = render(lv)
      refute html =~ ~s(aria-label="Fetching link metadata")
    end

    test "deletes an inbox bookmark from the detail panel", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark = bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#bookmark-more-#{bookmark.id}")
      |> render_click()

      lv
      |> element("#bookmark-form button", "Delete")
      |> render_click()

      refute has_element?(lv, "#bookmark-#{bookmark.id}")
      assert has_element?(lv, "#inbox-empty-state", "Your inbox is empty")
    end

    test "keeps the new link input visible when a bookmark is selected", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark = bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#bookmark-more-#{bookmark.id}")
      |> render_click()

      assert has_element?(lv, "#new-link-form")
      assert has_element?(lv, "#new_bookmark_url")
      assert has_element?(lv, "#bookmark-form")
    end

    test "shows an empty label when the inbox has no bookmarks", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="inbox-empty-state")
      assert has_element?(lv, "#inbox-empty-state", "Your inbox is empty.")
    end

    test "keeps the inbox empty label in the list when bookmarks are present", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark = bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#bookmark-#{bookmark.id}")
      assert has_element?(lv, "#inbox-empty-state")
    end

    test "inbox bookmark lists are sortable", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="bookmarks-sidebar")
      assert html =~ ~s(id="bookmarks-zone-inbox")
      assert html =~ ~s(phx-hook="CollectionBookmarkSort")
      assert html =~ ~s(data-collection-id="inbox")
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

    test "reorders deeply nested collections from the dashboard", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, first} =
        Collections.create_collection(scope, %{title: "Grand A", parent_id: child.id})

      {:ok, second} =
        Collections.create_collection(scope, %{title: "Grand B", parent_id: child.id})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, ~s(#collection-#{first.id}[data-reorderable="true"]))
      assert has_element?(lv, ~s(#collection-#{second.id}[data-reorderable="true"]))

      assert render_reorder_collections(lv, %{
               "parent_id" => to_string(child.id),
               "ordered_ids" => [to_string(second.id), to_string(first.id)]
             })

      assert Collections.get_collection!(second.id).position == 0
      assert Collections.get_collection!(first.id).position == 1
    end

    test "marks nested collections as reorderable for editable collaborators", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})

      {:ok, first} =
        Collections.create_collection(owner_scope, %{title: "Child A", parent_id: parent.id})

      {:ok, second} =
        Collections.create_collection(owner_scope, %{title: "Child B", parent_id: parent.id})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, parent, collaborator.email, false)

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, ~s(#collection-#{first.id}[data-reorderable="true"]))
      assert has_element?(lv, ~s(#collection-#{second.id}[data-reorderable="true"]))

      assert render_reorder_collections(lv, %{
               "parent_id" => to_string(parent.id),
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

    test "collapsing a collection keeps the detail panel when opened via more", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})

      {:ok, lv, _html} = live(conn, ~p"/")

      open_collection_details(lv, parent.id)

      assert has_element?(lv, "#collection-form")

      lv
      |> element("#collection-#{parent.id} summary")
      |> render_click()

      assert has_element?(lv, "#collection-form")
    end

    test "more button opens detail panel without expanding the collection tree", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      _child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "#collection-#{parent.id} > details[open]")

      open_collection_details(lv, parent.id)

      assert has_element?(lv, "#collection-form")
      refute has_element?(lv, "#collection-#{parent.id} > details[open]")
    end

    test "more button does not collapse an expanded collection", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      _child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#collection-#{parent.id} > details > summary")
      |> render_click()

      assert has_element?(lv, "#collection-#{parent.id} > details[open]")

      open_collection_details(lv, parent.id)

      assert has_element?(lv, "#collection-form")
      assert has_element?(lv, "#collection-#{parent.id} > details[open]")
    end

    test "closes detail panel from modal close button", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})

      {:ok, lv, _html} = live(conn, ~p"/")

      open_collection_details(lv, parent.id)

      assert has_element?(lv, "#collection-form")
      assert has_element?(lv, "#detail-panel")

      lv
      |> element("#detail-modal-close")
      |> render_click()

      refute has_element?(lv, "#collection-form")
      refute has_element?(lv, "#detail-panel")
    end

    test "opens bookmark links in a new tab from the sidebar", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})

      bookmark =
        bookmark_fixture(scope, %{title: "External link", url: "https://example.com/external"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "#bookmark-#{bookmark.id} a[href='https://example.com/external'][target='_blank']"
             )

      refute has_element?(lv, "#bookmark-form")
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

    test "clears the collaborator form after sharing", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      lv
      |> form("#collaboration-form form",
        collaboration: %{email: collaborator.email, readonly: "true"}
      )
      |> render_submit()

      assert has_element?(lv, "#collaborators-list", collaborator.email)
      assert has_element?(lv, "#collaboration-form input[type='email'][value='']")

      refute has_element?(
               lv,
               "#collaboration-form input[name='collaboration[readonly]'][checked]"
             )
    end

    test "lists collaborators in the detail panel and revokes access", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      assert {:ok, mount} =
               Collections.create_collaboration(
                 owner_scope,
                 collection,
                 collaborator.email,
                 false
               )

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      assert has_element?(lv, "#collaborators-list")
      assert has_element?(lv, "#collaborator-#{mount.id}", collaborator.email)
      assert has_element?(lv, "#collaborator-#{mount.id}", "Can edit · Active")

      lv
      |> element("#revoke-collaborator-#{mount.id}")
      |> render_click()

      assert has_element?(lv, "#collaborator-#{mount.id}", "Revoked")
      refute has_element?(lv, "#revoke-collaborator-#{mount.id}")

      lv
      |> element("#restore-collaborator-#{mount.id}")
      |> render_click()

      assert has_element?(lv, "#collaborator-#{mount.id}", "Can edit · Active")
      assert has_element?(lv, "#revoke-collaborator-#{mount.id}")
      refute has_element?(lv, "#restore-collaborator-#{mount.id}")

      collaborator_scope = user_scope_fixture(collaborator)
      assert Collections.can_edit_collection?(collaborator_scope, collection.id)
    end

    test "updates collaborator tree when a collection is shared or revoked", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Live Shared"})

      conn = log_in_user(conn, collaborator)
      {:ok, lv, html} = live(conn, ~p"/")

      refute html =~ "Live Shared"

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      html = render(lv)
      assert html =~ "Live Shared"
      assert has_element?(lv, "#collection-#{mount.id}")

      assert {:ok, _mount} = Collections.revoke_collaboration(owner_scope, mount)

      render(lv)
      assert has_element?(lv, ~s(#collection-#{mount.id}[data-revoked="true"]))
      assert has_element?(lv, ~s(#collection-#{mount.id}[data-reorderable="true"]))
    end

    test "reorders revoked shared collection mounts from the dashboard", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Revoked Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert {:ok, _mount} = Collections.revoke_collaboration(owner_scope, mount)

      collaborator_scope = user_scope_fixture(collaborator)
      {:ok, own} = Collections.create_collection(collaborator_scope, %{title: "Mine"})

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, ~s(#collection-#{mount.id}[data-revoked="true"]))
      assert has_element?(lv, ~s(#collection-#{mount.id}[data-reorderable="true"]))

      assert render_reorder_collections(lv, %{
               "parent_id" => "root",
               "ordered_ids" => [to_string(mount.id), to_string(own.id)]
             })

      assert Collections.get_collection!(mount.id).position == 0
      assert Collections.get_collection!(own.id).position == 1
    end

    test "collaborator removing a shared collection deletes only their mount", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared To Remove"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, mount.id)

      assert has_element?(lv, "button", "Remove")

      lv
      |> element("button", "Remove")
      |> render_click()

      html = render(lv)
      refute html =~ "Shared To Remove"
      assert Collections.get_collection!(source.id).title == "Shared To Remove"
      refute Repo.get(Collection, mount.id)
    end

    test "shows a copy link button for active public shares", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Shared Publicly"})

      assert {:ok, share} = Collections.create_public_share(scope, collection)

      conn = log_in_user(conn, scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      assert has_element?(lv, "#copy-public-share-#{share.id}", "Copy link")
    end

    test "owner can restore a revoked public share from the detail panel", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Shared Publicly"})

      assert {:ok, share} = Collections.create_public_share(scope, collection)
      assert {:ok, _revoked} = Collections.revoke_public_share(scope, share)

      conn = log_in_user(conn, scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      refute has_element?(lv, "#copy-public-share-#{share.id}")
      assert has_element?(lv, "#restore-public-share-#{share.id}", "Restore")

      lv
      |> element("#restore-public-share-#{share.id}")
      |> render_click()

      assert has_element?(lv, "#copy-public-share-#{share.id}", "Copy link")
      refute has_element?(lv, "#restore-public-share-#{share.id}")
      assert Collections.get_public_share_by_token(share.token)
    end

    test "editable collaborator can create a public share from the detail panel", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared Publicly"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, mount.id)

      assert has_element?(lv, "#collaboration-form")
      assert has_element?(lv, "button", "Create public link")

      lv
      |> element("button", "Create public link")
      |> render_click()

      html = render(lv)
      assert html =~ "Copy link"
    end

    test "read-only collaborator cannot manage sharing from the detail panel", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared Read Only"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, mount.id)

      html = render(lv)
      refute html =~ ~s(id="collaboration-form")
      refute html =~ "Create public link"
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

      open_collection_details(lv, parent.id)

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

  defp open_collection_details(view, collection_id) do
    view
    |> element("#collection-more-#{collection_id}")
    |> render_click()

    view
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
