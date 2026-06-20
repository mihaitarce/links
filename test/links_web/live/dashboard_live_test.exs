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

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Paste a new link"
      assert html =~ "Inbox"
      assert html =~ "Collections"
      assert html =~ "Reading"
      assert html =~ "Inbox link"
      assert has_element?(lv, "#inbox-bookmark-count", "1")
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

    test "does not show completed checkbox for inbox links", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark = bookmark_fixture(scope, %{title: "Read me", url: "https://example.com/read"})
      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "#bookmark-completed-#{bookmark.id}")

      lv
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      refute has_element?(lv, "#bookmark-completed-input")
    end

    test "toggles completed on collection links", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      collection = collection_fixture(scope, %{title: "Reading"})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Read me",
          url: "https://example.com/read",
          collection_id: collection.id
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      refute Collections.get_bookmark!(bookmark.id).completed
      assert has_element?(lv, "#bookmark-completed-#{bookmark.id}:not([checked])")

      lv
      |> element("#bookmark-completed-#{bookmark.id}")
      |> render_click()

      assert Collections.get_bookmark!(bookmark.id).completed
      assert has_element?(lv, "#bookmark-completed-#{bookmark.id}[checked]")
      assert has_element?(lv, "#bookmark-#{bookmark.id} .bookmark-completed")
    end

    test "toggles completed from the link detail page", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      collection = collection_fixture(scope, %{title: "Reading"})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Detail link",
          url: "https://example.com/detail",
          collection_id: collection.id
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      refute Collections.get_bookmark!(bookmark.id).completed
      assert has_element?(lv, "#bookmark-completed-input:not([checked])")

      lv
      |> element("#bookmark-completed-input")
      |> render_click()

      assert Collections.get_bookmark!(bookmark.id).completed
      assert has_element?(lv, "#bookmark-completed-input[checked]")
      assert has_element?(lv, "#bookmark-#{bookmark.id} .bookmark-completed")
    end

    test "disables completed checkbox on read-only collection links", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      {:ok, bookmark} =
        Collections.create_bookmark(owner_scope, %{
          title: "Shared link",
          url: "https://example.com/shared",
          collection_id: source.id
        })

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#collection-#{mount.id} > details > summary")
      |> render_click()

      assert has_element?(
               lv,
               "#bookmark-completed-#{bookmark.id}[disabled]"
             )
    end

    test "adds an active public share URL as a read-only collection", %{conn: conn} do
      owner_scope = user_scope_fixture()
      subscriber_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope, %{title: "Shared Reading List"})

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)

      conn = log_in_user(conn, subscriber_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      share_url = "http://localhost:4000/share/#{share.token}"

      html =
        lv
        |> form("#new-link-form", new_bookmark: %{url: share_url})
        |> render_submit()

      assert html =~ "Shared Reading List"
      refute html =~ share_url

      mount =
        Repo.get_by!(Collection,
          owner_id: subscriber_scope.user.id,
          collaboration_id: collection.id
        )

      assert mount.collaboration_readonly
      assert has_element?(lv, "#collection-#{mount.id}", "Shared Reading List")
    end

    test "falls back to inbox bookmark for revoked public share URLs", %{conn: conn} do
      owner_scope = user_scope_fixture()
      subscriber_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope, %{title: "Shared Reading List"})

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)
      assert {:ok, _revoked} = Collections.revoke_public_share(owner_scope, share)

      conn = log_in_user(conn, subscriber_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      share_url = "http://localhost:4000/share/#{share.token}"

      html =
        lv
        |> form("#new-link-form", new_bookmark: %{url: share_url})
        |> render_submit()

      assert html =~ share_url
      refute html =~ "Shared Reading List"
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
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      lv
      |> element("#delete-bookmark-button")
      |> render_click()

      assert has_element?(lv, "#delete-bookmark-confirm-modal")

      lv
      |> element("#delete-bookmark-confirm-button")
      |> render_click()

      refute has_element?(lv, "#bookmark-#{bookmark.id}")
      assert has_element?(lv, "#inbox-empty-state", "Your inbox is empty")
    end

    test "canceling bookmark delete confirmation keeps the link", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark = bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      lv
      |> element("#delete-bookmark-button")
      |> render_click()

      assert has_element?(lv, "#delete-bookmark-confirm-modal")

      lv
      |> element("#delete-bookmark-cancel-button")
      |> render_click()

      refute has_element?(lv, "#delete-bookmark-confirm-modal")
      assert has_element?(lv, "#bookmark-#{bookmark.id}")
    end

    test "keeps the new link input visible when a bookmark is selected", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      bookmark = bookmark_fixture(scope, %{title: "Inbox link", url: "https://example.com/inbox"})
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      assert has_element?(lv, "#new-link-form")
      assert has_element?(lv, "#new-link-form input[type=\"url\"]")
      assert has_element?(lv, "#bookmark-form")
    end

    test "shows an empty label when the inbox has no bookmarks", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="inbox-empty-state")
      assert has_element?(lv, "#inbox-empty-state", "Your inbox is empty")
    end

    test "shows an empty label when there are no collections", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ ~s(id="collections-empty-state")
      assert has_element?(lv, "#collections-empty-state", "You don't have any collections yet")
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
      refute Collections.get_bookmark!(collection_bookmark.id).completed
    end

    test "clears completed when moving a completed link back to the inbox", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      collection = collection_fixture(scope, %{title: "Reading"})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Done link",
          url: "https://example.com/done",
          collection_id: collection.id,
          completed: true
        })

      {:ok, lv, _html} = live(conn, ~p"/")

      assert render_click_move_bookmark(lv, %{
               "id" => to_string(bookmark.id),
               "collection_id" => nil,
               "ordered_ids" => [to_string(bookmark.id)]
             })

      moved = Collections.get_bookmark!(bookmark.id)
      assert moved.collection_id == nil
      refute moved.completed
      refute has_element?(lv, "#bookmark-completed-#{bookmark.id}")
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
      assert has_element?(lv, "#collection-#{collection.id} summary .badge.badge-ghost", "0 / 1")
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

    test "copies bookmarks from read-only collections via drag hook", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared Reading"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      {:ok, bookmark} =
        Collections.create_bookmark(owner_scope, %{
          title: "Shared link",
          url: "https://example.com/shared",
          collection_id: source.id
        })

      collaborator_scope = user_scope_fixture(collaborator)
      target = collection_fixture(collaborator_scope, %{title: "Saved"})

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#collection-#{mount.id} > details > summary")
      |> render_click()

      assert has_element?(lv, "#nested-zone-#{source.id}[data-readonly=\"true\"]")

      assert render_click_copy_bookmark(lv, %{
               "id" => to_string(bookmark.id),
               "collection_id" => to_string(target.id),
               "ordered_ids" => [to_string(bookmark.id)]
             })

      copied =
        Repo.get_by!(Bookmark,
          collection_id: target.id,
          url: "https://example.com/shared",
          created_by_id: collaborator.id
        )

      assert copied.id != bookmark.id
      assert Collections.get_bookmark!(bookmark.id).collection_id == source.id
      assert has_element?(lv, "#bookmark-#{copied.id}")
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

      assert has_element?(lv, "#collection-#{parent.id} summary .badge.badge-ghost", "0 / 2")
      assert has_element?(lv, "#collection-#{child.id} summary .badge.badge-ghost", "0 / 1")
    end

    test "keeps collection trees collapsed on initial load", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, _lv, html} = live(conn, ~p"/")

      refute html =~ ~s(<details open)
    end

    test "collapsing a collection keeps the detail panel when it is selected", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})

      {:ok, lv, _html} = live(conn, ~p"/")

      open_collection_details(lv, parent.id)

      assert has_element?(lv, "#collection-form")

      lv
      |> element("#collection-#{parent.id} > details > summary")
      |> render_click()

      assert has_element?(lv, "#collection-form")
    end

    test "clicking a collection selects it and shows the detail panel", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})

      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "#collection-form")

      lv
      |> element("#collection-#{parent.id} > details > summary")
      |> render_click()

      assert has_element?(lv, "#collection-form")
      assert has_element?(lv, "#collection-#{parent.id} summary.sidebar-item-active")
    end

    test "clicking a collapsed collection with children expands it and opens the detail panel", %{
      conn: conn
    } do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      parent = collection_fixture(scope, %{title: "Parent"})
      _child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "#collection-#{parent.id} > details[open]")

      lv
      |> element("#collection-#{parent.id} > details > summary")
      |> render_click()

      assert has_element?(lv, "#collection-form")
      assert has_element?(lv, "#collection-#{parent.id} > details[open]")
    end

    test "selecting a collection does not change whether it is expanded", %{conn: conn} do
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

    test "opens bookmark links in a new tab from the more button", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})

      bookmark =
        bookmark_fixture(scope, %{title: "External link", url: "https://example.com/external"})

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "#bookmark-more-#{bookmark.id}[href='https://example.com/external'][target='_blank']"
             )

      lv
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      assert has_element?(lv, "#bookmark-form")
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

      lv
      |> element("#collection-#{collection.id} > details > summary")
      |> render_click()

      assert has_element?(lv, "#collection-#{collection.id} summary.sidebar-item-active")

      assert has_element?(
               lv,
               "#collection-#{collection.id} summary.sidebar-item-active [aria-label='Shared with others']"
             )
    end

    test "suggests existing users while typing collaborator query", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture(%{email: "collaborator-search@example.com"})
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)
      lv = show_collaborator_suggestions(lv)

      lv
      |> form("#collaboration-form form", collaboration: %{email: "collaborator-search"})
      |> render_change()

      assert has_element?(lv, "#collaboration-email-suggestions", collaborator.email)

      lv = select_collaborator_suggestion(lv, collaborator.email)

      assert has_element?(
               lv,
               "#collaboration-form input[type='text'][value='#{collaborator.email}']"
             )

      refute has_element?(lv, "#collaboration-email-suggestions")
    end

    test "hides collaborator suggestions after field loses focus", %{conn: conn} do
      owner_scope = user_scope_fixture()
      _collaborator = user_fixture(%{email: "blur-test@example.com"})
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)
      lv = show_collaborator_suggestions(lv)

      lv
      |> form("#collaboration-form form", collaboration: %{email: "blur-test"})
      |> render_change()

      assert has_element?(lv, "#collaboration-email-suggestions", "blur-test@example.com")

      lv = hide_collaborator_suggestions(lv)

      refute has_element?(lv, "#collaboration-email-suggestions")

      lv
      |> form("#collaboration-form form", collaboration: %{email: "blur-test"})
      |> render_change()

      refute has_element?(lv, "#collaboration-email-suggestions")
    end

    test "hides collaborator suggestions when the form is submitted", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture(%{email: "submit-hide@example.com"})
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)
      lv = show_collaborator_suggestions(lv)

      lv
      |> form("#collaboration-form form", collaboration: %{email: "submit-hide"})
      |> render_change()

      assert has_element?(lv, "#collaboration-email-suggestions", collaborator.email)

      lv
      |> form("#collaboration-form form", collaboration: %{email: collaborator.email})
      |> render_submit()

      refute has_element?(lv, "#collaboration-email-suggestions")
      assert has_element?(lv, "#collaborators-list", collaborator.email)
    end

    test "shows validation when inviting an active collaborator again", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      assert {:ok, _mount} =
               Collections.create_collaboration(
                 owner_scope,
                 collection,
                 collaborator.email,
                 true
               )

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      lv
      |> form("#collaboration-form form", collaboration: %{email: collaborator.email})
      |> render_change()

      assert has_element?(lv, "#collaboration-form", "This user is already a collaborator")

      lv
      |> form("#collaboration-form form", collaboration: %{email: collaborator.email})
      |> render_submit()

      assert has_element?(lv, "#collaboration-form", "This user is already a collaborator")
      assert length(Collections.list_collaborators(owner_scope, collection)) == 1
    end

    test "omits active collaborators from email suggestions", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture(%{email: "active-collaborator@example.com"})
      _other = user_fixture(%{email: "other-collaborator@example.com"})
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      assert {:ok, _mount} =
               Collections.create_collaboration(
                 owner_scope,
                 collection,
                 collaborator.email,
                 true
               )

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)
      lv = show_collaborator_suggestions(lv)

      lv
      |> form("#collaboration-form form", collaboration: %{email: "active-collaborator"})
      |> render_change()

      refute has_element?(lv, "#collaboration-email-suggestions", collaborator.email)
      assert has_element?(lv, "#collaboration-email-no-matches", "No matches found")

      lv
      |> form("#collaboration-form form", collaboration: %{email: "other-collaborator"})
      |> render_change()

      assert has_element?(
               lv,
               "#collaboration-email-suggestions",
               "other-collaborator@example.com"
             )

      refute has_element?(lv, "#collaboration-email-no-matches")
    end

    test "shows no matches found when user search has no results", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)
      lv = show_collaborator_suggestions(lv)

      lv
      |> form("#collaboration-form form", collaboration: %{email: "nobody-here"})
      |> render_change()

      assert has_element?(lv, "#collaboration-email-no-matches", "No matches found")
      refute has_element?(lv, "[id^='collaboration-email-option-']")
    end

    test "shows validation when user does not exist", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      lv
      |> form("#collaboration-form form", collaboration: %{email: "nobody-here"})
      |> render_submit()

      assert has_element?(lv, "#collaboration-form", "User not found")
    end

    test "allows inviting a user without an email address", %{conn: conn} do
      owner_scope = user_scope_fixture()
      {:ok, collaborator} = Links.Accounts.get_or_register_forward_auth_user("proxy-user")
      collection = collection_fixture(owner_scope, %{title: "Team Project"})

      conn = log_in_user(conn, owner_scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      lv
      |> form("#collaboration-form form", collaboration: %{email: collaborator.email})
      |> render_submit()

      assert has_element?(lv, "#collaborators-list", collaborator.email)
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
      assert has_element?(lv, "#collaboration-form input[type='text'][value='']")

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

      assert has_element?(lv, "#revoke-collaboration-confirm-modal")

      lv
      |> element("#revoke-collaboration-confirm-button")
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

    test "canceling collaborator revoke confirmation keeps access active", %{conn: conn} do
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

      lv
      |> element("#revoke-collaborator-#{mount.id}")
      |> render_click()

      assert has_element?(lv, "#revoke-collaboration-confirm-modal")

      lv
      |> element("#revoke-collaboration-cancel-button")
      |> render_click()

      refute has_element?(lv, "#revoke-collaboration-confirm-modal")
      assert has_element?(lv, "#collaborator-#{mount.id}", "Can edit · Active")
      assert has_element?(lv, "#revoke-collaborator-#{mount.id}")
    end

    test "revokes a public share from the detail panel", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Shared Publicly"})

      assert {:ok, share} = Collections.create_public_share(scope, collection)

      conn = log_in_user(conn, scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      assert has_element?(lv, "#revoke-public-share-#{share.id}")

      lv
      |> element("#revoke-public-share-#{share.id}")
      |> render_click()

      assert has_element?(lv, "#revoke-public-share-confirm-modal")

      lv
      |> element("#revoke-public-share-confirm-button")
      |> render_click()

      refute has_element?(lv, "#revoke-public-share-#{share.id}")
      assert has_element?(lv, "#restore-public-share-#{share.id}", "Restore")
    end

    test "canceling public share revoke confirmation keeps the link active", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Shared Publicly"})

      assert {:ok, share} = Collections.create_public_share(scope, collection)

      conn = log_in_user(conn, scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      lv
      |> element("#revoke-public-share-#{share.id}")
      |> render_click()

      assert has_element?(lv, "#revoke-public-share-confirm-modal")

      lv
      |> element("#revoke-public-share-cancel-button")
      |> render_click()

      refute has_element?(lv, "#revoke-public-share-confirm-modal")
      assert has_element?(lv, "#revoke-public-share-#{share.id}")
      assert has_element?(lv, "#copy-public-share-#{share.id}", "Copy link")
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

    test "hides revoked shared collections after one hour", %{conn: conn} do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Expired Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert {:ok, revoked} = Collections.revoke_collaboration(owner_scope, mount)

      expired_at =
        DateTime.utc_now(:second)
        |> DateTime.add(-3601, :second)

      revoked
      |> Collection.changeset(%{collaboration_revoked_at: expired_at})
      |> Repo.update!()

      conn = log_in_user(conn, collaborator)
      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "#collection-#{mount.id}")
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

      assert has_element?(lv, "#delete-collection-button", "Remove")

      lv
      |> element("#delete-collection-button")
      |> render_click()

      assert has_element?(lv, "#delete-collection-confirm-modal")

      lv
      |> element("#delete-collection-confirm-button")
      |> render_click()

      html = render(lv)
      refute html =~ "Shared To Remove"
      assert Collections.get_collection!(source.id).title == "Shared To Remove"
      refute Repo.get(Collection, mount.id)
    end

    test "canceling collection delete confirmation keeps the collection", %{conn: conn} do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Keep Me"})
      conn = log_in_user(conn, scope.user)
      {:ok, lv, _html} = live(conn, ~p"/")

      lv = open_collection_details(lv, collection.id)

      lv
      |> element("#delete-collection-button")
      |> render_click()

      assert has_element?(lv, "#delete-collection-confirm-modal")

      lv
      |> element("#delete-collection-cancel-button")
      |> render_click()

      refute has_element?(lv, "#delete-collection-confirm-modal")
      assert has_element?(lv, "#collection-#{collection.id}")
      assert Collections.get_collection!(collection.id).title == "Keep Me"
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

      bookmark = bookmark_fixture(scope, %{url: "https://example.com"})

      fetched_at = ~U[2026-06-20 12:34:56Z]

      {:ok, _bookmark} =
        Collections.update_bookmark_metadata(bookmark, %{
          title: "Example Domain",
          favicon_data: <<0, 1, 2>>,
          favicon_content_type: "image/png",
          favicon_byte_size: 3,
          favicon_source_url: "https://example.com/favicon.ico",
          metadata_fetched_at: fetched_at
        })

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Example Domain"
      assert html =~ ~s(/bookmarks/#{bookmark.id}/favicon)

      lv
      |> element("#bookmark-select-#{bookmark.id}")
      |> render_click()

      assert has_element?(lv, "#bookmark-metadata-fetched-at")
      assert render(lv) =~ "Metadata fetched at 2026-06-20 12:34:56 UTC"
    end
  end

  defp open_collection_details(view, collection_id) do
    render_click(view, "select_collection", %{"id" => to_string(collection_id)})
    view
  end

  defp show_collaborator_suggestions(view) do
    render_click(view, "show_collaborator_email_suggestions")
    view
  end

  defp hide_collaborator_suggestions(view) do
    render_click(view, "hide_collaborator_email_suggestions")
    view
  end

  defp select_collaborator_suggestion(view, email) do
    render_click(view, "select_collaborator_email", %{"email" => email})
    view
  end

  defp render_click_move_bookmark(view, params) do
    view
    |> element("#bookmarks-sidebar")
    |> render_hook("move_bookmark", params)
  end

  defp render_click_copy_bookmark(view, params) do
    view
    |> element("#bookmarks-sidebar")
    |> render_hook("copy_bookmark", params)
  end

  defp render_reorder_collections(view, params) do
    view
    |> element("#bookmarks-sidebar")
    |> render_hook("reorder_collections", params)
  end
end
