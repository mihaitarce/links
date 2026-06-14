defmodule Links.CollectionsTest do
  use Links.DataCase

  import Links.AccountsFixtures
  import Links.CollectionsFixtures

  alias Links.Collections
  alias Links.Repo

  describe "collections and inbox bookmarks" do
    test "creates nested collections and inbox bookmarks" do
      scope = user_scope_fixture()
      root = collection_fixture(scope, %{title: "Root"})

      {:ok, child} = Collections.create_collection(scope, %{title: "Child", parent_id: root.id})
      {:ok, bookmark} = Collections.create_inbox_bookmark(scope, %{url: "https://example.com"})

      assert child.parent_id == root.id
      assert bookmark.collection_id == nil
      assert bookmark.title == "https://example.com"
    end

    test "enqueues metadata fetch jobs when bookmarks are created" do
      scope = user_scope_fixture()
      {:ok, bookmark} = Collections.create_inbox_bookmark(scope, %{url: "https://example.com"})

      assert [%Oban.Job{args: %{"bookmark_id" => bookmark_id}, queue: "metadata"}] =
               Repo.all(Oban.Job)

      assert bookmark_id == bookmark.id
    end

    test "moves bookmarks from inbox to collection through server-side reorder API" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope)
      bookmark = bookmark_fixture(scope)

      assert {:ok, moved} =
               Collections.move_bookmark(scope, bookmark.id, collection.id, [bookmark.id])

      assert moved.collection_id == collection.id
    end
  end

  describe "public shares" do
    test "creates and revokes public shares separately from collections" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope)

      assert {:ok, share} = Collections.create_public_share(scope, collection)
      assert share.collection_id == collection.id
      assert is_binary(share.token)

      assert {:ok, revoked} = Collections.revoke_public_share(scope, share)
      assert revoked.revoked_at
    end
  end

  describe "collaboration mounts" do
    test "mounts collaborations into the collaborator collection tree" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(
                 owner_scope,
                 source,
                 collaborator.email,
                 true
               )

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      assert mount.owner_id == collaborator.id
      assert mount.collaboration_id == source.id
      assert [%{title: "Shared", readonly: true}] = dashboard.tree
      refute Collections.can_edit_collection?(collaborator_scope, source.id)
      assert Collections.can_view_collection?(collaborator_scope, source.id)
    end

    test "revoked collaborations stay in the tree but stop granting access" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Revoked"})

      {:ok, mount} =
        Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      {:ok, _mount} = Collections.revoke_collaboration(owner_scope, mount)

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      assert [%{title: "Revoked", revoked: true}] = dashboard.tree
      refute Collections.can_view_collection?(collaborator_scope, source.id)
      refute Collections.can_edit_collection?(collaborator_scope, source.id)
    end
  end
end
