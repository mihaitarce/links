defmodule Links.Collections do
  @moduledoc """
  Collection, bookmark, collaboration, and public sharing operations.
  """

  import Ecto.Query, warn: false

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

    own_collections =
      Collection
      |> where([c], c.owner_id == ^user_id)
      |> order_by([c], asc: c.position, asc: c.title, asc: c.id)
      |> Repo.all()

    active_mount_targets =
      own_collections
      |> Enum.filter(&active_collaboration_mount?/1)
      |> Enum.map(& &1.collaboration_id)

    visible_target_ids = descendant_ids(active_mount_targets)

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

    %{
      inbox: list_inbox_bookmarks(scope),
      tree: build_tree(collections, bookmarks, own_collections),
      collections: collections
    }
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
    end
  end

  def update_collection(%Scope{} = scope, %Collection{} = collection, attrs) do
    if can_edit_collection?(scope, collection.id) do
      collection
      |> Collection.changeset(normalize_attrs(attrs))
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  def delete_collection(%Scope{} = scope, %Collection{} = collection) do
    if can_edit_collection?(scope, collection.id) do
      collection_id = collection.id

      with {:ok, collection} <- Repo.delete(collection) do
        broadcast_collection_bookmarks_changed(collection_id)
        {:ok, collection}
      end
    else
      {:error, :unauthorized}
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
        broadcast_collection_bookmarks_changed(bookmark.collection_id)
      end)
    else
      {:error, :unauthorized}
    end
  end

  def delete_bookmark(%Scope{} = scope, %Bookmark{} = bookmark) do
    if can_edit_bookmark?(scope, bookmark) do
      collection_id = bookmark.collection_id

      with {:ok, bookmark} <- Repo.delete(bookmark) do
        broadcast_inbox_bookmarks_changed(scope.user.id)
        broadcast_collection_bookmarks_changed(collection_id)
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
      |> Multi.update(:bookmark, Bookmark.changeset(bookmark, %{collection_id: collection_id}))
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

  def update_bookmark_metadata(%Bookmark{} = bookmark, attrs) do
    bookmark
    |> Bookmark.metadata_changeset(attrs)
    |> Repo.update()
  end

  def create_public_share(%Scope{} = scope, %Collection{} = collection) do
    if owns_effective_collection?(scope, collection) do
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
    if owns_effective_collection?(scope, collection) do
      PublicShare
      |> where([s], s.collection_id == ^collection.id)
      |> order_by([s], desc: s.inserted_at, desc: s.id)
      |> Repo.all()
    else
      []
    end
  end

  def get_public_share!(id), do: Repo.get!(PublicShare, id)

  def revoke_public_share(%Scope{} = scope, %PublicShare{} = public_share) do
    public_share = Repo.preload(public_share, :collection)

    if owns_effective_collection?(scope, public_share.collection) do
      public_share
      |> PublicShare.changeset(%{revoked_at: DateTime.utc_now(:second)})
      |> Repo.update()
    else
      {:error, :unauthorized}
    end
  end

  def create_collaboration(%Scope{} = scope, %Collection{} = source, collaborator_email, readonly) do
    with true <- source.owner_id == scope.user.id,
         %Accounts.User{} = collaborator <- Accounts.get_user_by_email(collaborator_email),
         false <- collaborator.id == scope.user.id do
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
    else
      _ -> {:error, :unauthorized}
    end
  end

  def revoke_collaboration(%Scope{} = scope, %Collection{} = collaboration_mount) do
    source = Repo.get(Collection, collaboration_mount.collaboration_id)

    if source && source.owner_id == scope.user.id do
      collaboration_mount
      |> Collection.changeset(%{collaboration_revoked_at: DateTime.utc_now(:second)})
      |> Repo.update()
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

  def can_edit_collection?(%Scope{} = scope, collection_id) do
    user_id = scope.user.id

    case Repo.get(Collection, collection_id) do
      %Collection{owner_id: ^user_id} ->
        true

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

  defp build_tree(collections, bookmarks, own_collections) do
    by_id = Map.new(collections, &{&1.id, &1})
    by_parent = Enum.group_by(collections, & &1.parent_id)
    bookmarks_by_collection = Enum.group_by(bookmarks, & &1.collection_id)

    own_collections
    |> Enum.filter(&is_nil(&1.parent_id))
    |> Enum.sort_by(&{&1.position, &1.title, &1.id})
    |> Enum.map(&build_node(&1, by_id, by_parent, bookmarks_by_collection, nil))
  end

  defp build_node(collection, by_id, by_parent, bookmarks_by_collection, mount) do
    cond do
      revoked_collaboration_mount?(collection) ->
        node(collection, collection, [], [], collection, true, true)

      active_collaboration_mount?(collection) ->
        target = Map.fetch!(by_id, collection.collaboration_id)
        mount = %{root: collection, readonly: collection.collaboration_readonly}
        children = child_nodes(target, by_id, by_parent, bookmarks_by_collection, mount)
        bookmarks = Map.get(bookmarks_by_collection, target.id, [])

        node(
          collection,
          target,
          children,
          bookmarks,
          collection,
          collection.collaboration_readonly,
          false
        )

      true ->
        children = child_nodes(collection, by_id, by_parent, bookmarks_by_collection, mount)
        bookmarks = Map.get(bookmarks_by_collection, collection.id, [])
        readonly = mount && mount.readonly

        node(
          collection,
          collection,
          children,
          bookmarks,
          mount && mount.root,
          readonly || false,
          false
        )
    end
  end

  defp child_nodes(collection, by_id, by_parent, bookmarks_by_collection, mount) do
    collection.id
    |> then(&Map.get(by_parent, &1, []))
    |> Enum.sort_by(&{&1.position, &1.title, &1.id})
    |> Enum.map(&build_node(&1, by_id, by_parent, bookmarks_by_collection, mount))
  end

  defp node(collection, effective_collection, children, bookmarks, mount, readonly, revoked) do
    %{
      collection: collection,
      effective_collection: effective_collection,
      mount: mount,
      readonly: readonly,
      revoked: revoked,
      title: effective_collection.title,
      children: children,
      bookmarks: bookmarks
    }
  end

  defp visible_collaboration_ids(%Scope{} = scope) do
    scope
    |> active_mounts()
    |> Enum.map(& &1.collaboration_id)
    |> descendant_ids()
  end

  defp editable_collaboration_ids(%Scope{} = scope) do
    scope
    |> active_mounts()
    |> Enum.reject(& &1.collaboration_readonly)
    |> Enum.map(& &1.collaboration_id)
    |> descendant_ids()
  end

  defp active_mounts(%Scope{} = scope) do
    Collection
    |> where(
      [c],
      c.owner_id == ^scope.user.id and not is_nil(c.collaboration_id) and
        is_nil(c.collaboration_revoked_at)
    )
    |> Repo.all()
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
    with true <- can_edit_bookmark?(scope, bookmark),
         :ok <- authorize_bookmark_parent(scope, collection_id) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp validate_bookmark_order(%Scope{} = scope, bookmark, nil, ordered_ids) do
    user_id = scope.user.id

    existing_in_target =
      Bookmark
      |> where(
        [b],
        b.created_by_id == ^user_id and is_nil(b.collection_id) and b.id != ^bookmark.id
      )
      |> select([b], b.id)
      |> Repo.all()
      |> MapSet.new()

    expected = MapSet.put(existing_in_target, bookmark.id)
    actual = MapSet.new(ordered_ids)

    if MapSet.equal?(expected, actual), do: :ok, else: {:error, :invalid_order}
  end

  defp validate_bookmark_order(_scope, bookmark, collection_id, ordered_ids) do
    existing_in_target =
      Bookmark
      |> where([b], b.collection_id == ^collection_id and b.id != ^bookmark.id)
      |> select([b], b.id)
      |> Repo.all()
      |> MapSet.new()

    expected = MapSet.put(existing_in_target, bookmark.id)
    actual = MapSet.new(ordered_ids)

    if MapSet.equal?(expected, actual), do: :ok, else: {:error, :invalid_order}
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

  defp broadcast_bookmark_list_changes(%Scope{} = scope, nil) do
    broadcast_inbox_bookmarks_changed(scope.user.id)
  end

  defp broadcast_bookmark_list_changes(_scope, collection_id) do
    broadcast_collection_bookmarks_changed(collection_id)
  end

  defp normalize_collection_id(value) do
    case value do
      nil -> nil
      "" -> nil
      "inbox" -> nil
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
    end
  end

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

  defp owns_effective_collection?(%Scope{} = scope, %Collection{} = collection) do
    effective =
      if active_collaboration_mount?(collection) do
        Repo.get(Collection, collection.collaboration_id)
      else
        collection
      end

    effective && effective.owner_id == scope.user.id
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
