defmodule Links.Collections do
  @moduledoc """
  Collection, bookmark, collaboration, and public sharing operations.
  """

  import Ecto.Query, warn: false

  @revoked_mount_visibility_seconds 3600

  alias Ecto.Multi
  alias Links.Accounts
  alias Links.Accounts.Scope
  alias Links.Bookmarks.Bookmark
  alias Links.Collections.Collection
  alias Links.Repo
  alias Links.Sharing.PublicShare
  alias Links.Workers.FetchBookmarkMetadataWorker

  def list_dashboard(%Scope{} = scope) do
    user_id = scope.user.id
    revoked_mount_cutoff = revoked_mount_visible_cutoff()

    own_collections =
      Collection
      |> where([c], c.owner_id == ^user_id)
      |> where(
        [c],
        is_nil(c.collaboration_revoked_at) or c.collaboration_revoked_at > ^revoked_mount_cutoff
      )
      |> order_by([c], asc: c.position, asc: c.title, asc: c.id)
      |> Repo.all()

    visible_target_ids =
      scope
      |> accessible_tree_root_ids()
      |> descendant_ids()

    target_collections =
      Collection
      |> where([c], c.id in ^visible_target_ids)
      |> order_by([c], asc: c.position, asc: c.title, asc: c.id)
      |> Repo.all()

    collections = uniq_by_id(own_collections ++ target_collections)
    collection_ids = Enum.map(collections, & &1.id)

    bookmarks =
      Bookmark
      |> where([b], b.collection_id in ^collection_ids)
      |> order_by([b], asc: b.position, asc: b.title, asc: b.id)
      |> Repo.all()

    shared_ids = shared_collection_ids(user_id)

    %{
      inbox: list_inbox_bookmarks(scope),
      tree: build_tree(collections, bookmarks, own_collections, shared_ids),
      collections: collections
    }
  end

  def shared_collection?(%Scope{} = scope, collection_id) do
    MapSet.member?(shared_collection_ids(scope.user.id), collection_id)
  end

  def list_inbox_bookmarks(%Scope{} = scope) do
    Bookmark
    |> where([b], b.created_by_id == ^scope.user.id and is_nil(b.collection_id))
    |> order_by([b], asc: b.position, asc: b.title, asc: b.id)
    |> Repo.all()
  end

  def collection_bookmarks_topic(collection_id) do
    "collection_bookmarks:#{collection_id}"
  end

  def broadcast_collection_bookmarks_changed(collection_id) when not is_nil(collection_id) do
    Phoenix.PubSub.broadcast(
      Links.PubSub,
      collection_bookmarks_topic(collection_id),
      {:collection_bookmarks_changed, collection_id}
    )
  end

  def inbox_bookmarks_topic(user_id) do
    "inbox_bookmarks:#{user_id}"
  end

  def broadcast_inbox_bookmarks_changed(user_id) do
    Phoenix.PubSub.broadcast(
      Links.PubSub,
      inbox_bookmarks_topic(user_id),
      {:inbox_bookmarks_changed, user_id}
    )
  end

  def broadcast_bookmark_list_changed(%Bookmark{collection_id: nil, created_by_id: user_id}) do
    broadcast_inbox_bookmarks_changed(user_id)
  end

  def broadcast_bookmark_list_changed(%Bookmark{collection_id: collection_id})
      when not is_nil(collection_id) do
    broadcast_collection_bookmarks_changed(collection_id)
  end

  def broadcast_bookmark_list_changed(%Scope{} = scope, collection_id) do
    if is_nil(collection_id) do
      broadcast_inbox_bookmarks_changed(scope.user.id)
    else
      broadcast_collection_bookmarks_changed(collection_id)
    end
  end

  def user_collections_topic(user_id) do
    "user_collections:#{user_id}"
  end

  def broadcast_user_collections_changed(user_id) do
    Phoenix.PubSub.broadcast(
      Links.PubSub,
      user_collections_topic(user_id),
      {:user_collections_changed, user_id}
    )
  end

  def get_collection!(id), do: Repo.get!(Collection, id)

  def get_visible_collection(%Scope{} = scope, id) do
    collection = Repo.get(Collection, id)

    with %Collection{} <- collection,
         true <- can_view_collection?(scope, collection.id) do
      {:ok, collection}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_collection(%Scope{} = scope, id) do
    with %Collection{} = collection <- Repo.get(Collection, id),
         false <- revoked_collaboration_mount?(collection),
         true <- can_view_collection?(scope, collection.id) do
      effective_collection =
        if active_collaboration_mount?(collection) do
          Repo.get!(Collection, collection.collaboration_id)
        else
          collection
        end

      {:ok,
       %{
         collection: collection,
         effective_collection: effective_collection,
         mount: if(active_collaboration_mount?(collection), do: collection),
         readonly: not can_edit_collection?(scope, effective_collection.id)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def change_collection(%Collection{} = collection, attrs \\ %{}) do
    Collection.changeset(collection, attrs)
  end

  def create_collection(%Scope{} = scope, attrs) do
    parent_id = blank_to_nil(attrs["parent_id"] || attrs[:parent_id])

    with :ok <- authorize_parent(scope, parent_id) do
      attrs =
        attrs
        |> normalize_attrs()
        |> Map.put(:owner_id, scope.user.id)
        |> Map.put(:parent_id, parent_id)
        |> Map.put_new(:position, next_collection_position(parent_id))

      %Collection{}
      |> Collection.changeset(attrs)
      |> Repo.insert()
      |> tap(fn {:ok, collection} ->
        broadcast_parent_collection_changed(collection)
      end)
    end
  end

  def update_collection(%Scope{} = scope, %Collection{} = collection, attrs) do
    if can_edit_collection?(scope, collection.id) do
      old_parent_id = collection.parent_id

      collection
      |> Collection.changeset(normalize_attrs(attrs))
      |> Repo.update()
      |> tap(fn {:ok, updated} ->
        broadcast_collection_changed(updated.id)
        broadcast_collection_changed(old_parent_id)

        if updated.parent_id != old_parent_id do
          broadcast_collection_changed(updated.parent_id)
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  def delete_collection(%Scope{} = scope, %Collection{} = collection) do
    case collaboration_mount_for_user(scope, collection) do
      %Collection{} = mount ->
        delete_collaboration_mount(scope, mount)

      nil ->
        delete_owned_collection(scope, collection)
    end
  end

  defp delete_owned_collection(%Scope{} = scope, %Collection{} = collection) do
    if collection.owner_id == scope.user.id and is_nil(collection.collaboration_id) do
      collection_id = collection.id
      parent_id = collection.parent_id

      with {:ok, collection} <- Repo.delete(collection) do
        broadcast_collection_changed(collection_id)
        broadcast_collection_changed(parent_id)
        {:ok, collection}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp delete_collaboration_mount(%Scope{} = scope, %Collection{} = mount) do
    source = Repo.get(Collection, mount.collaboration_id)

    if mount.owner_id == scope.user.id and not is_nil(mount.collaboration_id) do
      with {:ok, mount} <- Repo.delete(mount) do
        broadcast_user_collections_changed(scope.user.id)

        if source do
          broadcast_user_collections_changed(source.owner_id)
        end

        {:ok, mount}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp collaboration_mount_for_user(%Scope{} = scope, %Collection{} = collection) do
    cond do
      collection.owner_id == scope.user.id and not is_nil(collection.collaboration_id) ->
        collection

      collection.owner_id != scope.user.id ->
        Collection
        |> where([c], c.owner_id == ^scope.user.id and c.collaboration_id == ^collection.id)
        |> Repo.one()

      true ->
        nil
    end
  end

  def move_collection(%Scope{} = scope, collection_id, parent_id, ordered_ids) do
    collection = get_collection!(collection_id)
    parent_id = normalize_reorder_parent_id(parent_id)
    ordered_ids = Enum.map(ordered_ids, &to_integer/1)
    source_parent_id = collection.parent_id

    with :ok <- validate_collection_move(scope, collection, parent_id, ordered_ids),
         :ok <- reject_cycle(collection.id, parent_id) do
      multi =
        if source_parent_id != parent_id do
          Multi.new()
          |> Multi.update(:collection, Collection.changeset(collection, %{parent_id: parent_id}))
        else
          Multi.new()
        end

      multi
      |> update_collection_positions(ordered_ids)
      |> Repo.transaction()
      |> case do
        {:ok, _results} ->
          broadcast_collection_changed(parent_id)

          if source_parent_id != parent_id do
            broadcast_collection_changed(source_parent_id)
          end

          {:ok, :moved}

        {:error, _name, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def reorder_collections(%Scope{} = scope, parent_id, ordered_ids) do
    ordered_ids = Enum.map(ordered_ids, &to_integer/1)

    case ordered_ids do
      [first | _] ->
        case move_collection(scope, first, parent_id, ordered_ids) do
          {:ok, _} -> {:ok, :reordered}
          error -> error
        end

      [] ->
        {:error, :invalid_order}
    end
  end

  def create_inbox_bookmark(%Scope{} = scope, attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.put(:created_by_id, scope.user.id)
      |> Map.put(:collection_id, nil)
      |> Map.put_new(:position, next_bookmark_position(scope.user.id, nil))

    %Bookmark{}
    |> Bookmark.changeset(attrs)
    |> Repo.insert()
    |> enqueue_metadata_fetch()
    |> tap(fn {:ok, _bookmark} ->
      broadcast_inbox_bookmarks_changed(scope.user.id)
    end)
  end

  def create_bookmark(%Scope{} = scope, attrs) do
    attrs = normalize_attrs(attrs)
    collection_id = blank_to_nil(attrs[:collection_id])

    with :ok <- authorize_bookmark_parent(scope, collection_id) do
      attrs =
        attrs
        |> Map.put(:created_by_id, scope.user.id)
        |> Map.put(:collection_id, collection_id)
        |> Map.put_new(:position, next_bookmark_position(scope.user.id, collection_id))

      %Bookmark{}
      |> Bookmark.changeset(attrs)
      |> Repo.insert()
      |> enqueue_metadata_fetch()
      |> tap(fn {:ok, bookmark} ->
        broadcast_collection_bookmarks_changed(bookmark.collection_id)
      end)
    end
  end

  def update_bookmark(%Scope{} = scope, %Bookmark{} = bookmark, attrs) do
    if can_edit_bookmark?(scope, bookmark) do
      bookmark
      |> Bookmark.changeset(normalize_attrs(attrs))
      |> Repo.update()
      |> tap(fn {:ok, bookmark} ->
        broadcast_bookmark_list_changed(scope, bookmark.collection_id)
      end)
    else
      {:error, :unauthorized}
    end
  end

  def delete_bookmark(%Scope{} = scope, %Bookmark{} = bookmark) do
    if can_edit_bookmark?(scope, bookmark) do
      collection_id = bookmark.collection_id

      with {:ok, bookmark} <- Repo.delete(bookmark) do
        broadcast_bookmark_list_changed(scope, collection_id)
        {:ok, bookmark}
      end
    else
      {:error, :unauthorized}
    end
  end

  def get_bookmark!(id), do: Repo.get!(Bookmark, id)

  def get_bookmark(id), do: Repo.get(Bookmark, id)

  def move_bookmark(%Scope{} = scope, bookmark_id, collection_id, ordered_ids) do
    bookmark = get_bookmark!(bookmark_id)
    source_collection_id = bookmark.collection_id
    collection_id = normalize_collection_id(collection_id)
    ordered_ids = Enum.map(ordered_ids, &to_integer/1)

    with :ok <- authorize_bookmark_move(scope, bookmark, collection_id),
         :ok <- validate_bookmark_order(scope, bookmark, collection_id, ordered_ids) do
      Multi.new()
      |> Multi.update(
        :bookmark,
        Bookmark.changeset(bookmark, move_bookmark_attrs(scope, collection_id))
      )
      |> update_bookmark_positions(scope, collection_id, ordered_ids)
      |> Repo.transaction()
      |> case do
        {:ok, %{bookmark: bookmark}} ->
          broadcast_bookmark_list_changes(scope, source_collection_id)
          broadcast_bookmark_list_changes(scope, collection_id)
          {:ok, bookmark}

        {:error, _name, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def copy_bookmark(%Scope{} = scope, bookmark_id, collection_id, ordered_ids) do
    bookmark = get_bookmark!(bookmark_id)
    collection_id = normalize_collection_id(collection_id)
    ordered_ids = Enum.map(ordered_ids, &to_integer/1)

    with :ok <- authorize_bookmark_copy(scope, bookmark, collection_id),
         :ok <- validate_copy_bookmark_order(scope, bookmark, collection_id, ordered_ids) do
      Multi.new()
      |> Multi.insert(:bookmark, duplicate_bookmark_changeset(scope, bookmark, collection_id))
      |> Multi.merge(fn %{bookmark: new_bookmark} ->
        final_ordered_ids =
          Enum.map(ordered_ids, fn
            id when id == bookmark.id -> new_bookmark.id
            id -> id
          end)

        update_bookmark_positions(Multi.new(), scope, collection_id, final_ordered_ids)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{bookmark: bookmark}} ->
          broadcast_bookmark_list_changes(scope, collection_id)
          {:ok, bookmark}

        {:error, _name, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def update_bookmark_metadata(%Bookmark{} = bookmark, attrs) do
    bookmark
    |> Bookmark.metadata_changeset(attrs)
    |> Repo.update()
  end

  def create_public_share(%Scope{} = scope, %Collection{} = collection) do
    if can_manage_collection?(scope, collection) do
      %PublicShare{}
      |> PublicShare.changeset(%{
        collection_id: collection.id,
        created_by_id: scope.user.id,
        token: generate_token()
      })
      |> Repo.insert()
    else
      {:error, :unauthorized}
    end
  end

  def list_public_shares(%Scope{} = scope, %Collection{} = collection) do
    if can_manage_collection?(scope, collection) do
      PublicShare
      |> where([s], s.collection_id == ^collection.id)
      |> order_by([s], asc_nulls_first: s.revoked_at, desc: s.updated_at, desc: s.id)
      |> Repo.all()
    else
      []
    end
  end

  def get_public_share!(id), do: Repo.get!(PublicShare, id)

  def get_public_share_by_token(token) when is_binary(token) do
    PublicShare
    |> where([s], s.token == ^token and is_nil(s.revoked_at))
    |> preload(:collection)
    |> Repo.one()
  end

  def join_public_share(%Scope{} = scope, token) when is_binary(token) do
    case get_public_share_by_token(token) do
      %PublicShare{collection: %Collection{} = source} ->
        join_public_share_collection(scope, source)

      nil ->
        {:error, :not_found}
    end
  end

  defp join_public_share_collection(%Scope{} = scope, %Collection{} = source) do
    user_id = scope.user.id

    cond do
      source.owner_id == user_id ->
        {:error, :already_owned}

      active_collaborator?(source, user_id) ->
        case collaboration_mount_for_user_and_source(user_id, source.id) do
          %Collection{} = mount -> {:ok, mount}
          nil -> {:error, :already_collaborator}
        end

      true ->
        case collaboration_mount_for_user_and_source(user_id, source.id) do
          %Collection{collaboration_revoked_at: revoked_at} = mount when not is_nil(revoked_at) ->
            mount
            |> Collection.changeset(%{
              collaboration_revoked_at: nil,
              collaboration_readonly: true
            })
            |> Repo.update()
            |> tap_join_public_share(user_id)

          nil ->
            %Collection{}
            |> Collection.changeset(%{
              owner_id: user_id,
              title: source.title,
              collaboration_id: source.id,
              collaboration_readonly: true,
              position: next_collection_position(nil, user_id)
            })
            |> Repo.insert()
            |> tap_join_public_share(user_id)
        end
    end
  end

  defp collaboration_mount_for_user_and_source(user_id, source_id) do
    Collection
    |> where([c], c.owner_id == ^user_id and c.collaboration_id == ^source_id)
    |> Repo.one()
  end

  defp tap_join_public_share({:ok, _mount} = result, user_id) do
    broadcast_user_collections_changed(user_id)
    result
  end

  defp tap_join_public_share(result, _user_id), do: result

  def fetch_public_share_dashboard(token) when is_binary(token) do
    case get_public_share_by_token(token) do
      %PublicShare{collection: %Collection{} = root} = share ->
        collection_ids = public_share_collection_ids(root.id)

        collections =
          Collection
          |> where([c], c.id in ^collection_ids)
          |> order_by([c], asc: c.position, asc: c.title, asc: c.id)
          |> Repo.all()

        bookmarks =
          Bookmark
          |> where([b], b.collection_id in ^collection_ids)
          |> order_by([b], asc: b.position, asc: b.title, asc: b.id)
          |> Repo.all()

        by_id = Map.new(collections, &{&1.id, &1})
        by_parent = Enum.group_by(collections, & &1.parent_id)
        bookmarks_by_collection = Enum.group_by(bookmarks, & &1.collection_id)
        shared_ids = MapSet.new()

        tree = [
          build_node(root, by_id, by_parent, bookmarks_by_collection, nil, shared_ids)
        ]

        {:ok,
         %{
           share: share,
           root: root,
           tree: tree,
           collection_ids: collection_ids
         }}

      _ ->
        {:error, :not_found}
    end
  end

  def public_share_collection_ids(root_id) do
    [root_id | descendant_ids([root_id])]
  end

  def public_share_topic(token) when is_binary(token) do
    "public_share:#{token}"
  end

  def broadcast_public_share_changed(token) when is_binary(token) do
    Phoenix.PubSub.broadcast(
      Links.PubSub,
      public_share_topic(token),
      {:public_share_changed, token}
    )
  end

  def revoke_public_share(%Scope{} = scope, %PublicShare{} = public_share) do
    public_share = Repo.preload(public_share, :collection)

    if can_manage_collection?(scope, public_share.collection) do
      public_share
      |> PublicShare.changeset(%{revoked_at: DateTime.utc_now(:second)})
      |> Repo.update()
      |> tap(fn
        {:ok, share} -> broadcast_public_share_changed(share.token)
        _ -> :ok
      end)
    else
      {:error, :unauthorized}
    end
  end

  def restore_public_share(%Scope{} = scope, %PublicShare{} = public_share) do
    public_share = Repo.preload(public_share, :collection)
    collection = public_share.collection

    cond do
      collection.owner_id != scope.user.id ->
        {:error, :unauthorized}

      is_nil(public_share.revoked_at) ->
        {:error, :unauthorized}

      true ->
        public_share
        |> PublicShare.changeset(%{revoked_at: nil})
        |> Repo.update()
        |> tap(fn
          {:ok, share} -> broadcast_public_share_changed(share.token)
          _ -> :ok
        end)
    end
  end

  def create_collaboration(%Scope{} = scope, %Collection{} = source, collaborator_email, readonly) do
    collaborator = collaborator_email |> String.trim() |> Accounts.get_user_by_email()

    cond do
      not can_manage_collection?(scope, source) ->
        {:error, :unauthorized}

      is_nil(collaborator) ->
        {:error, :unauthorized}

      collaborator.id == scope.user.id ->
        {:error, :unauthorized}

      active_collaborator?(source, collaborator) ->
        {:error, :already_collaborator}

      true ->
        attrs = %{
          owner_id: collaborator.id,
          title: source.title,
          collaboration_id: source.id,
          collaboration_readonly: readonly,
          position: next_collection_position(nil, collaborator.id)
        }

        %Collection{}
        |> Collection.changeset(attrs)
        |> Repo.insert()
        |> tap(fn
          {:ok, _mount} ->
            broadcast_user_collections_changed(collaborator.id)
            broadcast_user_collections_changed(scope.user.id)

          _ ->
            :ok
        end)
    end
  end

  def active_collaborator?(%Collection{} = source, %Accounts.User{} = collaborator) do
    active_collaborator?(source, collaborator.id)
  end

  def active_collaborator?(%Collection{} = source, user_id) when is_integer(user_id) do
    Collection
    |> where(
      [c],
      c.collaboration_id == ^source.id and c.owner_id == ^user_id and
        is_nil(c.collaboration_revoked_at)
    )
    |> Repo.exists?()
  end

  def active_collaborator_user_ids(%Collection{} = source) do
    Collection
    |> where(
      [c],
      c.collaboration_id == ^source.id and is_nil(c.collaboration_revoked_at)
    )
    |> select([c], c.owner_id)
    |> Repo.all()
  end

  def list_collaborators(%Scope{} = scope, %Collection{} = collection) do
    if can_manage_collection?(scope, collection) do
      Collection
      |> where([c], c.collaboration_id == ^collection.id)
      |> order_by([c],
        asc_nulls_first: c.collaboration_revoked_at,
        desc: c.updated_at,
        desc: c.id
      )
      |> preload(:owner)
      |> Repo.all()
    else
      []
    end
  end

  def revoke_collaboration(%Scope{} = scope, %Collection{} = collaboration_mount) do
    source = Repo.get(Collection, collaboration_mount.collaboration_id)

    if source &&
         can_manage_collection?(scope, source) &&
         active_collaboration_mount?(collaboration_mount) do
      collaboration_mount
      |> Collection.changeset(%{collaboration_revoked_at: DateTime.utc_now(:second)})
      |> Repo.update()
      |> tap(fn
        {:ok, _mount} ->
          broadcast_user_collections_changed(collaboration_mount.owner_id)
          broadcast_user_collections_changed(scope.user.id)

        _ ->
          :ok
      end)
    else
      {:error, :unauthorized}
    end
  end

  def restore_collaboration(%Scope{} = scope, %Collection{} = collaboration_mount) do
    source = Repo.get(Collection, collaboration_mount.collaboration_id)

    if source &&
         source.owner_id == scope.user.id &&
         revoked_collaboration_mount?(collaboration_mount) do
      collaboration_mount
      |> Collection.changeset(%{collaboration_revoked_at: nil})
      |> Repo.update()
      |> tap(fn
        {:ok, _mount} ->
          broadcast_user_collections_changed(collaboration_mount.owner_id)
          broadcast_user_collections_changed(scope.user.id)

        _ ->
          :ok
      end)
    else
      {:error, :unauthorized}
    end
  end

  def active_collaboration_mount?(%Collection{
        collaboration_id: collaboration_id,
        collaboration_revoked_at: revoked_at
      }) do
    not is_nil(collaboration_id) and is_nil(revoked_at)
  end

  def revoked_collaboration_mount?(%Collection{
        collaboration_id: collaboration_id,
        collaboration_revoked_at: revoked_at
      }) do
    not is_nil(collaboration_id) and not is_nil(revoked_at)
  end

  def visible_revoked_collaboration_mount?(%Collection{} = collection) do
    revoked_collaboration_mount?(collection) and
      recent_revoked_collaboration_mount?(collection)
  end

  def can_manage_collection?(%Scope{} = scope, %Collection{} = collection) do
    effective = effective_collection(collection)
    effective && effective.id in editable_collaboration_ids(scope)
  end

  def can_edit_collection?(%Scope{} = scope, collection_id) do
    user_id = scope.user.id

    case Repo.get(Collection, collection_id) do
      %Collection{owner_id: ^user_id} = collection ->
        not revoked_collaboration_mount?(collection)

      %Collection{} ->
        collection_id in editable_collaboration_ids(scope)

      nil ->
        false
    end
  end

  def can_reorder_collection?(%Scope{} = scope, collection_id) do
    user_id = scope.user.id

    case Repo.get(Collection, collection_id) do
      %Collection{owner_id: ^user_id} = collection ->
        not revoked_collaboration_mount?(collection) or
          recent_revoked_collaboration_mount?(collection)

      %Collection{} ->
        collection_id in editable_collaboration_ids(scope)

      nil ->
        false
    end
  end

  def can_view_collection?(%Scope{} = scope, collection_id) do
    user_id = scope.user.id

    case Repo.get(Collection, collection_id) do
      %Collection{owner_id: ^user_id} ->
        true

      %Collection{} ->
        collection_id in visible_collaboration_ids(scope)

      nil ->
        false
    end
  end

  def can_edit_bookmark?(%Scope{} = scope, %Bookmark{collection_id: nil} = bookmark) do
    bookmark.created_by_id == scope.user.id
  end

  def can_edit_bookmark?(%Scope{} = scope, %Bookmark{collection_id: collection_id}) do
    can_edit_collection?(scope, collection_id)
  end

  def can_view_bookmark?(%Scope{} = scope, %Bookmark{collection_id: nil} = bookmark) do
    bookmark.created_by_id == scope.user.id
  end

  def can_view_bookmark?(%Scope{} = scope, %Bookmark{collection_id: collection_id}) do
    can_view_collection?(scope, collection_id)
  end

  defp build_tree(collections, bookmarks, own_collections, shared_ids) do
    by_id = Map.new(collections, &{&1.id, &1})
    by_parent = Enum.group_by(collections, & &1.parent_id)
    bookmarks_by_collection = Enum.group_by(bookmarks, & &1.collection_id)

    own_collections
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.sort_by(&{&1.position, &1.title, &1.id})
    |> Enum.map(&build_node(&1, by_id, by_parent, bookmarks_by_collection, nil, shared_ids))
  end

  defp build_node(collection, by_id, by_parent, bookmarks_by_collection, mount, shared_ids) do
    cond do
      revoked_collaboration_mount?(collection) ->
        node(collection, collection, [], [], collection, true, true, false)

      active_collaboration_mount?(collection) ->
        target = Map.fetch!(by_id, collection.collaboration_id)
        mount = %{root: collection, readonly: collection.collaboration_readonly}

        children =
          child_nodes(target, by_id, by_parent, bookmarks_by_collection, mount, shared_ids)

        bookmarks = Map.get(bookmarks_by_collection, target.id, [])

        node(
          collection,
          target,
          children,
          bookmarks,
          collection,
          collection.collaboration_readonly,
          false,
          false
        )

      true ->
        children =
          child_nodes(collection, by_id, by_parent, bookmarks_by_collection, mount, shared_ids)

        bookmarks = Map.get(bookmarks_by_collection, collection.id, [])
        readonly = mount && mount.readonly
        shared = MapSet.member?(shared_ids, collection.id)

        node(
          collection,
          collection,
          children,
          bookmarks,
          mount && mount.root,
          readonly || false,
          false,
          shared
        )
    end
  end

  defp child_nodes(collection, by_id, by_parent, bookmarks_by_collection, mount, shared_ids) do
    collection.id
    |> then(&Map.get(by_parent, &1, []))
    |> Enum.sort_by(&{&1.position, &1.title, &1.id})
    |> Enum.map(&build_node(&1, by_id, by_parent, bookmarks_by_collection, mount, shared_ids))
  end

  defp node(
         collection,
         effective_collection,
         children,
         bookmarks,
         mount,
         readonly,
         revoked,
         shared
       ) do
    bookmark_count =
      length(bookmarks) + Enum.sum(Enum.map(children, & &1.bookmark_count))

    completed_bookmark_count =
      Enum.count(bookmarks, & &1.completed) +
        Enum.sum(Enum.map(children, & &1.completed_bookmark_count))

    %{
      collection: collection,
      effective_collection: effective_collection,
      mount: mount,
      readonly: readonly,
      revoked: revoked,
      shared: shared,
      title: effective_collection.title,
      children: children,
      bookmarks: bookmarks,
      bookmark_count: bookmark_count,
      completed_bookmark_count: completed_bookmark_count
    }
  end

  @doc """
  Formats a bookmark badge as completed/total.
  """
  def bookmark_badge(completed, total) when is_integer(completed) and is_integer(total) do
    "#{completed} / #{total}"
  end

  @doc """
  Formats a collection tree node's bookmark badge as completed/total.
  """
  def collection_bookmark_badge(%{
        bookmark_count: total,
        completed_bookmark_count: completed
      }) do
    bookmark_badge(completed, total)
  end

  @doc """
  Formats an inbox bookmark badge as the total link count.
  """
  def inbox_bookmark_badge(bookmarks) when is_list(bookmarks) do
    length(bookmarks) |> Integer.to_string()
  end

  defp shared_collection_ids(user_id) do
    collaboration_ids =
      Collection
      |> where([c], not is_nil(c.collaboration_id) and is_nil(c.collaboration_revoked_at))
      |> join(:inner, [c], source in Collection, on: source.id == c.collaboration_id)
      |> where([_c, source], source.owner_id == ^user_id)
      |> select([_c, source], source.id)
      |> distinct(true)
      |> Repo.all()

    public_share_ids =
      PublicShare
      |> where([s], is_nil(s.revoked_at))
      |> join(:inner, [s], collection in Collection, on: collection.id == s.collection_id)
      |> where([_s, collection], collection.owner_id == ^user_id)
      |> select([_s, collection], collection.id)
      |> distinct(true)
      |> Repo.all()

    MapSet.new(collaboration_ids ++ public_share_ids)
  end

  defp visible_collaboration_ids(%Scope{} = scope) do
    scope
    |> accessible_tree_root_ids()
    |> descendant_ids()
  end

  defp editable_collaboration_ids(%Scope{} = scope) do
    user_id = scope.user.id

    own_source_ids =
      Collection
      |> where([c], c.owner_id == ^user_id and is_nil(c.collaboration_id))
      |> select([c], c.id)
      |> Repo.all()

    collaboration_target_ids =
      Collection
      |> where(
        [c],
        c.owner_id == ^user_id and not is_nil(c.collaboration_id) and
          is_nil(c.collaboration_revoked_at) and c.collaboration_readonly == false
      )
      |> select([c], c.collaboration_id)
      |> Repo.all()

    (own_source_ids ++ collaboration_target_ids)
    |> descendant_ids()
  end

  defp accessible_tree_root_ids(%Scope{} = scope) do
    user_id = scope.user.id

    own_source_ids =
      Collection
      |> where([c], c.owner_id == ^user_id and is_nil(c.collaboration_id))
      |> select([c], c.id)
      |> Repo.all()

    collaboration_target_ids =
      Collection
      |> where(
        [c],
        c.owner_id == ^user_id and not is_nil(c.collaboration_id) and
          is_nil(c.collaboration_revoked_at)
      )
      |> select([c], c.collaboration_id)
      |> Repo.all()

    own_source_ids ++ collaboration_target_ids
  end

  defp descendant_ids([]), do: []

  defp descendant_ids(root_ids) do
    root_ids
    |> MapSet.new()
    |> collect_descendant_ids(root_ids)
    |> MapSet.to_list()
  end

  defp collect_descendant_ids(acc, []), do: acc

  defp collect_descendant_ids(acc, parent_ids) do
    child_ids =
      Collection
      |> where([c], c.parent_id in ^parent_ids)
      |> select([c], c.id)
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(acc, &1))

    acc
    |> MapSet.union(MapSet.new(child_ids))
    |> collect_descendant_ids(child_ids)
  end

  defp authorize_parent(_scope, nil), do: :ok

  defp authorize_parent(scope, parent_id) do
    if can_edit_collection?(scope, parent_id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_bookmark_parent(_scope, nil), do: :ok

  defp authorize_bookmark_parent(scope, collection_id) do
    if can_edit_collection?(scope, collection_id), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_bookmark_move(scope, bookmark, collection_id) do
    target_id = normalize_collection_id(collection_id)

    if same_bookmark_location?(bookmark.collection_id, target_id) do
      authorize_bookmark_reorder(scope, bookmark)
    else
      authorize_bookmark_transfer(scope, bookmark, target_id)
    end
  end

  defp authorize_bookmark_reorder(%Scope{} = scope, %Bookmark{} = bookmark) do
    if can_edit_bookmark?(scope, bookmark), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_bookmark_transfer(%Scope{} = scope, %Bookmark{} = bookmark, target_id) do
    with true <- can_take_bookmark?(scope, bookmark),
         :ok <- authorize_bookmark_target(scope, target_id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp can_take_bookmark?(%Scope{} = scope, %Bookmark{collection_id: nil} = bookmark) do
    bookmark.created_by_id == scope.user.id
  end

  defp can_take_bookmark?(%Scope{} = scope, %Bookmark{} = bookmark) do
    can_edit_bookmark?(scope, bookmark) or can_view_bookmark?(scope, bookmark)
  end

  defp authorize_bookmark_target(_scope, nil), do: :ok

  defp authorize_bookmark_target(%Scope{} = scope, collection_id) do
    if can_edit_collection?(scope, collection_id), do: :ok, else: {:error, :unauthorized}
  end

  defp same_bookmark_location?(left, right), do: left == right

  defp authorize_bookmark_copy(scope, bookmark, collection_id) do
    with true <- can_view_bookmark?(scope, bookmark),
         false <- can_edit_bookmark?(scope, bookmark),
         :ok <- authorize_bookmark_parent(scope, collection_id),
         false <- same_bookmark_collection?(bookmark, collection_id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp same_bookmark_collection?(%Bookmark{collection_id: nil}, nil), do: true

  defp same_bookmark_collection?(%Bookmark{collection_id: collection_id}, collection_id),
    do: true

  defp same_bookmark_collection?(_, _), do: false

  defp duplicate_bookmark_changeset(%Scope{} = scope, %Bookmark{} = source, collection_id) do
    %Bookmark{}
    |> Bookmark.changeset(%{
      title: source.title,
      url: source.url,
      description: source.description,
      created_by_id: scope.user.id,
      collection_id: collection_id
    })
    |> Ecto.Changeset.put_change(:favicon_data, source.favicon_data)
    |> Ecto.Changeset.put_change(:favicon_content_type, source.favicon_content_type)
    |> Ecto.Changeset.put_change(:favicon_byte_size, source.favicon_byte_size)
    |> Ecto.Changeset.put_change(:favicon_source_url, source.favicon_source_url)
    |> Ecto.Changeset.put_change(:metadata_fetched_at, source.metadata_fetched_at)
  end

  defp validate_copy_bookmark_order(%Scope{} = scope, source, nil, ordered_ids) do
    user_id = scope.user.id

    if source.id in ordered_ids do
      existing_in_target =
        Bookmark
        |> where([b], b.created_by_id == ^user_id and is_nil(b.collection_id))
        |> select([b], b.id)
        |> Repo.all()
        |> MapSet.new()

      actual_without_source =
        ordered_ids
        |> List.delete(source.id)
        |> MapSet.new()

      if MapSet.equal?(existing_in_target, actual_without_source),
        do: :ok,
        else: {:error, :invalid_order}
    else
      {:error, :invalid_order}
    end
  end

  defp validate_copy_bookmark_order(_scope, source, collection_id, ordered_ids) do
    if source.id in ordered_ids do
      existing_in_target =
        Bookmark
        |> where([b], b.collection_id == ^collection_id)
        |> select([b], b.id)
        |> Repo.all()
        |> MapSet.new()

      actual_without_source =
        ordered_ids
        |> List.delete(source.id)
        |> MapSet.new()

      if MapSet.equal?(existing_in_target, actual_without_source),
        do: :ok,
        else: {:error, :invalid_order}
    else
      {:error, :invalid_order}
    end
  end

  defp validate_collection_move(scope, %Collection{} = collection, parent_id, ordered_ids) do
    with :ok <- ensure_moved_in_order(collection, ordered_ids),
         :ok <- authorize_collection_move(scope, collection, parent_id) do
      :ok
    end
  end

  defp ensure_moved_in_order(%Collection{} = collection, ordered_ids) do
    if collection.id in ordered_ids, do: :ok, else: {:error, :invalid_order}
  end

  defp authorize_collection_move(%Scope{} = scope, %Collection{} = collection, parent_id) do
    normalized_parent = normalize_reorder_parent_id(parent_id)

    cond do
      not can_reorder_collection?(scope, collection.id) ->
        {:error, :unauthorized}

      collaboration_mount?(collection) and not is_nil(normalized_parent) ->
        {:error, :unauthorized}

      collection.parent_id != normalized_parent ->
        authorize_collection_reparent(scope, collection, normalized_parent)

      true ->
        authorize_collection_sibling_reorder(scope, collection, normalized_parent)
    end
  end

  defp authorize_collection_reparent(%Scope{} = scope, %Collection{} = collection, parent_id) do
    if user_owned_collection?(scope, collection) and drop_target_editable?(scope, parent_id) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp authorize_collection_sibling_reorder(
         %Scope{} = scope,
         %Collection{} = collection,
         parent_id
       ) do
    cond do
      collaboration_mount?(collection) and is_nil(parent_id) ->
        :ok

      user_owned_collection?(scope, collection) and drop_target_editable?(scope, parent_id) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp drop_target_editable?(_scope, nil), do: true

  defp drop_target_editable?(scope, parent_id), do: can_edit_collection?(scope, parent_id)

  defp user_owned_collection?(%Scope{} = scope, %Collection{} = collection) do
    collection.owner_id == scope.user.id and is_nil(collection.collaboration_id)
  end

  defp collaboration_mount?(%Collection{} = collection) do
    not is_nil(collection.collaboration_id)
  end

  defp reject_cycle(_collection_id, nil), do: :ok

  defp reject_cycle(collection_id, parent_id) when collection_id == parent_id do
    {:error, :cycle}
  end

  defp reject_cycle(collection_id, parent_id) do
    if parent_id in descendant_ids([collection_id]) do
      {:error, :cycle}
    else
      :ok
    end
  end

  defp update_collection_positions(multi, ordered_ids) do
    ordered_ids
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {id, position}, multi ->
      Multi.update_all(
        multi,
        {:collection_position, id},
        from(c in Collection, where: c.id == ^id),
        set: [position: position]
      )
    end)
  end

  defp validate_bookmark_order(_scope, bookmark, _collection_id, ordered_ids) do
    if bookmark.id in ordered_ids do
      :ok
    else
      {:error, :invalid_order}
    end
  end

  defp update_bookmark_positions(multi, %Scope{} = scope, nil, ordered_ids) do
    user_id = scope.user.id

    ordered_ids
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {id, position}, multi ->
      Multi.update_all(
        multi,
        {:bookmark_position, id},
        bookmark_position_query(id, nil, user_id),
        set: [position: position]
      )
    end)
  end

  defp update_bookmark_positions(multi, _scope, collection_id, ordered_ids) do
    ordered_ids
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {id, position}, multi ->
      Multi.update_all(
        multi,
        {:bookmark_position, id},
        bookmark_position_query(id, collection_id),
        set: [position: position]
      )
    end)
  end

  defp bookmark_position_query(id, nil, user_id) do
    from(b in Bookmark,
      where: b.id == ^id and is_nil(b.collection_id) and b.created_by_id == ^user_id
    )
  end

  defp bookmark_position_query(id, collection_id) do
    from(b in Bookmark, where: b.id == ^id and b.collection_id == ^collection_id)
  end

  defp broadcast_bookmark_list_changes(scope, collection_id) do
    broadcast_bookmark_list_changed(scope, collection_id)
  end

  defp broadcast_parent_collection_changed(%Collection{parent_id: parent_id}) do
    broadcast_collection_changed(parent_id)
  end

  defp broadcast_collection_changed(nil), do: :ok

  defp broadcast_collection_changed(collection_id),
    do: broadcast_collection_bookmarks_changed(collection_id)

  defp normalize_collection_id(value) do
    case value do
      nil -> nil
      "" -> nil
      "inbox" -> nil
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
    end
  end

  defp move_bookmark_attrs(%Scope{} = scope, nil) do
    %{collection_id: nil, created_by_id: scope.user.id, completed: false}
  end

  defp move_bookmark_attrs(_scope, collection_id) do
    %{collection_id: collection_id}
  end

  defp normalize_reorder_parent_id("root"), do: nil

  defp normalize_reorder_parent_id(parent_id) when is_binary(parent_id),
    do: String.to_integer(parent_id)

  defp normalize_reorder_parent_id(parent_id), do: parent_id

  defp next_collection_position(parent_id, owner_id \\ nil)

  defp next_collection_position(nil, owner_id) do
    Collection
    |> where([c], is_nil(c.parent_id))
    |> maybe_filter_owner(owner_id)
    |> select([c], coalesce(max(c.position), -1) + 1)
    |> Repo.one()
  end

  defp next_collection_position(parent_id, owner_id) do
    Collection
    |> where([c], c.parent_id == ^parent_id)
    |> maybe_filter_owner(owner_id)
    |> select([c], coalesce(max(c.position), -1) + 1)
    |> Repo.one()
  end

  defp maybe_filter_owner(query, nil), do: query
  defp maybe_filter_owner(query, owner_id), do: where(query, [c], c.owner_id == ^owner_id)

  defp next_bookmark_position(user_id, nil) do
    Bookmark
    |> where([b], b.created_by_id == ^user_id and is_nil(b.collection_id))
    |> select([b], coalesce(max(b.position), -1) + 1)
    |> Repo.one()
  end

  defp next_bookmark_position(_user_id, collection_id) do
    Bookmark
    |> where([b], b.collection_id == ^collection_id)
    |> select([b], coalesce(max(b.position), -1) + 1)
    |> Repo.one()
  end

  defp effective_collection(%Collection{} = collection) do
    if active_collaboration_mount?(collection) do
      Repo.get(Collection, collection.collaboration_id)
    else
      collection
    end
  end

  defp normalize_attrs(attrs) do
    for {key, value} <- attrs, into: %{} do
      key =
        case key do
          key when is_binary(key) -> String.to_existing_atom(key)
          key -> key
        end

      {key, value}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: to_integer(value)

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  defp revoked_mount_visible_cutoff do
    DateTime.utc_now(:second)
    |> DateTime.add(-@revoked_mount_visibility_seconds, :second)
  end

  defp recent_revoked_collaboration_mount?(%Collection{collaboration_revoked_at: revoked_at})
       when not is_nil(revoked_at) do
    DateTime.compare(revoked_at, revoked_mount_visible_cutoff()) == :gt
  end

  defp recent_revoked_collaboration_mount?(_), do: false

  defp uniq_by_id(collections), do: Map.values(Map.new(collections, &{&1.id, &1}))

  defp generate_token do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp enqueue_metadata_fetch({:ok, %Bookmark{} = bookmark}) do
    %{bookmark_id: bookmark.id}
    |> FetchBookmarkMetadataWorker.new()
    |> Oban.insert()

    {:ok, bookmark}
  end

  defp enqueue_metadata_fetch(result), do: result
end
