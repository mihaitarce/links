defmodule LinksWeb.DashboardLive do
  use LinksWeb, :live_view

  alias Links.Bookmarks.Bookmark
  alias Links.Collections
  alias Links.Collections.Collection

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Links.PubSub, "bookmarks")

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:collapsed, MapSet.new())
     |> assign(:selected, nil)
     |> assign(:selected_context, nil)
     |> assign(:public_shares, [])
     |> assign(:collaboration_email, "")
     |> assign(:collaboration_readonly, false)
     |> assign_forms()
     |> refresh_dashboard()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-3rem)] w-full overflow-hidden bg-base-200 text-sm">
        <aside class="flex w-[28rem] shrink-0 flex-col border-r border-base-300 bg-base-100">
          <div class="border-b border-base-300 p-3">
            <.form for={@new_bookmark_form} id="new-link-form" phx-submit="create_link">
              <div class="join w-full">
                <input
                  type="url"
                  name="bookmark[url]"
                  value=""
                  placeholder="Paste a new link..."
                  class="input join-item input-sm w-full"
                  required
                />
                <button class="btn btn-primary join-item btn-sm">Add</button>
              </div>
            </.form>
          </div>

          <div class="min-h-0 flex-1 overflow-auto">
            <section class="border-b border-base-300 p-3">
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Inbox
                </h2>
                <span class="badge badge-ghost badge-sm">{length(@dashboard.inbox)}</span>
              </div>
              <ul
                id="bookmarks-zone-inbox"
                phx-hook="SortableTree"
                data-kind="bookmark"
                data-parent-id=""
                class="space-y-1"
              >
                <li
                  :for={bookmark <- @dashboard.inbox}
                  id={"bookmark-#{bookmark.id}"}
                  data-id={bookmark.id}
                  class="group flex cursor-grab items-center gap-2 rounded px-2 py-1 hover:bg-base-200"
                >
                  <span class="text-base-content/40">⋮⋮</span>
                  <.bookmark_icon bookmark={bookmark} />
                  <button
                    type="button"
                    phx-click="select_bookmark"
                    phx-value-id={bookmark.id}
                    class={[
                      "truncate text-left",
                      selected?(@selected, :bookmark, bookmark.id) && "font-semibold text-primary"
                    ]}
                  >
                    {bookmark_label(bookmark)}
                  </button>
                </li>
              </ul>
            </section>

            <section class="p-3">
              <div class="mb-2 flex items-center justify-between">
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Projects
                </h2>
                <button class="btn btn-ghost btn-xs" phx-click="new_collection">New</button>
              </div>
              <ul
                id="collections-zone-root"
                phx-hook="SortableTree"
                data-kind="collection"
                data-parent-id=""
                class="space-y-1"
              >
                <.tree_node
                  :for={node <- @dashboard.tree}
                  node={node}
                  selected={@selected}
                  collapsed={@collapsed}
                  depth={0}
                />
              </ul>
            </section>
          </div>
        </aside>

        <section class="min-w-0 flex-1 overflow-auto p-4">
          <%= if @selected_context do %>
            <.detail_panel
              selected={@selected}
              context={@selected_context}
              collection_form={@collection_form}
              child_collection_form={@child_collection_form}
              bookmark_form={@bookmark_form}
              public_shares={@public_shares}
              collaboration_email={@collaboration_email}
              collaboration_readonly={@collaboration_readonly}
            />
          <% else %>
            <div class="flex h-full items-center justify-center">
              <div class="max-w-md rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center">
                <h1 class="text-lg font-semibold">Select a collection or bookmark</h1>
                <p class="mt-2 text-base-content/60">
                  The inbox is always visible on the left. Use the project tree for details,
                  sharing, collaboration, and editing.
                </p>
              </div>
            </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :bookmark, Bookmark, required: true
  attr :class, :string, default: "size-4"

  def bookmark_icon(assigns) do
    ~H"""
    <%= if @bookmark.favicon_data do %>
      <img
        src={~p"/bookmarks/#{@bookmark.id}/favicon"}
        alt=""
        class={["shrink-0 rounded-sm object-contain", @class]}
      />
    <% else %>
      <.icon name="hero-link" class={["shrink-0 text-base-content/40", @class]} />
    <% end %>
    """
  end

  attr :node, :map, required: true
  attr :selected, :map, default: nil
  attr :collapsed, MapSet, required: true
  attr :depth, :integer, required: true

  def tree_node(assigns) do
    assigns =
      assigns
      |> assign(:collection, assigns.node.collection)
      |> assign(:effective, assigns.node.effective_collection)
      |> assign(:expanded, not MapSet.member?(assigns.collapsed, assigns.node.collection.id))
      |> assign(:has_children, assigns.node.children != [] or assigns.node.bookmarks != [])
      |> assign(:padding, 0.75 + assigns.depth * 0.9)

    ~H"""
    <li
      id={"collection-#{@collection.id}"}
      data-id={@collection.id}
      class={["rounded", @node.revoked && "opacity-50"]}
    >
      <div
        class={[
          "group flex items-center gap-1 rounded px-2 py-1 hover:bg-base-200",
          selected?(@selected, :collection, @collection.id) && "bg-primary/10 text-primary",
          @node.revoked && "pointer-events-none line-through"
        ]}
        style={"padding-left: #{@padding}rem"}
      >
        <button
          :if={@has_children}
          type="button"
          class="btn btn-ghost btn-xs h-5 min-h-5 w-5 px-0"
          phx-click="toggle_collection"
          phx-value-id={@collection.id}
        >
          {if @expanded, do: "▾", else: "▸"}
        </button>
        <span :if={!@has_children} class="w-5" />
        <span class="cursor-grab text-base-content/40">⋮⋮</span>
        <button
          type="button"
          class="min-w-0 flex-1 truncate text-left"
          disabled={@node.revoked}
          phx-click="select_collection"
          phx-value-id={@collection.id}
        >
          {@node.title}
        </button>
        <span :if={@node.mount && !@node.revoked} class="badge badge-outline badge-xs">
          {if @node.readonly, do: "read", else: "edit"}
        </span>
      </div>

      <div :if={@expanded && !@node.revoked}>
        <ul
          id={"collections-zone-#{@effective.id}"}
          phx-hook="SortableTree"
          data-kind="collection"
          data-parent-id={@effective.id}
          class="space-y-1"
        >
          <.tree_node
            :for={child <- @node.children}
            node={child}
            selected={@selected}
            collapsed={@collapsed}
            depth={@depth + 1}
          />
        </ul>
        <ul
          id={"bookmarks-zone-#{@effective.id}"}
          phx-hook="SortableTree"
          data-kind="bookmark"
          data-parent-id={@effective.id}
          class="space-y-1"
        >
          <li
            :for={bookmark <- @node.bookmarks}
            id={"bookmark-#{bookmark.id}"}
            data-id={bookmark.id}
            class="group flex cursor-grab items-center gap-2 rounded px-2 py-1 hover:bg-base-200"
            style={"padding-left: #{@padding + 1.8}rem"}
          >
            <span class="text-base-content/40">⋮⋮</span>
            <.bookmark_icon bookmark={bookmark} />
            <button
              type="button"
              phx-click="select_bookmark"
              phx-value-id={bookmark.id}
              class={[
                "truncate text-left",
                selected?(@selected, :bookmark, bookmark.id) && "font-semibold text-primary"
              ]}
            >
              {bookmark_label(bookmark)}
            </button>
          </li>
        </ul>
      </div>
    </li>
    """
  end

  @impl true
  def handle_info({:bookmark_metadata_updated, bookmark_id}, socket) do
    socket = refresh_dashboard(socket)

    socket =
      case socket.assigns.selected do
        %{type: :bookmark, id: ^bookmark_id} ->
          bookmark = Collections.get_bookmark!(bookmark_id)
          select_bookmark(socket, bookmark)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  attr :selected, :map, required: true
  attr :context, :map, required: true
  attr :collection_form, :any, required: true
  attr :child_collection_form, :any, required: true
  attr :bookmark_form, :any, required: true
  attr :public_shares, :list, default: []
  attr :collaboration_email, :string, default: ""
  attr :collaboration_readonly, :boolean, default: false

  def detail_panel(%{selected: %{type: :bookmark}} = assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl space-y-4">
      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <div class="mb-4 flex items-start gap-3">
          <.bookmark_icon bookmark={@context.bookmark} class="mt-1 size-8" />
          <div class="min-w-0">
            <h1 class="truncate text-lg font-semibold">{bookmark_label(@context.bookmark)}</h1>
            <p class="truncate text-sm text-base-content/60">{@context.bookmark.url}</p>
          </div>
        </div>
        <.form
          for={@bookmark_form}
          id="bookmark-form"
          phx-submit="save_bookmark"
          phx-change="validate_bookmark"
        >
          <.input field={@bookmark_form[:title]} label="Title" disabled={@context.readonly} />
          <.input field={@bookmark_form[:url]} type="url" label="URL" disabled={@context.readonly} />
          <.input
            field={@bookmark_form[:description]}
            type="textarea"
            label="Description"
            disabled={@context.readonly}
          />
          <div :if={!@context.readonly} class="mt-4 flex gap-2">
            <button class="btn btn-primary btn-sm">Save</button>
            <button
              type="button"
              class="btn btn-error btn-soft btn-sm"
              phx-click="delete_bookmark"
              phx-value-id={@context.bookmark.id}
            >
              Delete
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  def detail_panel(assigns) do
    assigns = assign(assigns, :readonly, assigns.context.readonly)

    ~H"""
    <div class="mx-auto max-w-4xl space-y-4">
      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <div class="mb-4 flex items-start justify-between gap-4">
          <div>
            <p :if={@context.mount} class="text-xs uppercase tracking-wide text-base-content/50">
              Collaborated collection
            </p>
            <h1 class="text-xl font-semibold">{@context.effective_collection.title}</h1>
            <p :if={@readonly} class="mt-1 text-sm text-base-content/60">Read-only access</p>
          </div>
          <button
            :if={!@readonly}
            type="button"
            class="btn btn-error btn-soft btn-sm"
            phx-click="delete_collection"
            phx-value-id={@context.effective_collection.id}
          >
            Delete
          </button>
        </div>

        <.form
          :if={!@readonly}
          for={@collection_form}
          id="collection-form"
          phx-submit="save_collection"
          phx-change="validate_collection"
        >
          <.input field={@collection_form[:title]} label="Title" />
          <button class="btn btn-primary btn-sm mt-2">Save collection</button>
        </.form>
      </div>

      <div :if={!@readonly} class="grid gap-4 lg:grid-cols-2">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="mb-3 font-semibold">Add Sub-Collection</h2>
          <.form
            for={@child_collection_form}
            id="child-collection-form"
            phx-submit="create_child_collection"
          >
            <.input field={@child_collection_form[:title]} label="Title" />
            <button class="btn btn-primary btn-sm mt-2">Create</button>
          </.form>
        </div>

        <div :if={@context.can_manage} class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="mb-3 font-semibold">Collaborators</h2>
          <.form for={%{}} id="collaboration-form" phx-submit="create_collaboration">
            <.input
              name="collaboration[email]"
              value={@collaboration_email}
              type="email"
              label="User email"
            />
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="collaboration[readonly]"
                value="true"
                checked={@collaboration_readonly}
                class="checkbox checkbox-sm"
              /> Read-only
            </label>
            <button class="btn btn-primary btn-sm mt-2">Add collaborator</button>
          </.form>
        </div>
      </div>

      <div
        :if={!@readonly && @context.can_manage}
        class="rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-3 flex items-center justify-between">
          <h2 class="font-semibold">Public Sharing</h2>
          <button class="btn btn-primary btn-sm" phx-click="create_public_share">Create public link</button>
        </div>
        <ul class="space-y-2">
          <li
            :for={share <- @public_shares}
            class="flex items-center justify-between rounded bg-base-200 p-2"
          >
            <div class="min-w-0">
              <p class={["truncate font-mono text-xs", share.revoked_at && "line-through opacity-60"]}>
                {share.token}
              </p>
              <p class="text-xs text-base-content/50">
                {if share.revoked_at, do: "Revoked", else: "Active"}
              </p>
            </div>
            <button
              :if={is_nil(share.revoked_at)}
              class="btn btn-ghost btn-xs"
              phx-click="revoke_public_share"
              phx-value-id={share.id}
            >
              Revoke
            </button>
          </li>
          <li :if={@public_shares == []} class="text-sm text-base-content/60">
            No public shares yet.
          </li>
        </ul>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("create_link", %{"bookmark" => bookmark_params}, socket) do
    case Collections.create_inbox_bookmark(socket.assigns.current_scope, bookmark_params) do
      {:ok, _bookmark} ->
        {:noreply, refresh_dashboard(socket)}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_bookmark_form, to_form(changeset))}
    end
  end

  def handle_event("new_collection", _params, socket) do
    case Collections.create_collection(socket.assigns.current_scope, %{
           title: "Untitled collection"
         }) do
      {:ok, collection} ->
        {:noreply, socket |> refresh_dashboard() |> select_collection(collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create collection")}
    end
  end

  def handle_event("select_collection", %{"id" => id}, socket) do
    {:noreply, select_collection(socket, id)}
  end

  def handle_event("select_bookmark", %{"id" => id}, socket) do
    bookmark = Collections.get_bookmark!(id)

    if Collections.can_view_bookmark?(socket.assigns.current_scope, bookmark) do
      {:noreply,
       socket
       |> assign(:selected, %{type: :bookmark, id: bookmark.id})
       |> assign(:selected_context, %{
         bookmark: bookmark,
         readonly: not Collections.can_edit_bookmark?(socket.assigns.current_scope, bookmark)
       })
       |> assign(:bookmark_form, to_form(Bookmark.changeset(bookmark, %{})))}
    else
      {:noreply, put_flash(socket, :error, "You do not have access to that bookmark")}
    end
  end

  def handle_event("toggle_collection", %{"id" => id}, socket) do
    id = String.to_integer(id)
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, id) do
        MapSet.delete(collapsed, id)
      else
        MapSet.put(collapsed, id)
      end

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  def handle_event("validate_collection", %{"collection" => params}, socket) do
    collection = socket.assigns.selected_context.effective_collection
    changeset = Collection.changeset(collection, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :collection_form, to_form(changeset))}
  end

  def handle_event("save_collection", %{"collection" => params}, socket) do
    collection = socket.assigns.selected_context.effective_collection

    case Collections.update_collection(socket.assigns.current_scope, collection, params) do
      {:ok, collection} ->
        {:noreply, socket |> refresh_dashboard() |> select_collection(collection.id)}

      {:error, changeset} ->
        {:noreply, assign(socket, :collection_form, to_form(changeset))}
    end
  end

  def handle_event("delete_collection", %{"id" => id}, socket) do
    collection = Collections.get_collection!(id)

    case Collections.delete_collection(socket.assigns.current_scope, collection) do
      {:ok, _collection} ->
        {:noreply,
         socket |> assign(:selected, nil) |> assign(:selected_context, nil) |> refresh_dashboard()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete collection")}
    end
  end

  def handle_event("create_child_collection", %{"collection" => params}, socket) do
    parent = socket.assigns.selected_context.effective_collection
    params = Map.put(params, "parent_id", parent.id)

    case Collections.create_collection(socket.assigns.current_scope, params) do
      {:ok, collection} ->
        {:noreply, socket |> refresh_dashboard() |> select_collection(collection.id)}

      {:error, changeset} ->
        {:noreply, assign(socket, :child_collection_form, to_form(changeset))}
    end
  end

  def handle_event("validate_bookmark", %{"bookmark" => params}, socket) do
    bookmark = socket.assigns.selected_context.bookmark
    changeset = Bookmark.changeset(bookmark, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :bookmark_form, to_form(changeset))}
  end

  def handle_event("save_bookmark", %{"bookmark" => params}, socket) do
    bookmark = socket.assigns.selected_context.bookmark

    case Collections.update_bookmark(socket.assigns.current_scope, bookmark, params) do
      {:ok, bookmark} ->
        {:noreply, socket |> refresh_dashboard() |> select_bookmark(bookmark)}

      {:error, changeset} ->
        {:noreply, assign(socket, :bookmark_form, to_form(changeset))}
    end
  end

  def handle_event("delete_bookmark", %{"id" => id}, socket) do
    bookmark = Collections.get_bookmark!(id)

    case Collections.delete_bookmark(socket.assigns.current_scope, bookmark) do
      {:ok, _bookmark} ->
        {:noreply,
         socket |> assign(:selected, nil) |> assign(:selected_context, nil) |> refresh_dashboard()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete bookmark")}
    end
  end

  def handle_event("move_collection", params, socket) do
    with %{"id" => id, "parent_id" => parent_id, "ordered_ids" => ordered_ids} <- params,
         {:ok, _collection} <-
           Collections.move_collection(socket.assigns.current_scope, id, parent_id, ordered_ids) do
      {:noreply, refresh_dashboard(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not move collection")}
    end
  end

  def handle_event("move_bookmark", params, socket) do
    with %{"id" => id, "parent_id" => parent_id, "ordered_ids" => ordered_ids} <- params,
         {:ok, _bookmark} <-
           Collections.move_bookmark(socket.assigns.current_scope, id, parent_id, ordered_ids) do
      {:noreply, refresh_dashboard(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not move bookmark")}
    end
  end

  def handle_event("create_public_share", _params, socket) do
    collection = socket.assigns.selected_context.effective_collection

    case Collections.create_public_share(socket.assigns.current_scope, collection) do
      {:ok, _share} ->
        {:noreply, select_collection(refresh_dashboard(socket), collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not create public share")}
    end
  end

  def handle_event("revoke_public_share", %{"id" => id}, socket) do
    share = Collections.get_public_share!(id)
    collection = socket.assigns.selected_context.effective_collection

    case Collections.revoke_public_share(socket.assigns.current_scope, share) do
      {:ok, _share} ->
        {:noreply, select_collection(refresh_dashboard(socket), collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke public share")}
    end
  end

  def handle_event("create_collaboration", %{"collaboration" => params}, socket) do
    collection = socket.assigns.selected_context.effective_collection
    readonly = Map.get(params, "readonly") == "true"

    case Collections.create_collaboration(
           socket.assigns.current_scope,
           collection,
           params["email"],
           readonly
         ) do
      {:ok, _mount} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collaborator added")
         |> assign(:collaboration_email, "")
         |> refresh_dashboard()
         |> select_collection(collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not add collaborator")}
    end
  end

  defp refresh_dashboard(socket) do
    assign(socket, :dashboard, Collections.list_dashboard(socket.assigns.current_scope))
  end

  defp assign_forms(socket) do
    socket
    |> assign(:new_bookmark_form, to_form(Bookmark.changeset(%Bookmark{}, %{})))
    |> assign(:collection_form, to_form(Collection.changeset(%Collection{}, %{})))
    |> assign(:child_collection_form, to_form(Collection.changeset(%Collection{}, %{})))
    |> assign(:bookmark_form, to_form(Bookmark.changeset(%Bookmark{}, %{})))
  end

  defp select_collection(socket, id) do
    case Collections.resolve_collection(socket.assigns.current_scope, id) do
      {:ok, context} ->
        can_manage = context.effective_collection.owner_id == socket.assigns.current_scope.user.id
        context = Map.put(context, :can_manage, can_manage)

        shares =
          Collections.list_public_shares(
            socket.assigns.current_scope,
            context.effective_collection
          )

        socket
        |> assign(:selected, %{type: :collection, id: context.collection.id})
        |> assign(:selected_context, context)
        |> assign(:public_shares, shares)
        |> assign(
          :collection_form,
          to_form(Collection.changeset(context.effective_collection, %{}))
        )
        |> assign(:child_collection_form, to_form(Collection.changeset(%Collection{}, %{})))

      {:error, _reason} ->
        put_flash(socket, :error, "That collection is not available")
    end
  end

  defp select_bookmark(socket, %Bookmark{} = bookmark) do
    socket
    |> assign(:selected, %{type: :bookmark, id: bookmark.id})
    |> assign(:selected_context, %{
      bookmark: bookmark,
      readonly: not Collections.can_edit_bookmark?(socket.assigns.current_scope, bookmark)
    })
    |> assign(:bookmark_form, to_form(Bookmark.changeset(bookmark, %{})))
  end

  def selected?(%{type: type, id: id}, type, id), do: true
  def selected?(_, _, _), do: false

  def bookmark_label(%Bookmark{page_title: title}) when is_binary(title) and title != "",
    do: title

  def bookmark_label(%Bookmark{title: title}), do: title
end
