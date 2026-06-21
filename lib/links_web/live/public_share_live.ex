defmodule LinksWeb.PublicShareLive do
  use LinksWeb, :live_view

  alias Links.Bookmarks.Bookmark
  alias Links.Collections

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:token, token)
      |> assign(:not_found, false)
      |> assign(:subscribed_collection_ids, MapSet.new())

    case Collections.fetch_public_share_dashboard(token) do
      {:ok, dashboard} ->
        [root_node] = dashboard.tree

        socket =
          socket
          |> assign(:share, dashboard.share)
          |> assign(:root, dashboard.root)
          |> assign(:root_bookmarks, root_node.bookmarks)
          |> assign(:sections, root_node.children)
          |> assign(:collection_ids, dashboard.collection_ids)
          |> assign(:page_title, dashboard.root.title)

        socket =
          if connected?(socket) do
            socket
            |> subscribe_to_public_share()
            |> sync_collection_subscriptions(dashboard.collection_ids)
          else
            socket
          end

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> assign(:share, nil)
         |> assign(:root, nil)
         |> assign(:root_bookmarks, [])
         |> assign(:sections, [])
         |> assign(:collection_ids, [])
         |> assign(:page_title, "Shared collection")
         |> assign(:not_found, true)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} show_home_link={false}>
      <%= if @not_found do %>
        <div class="flex h-full items-center justify-center p-4">
          <div class="max-w-md rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center">
            <h1 class="text-lg font-semibold">Shared collection unavailable</h1>
            <p class="mt-2 text-base-content/60">
              This public link may have been revoked or no longer exists.
            </p>
          </div>
        </div>
      <% else %>
        <div class="h-full overflow-auto bg-base-200 p-4 text-sm">
          <div
            id="public-share-sidebar"
            class="mx-auto w-full max-w-[120ch] rounded-box border border-base-300 bg-base-100 p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Shared collection
            </p>
            <h1 class="truncate text-xl font-semibold">{@root.title}</h1>

            <ul id="public-share-tree" class={sidebar_menu_class(["mt-4", "overflow-y-auto"])}>
              <.tree_node :for={node <- @sections} node={node} />
              <.bookmark_menu_link
                :for={bookmark <- @root_bookmarks}
                bookmark={bookmark}
              />
            </ul>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :node, :map, required: true

  def tree_node(assigns) do
    assigns =
      assigns
      |> assign(:collection, assigns.node.collection)
      |> assign(:empty?, empty_collection?(assigns.node))

    ~H"""
    <li id={"collection-#{@collection.id}"} class="min-w-0 max-w-full">
      <%= if @empty? do %>
        <span class="flex min-w-0 w-full items-center gap-2">
          <.folder_icon />
          <span class="flex min-w-0 flex-1 items-center gap-1.5 leading-none">
            <span class="min-w-0 truncate leading-normal">{@node.title}</span>
            <span class="badge badge-ghost badge-sm shrink-0 tabular-nums">0</span>
          </span>
        </span>
      <% else %>
        <details class="min-w-0 max-w-full" open>
          <summary class="min-w-0 max-w-full">
            <.folder_icon />
            <span class="flex min-w-0 flex-1 items-center gap-1.5 leading-none">
              <span class="min-w-0 truncate leading-normal">{@node.title}</span>
              <span class="badge badge-ghost badge-sm shrink-0 tabular-nums">
                {@node.bookmark_count}
              </span>
            </span>
          </summary>
          <ul :if={@node.children != []}>
            <.tree_node :for={child <- @node.children} node={child} />
          </ul>
          <ul :if={@node.bookmarks != []}>
            <.bookmark_menu_link :for={bookmark <- @node.bookmarks} bookmark={bookmark} />
          </ul>
        </details>
      <% end %>
    </li>
    """
  end

  attr :bookmark, Bookmark, required: true

  def bookmark_menu_link(assigns) do
    ~H"""
    <li
      id={"bookmark-#{@bookmark.id}"}
      class="bookmark-menu-row flex min-w-0 w-full max-w-full items-center gap-2"
    >
      <a
        href={@bookmark.url}
        target="_blank"
        rel="noopener noreferrer"
        class="flex min-w-0 flex-1 items-center gap-2"
      >
        <.bookmark_icon bookmark={@bookmark} />
        <span class="flex min-w-0 flex-1 items-baseline gap-1 overflow-hidden text-left leading-normal">
          <span class="min-w-0 truncate">{bookmark_label(@bookmark)}</span>
          <span
            :if={domain = Bookmark.display_host(@bookmark)}
            class="bookmark-domain shrink-0 truncate"
          >
            {domain}
          </span>
        </span>
      </a>
    </li>
    """
  end

  attr :bookmark, Bookmark, required: true
  attr :class, :string, default: "h-4 w-4"

  def bookmark_icon(assigns) do
    ~H"""
    <%= if url = favicon_data_url(@bookmark) do %>
      <img
        src={url}
        alt=""
        loading="lazy"
        class={["shrink-0 rounded-sm object-contain", @class]}
      />
    <% else %>
      <.file_icon class={@class} />
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

  @impl true
  def handle_info({:collection_bookmarks_changed, _collection_id}, socket) do
    {:noreply, refresh_public_share(socket)}
  end

  def handle_info({:public_share_changed, token}, socket) do
    if socket.assigns.token == token do
      {:noreply, refresh_public_share(socket)}
    else
      {:noreply, socket}
    end
  end

  defp refresh_public_share(socket) do
    case Collections.fetch_public_share_dashboard(socket.assigns.token) do
      {:ok, dashboard} ->
        [root_node] = dashboard.tree

        socket
        |> assign(:not_found, false)
        |> assign(:share, dashboard.share)
        |> assign(:root, dashboard.root)
        |> assign(:root_bookmarks, root_node.bookmarks)
        |> assign(:sections, root_node.children)
        |> assign(:collection_ids, dashboard.collection_ids)
        |> assign(:page_title, dashboard.root.title)
        |> sync_collection_subscriptions(dashboard.collection_ids)

      {:error, :not_found} ->
        socket
        |> assign(:not_found, true)
        |> assign(:share, nil)
        |> assign(:root, nil)
        |> assign(:root_bookmarks, [])
        |> assign(:sections, [])
        |> assign(:collection_ids, [])
    end
  end

  defp subscribe_to_public_share(socket) do
    Phoenix.PubSub.subscribe(Links.PubSub, Collections.public_share_topic(socket.assigns.token))
    socket
  end

  defp sync_collection_subscriptions(socket, collection_ids) do
    if connected?(socket) do
      visible_ids = MapSet.new(collection_ids)
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

  defp sidebar_menu_class(extra) do
    [
      "menu flex-col flex-nowrap bg-base-200 rounded-box w-full min-w-0",
      "[&_li]:min-w-0 [&_a]:min-w-0"
      | extra
    ]
  end

  defp empty_collection?(node) do
    node.children == [] and node.bookmarks == []
  end

  defp favicon_data_url(%Bookmark{favicon_data: data, favicon_content_type: content_type})
       when is_binary(data) and byte_size(data) > 0 and is_binary(content_type) and
              content_type != "" do
    "data:#{content_type};base64,#{Base.encode64(data)}"
  end

  defp favicon_data_url(_), do: nil

  def bookmark_label(%Bookmark{title: title}) when is_binary(title) and title != "",
    do: title

  def bookmark_label(%Bookmark{url: url}) when is_binary(url), do: url

  def bookmark_label(_), do: "Untitled"
end
