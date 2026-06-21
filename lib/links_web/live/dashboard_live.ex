defmodule LinksWeb.DashboardLive do
  use LinksWeb, :live_view

  alias Links.Accounts
  alias Links.Bookmarks.Bookmark
  alias Links.Collections
  alias Links.Collections.Collection
  alias Links.Sharing.PublicShare

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Links.PubSub, "bookmarks")

      Phoenix.PubSub.subscribe(
        Links.PubSub,
        Collections.inbox_bookmarks_topic(socket.assigns.current_scope.user.id)
      )

      Phoenix.PubSub.subscribe(
        Links.PubSub,
        Collections.user_collections_topic(socket.assigns.current_scope.user.id)
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "links: dashboard")
     |> assign(:collapsed, MapSet.new())
     |> assign(:subscribed_collection_ids, MapSet.new())
     |> assign(:selected, nil)
     |> assign(:selected_context, nil)
     |> assign(:confirm_delete_collection?, false)
     |> assign(:confirm_delete_bookmark?, false)
     |> assign(:confirm_revoke_collaboration_id, nil)
     |> assign(:confirm_revoke_public_share_id, nil)
     |> assign(:public_shares, [])
     |> assign(:collaborators, [])
     |> assign(:pending_metadata_ids, MapSet.new())
     |> assign_forms()
     |> refresh_dashboard()
     |> collapse_all_collections()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-full min-h-0 w-full flex-col lg:flex-row lg:overflow-hidden bg-base-200 text-sm">
        <aside class="flex w-full min-w-0 shrink-0 flex-col border-r border-base-300 bg-base-100 lg:w-[70ch] lg:max-w-[70ch] xl:w-[90ch] xl:max-w-[90ch]">
          <div class="border-b border-base-300 p-3">
            <.form for={@new_bookmark_form} id="new-link-form" phx-submit="create_link">
              <div class="join w-full">
                <input
                  type="url"
                  name={@new_bookmark_form[:url].name}
                  id={@new_bookmark_form[:url].id}
                  value={@new_bookmark_form[:url].value || ""}
                  placeholder="Paste a new link..."
                  class="input join-item w-full"
                  required
                  autocomplete="off"
                />
                <button class="btn btn-primary join-item">Add</button>
              </div>
            </.form>
          </div>

          <div
            id="bookmarks-sidebar"
            phx-hook="CollectionSort"
            class="flex min-h-0 flex-1 flex-col"
          >
            <section class="flex min-h-0 max-h-[50dvh] shrink-0 flex-col overflow-hidden border-b border-base-300 p-3">
              <div class="mb-2 flex shrink-0 items-center gap-1.5">
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Inbox
                </h2>
                <span
                  id="inbox-bookmark-count"
                  class="badge badge-ghost badge-sm shrink-0 tabular-nums"
                >
                  {Collections.inbox_bookmark_badge(@dashboard.inbox)}
                </span>
              </div>
              <ul
                id="bookmarks-zone-inbox"
                phx-hook="BookmarkSort"
                data-collection-id="inbox"
                class={sidebar_menu_class(["overflow-y-auto"])}
              >
                <.bookmark_menu_link
                  :for={bookmark <- @dashboard.inbox}
                  bookmark={bookmark}
                  selected={selected?(@selected, :bookmark, bookmark.id)}
                  metadata_pending={MapSet.member?(@pending_metadata_ids, bookmark.id)}
                />
                <li
                  id="inbox-empty-state"
                  class="inbox-empty-state bookmark-menu-row flex min-w-0 w-full items-center justify-center"
                  aria-hidden="true"
                >
                  <span class="inbox-empty-state-placeholder">Your inbox is empty</span>
                </li>
              </ul>
            </section>

            <section class="flex min-h-0 flex-1 flex-col overflow-hidden p-3">
              <div class="mb-2 flex shrink-0 items-center justify-between">
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Collections
                </h2>
                <button class="btn btn-primary btn-soft" phx-click="new_collection">
                  New collection
                </button>
              </div>
              <ul
                id="collections-zone-root"
                data-collection-sortable
                data-parent-id="root"
                class={sidebar_menu_class(["overflow-y-auto overflow-x-hidden"])}
              >
                <.tree_node
                  :for={node <- @dashboard.tree}
                  node={node}
                  selected={@selected}
                  collapsed={@collapsed}
                  depth={0}
                  current_scope={@current_scope}
                  pending_metadata_ids={@pending_metadata_ids}
                />
                <li
                  id="collections-empty-state"
                  class="inbox-empty-state bookmark-menu-row flex min-w-0 w-full items-center justify-center"
                  aria-hidden="true"
                >
                  <span class="inbox-empty-state-placeholder">
                    You don't have any collections yet
                  </span>
                </li>
              </ul>
            </section>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".BookmarkOpenOnDblClick">
            export default {
              mounted() {
                this.onDblClick = () => {
                  const url = this.el.dataset.url

                  if (url) {
                    window.open(url, "_blank", "noopener,noreferrer")
                  }
                }

                this.el.addEventListener("dblclick", this.onDblClick)
              },
              destroyed() {
                this.el.removeEventListener("dblclick", this.onDblClick)
              }
            }
          </script>
        </aside>

        <%= if @selected_context do %>
          <div
            id="detail-panel"
            class="hidden min-w-0 flex-1 flex-col overflow-auto border-l border-base-300 lg:flex"
          >
            <div class="min-h-0 flex-1 overflow-y-auto p-4">
              <.detail_panel
                selected={@selected}
                context={@selected_context}
                collection_form={@collection_form}
                child_collection_form={@child_collection_form}
                bookmark_form={@bookmark_form}
                public_shares={@public_shares}
                collaborators={@collaborators}
                collaboration_form={@collaboration_form}
                collaborator_email_suggestions={@collaborator_email_suggestions}
                collaborator_email_suggestions_open?={@collaborator_email_suggestions_open?}
                pending_metadata_ids={@pending_metadata_ids}
              />
            </div>
          </div>
        <% else %>
          <section class="hidden min-w-0 flex-1 overflow-auto p-4 lg:block">
            <div class="flex h-full items-center justify-center">
              <div class="max-w-md rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center">
                <h1 class="text-lg font-semibold">Select a collection or bookmark</h1>
                <p class="mt-2 text-base-content/60">
                  Use More on a collection or link to edit details, share, and collaborate.
                </p>
              </div>
            </div>
          </section>
        <% end %>
      </div>
    </Layouts.app>

    <div
      :if={@confirm_delete_collection? && @selected_context}
      id="delete-collection-confirm-modal"
      class="modal modal-open"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="delete-collection-confirm-title"
    >
      <div class="modal-box">
        <h3 id="delete-collection-confirm-title" class="text-lg font-bold">
          {if @selected_context.mount, do: "Remove collection?", else: "Delete collection?"}
        </h3>
        <p class="py-4 text-base-content/70">
          <%= if @selected_context.mount do %>
            Remove "{@selected_context.effective_collection.title}" from your sidebar? The shared collection will remain for other collaborators.
          <% else %>
            Delete "{@selected_context.effective_collection.title}" permanently? This will remove all bookmarks and subcollections inside it.
          <% end %>
        </p>
        <div class="modal-action">
          <button
            type="button"
            id="delete-collection-cancel-button"
            class="btn"
            phx-click="cancel_delete_collection"
          >
            Cancel
          </button>
          <button
            type="button"
            id="delete-collection-confirm-button"
            class="btn btn-error"
            phx-click="delete_collection"
            phx-value-id={@selected_context.collection.id}
          >
            {if @selected_context.mount, do: "Remove", else: "Delete"}
          </button>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="cancel_delete_collection"
        aria-label="Close"
      />
    </div>

    <div
      :if={
        @confirm_delete_bookmark? && @selected_context && Map.has_key?(@selected_context, :bookmark)
      }
      id="delete-bookmark-confirm-modal"
      class="modal modal-open"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="delete-bookmark-confirm-title"
    >
      <div class="modal-box">
        <h3 id="delete-bookmark-confirm-title" class="text-lg font-bold">Delete link?</h3>
        <p class="py-4 text-base-content/70">
          Delete "{bookmark_label(@selected_context.bookmark)}" permanently? This cannot be undone.
        </p>
        <div class="modal-action">
          <button
            type="button"
            id="delete-bookmark-cancel-button"
            class="btn"
            phx-click="cancel_delete_bookmark"
          >
            Cancel
          </button>
          <button
            type="button"
            id="delete-bookmark-confirm-button"
            class="btn btn-error"
            phx-click="delete_bookmark"
            phx-value-id={@selected_context.bookmark.id}
          >
            Delete
          </button>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="cancel_delete_bookmark"
        aria-label="Close"
      />
    </div>

    <div
      :if={@confirm_revoke_collaboration_id}
      id="revoke-collaboration-confirm-modal"
      class="modal modal-open"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="revoke-collaboration-confirm-title"
    >
      <div class="modal-box">
        <h3 id="revoke-collaboration-confirm-title" class="text-lg font-bold">Revoke access?</h3>
        <p class="py-4 text-base-content/70">
          Revoke access for "{collaborator_email(@collaborators, @confirm_revoke_collaboration_id)}"? They will no longer be able to edit this collection.
        </p>
        <div class="modal-action">
          <button
            type="button"
            id="revoke-collaboration-cancel-button"
            class="btn"
            phx-click="cancel_revoke_collaboration"
          >
            Cancel
          </button>
          <button
            type="button"
            id="revoke-collaboration-confirm-button"
            class="btn btn-error"
            phx-click="revoke_collaboration"
            phx-value-id={@confirm_revoke_collaboration_id}
          >
            Revoke
          </button>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="cancel_revoke_collaboration"
        aria-label="Close"
      />
    </div>

    <div
      :if={@confirm_revoke_public_share_id}
      id="revoke-public-share-confirm-modal"
      class="modal modal-open"
      role="alertdialog"
      aria-modal="true"
      aria-labelledby="revoke-public-share-confirm-title"
    >
      <div class="modal-box">
        <h3 id="revoke-public-share-confirm-title" class="text-lg font-bold">Revoke public link?</h3>
        <p class="py-4 text-base-content/70">
          Revoke public link "{public_share_token(@public_shares, @confirm_revoke_public_share_id)}"? The shared URL will stop working.
        </p>
        <div class="modal-action">
          <button
            type="button"
            id="revoke-public-share-cancel-button"
            class="btn"
            phx-click="cancel_revoke_public_share"
          >
            Cancel
          </button>
          <button
            type="button"
            id="revoke-public-share-confirm-button"
            class="btn btn-error"
            phx-click="revoke_public_share"
            phx-value-id={@confirm_revoke_public_share_id}
          >
            Revoke
          </button>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="cancel_revoke_public_share"
        aria-label="Close"
      />
    </div>
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
        loading="lazy"
        class={["shrink-0 rounded-sm object-contain", @class]}
      />
    <% else %>
      <.file_icon class={@class} />
    <% end %>
    """
  end

  attr :bookmark, Bookmark, required: true
  attr :selected, :boolean, default: false
  attr :metadata_pending, :boolean, default: false
  attr :editable, :boolean, default: true

  def bookmark_menu_link(assigns) do
    ~H"""
    <li
      id={"bookmark-#{@bookmark.id}"}
      class={[
        "bookmark-menu-row w-full flex flex-row items-center gap-2",
        @bookmark.completed && "bookmark-completed"
      ]}
    >
      <button
        type="button"
        id={"bookmark-select-#{@bookmark.id}"}
        phx-hook=".BookmarkOpenOnDblClick"
        data-url={@bookmark.url}
        phx-click="select_bookmark"
        phx-value-id={@bookmark.id}
        class="bookmark-select-button flex-1 items-center gap-2"
      >
        <.bookmark_status_icon bookmark={@bookmark} metadata_pending={@metadata_pending} />
        <span class="flex flex-1 items-baseline gap-2 overflow-hidden">
          <span class="bookmark-title truncate">{bookmark_label(@bookmark)}</span>
          <span
            :if={domain = Bookmark.display_host(@bookmark)}
            class="text-base-content/50 shrink-0 max-w-48 truncate"
          >
            {domain}
          </span>
        </span>
      </button>
      <.bookmark_completed_toggle
        :if={@bookmark.collection_id}
        bookmark={@bookmark}
        editable={@editable}
      />
      <a
        id={"bookmark-more-#{@bookmark.id}"}
        href={@bookmark.url}
        target="_blank"
        rel="noopener noreferrer"
        class="sidebar-more-button btn btn-ghost btn-xs shrink-0"
        aria-label="Open link in new tab"
      >
        <.icon name="hero-arrow-top-right-on-square" class="size-4" />
      </a>
    </li>
    """
  end

  attr :bookmark, Bookmark, required: true
  attr :editable, :boolean, default: true
  attr :id, :string, default: nil

  attr :checkbox_class, :string,
    default: "checkbox checkbox-sm shrink-0 bookmark-completed-toggle"

  def bookmark_completed_toggle(assigns) do
    assigns =
      assign(assigns, :input_id, bookmark_completed_input_id(assigns.bookmark, assigns.id))

    ~H"""
    <%= if @bookmark.completed do %>
      <input
        type="checkbox"
        id={@input_id}
        phx-click="toggle_bookmark_completed"
        phx-value-id={@bookmark.id}
        phx-value-completed="false"
        checked
        disabled={not @editable}
        class={@checkbox_class}
        aria-label={"Mark \"#{bookmark_label(@bookmark)}\" complete"}
      />
    <% else %>
      <input
        type="checkbox"
        id={@input_id}
        phx-click="toggle_bookmark_completed"
        phx-value-id={@bookmark.id}
        phx-value-completed="true"
        disabled={not @editable}
        class={@checkbox_class}
        aria-label={"Mark \"#{bookmark_label(@bookmark)}\" complete"}
      />
    <% end %>
    """
  end

  attr :bookmark, Bookmark, required: true
  attr :metadata_pending, :boolean, default: false
  attr :class, :string, default: "size-4"

  def bookmark_status_icon(assigns) do
    ~H"""
    <%= if @metadata_pending do %>
      <span
        class={["loading loading-spinner loading-xs shrink-0 text-base-content/50", @class]}
        aria-label="Fetching link metadata"
      />
    <% else %>
      <.bookmark_icon bookmark={@bookmark} class={@class} />
    <% end %>
    """
  end

  attr :class, :string, default: "h-4 w-4"

  def folder_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class={["shrink-0", @class]}
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M2.25 12.75V12A2.25 2.25 0 014.5 9.75h15A2.25 2.25 0 0121.75 12v.75m-8.69-6.44l-2.12-2.12a1.5 1.5 0 00-1.061-.44H4.5A2.25 2.25 0 002.25 6v12a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18V9a2.25 2.25 0 00-2.25-2.25h-5.379a1.5 1.5 0 01-1.06-.44z"
      />
    </svg>
    """
  end

  attr :class, :string, default: "h-4 w-4"

  def file_icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      class={["shrink-0", @class]}
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M19.5 14.25v-2.625a3.375 3.375 0 00-3.375-3.375h-1.5A1.125 1.125 0 0113.5 7.125v-1.5a3.375 3.375 0 00-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 00-9-9z"
      />
    </svg>
    """
  end

  attr :label_node, :map, required: true
  attr :shared, :boolean, default: false
  attr :collaboration_mount?, :boolean, default: false
  attr :readonly, :boolean, default: false

  def collection_tree_label(assigns) do
    ~H"""
    <span class="truncate">{@label_node.title}</span>
    <span
      :if={@shared}
      class="inline-flex shrink-0 items-center opacity-60"
      aria-label="Shared with others"
    >
      <.icon name="hero-user-group" class="size-4" />
    </span>
    <span
      :if={@collaboration_mount?}
      class="inline-flex shrink-0 items-center opacity-60"
      aria-label={
        if(@readonly, do: "Read-only collaboration", else: "Editable collaboration")
      }
    >
      <.icon
        name={if @readonly, do: "hero-eye", else: "hero-pencil-square"}
        class="size-4"
      />
    </span>
    <span
      :if={@label_node.source_title}
      class="truncate text-base-content/50"
    >
      {@label_node.source_title}
    </span>
    """
  end

  attr :node, :map, required: true
  attr :selected, :map, default: nil
  attr :collapsed, MapSet, required: true
  attr :depth, :integer, required: true
  attr :current_scope, :map, required: true
  attr :pending_metadata_ids, MapSet, required: true

  def tree_node(assigns) do
    assigns =
      assigns
      |> assign(:collection, assigns.node.collection)
      |> assign(:effective, assigns.node.effective_collection)
      |> assign(:expanded, not MapSet.member?(assigns.collapsed, assigns.node.collection.id))
      |> assign(
        :collaboration_mount?,
        Collections.active_collaboration_mount?(assigns.node.collection)
      )
      |> assign(
        :root_only_mount?,
        Collections.active_collaboration_mount?(assigns.node.collection) or
          Collections.revoked_collaboration_mount?(assigns.node.collection)
      )

    ~H"""
    <li
      id={"collection-#{@collection.id}"}
      data-readonly={to_string(@node.readonly || false)}
      data-revoked={to_string(@node.revoked || false)}
      data-collaboration-mount={to_string(@root_only_mount? || false)}
      data-nest-parent-id={(!@node.revoked && @effective.id) || nil}
      data-bookmark-collection-id={(!@node.revoked && @effective.id) || nil}
    >
      <div
        :if={@node.revoked}
        class="collection-tree-row line-through opacity-50"
      >
        <span class="flex min-w-0 items-center gap-2">
          <.folder_icon />
          <.collection_tree_label label_node={@node} />
        </span>
      </div>
      <details :if={not @node.revoked} open={@expanded}>
        <summary
          phx-click="toggle_collection"
          phx-value-id={@collection.id}
        >
          <span class="flex min-w-0 flex-1 items-center gap-2">
            <.folder_icon />
            <.collection_tree_label
              label_node={@node}
              shared={@node.shared}
              collaboration_mount?={@collaboration_mount?}
              readonly={@node.readonly}
            />
          </span>
          <span class="badge badge-sm shrink-0 tabular-nums">
            {Collections.collection_bookmark_badge(@node)}
          </span>
        </summary>
        <ul
          :if={@node.children != []}
          id={"collections-zone-#{@effective.id}"}
          data-parent-id={@effective.id}
          data-readonly={to_string(@node.readonly || false)}
          data-collection-sortable
        >
          <.tree_node
            :for={child <- @node.children}
            node={child}
            selected={@selected}
            collapsed={@collapsed}
            depth={@depth + 1}
            current_scope={@current_scope}
            pending_metadata_ids={@pending_metadata_ids}
          />
        </ul>
        <ul
          id={"nested-zone-#{@effective.id}"}
          phx-hook={(!@node.readonly && "BookmarkSort") || nil}
          data-collection-id={@effective.id}
          data-readonly={to_string(@node.readonly || false)}
          class={@node.bookmarks == [] && "collection-bookmark-drop-hidden"}
        >
          <.bookmark_menu_link
            :for={bookmark <- @node.bookmarks}
            bookmark={bookmark}
            selected={selected?(@selected, :bookmark, bookmark.id)}
            metadata_pending={MapSet.member?(@pending_metadata_ids, bookmark.id)}
            editable={not @node.readonly}
          />
        </ul>
      </details>
    </li>
    """
  end

  @impl true
  def handle_info({:collection_bookmarks_changed, _collection_id}, socket) do
    {:noreply, refresh_dashboard_and_selection(socket)}
  end

  def handle_info({:inbox_bookmarks_changed, _user_id}, socket) do
    {:noreply, refresh_dashboard_and_selection(socket)}
  end

  def handle_info({:user_collections_changed, _user_id}, socket) do
    {:noreply, refresh_dashboard_and_selection(socket)}
  end

  def handle_info({:bookmark_metadata_updated, bookmark_id}, socket) do
    socket =
      socket
      |> clear_metadata_pending(bookmark_id)
      |> refresh_dashboard()

    socket =
      case socket.assigns.selected do
        %{type: :bookmark, id: ^bookmark_id} ->
          refresh_selected_bookmark(socket, bookmark_id)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:bookmark_metadata_failed, bookmark_id}, socket) do
    {:noreply, clear_metadata_pending(socket, bookmark_id)}
  end

  attr :selected, :map, required: true
  attr :context, :map, required: true
  attr :collection_form, :any, required: true
  attr :child_collection_form, :any, required: true
  attr :bookmark_form, :any, required: true
  attr :public_shares, :list, default: []
  attr :collaborators, :list, default: []
  attr :collaboration_form, :any, required: true
  attr :collaborator_email_suggestions, :any, default: nil
  attr :collaborator_email_suggestions_open?, :boolean, default: false
  attr :pending_metadata_ids, MapSet, default: MapSet.new()

  def detail_panel(%{selected: %{type: :bookmark}} = assigns) do
    assigns =
      assign(
        assigns,
        :metadata_pending,
        MapSet.member?(assigns.pending_metadata_ids, assigns.context.bookmark.id)
      )

    ~H"""
    <div class="mx-auto max-w-3xl space-y-4">
      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <div class="mb-4 flex items-start justify-between gap-4">
          <div class="flex min-w-0 flex-1 items-center gap-3">
            <.bookmark_status_icon
              bookmark={@context.bookmark}
              metadata_pending={@metadata_pending}
              class="size-8 shrink-0"
            />
            <div class="min-w-0 flex-1">
              <a
                id="bookmark-url"
                href={@context.bookmark.url}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-hover break-all text-sm text-base-content/60"
              >
                {@context.bookmark.url}
              </a>
              <p :if={@metadata_pending} class="mt-1 text-xs text-base-content/50">
                Fetching page title and icon…
              </p>
            </div>
          </div>
          <button
            :if={!@context.readonly}
            type="button"
            id="delete-bookmark-button"
            class="btn btn-error btn-soft shrink-0"
            phx-click="confirm_delete_bookmark"
          >
            Delete
          </button>
        </div>

        <.form
          for={@bookmark_form}
          id="bookmark-form"
          phx-submit="save_bookmark"
          phx-change="validate_bookmark"
        >
          <div class="mb-2">
            <label for={@bookmark_form[:title].id} class="label mb-1">Title</label>
            <input
              type="text"
              name={@bookmark_form[:title].name}
              id={@bookmark_form[:title].id}
              value={@bookmark_form[:title].value}
              class={[
                "input w-full",
                @bookmark_form[:title].errors != [] && "input-error"
              ]}
              disabled={@context.readonly}
            />
            <p
              :for={msg <- bookmark_field_errors(@bookmark_form[:title])}
              class="mt-1.5 flex items-center gap-2 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" />
              {msg}
            </p>
          </div>
          <div class="mb-2">
            <label for={@bookmark_form[:description].id} class="label mb-1">Description</label>
            <textarea
              name={@bookmark_form[:description].name}
              id={@bookmark_form[:description].id}
              class={[
                "textarea w-full",
                @bookmark_form[:description].errors != [] && "textarea-error"
              ]}
              disabled={@context.readonly}
            >{Phoenix.HTML.Form.normalize_value("textarea", @bookmark_form[:description].value)}</textarea>
            <p
              :for={msg <- bookmark_field_errors(@bookmark_form[:description])}
              class="mt-1.5 flex items-center gap-2 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-5" />
              {msg}
            </p>
          </div>
          <p
            :if={@context.bookmark.metadata_fetched_at}
            id="bookmark-metadata-fetched-at"
            class="mt-2 text-xs text-base-content/50"
          >
            Metadata fetched at {format_metadata_fetched_at(@context.bookmark.metadata_fetched_at)}
          </p>
        </.form>
        <div :if={@context.bookmark.collection_id || !@context.readonly} class={[
          "mt-4 flex items-center gap-4",
          @context.bookmark.collection_id && "justify-between",
          is_nil(@context.bookmark.collection_id) && "justify-end"
        ]}>
          <div :if={@context.bookmark.collection_id} class="flex items-center gap-2">
            <.bookmark_completed_toggle
              bookmark={@context.bookmark}
              editable={!@context.readonly}
              id="bookmark-completed-input"
              checkbox_class="checkbox checkbox-lg"
            />
            <label
              for={bookmark_completed_input_id(@context.bookmark, "bookmark-completed-input")}
              class={["text-base", !@context.readonly && "cursor-pointer"]}
            >
              Completed
            </label>
          </div>
          <button
            :if={!@context.readonly}
            type="submit"
            form="bookmark-form"
            class="btn btn-primary shrink-0"
          >
            Save
          </button>
        </div>
      </div>
    </div>
    """
  end

  def detail_panel(assigns) do
    assigns =
      assigns
      |> assign(:readonly, assigns.context.readonly)
      |> assign(:title_collection, title_editable_collection(assigns.context))

    ~H"""
    <div class="mx-auto max-w-4xl space-y-4">
      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <div class="mb-4 flex items-start justify-between gap-4">
          <div>
            <p :if={@context.mount} class="text-xs uppercase tracking-wide text-base-content/50">
              Shared collection{if(@readonly, do: " (read-only)")}
            </p>
            <h1 class="text-xl font-semibold">
              {@title_collection.title}
            </h1>
            <p :if={@readonly && !@context.mount} class="mt-1 text-sm text-base-content/60">
              Read-only access
            </p>
          </div>
          <button
            :if={@context.mount || !@readonly}
            type="button"
            id="delete-collection-button"
            class="btn btn-error btn-soft"
            phx-click="confirm_delete_collection"
          >
            {if @context.mount, do: "Remove", else: "Delete"}
          </button>
        </div>

        <.form
          :if={!@readonly}
          for={@collection_form}
          id="collection-form"
          phx-submit="save_collection"
          phx-change="validate_collection"
        >
          <label for={@collection_form[:title].id} class="label mb-1">Title</label>
          <div class="join w-full">
            <input
              type="text"
              name={@collection_form[:title].name}
              id={@collection_form[:title].id}
              value={@collection_form[:title].value}
              class="input join-item w-full"
            />
            <button class="btn btn-primary join-item">Save</button>
          </div>
        </.form>
      </div>

      <div :if={!@readonly} class="space-y-4">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="mb-3 font-semibold">New child collection</h2>
          <.form
            for={@child_collection_form}
            id="child-collection-form"
            phx-submit="create_child_collection"
          >
            <label for={@child_collection_form[:title].id} class="label mb-1">Title</label>
            <div class="join w-full">
              <input
                type="text"
                name={@child_collection_form[:title].name}
                id={@child_collection_form[:title].id}
                value={@child_collection_form[:title].value}
                class="input join-item w-full"
              />
              <button class="btn btn-primary btn-soft join-item">Create</button>
            </div>
          </.form>
        </div>

        <div :if={@context.can_manage} class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="mb-3 font-semibold">Collaborators</h2>
          <div id="collaboration-form">
            <.form
              for={@collaboration_form}
              id={"collaboration-form-fields-#{@collaboration_form.id}"}
              phx-change="validate_collaboration"
              phx-submit="create_collaboration"
            >
              <label for={@collaboration_form[:email].id} class="label mb-1">User</label>
              <div class="flex items-center gap-4">
                <div
                  class="relative min-w-0 flex-1"
                  id="collaboration-email-field"
                  phx-hook=".CollaboratorEmailSearch"
                >
                  <div class="relative">
                    <input
                      type="text"
                      name={@collaboration_form[:email].name}
                      id={@collaboration_form[:email].id}
                      value={@collaboration_form[:email].value}
                      class={[
                        "input w-full",
                        @collaboration_form[:email].errors != [] && "input-error"
                      ]}
                      autocomplete="off"
                      phx-debounce="200"
                      required
                    />
                    <ul
                      :if={
                        @collaborator_email_suggestions_open? &&
                          is_list(@collaborator_email_suggestions)
                      }
                      id="collaboration-email-suggestions"
                      role="listbox"
                      class="menu absolute left-0 right-0 top-full z-20 mt-1 max-h-48 w-full overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
                    >
                      <li
                        :if={@collaborator_email_suggestions == []}
                        id="collaboration-email-no-matches"
                      >
                        <span class="pointer-events-none px-3 py-2 text-sm text-base-content/60">
                          No matches found
                        </span>
                      </li>
                      <li :for={email <- @collaborator_email_suggestions}>
                        <button
                          type="button"
                          data-suggestion
                          data-email={email}
                          id={"collaboration-email-option-#{email_option_dom_id(email)}"}
                        >
                          {email}
                        </button>
                      </li>
                    </ul>
                  </div>
                  <p
                    :for={msg <- collaboration_email_errors(@collaboration_form[:email])}
                    class="mt-1.5 flex items-center gap-2 text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-5" />
                    {msg}
                  </p>
                </div>
                <script :type={Phoenix.LiveView.ColocatedHook} name=".CollaboratorEmailSearch">
                  export default {
                    mounted() {
                      this.blurTimer = null
                      this.form = this.el.closest("form")

                      this.onFocusIn = (event) => {
                        if (!event.target.matches("input[type='text']")) return
                        clearTimeout(this.blurTimer)
                        this.pushEvent("show_collaborator_email_suggestions")
                      }

                      this.onFocusOut = (event) => {
                        if (!event.target.matches("input[type='text']")) return

                        this.blurTimer = setTimeout(() => {
                          this.pushEvent("hide_collaborator_email_suggestions")
                        }, 200)
                      }

                      this.onMouseDown = (event) => {
                        const suggestion = event.target.closest("[data-suggestion]")
                        if (!suggestion) return

                        event.preventDefault()
                        clearTimeout(this.blurTimer)

                        const email = suggestion.dataset.email
                        const input = this.el.querySelector("input[type='text']")
                        if (!email || !input) return

                        input.value = email
                        input.dispatchEvent(new Event("input", { bubbles: true }))
                        input.blur()
                        this.pushEvent("select_collaborator_email", { email })
                      }

                      this.onSubmit = () => {
                        clearTimeout(this.blurTimer)
                        this.pushEvent("hide_collaborator_email_suggestions")
                      }

                      this.el.addEventListener("focusin", this.onFocusIn)
                      this.el.addEventListener("focusout", this.onFocusOut)
                      this.el.addEventListener("mousedown", this.onMouseDown, true)
                      this.form?.addEventListener("submit", this.onSubmit)

                      this.handleEvent("collaborator-selected", ({ email }) => {
                        const input = this.el.querySelector("input[type='text']")
                        if (input && email) {
                          input.value = email
                        }
                      })
                    },
                    destroyed() {
                      clearTimeout(this.blurTimer)
                      this.el.removeEventListener("focusin", this.onFocusIn)
                      this.el.removeEventListener("focusout", this.onFocusOut)
                      this.el.removeEventListener("mousedown", this.onMouseDown, true)
                      this.form?.removeEventListener("submit", this.onSubmit)
                    }
                  }
                </script>
                <label class="label shrink-0 cursor-pointer gap-2 whitespace-nowrap">
                  <input
                    type="checkbox"
                    name={@collaboration_form[:readonly].name}
                    value="true"
                    checked={collaboration_readonly_checked?(@collaboration_form)}
                    class="checkbox checkbox-sm"
                  /> Read-only
                </label>
                <button class="btn btn-accent shrink-0">Share</button>
              </div>
            </.form>
          </div>
          <ul id="collaborators-list" class="mt-4 space-y-2">
            <li
              :for={collaborator <- @collaborators}
              id={"collaborator-#{collaborator.id}"}
              class="flex items-center justify-between rounded bg-base-200 p-2"
            >
              <div class="min-w-0">
                <p class={[
                  "truncate text-sm",
                  collaborator.collaboration_revoked_at && "line-through opacity-60"
                ]}>
                  {collaborator.owner.email}
                </p>
                <p class="text-xs text-base-content/50">
                  {collaborator_access_label(collaborator)}
                </p>
              </div>
              <button
                :if={is_nil(collaborator.collaboration_revoked_at)}
                id={"revoke-collaborator-#{collaborator.id}"}
                class="btn btn-dash btn-sm"
                phx-click="confirm_revoke_collaboration"
                phx-value-id={collaborator.id}
              >
                Revoke
              </button>
              <button
                :if={collaborator.collaboration_revoked_at && @context.can_restore_collaborators}
                id={"restore-collaborator-#{collaborator.id}"}
                class="btn btn-outline btn-sm"
                phx-click="restore_collaboration"
                phx-value-id={collaborator.id}
              >
                Restore
              </button>
            </li>
            <li :if={@collaborators == []} class="text-sm text-base-content/60">
              No collaborators yet.
            </li>
          </ul>
        </div>
      </div>

      <div
        :if={!@readonly && @context.can_manage}
        class="rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-3 flex items-center justify-between">
          <h2 class="font-semibold">Public Sharing</h2>
          <button class="btn btn-accent" phx-click="create_public_share">Create public link</button>
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
            <div :if={is_nil(share.revoked_at)} class="flex shrink-0 items-center gap-2">
              <button
                id={"copy-public-share-#{share.id}"}
                type="button"
                class="btn btn-soft btn-sm"
                phx-click={JS.dispatch("phx:copy", detail: %{text: public_share_url(share)})}
              >
                <.icon name="hero-clipboard-document" class="size-4" /> Copy link
              </button>
              <button
                id={"revoke-public-share-#{share.id}"}
                class="btn btn-dash btn-sm"
                phx-click="confirm_revoke_public_share"
                phx-value-id={share.id}
              >
                Revoke
              </button>
            </div>
            <button
              :if={share.revoked_at && @context.can_restore_collaborators}
              id={"restore-public-share-#{share.id}"}
              type="button"
              class="btn btn-outline btn-sm shrink-0"
              phx-click="restore_public_share"
              phx-value-id={share.id}
            >
              Restore
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
  def handle_event("create_link", %{"new_bookmark" => bookmark_params}, socket) do
    url = Map.get(bookmark_params, "url")

    case url && LinksWeb.PublicShareUrl.parse(url) do
      {:ok, token} ->
        handle_public_share_url(socket, token, bookmark_params)

      _ ->
        create_inbox_bookmark(socket, bookmark_params)
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
    id = String.to_integer(id)
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
    collection = Collections.get_collection!(id)

    if Collections.revoked_collaboration_mount?(collection) do
      {:noreply, socket}
    else
      collapsed = socket.assigns.collapsed

      collapsed =
        if MapSet.member?(collapsed, id) do
          MapSet.delete(collapsed, id)
        else
          MapSet.put(collapsed, id)
        end

      {:noreply,
       socket
       |> assign(:collapsed, collapsed)
       |> select_collection(id)}
    end
  end

  def handle_event("expand_collection", %{"id" => id}, socket) do
    id = String.to_integer(id)
    collection = Collections.get_collection!(id)

    if Collections.revoked_collaboration_mount?(collection) do
      {:noreply, socket}
    else
      {:noreply, expand_collection(socket, id)}
    end
  end

  def handle_event(
        "copy_bookmark",
        %{"id" => id, "collection_id" => collection_id, "ordered_ids" => ordered_ids},
        socket
      ) do
    case Collections.copy_bookmark(
           socket.assigns.current_scope,
           id,
           collection_id,
           ordered_ids
         ) do
      {:ok, _} ->
        {:noreply, refresh_dashboard(socket)}

      {:error, :invalid_order} ->
        {:noreply, put_flash(socket, :error, "Could not copy bookmark")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to copy this link")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not copy bookmark")}
    end
  end

  def handle_event(
        "move_bookmark",
        %{"id" => id, "collection_id" => collection_id, "ordered_ids" => ordered_ids},
        socket
      ) do
    case Collections.move_bookmark(
           socket.assigns.current_scope,
           id,
           collection_id,
           ordered_ids
         ) do
      {:ok, _} ->
        {:noreply, refresh_dashboard(socket)}

      {:error, :invalid_order} ->
        {:noreply, put_flash(socket, :error, "Could not reorder bookmarks")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to move this link")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not move bookmark")}
    end
  end

  def handle_event(
        "copy_collection",
        %{"id" => id, "parent_id" => parent_id, "ordered_ids" => ordered_ids},
        socket
      ) do
    case Collections.copy_collection(
           socket.assigns.current_scope,
           id,
           parent_id,
           ordered_ids
         ) do
      {:ok, _} ->
        {:noreply, refresh_dashboard(socket)}

      {:error, :invalid_order} ->
        {:noreply, put_flash(socket, :error, "Could not copy collection")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to copy this collection")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not copy collection")}
    end
  end

  def handle_event(
        "move_collection",
        %{"id" => id, "parent_id" => parent_id, "ordered_ids" => ordered_ids},
        socket
      ) do
    case Collections.move_collection(
           socket.assigns.current_scope,
           id,
           parent_id,
           ordered_ids
         ) do
      {:ok, _} ->
        {:noreply, refresh_dashboard(socket)}

      {:error, :invalid_order} ->
        {:noreply, put_flash(socket, :error, "Could not reorder collections")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You do not have permission to move this collection")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not move collection")}
    end
  end

  def handle_event("validate_collection", %{"collection" => params}, socket) do
    collection = title_editable_collection(socket.assigns.selected_context)
    changeset = Collection.changeset(collection, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :collection_form, to_form(changeset))}
  end

  def handle_event("save_collection", %{"collection" => params}, socket) do
    collection = title_editable_collection(socket.assigns.selected_context)

    case Collections.update_collection(socket.assigns.current_scope, collection, params) do
      {:ok, _collection} ->
        select_id = socket.assigns.selected_context.collection.id

        {:noreply, socket |> refresh_dashboard() |> select_collection(select_id)}

      {:error, changeset} ->
        {:noreply, assign(socket, :collection_form, to_form(changeset))}
    end
  end

  def handle_event("confirm_delete_collection", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_collection?, true)}
  end

  def handle_event("cancel_delete_collection", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_collection?, false)}
  end

  def handle_event("delete_collection", %{"id" => id}, socket) do
    collection = Collections.get_collection!(id)

    case Collections.delete_collection(socket.assigns.current_scope, collection) do
      {:ok, _collection} ->
        {:noreply,
         socket
         |> assign(:confirm_delete_collection?, false)
         |> assign(:selected, nil)
         |> assign(:selected_context, nil)
         |> refresh_dashboard()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirm_delete_collection?, false)
         |> put_flash(:error, "Could not delete collection")}
    end
  end

  def handle_event("create_child_collection", %{"child_collection" => params}, socket) do
    parent = socket.assigns.selected_context.effective_collection
    parent_tree_id = socket.assigns.selected_context.collection.id
    params = Map.put(params, "parent_id", parent.id)

    case Collections.create_collection(socket.assigns.current_scope, params) do
      {:ok, _collection} ->
        {:noreply,
         socket
         |> expand_collection(parent_tree_id)
         |> assign(:child_collection_form, child_collection_form())
         |> refresh_dashboard_and_selection()}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :child_collection_form, to_form(changeset, as: :child_collection))}
    end
  end

  def handle_event("validate_bookmark", %{"bookmark" => params}, socket) do
    bookmark = socket.assigns.selected_context.bookmark
    changeset = Bookmark.changeset(bookmark, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :bookmark_form, to_form(changeset))}
  end

  def handle_event("toggle_bookmark_completed", %{"id" => id, "completed" => completed}, socket) do
    bookmark = Collections.get_bookmark!(id)
    completed = completed in ["true", "1"]

    case Collections.update_bookmark(
           socket.assigns.current_scope,
           bookmark,
           %{completed: completed}
         ) do
      {:ok, bookmark} ->
        socket =
          socket
          |> refresh_dashboard()
          |> maybe_refresh_selected_bookmark(bookmark)

        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You do not have permission to update this link")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update link")}
    end
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

  def handle_event("confirm_delete_bookmark", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_bookmark?, true)}
  end

  def handle_event("cancel_delete_bookmark", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_bookmark?, false)}
  end

  def handle_event("delete_bookmark", %{"id" => id}, socket) do
    bookmark = Collections.get_bookmark!(id)

    case Collections.delete_bookmark(socket.assigns.current_scope, bookmark) do
      {:ok, _bookmark} ->
        {:noreply,
         socket
         |> assign(:confirm_delete_bookmark?, false)
         |> assign(:selected, nil)
         |> assign(:selected_context, nil)
         |> refresh_dashboard()}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirm_delete_bookmark?, false)
         |> put_flash(:error, "Could not delete bookmark")}
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

  def handle_event("confirm_revoke_public_share", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_revoke_public_share_id, String.to_integer(id))}
  end

  def handle_event("cancel_revoke_public_share", _params, socket) do
    {:noreply, assign(socket, :confirm_revoke_public_share_id, nil)}
  end

  def handle_event("revoke_public_share", %{"id" => id}, socket) do
    share = Collections.get_public_share!(id)
    collection = socket.assigns.selected_context.effective_collection

    case Collections.revoke_public_share(socket.assigns.current_scope, share) do
      {:ok, _share} ->
        {:noreply,
         socket
         |> assign(:confirm_revoke_public_share_id, nil)
         |> refresh_dashboard()
         |> select_collection(collection.id)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirm_revoke_public_share_id, nil)
         |> put_flash(:error, "Could not revoke public share")}
    end
  end

  def handle_event("restore_public_share", %{"id" => id}, socket) do
    share = Collections.get_public_share!(id)
    collection = socket.assigns.selected_context.effective_collection

    case Collections.restore_public_share(socket.assigns.current_scope, share) do
      {:ok, _share} ->
        {:noreply,
         socket
         |> put_flash(:info, "Public link restored")
         |> refresh_dashboard()
         |> select_collection(collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not restore public share")}
    end
  end

  def handle_event("validate_collaboration", %{"collaboration" => params}, socket) do
    {:noreply, update_collaboration_form(socket, params)}
  end

  def handle_event("show_collaborator_email_suggestions", _params, socket) do
    {:noreply, show_collaborator_email_suggestions(socket)}
  end

  def handle_event("hide_collaborator_email_suggestions", _params, socket) do
    {:noreply, hide_collaborator_suggestions(socket)}
  end

  def handle_event("select_collaborator_email", %{"email" => email}, socket) do
    readonly =
      collaboration_readonly_checked?(socket.assigns.collaboration_form)

    collection = socket.assigns.selected_context.effective_collection
    params = %{"email" => email, "readonly" => readonly}
    errors = collaboration_email_errors(collection, email)

    {:noreply,
     socket
     |> push_event("collaborator-selected", %{email: email})
     |> assign(:collaborator_email_suggestions, nil)
     |> assign(:collaborator_email_suggestions_open?, false)
     |> assign_collaboration_form(params, readonly, errors)}
  end

  def handle_event("create_collaboration", %{"collaboration" => params}, socket) do
    socket = hide_collaborator_suggestions(socket)

    collection = socket.assigns.selected_context.effective_collection
    readonly = Map.get(params, "readonly") == "true"
    email = Map.get(params, "email", "")

    errors = collaboration_email_errors(collection, email, submit?: true)

    if errors != [] do
      {:noreply, assign_collaboration_form(socket, params, readonly, errors)}
    else
      case Collections.create_collaboration(
             socket.assigns.current_scope,
             collection,
             String.trim(email),
             readonly
           ) do
        {:ok, _mount} ->
          {:noreply,
           socket
           |> put_flash(:info, "Collaborator added")
           |> refresh_dashboard()
           |> select_collection(collection.id)}

        {:error, :already_collaborator} ->
          {:noreply,
           assign_collaboration_form(
             socket,
             params,
             readonly,
             email: {"This user is already a collaborator", []}
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not add collaborator")}
      end
    end
  end

  def handle_event("confirm_revoke_collaboration", %{"id" => id}, socket) do
    {:noreply, assign(socket, :confirm_revoke_collaboration_id, String.to_integer(id))}
  end

  def handle_event("cancel_revoke_collaboration", _params, socket) do
    {:noreply, assign(socket, :confirm_revoke_collaboration_id, nil)}
  end

  def handle_event("revoke_collaboration", %{"id" => id}, socket) do
    mount = Collections.get_collection!(id)
    collection = socket.assigns.selected_context.effective_collection

    case Collections.revoke_collaboration(socket.assigns.current_scope, mount) do
      {:ok, _mount} ->
        {:noreply,
         socket
         |> assign(:confirm_revoke_collaboration_id, nil)
         |> refresh_dashboard()
         |> select_collection(collection.id)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:confirm_revoke_collaboration_id, nil)
         |> put_flash(:error, "Could not revoke collaborator")}
    end
  end

  def handle_event("restore_collaboration", %{"id" => id}, socket) do
    mount = Collections.get_collection!(id)
    collection = socket.assigns.selected_context.effective_collection

    case Collections.restore_collaboration(socket.assigns.current_scope, mount) do
      {:ok, _mount} ->
        {:noreply,
         socket
         |> put_flash(:info, "Collaborator access restored")
         |> refresh_dashboard()
         |> select_collection(collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not restore collaborator access")}
    end
  end

  defp handle_public_share_url(socket, token, bookmark_params) do
    case Collections.join_public_share(socket.assigns.current_scope, token) do
      {:ok, mount} ->
        {:noreply,
         socket
         |> reset_new_bookmark_form()
         |> put_flash(:info, "Added \"#{mount.title}\" to your collections")
         |> refresh_dashboard()
         |> select_collection(mount.id)}

      {:error, :already_owned} ->
        case Collections.get_public_share_by_token(token) do
          %PublicShare{collection: %{id: id}} ->
            {:noreply,
             socket
             |> reset_new_bookmark_form()
             |> refresh_dashboard()
             |> select_collection(id)}

          _ ->
            create_inbox_bookmark(socket, bookmark_params)
        end

      {:error, :not_found} ->
        create_inbox_bookmark(socket, bookmark_params)
    end
  end

  defp create_inbox_bookmark(socket, bookmark_params) do
    case Collections.create_inbox_bookmark(socket.assigns.current_scope, bookmark_params) do
      {:ok, bookmark} ->
        {:noreply,
         socket
         |> reset_new_bookmark_form()
         |> mark_metadata_pending(bookmark.id)
         |> refresh_dashboard()}

      {:error, changeset} ->
        {:noreply, assign_new_bookmark_form(socket, changeset)}
    end
  end

  defp mark_metadata_pending(socket, bookmark_id) do
    assign(
      socket,
      :pending_metadata_ids,
      MapSet.put(socket.assigns.pending_metadata_ids, bookmark_id)
    )
  end

  defp clear_metadata_pending(socket, bookmark_id) do
    assign(
      socket,
      :pending_metadata_ids,
      MapSet.delete(socket.assigns.pending_metadata_ids, bookmark_id)
    )
  end

  defp refresh_dashboard(socket) do
    socket
    |> assign(:dashboard, Collections.list_dashboard(socket.assigns.current_scope))
    |> sync_collection_subscriptions()
  end

  defp refresh_dashboard_and_selection(socket) do
    socket = refresh_dashboard(socket)

    case socket.assigns.selected do
      %{type: :bookmark, id: bookmark_id} ->
        refresh_selected_bookmark(socket, bookmark_id)

      %{type: :collection, id: collection_id} ->
        select_collection(socket, collection_id)

      _ ->
        socket
    end
  end

  defp expand_collection(socket, collection_id) do
    assign(socket, :collapsed, MapSet.delete(socket.assigns.collapsed, collection_id))
  end

  defp collapse_all_collections(socket) do
    assign(
      socket,
      :collapsed,
      socket.assigns.dashboard.collections
      |> Enum.map(& &1.id)
      |> MapSet.new()
    )
  end

  defp refresh_selected_bookmark(socket, bookmark_id) do
    case Collections.get_bookmark(bookmark_id) do
      %Bookmark{} = bookmark ->
        select_bookmark(socket, bookmark)

      nil ->
        socket
        |> assign(:selected, nil)
        |> assign(:selected_context, nil)
    end
  end

  defp sync_collection_subscriptions(socket) do
    if connected?(socket) do
      visible_ids = MapSet.new(Enum.map(socket.assigns.dashboard.collections, & &1.id))
      previous = socket.assigns.subscribed_collection_ids

      for collection_id <- MapSet.difference(visible_ids, previous) do
        Phoenix.PubSub.subscribe(
          Links.PubSub,
          Collections.collection_bookmarks_topic(collection_id)
        )
      end

      for collection_id <- MapSet.difference(previous, visible_ids) do
        Phoenix.PubSub.unsubscribe(
          Links.PubSub,
          Collections.collection_bookmarks_topic(collection_id)
        )
      end

      assign(socket, :subscribed_collection_ids, visible_ids)
    else
      socket
    end
  end

  defp assign_forms(socket) do
    socket
    |> assign(:new_bookmark_form, new_bookmark_form())
    |> reset_collaboration_form()
    |> assign(:collection_form, to_form(Collection.changeset(%Collection{}, %{})))
    |> assign(:child_collection_form, child_collection_form())
    |> assign(:bookmark_form, to_form(Bookmark.changeset(%Bookmark{}, %{})))
  end

  defp reset_collaboration_form(socket) do
    key = System.unique_integer([:positive])

    socket
    |> assign(:collaborator_email_suggestions, nil)
    |> assign(:collaborator_email_field_focused?, false)
    |> assign(:collaborator_email_suggestions_open?, false)
    |> assign(
      :collaboration_form,
      collaboration_form(%{"email" => "", "readonly" => false}, "collaboration-#{key}")
    )
  end

  defp hide_collaborator_suggestions(socket) do
    socket
    |> assign(:collaborator_email_field_focused?, false)
    |> assign(:collaborator_email_suggestions_open?, false)
  end

  defp show_collaborator_email_suggestions(socket) do
    email = socket.assigns.collaboration_form[:email].value
    collection = socket.assigns.selected_context.effective_collection

    suggestions =
      collaborator_email_suggestions(
        socket.assigns.current_scope,
        collection,
        email
      )

    socket
    |> assign(:collaborator_email_field_focused?, true)
    |> assign(:collaborator_email_suggestions, suggestions)
    |> assign(:collaborator_email_suggestions_open?, is_list(suggestions))
  end

  defp update_collaboration_form(socket, params) do
    readonly = Map.get(params, "readonly") == "true"
    email = Map.get(params, "email", "")
    collection = socket.assigns.selected_context.effective_collection

    suggestions =
      collaborator_email_suggestions(
        socket.assigns.current_scope,
        collection,
        email
      )

    errors = collaboration_email_errors(collection, email)

    open? =
      Map.get(socket.assigns, :collaborator_email_field_focused?, false) &&
        is_list(suggestions)

    socket
    |> assign(:collaborator_email_suggestions, suggestions)
    |> assign(:collaborator_email_suggestions_open?, open?)
    |> assign_collaboration_form(params, readonly, errors)
  end

  defp assign_collaboration_form(socket, params, readonly, errors) do
    form_id = socket.assigns.collaboration_form.id
    email = Map.get(params, "email", "")

    assign(
      socket,
      :collaboration_form,
      collaboration_form(
        %{"email" => email, "readonly" => readonly},
        form_id,
        errors: errors,
        action: if(errors != [], do: :validate)
      )
    )
  end

  defp collaborator_email_suggestions(scope, collection, email) do
    trimmed = String.trim(email)

    if trimmed == "" do
      nil
    else
      excluded_user_ids =
        [scope.user.id | Collections.active_collaborator_user_ids(collection)]
        |> Enum.uniq()

      Accounts.search_users_by_email(trimmed, exclude_user_ids: excluded_user_ids)
    end
  end

  defp collaboration_email_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_error/1)
    else
      []
    end
  end

  defp bookmark_field_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_error/1)
    else
      []
    end
  end

  defp collaboration_email_errors(%Collection{} = collection, email, opts \\ []) do
    trimmed = String.trim(email)
    submit? = Keyword.get(opts, :submit?, false)
    user = if trimmed != "", do: Accounts.get_user_by_email(trimmed), else: nil

    cond do
      submit? && trimmed == "" ->
        [email: {"can't be blank", []}]

      submit? && is_nil(user) ->
        [email: {"User not found", []}]

      user && Collections.active_collaborator?(collection, user) ->
        [email: {"This user is already a collaborator", []}]

      true ->
        []
    end
  end

  defp collaboration_form(attrs, id, opts \\ []) do
    errors = Keyword.get(opts, :errors, [])
    action = Keyword.get(opts, :action)

    form_opts = [as: :collaboration, id: id]

    form_opts =
      if errors != [] do
        Keyword.put(form_opts, :errors, errors)
      else
        form_opts
      end

    form_opts =
      if action do
        Keyword.put(form_opts, :action, action)
      else
        form_opts
      end

    to_form(attrs, form_opts)
  end

  defp email_option_dom_id(email) do
    email
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  defp collaboration_readonly_checked?(form) do
    Phoenix.HTML.Form.normalize_value("checkbox", form[:readonly].value)
  end

  defp reset_new_bookmark_form(socket) do
    assign(socket, :new_bookmark_form, new_bookmark_form())
  end

  defp assign_new_bookmark_form(socket, changeset) do
    form_id = socket.assigns.new_bookmark_form.id

    assign(socket, :new_bookmark_form, to_form(changeset, as: :new_bookmark, id: form_id))
  end

  defp new_bookmark_form do
    to_form(%{"url" => ""},
      as: :new_bookmark,
      id: "new-bookmark-#{System.unique_integer([:positive])}"
    )
  end

  defp child_collection_form do
    Collection.changeset(%Collection{}, %{})
    |> to_form(as: :child_collection)
  end

  defp title_editable_collection(%{mount: %Collection{} = mount}), do: mount
  defp title_editable_collection(%{effective_collection: collection}), do: collection

  defp select_collection(socket, id) do
    case Collections.resolve_collection(socket.assigns.current_scope, id) do
      {:ok, context} ->
        can_manage =
          Collections.can_manage_collection?(
            socket.assigns.current_scope,
            context.effective_collection
          )

        can_restore_collaborators =
          context.effective_collection.owner_id == socket.assigns.current_scope.user.id

        context =
          context
          |> Map.put(:can_manage, can_manage)
          |> Map.put(:can_restore_collaborators, can_restore_collaborators)

        shares =
          Collections.list_public_shares(
            socket.assigns.current_scope,
            context.effective_collection
          )

        collaborators =
          Collections.list_collaborators(
            socket.assigns.current_scope,
            context.effective_collection
          )

        socket
        |> assign(:selected, %{type: :collection, id: context.collection.id})
        |> assign(:selected_context, context)
        |> assign(:public_shares, shares)
        |> assign(:collaborators, collaborators)
        |> assign(:confirm_revoke_collaboration_id, nil)
        |> assign(:confirm_revoke_public_share_id, nil)
        |> reset_collaboration_form()
        |> assign(
          :collection_form,
          to_form(Collection.changeset(title_editable_collection(context), %{}))
        )
        |> assign(:child_collection_form, child_collection_form())

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

  defp maybe_refresh_selected_bookmark(socket, %Bookmark{id: id}) do
    if match?(%{type: :bookmark, id: ^id}, socket.assigns.selected) do
      select_bookmark(socket, Collections.get_bookmark!(id))
    else
      socket
    end
  end

  def selected?(%{type: type, id: id}, type, id), do: true
  def selected?(_, _, _), do: false

  defp bookmark_completed_input_id(%Bookmark{id: id, completed: completed}, custom_id) do
    base = custom_id || "bookmark-completed-#{id}"
    suffix = if completed, do: "checked", else: "unchecked"
    "#{base}-#{suffix}"
  end

  def bookmark_label(%Bookmark{title: title}) when is_binary(title) and title != "",
    do: title

  def bookmark_label(%Bookmark{url: url}) when is_binary(url), do: url

  def bookmark_label(_), do: "Untitled"

  defp format_metadata_fetched_at(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  def collaborator_access_label(%Collection{collaboration_revoked_at: revoked_at} = collaborator) do
    access =
      if collaborator.collaboration_readonly,
        do: "Read-only",
        else: "Can edit"

    status = if revoked_at, do: "Revoked", else: "Active"
    "#{access} · #{status}"
  end

  defp collaborator_email(collaborators, id) do
    case Enum.find(collaborators, &(&1.id == id)) do
      %{owner: %{email: email}} -> email
      _ -> "this collaborator"
    end
  end

  defp public_share_token(shares, id) do
    case Enum.find(shares, &(&1.id == id)) do
      %{token: token} -> token
      _ -> "this link"
    end
  end

  defp public_share_url(%{token: token}) do
    url(~p"/share/#{token}")
  end

  defp sidebar_menu_class(extra) do
    [
      "menu flex-nowrap bg-base-200 rounded-box w-full"
      | extra
    ]
  end
end
