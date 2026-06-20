defmodule LinksWeb.DashboardLive do
  use LinksWeb, :live_view

  alias Links.Accounts
  alias Links.Bookmarks.Bookmark
  alias Links.Collections
  alias Links.Collections.Collection

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
     |> assign(:page_title, "Dashboard")
     |> assign(:collapsed, MapSet.new())
     |> assign(:subscribed_collection_ids, MapSet.new())
     |> assign(:selected, nil)
     |> assign(:selected_context, nil)
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
                />
                <button class="btn btn-primary join-item">Add</button>
              </div>
            </.form>
          </div>

          <div
            id="bookmarks-sidebar"
            phx-hook="CollectionBookmarkSort"
            class="flex min-h-0 flex-1 flex-col"
          >
            <section class="shrink-0 border-b border-base-300 p-3">
              <div class="mb-2 flex items-center gap-1.5">
                <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Inbox
                </h2>
                <span id="inbox-bookmark-count" class="badge badge-ghost badge-xs shrink-0 tabular-nums">
                  {length(@dashboard.inbox)}
                </span>
              </div>
              <ul
                id="bookmarks-zone-inbox"
                data-bookmark-sortable
                data-collection-id="inbox"
                class={sidebar_menu_class()}
              >
                <li
                  :for={bookmark <- @dashboard.inbox}
                  id={"bookmark-#{bookmark.id}"}
                  data-id={bookmark.id}
                >
                  <.bookmark_menu_link
                    bookmark={bookmark}
                    selected={selected?(@selected, :bookmark, bookmark.id)}
                    metadata_pending={MapSet.member?(@pending_metadata_ids, bookmark.id)}
                  />
                </li>
                <li id="inbox-empty-state" class="inbox-empty-state" aria-hidden="true">
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
                  New
                </button>
              </div>
              <ul
                id="collections-zone-root"
                data-collection-sortable
                data-parent-id="root"
                class={sidebar_menu_class(["overflow-y-auto"])}
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
              </ul>
            </section>
          </div>
        </aside>

        <%= if @selected_context do %>
          <div
            id="detail-panel"
            class={[
              "fixed inset-0 z-[999] flex items-center justify-center bg-black/40 p-4",
              "lg:static lg:z-auto lg:flex lg:min-w-0 lg:flex-1 lg:flex-col lg:items-stretch lg:justify-start lg:overflow-auto lg:border-l lg:border-base-300 lg:bg-transparent lg:p-0"
            ]}
            role="dialog"
            aria-modal="true"
          >
            <button
              type="button"
              class="absolute inset-0 lg:hidden"
              phx-click="close_detail"
              aria-label="Close"
            />
            <div class="relative z-10 flex max-h-[90dvh] w-full max-w-3xl flex-col overflow-hidden rounded-box bg-base-100 shadow-xl lg:h-full lg:max-h-none lg:max-w-none lg:rounded-none lg:shadow-none">
              <div class="flex shrink-0 items-center justify-end border-b border-base-300 px-3 py-2 lg:hidden">
                <button
                  type="button"
                  id="detail-modal-close"
                  class="btn btn-ghost btn-sm btn-circle"
                  phx-click="close_detail"
                  aria-label="Close"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>
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
      <.file_icon class={@class} />
    <% end %>
    """
  end

  attr :bookmark, Bookmark, required: true
  attr :selected, :boolean, default: false
  attr :metadata_pending, :boolean, default: false

  def bookmark_menu_link(assigns) do
    ~H"""
    <div class={[
      "bookmark-menu-row flex min-w-0 w-full items-center gap-2",
      @selected && "menu-active"
    ]}>
      <a
        href={@bookmark.url}
        target="_blank"
        rel="noopener noreferrer"
        class="flex min-w-0 flex-1 items-center gap-2"
      >
        <.bookmark_status_icon bookmark={@bookmark} metadata_pending={@metadata_pending} />
        <span class="flex min-w-0 flex-1 items-baseline gap-1 overflow-hidden text-left leading-normal">
          <span class="min-w-0 truncate">{bookmark_label(@bookmark)}</span>
          <span
            :if={domain = Bookmark.display_host(@bookmark)}
            class="shrink-0 truncate text-base-content/50"
          >
            {domain}
          </span>
        </span>
      </a>
      <.sidebar_more_button
        id={"bookmark-more-#{@bookmark.id}"}
        event="select_bookmark"
        value_id={@bookmark.id}
        selected={@selected}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :value_id, :integer, required: true
  attr :selected, :boolean, default: false

  def sidebar_more_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class={[
        "sidebar-more-button btn btn-ghost btn-xs shrink-0",
        @selected && "btn-active"
      ]}
      phx-click={@event}
      phx-value-id={@value_id}
      phx-stop-propagation
      phx-hook=".PreventSummaryToggle"
      aria-label="More options"
    >
      <.icon name="hero-ellipsis-horizontal" class="size-4" />
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PreventSummaryToggle">
      export default {
        mounted() {
          this.onClick = (event) => event.preventDefault()
          this.el.addEventListener("click", this.onClick, true)
        },
        destroyed() {
          this.el.removeEventListener("click", this.onClick, true)
        }
      }
    </script>
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
        :reorderable?,
        Collections.can_reorder_collection?(
          assigns.current_scope,
          assigns.node.collection.id
        )
      )

    ~H"""
    <li
      id={"collection-#{@collection.id}"}
      data-readonly={to_string(@node.readonly || false)}
      data-reorderable={to_string(@reorderable?)}
      data-revoked={to_string(@node.revoked || false)}
      class="min-w-0 max-w-full"
    >
      <%= if @node.revoked do %>
        <details class="revoked-collection min-w-0 max-w-full">
          <summary class="min-w-0 max-w-full line-through opacity-50">
            <.folder_icon />
            <span class="min-w-0 truncate leading-normal">{@node.title}</span>
          </summary>
        </details>
      <% else %>
        <details class="min-w-0 max-w-full" open={@expanded}>
          <summary
            class={[
              "min-w-0 max-w-full",
              selected?(@selected, :collection, @collection.id) && "menu-active"
            ]}
            phx-click="toggle_collection"
            phx-value-id={@collection.id}
          >
            <.folder_icon />
            <span class="flex min-w-0 flex-1 items-center gap-1.5 leading-none">
              <span class="min-w-0 truncate leading-normal">{@node.title}</span>
              <span class="badge badge-ghost badge-xs shrink-0 tabular-nums">
                {@node.bookmark_count}
              </span>
              <span
                :if={@node.shared}
                class="inline-flex shrink-0 items-center justify-center self-center text-base-content/60"
                aria-label="Shared with others"
              >
                <.icon name="hero-user-group" class="size-4 block leading-none" />
              </span>
              <span
                :if={@collaboration_mount?}
                class="inline-flex shrink-0 items-center justify-center self-center text-base-content/60"
                aria-label={
                  if(@node.readonly,
                    do: "Read-only collaboration",
                    else: "Editable collaboration"
                  )
                }
              >
                <.icon
                  name={if @node.readonly, do: "hero-eye", else: "hero-pencil-square"}
                  class="size-4 block leading-none"
                />
              </span>
            </span>
            <.sidebar_more_button
              id={"collection-more-#{@collection.id}"}
              event="select_collection"
              value_id={@collection.id}
              selected={selected?(@selected, :collection, @collection.id)}
            />
          </summary>
          <ul
            :if={@node.children != []}
            id={"collections-zone-#{@effective.id}"}
            data-collection-sortable
            data-parent-id={@effective.id}
            data-readonly={to_string(@node.readonly || false)}
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
            data-bookmark-sortable
            data-collection-id={@effective.id}
            data-empty-bookmarks={to_string(@node.bookmarks == [])}
            data-readonly={to_string(@node.readonly || false)}
            class={@node.bookmarks == [] && "collection-bookmark-drop-hidden"}
          >
            <li
              :for={bookmark <- @node.bookmarks}
              id={"bookmark-#{bookmark.id}"}
              data-id={bookmark.id}
            >
              <.bookmark_menu_link
                bookmark={bookmark}
                selected={selected?(@selected, :bookmark, bookmark.id)}
                metadata_pending={MapSet.member?(@pending_metadata_ids, bookmark.id)}
              />
            </li>
          </ul>
        </details>
      <% end %>
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
        <div class="mb-4 flex items-start gap-3">
          <.bookmark_status_icon
            bookmark={@context.bookmark}
            metadata_pending={@metadata_pending}
            class="mt-1 size-8"
          />
          <div class="min-w-0">
            <h1 class="truncate text-lg font-semibold">{bookmark_label(@context.bookmark)}</h1>
            <p class="truncate text-sm text-base-content/60">{@context.bookmark.url}</p>
            <p :if={@metadata_pending} class="mt-1 text-xs text-base-content/50">
              Fetching page title and icon…
            </p>
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
            <button class="btn btn-primary">Save</button>
            <button
              type="button"
              class="btn btn-error btn-soft"
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
            :if={@context.mount || !@readonly}
            type="button"
            class="btn btn-error btn-soft"
            phx-click="delete_collection"
            phx-value-id={@context.collection.id}
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
            <button class="btn btn-primary join-item">Save collection</button>
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
              <button class="btn btn-primary join-item">Create</button>
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
              <label for={@collaboration_form[:email].id} class="label mb-1">User email</label>
              <div class="flex items-center gap-4">
                <div
                  class="relative min-w-0 flex-1"
                  id="collaboration-email-field"
                  phx-hook=".CollaboratorEmailSearch"
                >
                  <div class="relative">
                    <input
                      type="email"
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
                          id={"collaboration-email-option-#{email_option_dom_id(email)}"}
                          phx-click="select_collaborator_email"
                          phx-value-email={email}
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
                      this.input = this.el.querySelector("input[type='email']")
                      this.blurTimer = null

                      this.onFocus = () => {
                        clearTimeout(this.blurTimer)
                        this.pushEvent("show_collaborator_email_suggestions")
                      }

                      this.onBlur = () => {
                        this.blurTimer = setTimeout(() => {
                          this.pushEvent("hide_collaborator_email_suggestions")
                        }, 150)
                      }

                      this.onMouseDown = (event) => {
                        if (event.target.closest("[data-suggestion]")) {
                          clearTimeout(this.blurTimer)
                        }
                      }

                      this.input?.addEventListener("focus", this.onFocus)
                      this.input?.addEventListener("blur", this.onBlur)
                      this.el.addEventListener("mousedown", this.onMouseDown)
                    },
                    destroyed() {
                      clearTimeout(this.blurTimer)
                      this.input?.removeEventListener("focus", this.onFocus)
                      this.input?.removeEventListener("blur", this.onBlur)
                      this.el.removeEventListener("mousedown", this.onMouseDown)
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
                <button class="btn btn-primary shrink-0">Share</button>
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
                class="btn btn-ghost"
                phx-click="revoke_collaboration"
                phx-value-id={collaborator.id}
              >
                Revoke
              </button>
              <button
                :if={collaborator.collaboration_revoked_at && @context.can_restore_collaborators}
                id={"restore-collaborator-#{collaborator.id}"}
                class="btn btn-ghost"
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
          <button class="btn btn-primary" phx-click="create_public_share">Create public link</button>
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
            <div :if={is_nil(share.revoked_at)} class="flex shrink-0 items-center gap-1">
              <button
                id={"copy-public-share-#{share.id}"}
                type="button"
                class="btn btn-ghost"
                phx-click={JS.dispatch("phx:copy", detail: %{text: public_share_url(share)})}
              >
                Copy link
              </button>
              <button
                class="btn btn-ghost"
                phx-click="revoke_public_share"
                phx-value-id={share.id}
              >
                Revoke
              </button>
            </div>
            <button
              :if={share.revoked_at && @context.can_restore_collaborators}
              id={"restore-public-share-#{share.id}"}
              type="button"
              class="btn btn-ghost shrink-0"
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
    case Collections.create_inbox_bookmark(socket.assigns.current_scope, bookmark_params) do
      {:ok, bookmark} ->
        {:noreply,
         socket
         |> assign(:new_bookmark_form, new_bookmark_form())
         |> mark_metadata_pending(bookmark.id)
         |> refresh_dashboard()}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_bookmark_form, to_form(changeset, as: :new_bookmark))}
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

  def handle_event("close_detail", _params, socket) do
    {:noreply, clear_detail_selection(socket)}
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

  def handle_event("expand_collection", %{"id" => id}, socket) do
    {:noreply, expand_collection(socket, String.to_integer(id))}
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

  def handle_event("move_bookmark", params, socket) do
    with %{id: id, collection_id: collection_id, ordered_ids: ordered_ids} <-
           normalize_move_bookmark_params(params),
         {:ok, _bookmark} <-
           Collections.move_bookmark(
             socket.assigns.current_scope,
             id,
             collection_id,
             ordered_ids
           ) do
      {:noreply, refresh_dashboard(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not move bookmark")}
    end
  end

  def handle_event("reorder_collections", params, socket) do
    parent_id = params["parent_id"]
    ordered_ids = params["ordered_ids"] || []

    case Collections.reorder_collections(
           socket.assigns.current_scope,
           parent_id,
           ordered_ids
         ) do
      {:ok, _} ->
        {:noreply, refresh_dashboard(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not reorder collections")}
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
    {:noreply, assign(socket, :collaborator_email_suggestions_open?, false)}
  end

  def handle_event("select_collaborator_email", %{"email" => email}, socket) do
    readonly =
      collaboration_readonly_checked?(socket.assigns.collaboration_form)

    collection = socket.assigns.selected_context.effective_collection
    params = %{"email" => email, "readonly" => readonly}
    errors = collaboration_email_errors(collection, email)

    {:noreply,
     socket
     |> assign(:collaborator_email_suggestions, nil)
     |> assign(:collaborator_email_suggestions_open?, false)
     |> assign_collaboration_form(params, readonly, errors)}
  end

  def handle_event("create_collaboration", %{"collaboration" => params}, socket) do
    collection = socket.assigns.selected_context.effective_collection
    readonly = Map.get(params, "readonly") == "true"
    email = Map.get(params, "email", "")

    errors = collaboration_email_errors(collection, email)

    if errors != [] do
      {:noreply, assign_collaboration_form(socket, params, readonly, errors)}
    else
      case Collections.create_collaboration(
             socket.assigns.current_scope,
             collection,
             email,
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

  def handle_event("revoke_collaboration", %{"id" => id}, socket) do
    mount = Collections.get_collection!(id)
    collection = socket.assigns.selected_context.effective_collection

    case Collections.revoke_collaboration(socket.assigns.current_scope, mount) do
      {:ok, _mount} ->
        {:noreply, select_collection(refresh_dashboard(socket), collection.id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not revoke collaborator")}
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

  defp clear_detail_selection(socket) do
    socket
    |> assign(:selected, nil)
    |> assign(:selected_context, nil)
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
    |> assign(:collaborator_email_suggestions_open?, false)
    |> assign(
      :collaboration_form,
      collaboration_form(%{"email" => "", "readonly" => false}, "collaboration-#{key}")
    )
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

    socket
    |> assign(:collaborator_email_suggestions, suggestions)
    |> assign(:collaborator_email_suggestions_open?, is_list(suggestions))
    |> assign_collaboration_form(params, readonly, errors)
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
    |> assign(:collaborator_email_suggestions, suggestions)
    |> assign(:collaborator_email_suggestions_open?, is_list(suggestions))
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

  defp collaboration_email_errors(%Collection{} = collection, email) do
    trimmed = String.trim(email)

    with false <- trimmed == "",
         %Accounts.User{} = user <- Accounts.get_user_by_email(trimmed),
         true <- Collections.active_collaborator?(collection, user) do
      [email: {"This user is already a collaborator", []}]
    else
      _ -> []
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

  defp new_bookmark_form do
    Bookmark.changeset(%Bookmark{}, %{})
    |> to_form(as: :new_bookmark)
  end

  defp child_collection_form do
    Collection.changeset(%Collection{}, %{})
    |> to_form(as: :child_collection)
  end

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
        |> reset_collaboration_form()
        |> assign(
          :collection_form,
          to_form(Collection.changeset(context.effective_collection, %{}))
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

  def selected?(%{type: type, id: id}, type, id), do: true
  def selected?(_, _, _), do: false

  def bookmark_label(%Bookmark{page_title: title}) when is_binary(title) and title != "",
    do: title

  def bookmark_label(%Bookmark{title: title}), do: title

  def collaborator_access_label(%Collection{collaboration_revoked_at: revoked_at} = collaborator) do
    access =
      if collaborator.collaboration_readonly,
        do: "Read-only",
        else: "Can edit"

    status = if revoked_at, do: "Revoked", else: "Active"
    "#{access} · #{status}"
  end

  defp public_share_url(%{token: token}) do
    url(~p"/share/#{token}")
  end

  defp sidebar_menu_class(extra \\ []) do
    [
      "menu flex-col flex-nowrap bg-base-200 rounded-box w-full min-w-0 max-w-full",
      "[&_li]:min-w-0 [&_li]:max-w-full [&_a]:min-w-0 [&_details]:min-w-0 [&_details]:max-w-full"
      | extra
    ]
  end

  defp normalize_move_bookmark_params(%{"id" => id, "ordered_ids" => ordered_ids} = params) do
    collection_id =
      params
      |> Map.get("collection_id")
      |> normalize_move_collection_id()

    %{id: id, collection_id: collection_id, ordered_ids: ordered_ids}
  end

  defp normalize_move_bookmark_params(_), do: :error

  defp normalize_move_collection_id(collection_id) when collection_id in [nil, "", "inbox"],
    do: nil

  defp normalize_move_collection_id(collection_id) when is_integer(collection_id),
    do: collection_id

  defp normalize_move_collection_id(collection_id) when is_binary(collection_id),
    do: String.to_integer(collection_id)
end
