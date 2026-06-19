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

    test "reorders bookmarks within a collection" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope)

      {:ok, first} =
        Collections.create_bookmark(scope, %{
          title: "First",
          url: "https://example.com/1",
          collection_id: collection.id
        })

      {:ok, second} =
        Collections.create_bookmark(scope, %{
          title: "Second",
          url: "https://example.com/2",
          collection_id: collection.id
        })

      assert {:ok, _bookmark} =
               Collections.move_bookmark(scope, second.id, collection.id, [second.id, first.id])

      assert Collections.get_bookmark!(second.id).position == 0
      assert Collections.get_bookmark!(first.id).position == 1
    end

    test "moves bookmarks between collections" do
      scope = user_scope_fixture()
      source = collection_fixture(scope, %{title: "Source"})
      target = collection_fixture(scope, %{title: "Target"})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Link",
          url: "https://example.com/link",
          collection_id: source.id
        })

      {:ok, existing} =
        Collections.create_bookmark(scope, %{
          title: "Existing",
          url: "https://example.com/existing",
          collection_id: target.id
        })

      assert {:ok, moved} =
               Collections.move_bookmark(scope, bookmark.id, target.id, [existing.id, bookmark.id])

      assert moved.collection_id == target.id
      assert Collections.get_bookmark!(existing.id).position == 0
      assert Collections.get_bookmark!(bookmark.id).position == 1
    end

    test "broadcasts collection bookmark list changes" do
      scope = user_scope_fixture()
      source = collection_fixture(scope, %{title: "Source"})
      target = collection_fixture(scope, %{title: "Target"})

      Phoenix.PubSub.subscribe(Links.PubSub, Collections.collection_bookmarks_topic(source.id))
      Phoenix.PubSub.subscribe(Links.PubSub, Collections.collection_bookmarks_topic(target.id))

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Link",
          url: "https://example.com/link",
          collection_id: source.id
        })

      assert_receive {:collection_bookmarks_changed, collection_id}
                     when collection_id == source.id

      assert {:ok, _bookmark} =
               Collections.move_bookmark(scope, bookmark.id, target.id, [bookmark.id])

      assert_receive {:collection_bookmarks_changed, collection_id}
                     when collection_id == target.id

      assert_receive {:collection_bookmarks_changed, collection_id}
                     when collection_id == source.id
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
