defmodule Links.CollectionsTest do
  use Links.DataCase

  import Links.AccountsFixtures
  import Links.CollectionsFixtures

  alias Links.Collections
  alias Links.Collections.Collection
  alias Links.Repo

  describe "collections and inbox bookmarks" do
    test "creates nested collections and inbox bookmarks" do
      scope = user_scope_fixture()
      root = collection_fixture(scope, %{title: "Root"})

      {:ok, child} = Collections.create_collection(scope, %{title: "Child", parent_id: root.id})
      {:ok, bookmark} = Collections.create_inbox_bookmark(scope, %{url: "https://example.com"})

      assert child.parent_id == root.id
      assert bookmark.collection_id == nil
      assert bookmark.title == "example.com"
    end

    test "deletes inbox bookmarks without error" do
      scope = user_scope_fixture()
      {:ok, bookmark} = Collections.create_inbox_bookmark(scope, %{url: "https://example.com"})

      assert {:ok, _deleted} = Collections.delete_bookmark(scope, bookmark)
      assert Collections.list_inbox_bookmarks(scope) == []
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

    test "reorders root collections" do
      scope = user_scope_fixture()

      {:ok, first} = Collections.create_collection(scope, %{title: "First"})
      {:ok, second} = Collections.create_collection(scope, %{title: "Second"})

      assert {:ok, :reordered} =
               Collections.reorder_collections(scope, "root", [second.id, first.id])

      assert Collections.get_collection!(second.id).position == 0
      assert Collections.get_collection!(first.id).position == 1
    end

    test "move_collection reorders root collections" do
      scope = user_scope_fixture()

      {:ok, first} = Collections.create_collection(scope, %{title: "First"})
      {:ok, second} = Collections.create_collection(scope, %{title: "Second"})

      assert {:ok, :moved} =
               Collections.move_collection(scope, second.id, "root", [second.id, first.id])

      assert Collections.get_collection!(second.id).position == 0
      assert Collections.get_collection!(first.id).position == 1
    end

    test "move_collection rejects when moved collection is missing from order" do
      scope = user_scope_fixture()

      {:ok, first} = Collections.create_collection(scope, %{title: "First"})
      {:ok, second} = Collections.create_collection(scope, %{title: "Second"})

      assert {:error, :invalid_order} =
               Collections.move_collection(scope, first.id, "root", [second.id])
    end

    test "move_collection nests a collection as the last child of a new parent" do
      scope = user_scope_fixture()
      parent = collection_fixture(scope, %{title: "Parent"})
      child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})
      moving = collection_fixture(scope, %{title: "Moving"})

      assert {:ok, :moved} =
               Collections.move_collection(scope, moving.id, parent.id, [child.id, moving.id])

      assert Collections.get_collection!(moving.id).parent_id == parent.id
      assert Collections.get_collection!(moving.id).position == 1
      assert Collections.get_collection!(child.id).position == 0
    end

    test "reorders nested collections" do
      scope = user_scope_fixture()
      root = collection_fixture(scope)

      {:ok, first} =
        Collections.create_collection(scope, %{title: "Child A", parent_id: root.id})

      {:ok, second} =
        Collections.create_collection(scope, %{title: "Child B", parent_id: root.id})

      assert {:ok, :reordered} =
               Collections.reorder_collections(scope, root.id, [second.id, first.id])

      assert Collections.get_collection!(second.id).position == 0
      assert Collections.get_collection!(first.id).position == 1
    end

    test "collaborators can reorder revoked shared collection mounts among root siblings" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Revoked Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert {:ok, _mount} = Collections.revoke_collaboration(owner_scope, mount)

      collaborator_scope = user_scope_fixture(collaborator)
      {:ok, own} = Collections.create_collection(collaborator_scope, %{title: "Mine"})

      refute Collections.can_edit_collection?(collaborator_scope, mount.id)
      assert Collections.can_reorder_collection?(collaborator_scope, mount.id)

      assert {:ok, :reordered} =
               Collections.reorder_collections(collaborator_scope, "root", [mount.id, own.id])

      assert Collections.get_collection!(mount.id).position == 0
      assert Collections.get_collection!(own.id).position == 1
    end

    test "collaborators can reorder read-only shared collection mounts among root siblings" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)
      {:ok, own} = Collections.create_collection(collaborator_scope, %{title: "Mine"})

      assert {:ok, :reordered} =
               Collections.reorder_collections(collaborator_scope, "root", [mount.id, own.id])

      assert Collections.get_collection!(mount.id).position == 0
      assert Collections.get_collection!(own.id).position == 1
    end

    test "collaborators can reorder children inside read-only shared collections" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})

      {:ok, first} =
        Collections.create_collection(owner_scope, %{title: "Child A", parent_id: parent.id})

      {:ok, second} =
        Collections.create_collection(owner_scope, %{title: "Child B", parent_id: parent.id})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, parent, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, :reordered} =
               Collections.reorder_collections(collaborator_scope, parent.id, [
                 second.id,
                 first.id
               ])

      assert Collections.get_collection!(second.id).position == 0
      assert Collections.get_collection!(first.id).position == 1
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

    test "tree nodes count bookmarks in descendant collections" do
      scope = user_scope_fixture()
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

      dashboard = Collections.list_dashboard(scope)
      [parent_node] = dashboard.tree

      assert parent_node.bookmark_count == 2
      assert parent_node.completed_bookmark_count == 0
      [child_node] = parent_node.children
      assert child_node.bookmark_count == 1
      assert child_node.completed_bookmark_count == 0
    end

    test "counts completed bookmarks in collection tree badges" do
      scope = user_scope_fixture()
      parent = collection_fixture(scope, %{title: "Parent"})
      child = collection_fixture(scope, %{title: "Child", parent_id: parent.id})

      {:ok, parent_bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Parent link",
          url: "https://example.com/parent",
          collection_id: parent.id
        })

      {:ok, child_bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Child link",
          url: "https://example.com/child",
          collection_id: child.id
        })

      assert {:ok, _} =
               Collections.update_bookmark(scope, parent_bookmark, %{completed: true})

      dashboard = Collections.list_dashboard(scope)
      [parent_node] = dashboard.tree

      assert parent_node.bookmark_count == 2
      assert parent_node.completed_bookmark_count == 1
      assert Collections.collection_bookmark_badge(parent_node) == "1 / 2"

      [child_node] = parent_node.children
      assert child_node.completed_bookmark_count == 0
      assert Collections.collection_bookmark_badge(child_node) == "0 / 1"

      assert {:ok, _} =
               Collections.update_bookmark(scope, child_bookmark, %{completed: true})

      dashboard = Collections.list_dashboard(scope)
      [parent_node] = dashboard.tree

      assert parent_node.completed_bookmark_count == 2
      assert Collections.collection_bookmark_badge(parent_node) == "2 / 2"
    end

    test "formats inbox bookmark badges" do
      scope = user_scope_fixture()

      assert Collections.inbox_bookmark_badge([]) == "0"

      {:ok, first} = Collections.create_inbox_bookmark(scope, %{url: "https://example.com/1"})
      {:ok, _second} = Collections.create_inbox_bookmark(scope, %{url: "https://example.com/2"})
      assert {:ok, _} = Collections.update_bookmark(scope, first, %{completed: true})

      inbox = Collections.list_inbox_bookmarks(scope)
      assert Collections.inbox_bookmark_badge(inbox) == "2"
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

    test "broadcasts to parent when a sub-collection is created, updated, or deleted" do
      scope = user_scope_fixture()
      parent = collection_fixture(scope, %{title: "Parent"})

      Phoenix.PubSub.subscribe(Links.PubSub, Collections.collection_bookmarks_topic(parent.id))

      assert {:ok, child} =
               Collections.create_collection(scope, %{
                 title: "Child",
                 parent_id: parent.id
               })

      assert_receive {:collection_bookmarks_changed, collection_id}
                     when collection_id == parent.id

      assert {:ok, _child} =
               Collections.update_collection(scope, child, %{title: "Renamed Child"})

      assert_receive {:collection_bookmarks_changed, collection_id}
                     when collection_id == parent.id

      assert {:ok, _child} = Collections.delete_collection(scope, child)

      assert_receive {:collection_bookmarks_changed, collection_id}
                     when collection_id == parent.id
    end

    test "reorders inbox bookmarks" do
      scope = user_scope_fixture()

      {:ok, first} =
        Collections.create_inbox_bookmark(scope, %{
          title: "First",
          url: "https://example.com/1"
        })

      {:ok, second} =
        Collections.create_inbox_bookmark(scope, %{
          title: "Second",
          url: "https://example.com/2"
        })

      assert {:ok, _bookmark} =
               Collections.move_bookmark(scope, second.id, nil, [second.id, first.id])

      assert Collections.get_bookmark!(second.id).position == 0
      assert Collections.get_bookmark!(first.id).position == 1
    end

    test "broadcasts inbox bookmark list changes" do
      scope = user_scope_fixture()

      Phoenix.PubSub.subscribe(Links.PubSub, Collections.inbox_bookmarks_topic(scope.user.id))

      {:ok, _bookmark} =
        Collections.create_inbox_bookmark(scope, %{
          title: "Link",
          url: "https://example.com/link"
        })

      assert_receive {:inbox_bookmarks_changed, user_id} when user_id == scope.user.id
    end

    test "moves bookmarks between inbox and collections" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Reading"})

      {:ok, inbox_bookmark} =
        Collections.create_inbox_bookmark(scope, %{
          title: "Inbox link",
          url: "https://example.com/inbox"
        })

      assert {:ok, moved_to_collection} =
               Collections.move_bookmark(
                 scope,
                 inbox_bookmark.id,
                 collection.id,
                 [inbox_bookmark.id]
               )

      assert moved_to_collection.collection_id == collection.id

      {:ok, collection_bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Collection link",
          url: "https://example.com/collection",
          collection_id: collection.id
        })

      assert {:ok, moved_to_inbox} =
               Collections.move_bookmark(
                 scope,
                 collection_bookmark.id,
                 nil,
                 [collection_bookmark.id]
               )

      assert moved_to_inbox.collection_id == nil
      refute moved_to_inbox.completed
    end

    test "clears completed when moving a bookmark back to the inbox" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Reading"})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Done link",
          url: "https://example.com/done",
          collection_id: collection.id,
          completed: true
        })

      assert {:ok, moved} =
               Collections.move_bookmark(scope, bookmark.id, nil, [bookmark.id])

      assert moved.collection_id == nil
      refute moved.completed
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

    test "allows multiple active public shares for the same collection" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope)

      assert {:ok, first_share} = Collections.create_public_share(scope, collection)
      assert {:ok, second_share} = Collections.create_public_share(scope, collection)
      refute first_share.token == second_share.token

      shares = Collections.list_public_shares(scope, collection)
      active_ids = shares |> Enum.reject(& &1.revoked_at) |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.equal?(active_ids, MapSet.new([first_share.id, second_share.id]))
      assert Collections.get_public_share_by_token(first_share.token)
      assert Collections.get_public_share_by_token(second_share.token)
    end

    test "marks owned collections as shared when a public link exists" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope)

      assert {:ok, _share} = Collections.create_public_share(scope, collection)

      assert [%{shared: true}] = Collections.list_dashboard(scope).tree
      assert Collections.shared_collection?(scope, collection.id)
    end

    test "loads a public share dashboard by token" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope, %{title: "Public Root"})
      child = collection_fixture(scope, %{title: "Public Child", parent_id: collection.id})

      {:ok, bookmark} =
        Collections.create_bookmark(scope, %{
          title: "Public Link",
          url: "https://example.com/public",
          collection_id: child.id
        })

      assert {:ok, share} = Collections.create_public_share(scope, collection)
      assert {:ok, dashboard} = Collections.fetch_public_share_dashboard(share.token)

      assert dashboard.root.id == collection.id
      assert dashboard.collection_ids == Collections.public_share_collection_ids(collection.id)
      assert [root_node] = dashboard.tree
      assert root_node.title == "Public Root"
      assert hd(root_node.children).title == "Public Child"
      assert hd(hd(root_node.children).bookmarks).id == bookmark.id
    end

    test "join_public_share creates a read-only collaboration mount" do
      owner_scope = user_scope_fixture()
      subscriber_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope, %{title: "Shared Publicly"})

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)

      assert {:ok, mount} = Collections.join_public_share(subscriber_scope, share.token)
      assert mount.collaboration_id == collection.id
      assert mount.collaboration_readonly
      assert mount.owner_id == subscriber_scope.user.id
      assert Collections.can_view_collection?(subscriber_scope, collection.id)
      refute Collections.can_edit_collection?(subscriber_scope, collection.id)
    end

    test "join_public_share returns already_owned for the collection owner" do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope, %{title: "Mine"})

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)
      assert {:error, :already_owned} = Collections.join_public_share(owner_scope, share.token)
    end

    test "join_public_share restores a revoked read-only mount" do
      owner_scope = user_scope_fixture()
      subscriber = user_fixture()
      collection = collection_fixture(owner_scope, %{title: "Shared Publicly"})

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, collection, subscriber.email, true)

      assert {:ok, revoked} = Collections.revoke_collaboration(owner_scope, mount)

      subscriber_scope = user_scope_fixture(subscriber)

      assert {:ok, restored} = Collections.join_public_share(subscriber_scope, share.token)
      assert restored.id == revoked.id
      refute restored.collaboration_revoked_at
      assert restored.collaboration_readonly
    end

    test "join_public_share returns not_found for revoked shares" do
      owner_scope = user_scope_fixture()
      subscriber_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope)

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)
      assert {:ok, _revoked} = Collections.revoke_public_share(owner_scope, share)
      assert {:error, :not_found} = Collections.join_public_share(subscriber_scope, share.token)
    end

    test "broadcasts public share changes when a link is revoked" do
      scope = user_scope_fixture()
      collection = collection_fixture(scope)

      assert {:ok, share} = Collections.create_public_share(scope, collection)

      Phoenix.PubSub.subscribe(Links.PubSub, Collections.public_share_topic(share.token))

      assert {:ok, _revoked} = Collections.revoke_public_share(scope, share)
      assert_receive {:public_share_changed, token} when token == share.token
      refute Collections.get_public_share_by_token(share.token)
    end

    test "editable collaborators can create and revoke public shares" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, share} = Collections.create_public_share(collaborator_scope, source)
      assert share.collection_id == source.id
      assert share.created_by_id == collaborator.id

      assert [listed] = Collections.list_public_shares(collaborator_scope, source)
      assert listed.id == share.id

      assert {:ok, revoked} = Collections.revoke_public_share(collaborator_scope, share)
      assert revoked.revoked_at
      refute Collections.get_public_share_by_token(share.token)
    end

    test "read-only collaborators cannot manage public shares" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:error, :unauthorized} = Collections.create_public_share(collaborator_scope, source)
      assert Collections.list_public_shares(collaborator_scope, source) == []
    end

    test "owner can restore revoked public shares" do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope)

      assert {:ok, share} = Collections.create_public_share(owner_scope, collection)
      assert {:ok, revoked} = Collections.revoke_public_share(owner_scope, share)
      refute Collections.get_public_share_by_token(share.token)

      assert {:ok, restored} = Collections.restore_public_share(owner_scope, revoked)
      refute restored.revoked_at
      assert Collections.get_public_share_by_token(share.token)
    end

    test "editable collaborators cannot restore revoked public shares" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, share} = Collections.create_public_share(collaborator_scope, source)
      assert {:ok, revoked} = Collections.revoke_public_share(collaborator_scope, share)

      assert {:error, :unauthorized} =
               Collections.restore_public_share(collaborator_scope, revoked)
    end

    test "owner can restore revoked public shares while another link is active" do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope)

      assert {:ok, first_share} = Collections.create_public_share(owner_scope, collection)
      assert {:ok, revoked} = Collections.revoke_public_share(owner_scope, first_share)
      assert {:ok, _active_share} = Collections.create_public_share(owner_scope, collection)

      assert {:ok, restored} = Collections.restore_public_share(owner_scope, revoked)
      refute restored.revoked_at
      assert Collections.get_public_share_by_token(first_share.token)
    end

    test "lists active public shares before revoked public shares" do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope)

      assert {:ok, revoked_share} = Collections.create_public_share(owner_scope, collection)
      assert {:ok, _} = Collections.revoke_public_share(owner_scope, revoked_share)
      assert {:ok, active_share} = Collections.create_public_share(owner_scope, collection)

      assert [first, second] = Collections.list_public_shares(owner_scope, collection)
      assert first.id == active_share.id
      assert second.id == revoked_share.id
    end

    test "orders active public shares by last modified date descending" do
      owner_scope = user_scope_fixture()
      collection = collection_fixture(owner_scope)

      assert {:ok, older_share} = Collections.create_public_share(owner_scope, collection)
      assert {:ok, newer_share} = Collections.create_public_share(owner_scope, collection)

      assert [first, second] = Collections.list_public_shares(owner_scope, collection)
      assert first.id == newer_share.id
      assert second.id == older_share.id
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

    test "rejects inviting an active collaborator again" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert {:error, :already_collaborator} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      assert length(Collections.list_collaborators(owner_scope, source)) == 1
    end

    test "allows inviting a collaborator again after access was revoked" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert {:ok, _revoked} = Collections.revoke_collaboration(owner_scope, mount)

      assert {:ok, new_mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      assert new_mount.id != mount.id
      assert is_nil(new_mount.collaboration_revoked_at)
    end

    test "marks owned collections as shared when collaborators are invited" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      owner_dashboard = Collections.list_dashboard(owner_scope)
      collaborator_dashboard = Collections.list_dashboard(user_scope_fixture(collaborator))

      assert [%{title: "Shared", shared: true}] = owner_dashboard.tree
      assert [%{title: "Shared", readonly: true, shared: false}] = collaborator_dashboard.tree
      assert Collections.shared_collection?(owner_scope, source.id)
    end

    test "collaborators see nested child collections under a shared parent" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})

      {:ok, child} =
        Collections.create_collection(owner_scope, %{
          title: "Child Folder",
          parent_id: parent.id
        })

      {:ok, _mount} =
        Collections.create_collaboration(owner_scope, parent, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      assert [%{title: "Shared Parent", readonly: true, children: children}] = dashboard.tree
      assert Enum.any?(children, &(&1.title == "Child Folder"))
      assert Collections.can_view_collection?(collaborator_scope, child.id)
    end

    test "owner sees collaborator-created child collections under a shared parent" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, parent, collaborator.email, false)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, child} =
               Collections.create_collection(collaborator_scope, %{
                 title: "Collab Child",
                 parent_id: parent.id
               })

      owner_dashboard = Collections.list_dashboard(owner_scope)
      children = hd(owner_dashboard.tree).children

      assert Enum.any?(children, &(&1.title == "Collab Child"))
      assert Collections.can_view_collection?(owner_scope, child.id)
      assert Collections.can_edit_collection?(owner_scope, child.id)
    end

    test "collaborators see grandchildren under a shared parent" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})
      child = collection_fixture(owner_scope, %{title: "Child", parent_id: parent.id})

      {:ok, grandchild} =
        Collections.create_collection(owner_scope, %{
          title: "Grandchild",
          parent_id: child.id
        })

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, parent, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      child_node = hd(hd(dashboard.tree).children)
      assert child_node.title == "Child"
      assert hd(child_node.children).title == "Grandchild"
      assert Collections.can_view_collection?(collaborator_scope, grandchild.id)
    end

    test "collaborators see descendants when only a sub-collection is shared" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      root = collection_fixture(owner_scope, %{title: "Root"})
      shared = collection_fixture(owner_scope, %{title: "Shared Sub", parent_id: root.id})

      {:ok, child} =
        Collections.create_collection(owner_scope, %{
          title: "Nested",
          parent_id: shared.id
        })

      _sibling = collection_fixture(owner_scope, %{title: "Sibling", parent_id: root.id})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, shared, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      assert [%{title: "Shared Sub", children: [%{title: "Nested"}]}] = dashboard.tree
      assert Collections.can_view_collection?(collaborator_scope, child.id)
      refute Collections.can_view_collection?(collaborator_scope, root.id)
    end

    test "collaborators see child collections added after sharing" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      parent = collection_fixture(owner_scope, %{title: "Shared Parent"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, parent, collaborator.email, false)

      {:ok, child} =
        Collections.create_collection(owner_scope, %{
          title: "Later Child",
          parent_id: parent.id
        })

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      assert [%{title: "Shared Parent", children: children}] = dashboard.tree
      assert Enum.any?(children, &(&1.title == "Later Child"))
      assert Collections.can_view_collection?(collaborator_scope, child.id)
    end

    test "moving a shared bookmark to inbox transfers ownership to the mover" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      collection = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(
                 owner_scope,
                 collection,
                 collaborator.email,
                 false
               )

      {:ok, bookmark} =
        Collections.create_bookmark(owner_scope, %{
          title: "Shared link",
          url: "https://example.com/shared",
          collection_id: collection.id
        })

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, moved} =
               Collections.move_bookmark(collaborator_scope, bookmark.id, nil, [bookmark.id])

      assert moved.collection_id == nil
      assert moved.created_by_id == collaborator.id
      assert Collections.list_inbox_bookmarks(collaborator_scope) == [moved]
      assert Collections.list_inbox_bookmarks(owner_scope) == []
    end

    test "recently revoked collaborations stay in the tree but stop granting access" do
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
      refute Collections.can_edit_collection?(collaborator_scope, mount.id)
      assert Collections.can_reorder_collection?(collaborator_scope, mount.id)
    end

    test "revoked collaborations disappear from the tree after one hour" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Expired Revoke"})

      {:ok, mount} =
        Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      assert {:ok, revoked} = Collections.revoke_collaboration(owner_scope, mount)

      expired_at =
        DateTime.utc_now(:second)
        |> DateTime.add(-3601, :second)

      revoked
      |> Collection.changeset(%{collaboration_revoked_at: expired_at})
      |> Repo.update!()

      collaborator_scope = user_scope_fixture(collaborator)
      dashboard = Collections.list_dashboard(collaborator_scope)

      assert dashboard.tree == []
      refute Collections.can_reorder_collection?(collaborator_scope, mount.id)
    end

    test "lists collaborators for a collection" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert [listed] = Collections.list_collaborators(owner_scope, source)
      assert listed.id == mount.id
      assert listed.owner.email == collaborator.email
      assert listed.collaboration_readonly
      refute listed.collaboration_revoked_at
    end

    test "lists active collaborators before revoked collaborators" do
      owner_scope = user_scope_fixture()
      active = user_fixture(%{email: "active-collaborator@example.com"})
      revoked = user_fixture(%{email: "revoked-collaborator@example.com"})
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, active_mount} =
               Collections.create_collaboration(owner_scope, source, active.email, false)

      assert {:ok, revoked_mount} =
               Collections.create_collaboration(owner_scope, source, revoked.email, false)

      assert {:ok, _} = Collections.revoke_collaboration(owner_scope, revoked_mount)

      assert [first, second] = Collections.list_collaborators(owner_scope, source)
      assert first.id == active_mount.id
      assert second.id == revoked_mount.id
    end

    test "orders active collaborators by last modified date descending" do
      owner_scope = user_scope_fixture()
      older = user_fixture(%{email: "older-collaborator@example.com"})
      newer = user_fixture(%{email: "newer-collaborator@example.com"})
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, older_mount} =
               Collections.create_collaboration(owner_scope, source, older.email, false)

      assert {:ok, newer_mount} =
               Collections.create_collaboration(owner_scope, source, newer.email, false)

      assert [first, second] = Collections.list_collaborators(owner_scope, source)
      assert first.id == newer_mount.id
      assert second.id == older_mount.id
    end

    test "cannot revoke an already revoked collaboration" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      assert {:ok, revoked} = Collections.revoke_collaboration(owner_scope, mount)
      assert {:error, :unauthorized} = Collections.revoke_collaboration(owner_scope, revoked)
    end

    test "owner can restore revoked collaborator access" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      assert {:ok, revoked} = Collections.revoke_collaboration(owner_scope, mount)
      assert revoked.collaboration_revoked_at

      collaborator_scope = user_scope_fixture(collaborator)
      refute Collections.can_view_collection?(collaborator_scope, source.id)

      assert {:ok, restored} = Collections.restore_collaboration(owner_scope, revoked)
      refute restored.collaboration_revoked_at
      assert Collections.can_edit_collection?(collaborator_scope, source.id)
    end

    test "editable collaborators cannot restore revoked access" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      invitee = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, invitee_mount} =
               Collections.create_collaboration(collaborator_scope, source, invitee.email, true)

      assert {:ok, revoked} = Collections.revoke_collaboration(owner_scope, invitee_mount)

      assert {:error, :unauthorized} =
               Collections.restore_collaboration(collaborator_scope, revoked)
    end

    test "cannot restore an active collaboration" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert {:error, :unauthorized} = Collections.restore_collaboration(owner_scope, mount)
    end

    test "broadcasts user collection list changes when sharing and revoking" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      Phoenix.PubSub.subscribe(
        Links.PubSub,
        Collections.user_collections_topic(owner_scope.user.id)
      )

      Phoenix.PubSub.subscribe(
        Links.PubSub,
        Collections.user_collections_topic(collaborator.id)
      )

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      assert_receive {:user_collections_changed, user_id} when user_id == collaborator.id
      assert_receive {:user_collections_changed, user_id} when user_id == owner_scope.user.id

      assert {:ok, _mount} = Collections.revoke_collaboration(owner_scope, mount)

      assert_receive {:user_collections_changed, user_id} when user_id == collaborator.id
      assert_receive {:user_collections_changed, user_id} when user_id == owner_scope.user.id
    end

    test "deleting a shared collection removes only the collaborator mount" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      other = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared Project"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      assert {:ok, _other_mount} =
               Collections.create_collaboration(owner_scope, source, other.email, true)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, _deleted_mount} = Collections.delete_collection(collaborator_scope, source)

      assert Collections.get_collection!(source.id).title == "Shared Project"
      refute Repo.get(Collection, mount.id)
      refute Collections.can_view_collection?(collaborator_scope, source.id)

      other_scope = user_scope_fixture(other)
      assert Collections.can_view_collection?(other_scope, source.id)
      assert length(Collections.list_collaborators(owner_scope, source)) == 1
    end

    test "collaborators can remove a shared collection using their mount id" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared Project"})

      assert {:ok, mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, _deleted_mount} = Collections.delete_collection(collaborator_scope, mount)
      assert Collections.get_collection!(source.id).id == source.id
      refute Repo.get(Collection, mount.id)
    end

    test "editable collaborators can invite and list collaborators" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      invitee = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, invitee_mount} =
               Collections.create_collaboration(
                 collaborator_scope,
                 source,
                 invitee.email,
                 true
               )

      assert invitee_mount.collaboration_id == source.id
      assert invitee_mount.owner_id == invitee.id

      listed = Collections.list_collaborators(collaborator_scope, source)
      assert Enum.any?(listed, &(&1.id == invitee_mount.id))
    end

    test "editable collaborators can revoke collaborations" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      invitee = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, false)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, invitee_mount} =
               Collections.create_collaboration(collaborator_scope, source, invitee.email, true)

      assert {:ok, revoked} = Collections.revoke_collaboration(collaborator_scope, invitee_mount)
      assert revoked.collaboration_revoked_at
    end

    test "read-only collaborators cannot manage collaborators" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      invitee = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:error, :unauthorized} =
               Collections.create_collaboration(
                 collaborator_scope,
                 source,
                 invitee.email,
                 false
               )

      assert Collections.list_collaborators(collaborator_scope, source) == []
    end

    test "read-only collaborators can copy bookmarks into their own collections" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})
      target = collection_fixture(user_scope_fixture(collaborator), %{title: "Saved"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      {:ok, bookmark} =
        Collections.create_bookmark(owner_scope, %{
          title: "Shared link",
          url: "https://example.com/shared",
          collection_id: source.id
        })

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, copied} =
               Collections.copy_bookmark(
                 collaborator_scope,
                 bookmark.id,
                 target.id,
                 [bookmark.id]
               )

      assert copied.id != bookmark.id
      assert copied.collection_id == target.id
      assert copied.url == bookmark.url
      assert copied.created_by_id == collaborator.id
      assert Collections.get_bookmark!(bookmark.id).collection_id == source.id
    end

    test "read-only collaborators can copy bookmarks into inbox" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      {:ok, bookmark} =
        Collections.create_bookmark(owner_scope, %{
          title: "Shared link",
          url: "https://example.com/shared",
          collection_id: source.id
        })

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:ok, copied} =
               Collections.copy_bookmark(collaborator_scope, bookmark.id, nil, [bookmark.id])

      assert copied.collection_id == nil
      assert copied.created_by_id == collaborator.id
      assert Collections.get_bookmark!(bookmark.id).collection_id == source.id
      assert Collections.list_inbox_bookmarks(collaborator_scope) == [copied]
    end

    test "copy_bookmark rejects reordering within the same collection" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      {:ok, first} =
        Collections.create_bookmark(owner_scope, %{
          title: "First",
          url: "https://example.com/first",
          collection_id: source.id
        })

      {:ok, second} =
        Collections.create_bookmark(owner_scope, %{
          title: "Second",
          url: "https://example.com/second",
          collection_id: source.id
        })

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:error, :unauthorized} =
               Collections.copy_bookmark(
                 collaborator_scope,
                 first.id,
                 source.id,
                 [second.id, first.id]
               )
    end

    test "read-only collaborators cannot move shared bookmarks" do
      owner_scope = user_scope_fixture()
      collaborator = user_fixture()
      source = collection_fixture(owner_scope, %{title: "Shared"})
      target = collection_fixture(user_scope_fixture(collaborator), %{title: "Saved"})

      assert {:ok, _mount} =
               Collections.create_collaboration(owner_scope, source, collaborator.email, true)

      {:ok, bookmark} =
        Collections.create_bookmark(owner_scope, %{
          title: "Shared link",
          url: "https://example.com/shared",
          collection_id: source.id
        })

      collaborator_scope = user_scope_fixture(collaborator)

      assert {:error, :unauthorized} =
               Collections.move_bookmark(collaborator_scope, bookmark.id, target.id, [bookmark.id])

      assert Collections.get_bookmark!(bookmark.id).collection_id == source.id
    end
  end
end
