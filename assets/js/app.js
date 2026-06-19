// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/links"
import Sortable from "sortablejs"
import topbar from "../vendor/topbar"

const bookmarkSortContainers = (root) => [
  ...(root.hasAttribute("data-bookmark-sortable") ? [root] : []),
  ...root.querySelectorAll("[data-bookmark-sortable]"),
]

const targetCollectionId = (el) => {
  if (!el) return null

  const collectionId = el.dataset.collectionId

  if (collectionId === "inbox" || collectionId == null) {
    return null
  }

  return collectionId
}

const sortContainerForSummary = (summary) => {
  if (!summary) return null

  return summary.closest("details")?.querySelector(":scope > [data-bookmark-sortable]") ?? null
}

const isWritableSortContainer = (container) =>
  container != null && container.dataset.readonly !== "true"

const isEmptyBookmarkContainer = (container) =>
  container != null &&
  container.dataset.collectionId !== "inbox" &&
  container.dataset.emptyBookmarks === "true"

const DROP_HIGHLIGHT_CLASS = "bookmark-drop-highlight"
const AUTO_EXPAND_DELAY_MS = 2000

const CollectionBookmarkSort = {
  mounted() {
    this.highlightedSummary = null
    this.sourceSummary = null
    this.expandTimer = null
    this.expandTargetId = null
    this.pendingExpandSummary = null
    this.autoExpandedIds = new Set()
    this.sortables = []
    this.initSortables()
  },
  updated() {
    this.destroySortables()
    this.clearDropHighlight()
    this.clearExpandTimer()
    this.sourceSummary = null
    this.initSortables()
  },
  destroyed() {
    this.destroySortables()
    this.clearDropHighlight()
    this.clearExpandTimer()
    this.unbindDragOver()
    this.sourceSummary = null
  },
  clearExpandTimer() {
    if (this.expandTimer) {
      clearTimeout(this.expandTimer)
      this.expandTimer = null
    }

    this.expandTargetId = null
    this.pendingExpandSummary = null
  },
  clearDropHighlight() {
    if (this.highlightedSummary) {
      this.highlightedSummary.classList.remove(DROP_HIGHLIGHT_CLASS)
      this.highlightedSummary = null
    }
  },
  setDropHighlight(summary) {
    if (this.highlightedSummary === summary) {
      if (summary) this.scheduleExpand(summary)
      return
    }

    this.clearDropHighlight()
    this.clearExpandTimer()

    if (!summary) return

    const collection = summary.closest("li[id^='collection-']")

    if (collection?.dataset.readonly === "true") return

    summary.classList.add(DROP_HIGHLIGHT_CLASS)
    this.highlightedSummary = summary
    this.scheduleExpand(summary)
  },
  isExpandedCollection(summary) {
    if (!summary) return false

    const details = summary.closest("details")

    return details?.open ?? false
  },
  summaryFromPointerTarget(target) {
    if (!target) return null

    return target.closest("li[id^='collection-'] > details > summary")
  },
  dropContainerFromPointerTarget(target) {
    if (!target) return null

    const summaryContainer = sortContainerForSummary(this.summaryFromPointerTarget(target))

    if (isWritableSortContainer(summaryContainer)) {
      return summaryContainer
    }

    const sortContainer = target.closest("[data-bookmark-sortable]")

    if (isWritableSortContainer(sortContainer)) {
      return sortContainer
    }

    return null
  },
  updateDropHighlightFromTarget(target) {
    const summary = this.summaryFromPointerTarget(target)

    if (summary) {
      this.setDropHighlight(summary)

      if (!this.isExpandedCollection(summary)) {
        this.scheduleExpand(summary)
      }

      return
    }

    const container = target.closest("[data-bookmark-sortable]")

    if (container) {
      this.setDropHighlight(this.summaryForSortContainer(container) || this.sourceSummary)
      return
    }

    this.setDropHighlight(this.sourceSummary)
  },
  shouldRejectMoveInContainer(event, pointerTarget) {
    const dropContainer = this.dropContainerFromPointerTarget(pointerTarget)

    if (dropContainer != null && event.to !== dropContainer) {
      return true
    }

    if (isEmptyBookmarkContainer(event.to) && !this.summaryFromPointerTarget(pointerTarget)) {
      return true
    }

    return false
  },
  scheduleExpand(summary) {
    const details = summary.closest("details")

    if (!details || details.open) {
      this.clearExpandTimer()
      return
    }

    const collection = summary.closest("li[id^='collection-']")

    if (collection?.dataset.readonly === "true") {
      this.clearExpandTimer()
      return
    }

    const collectionId = collection.id

    if (this.expandTargetId === collectionId && this.expandTimer) return

    this.clearExpandTimer()
    this.expandTargetId = collectionId
    this.pendingExpandSummary = summary

    this.expandTimer = setTimeout(() => {
      this.expandCollectionForDrop(this.pendingExpandSummary)
      this.clearExpandTimer()
    }, AUTO_EXPAND_DELAY_MS)
  },
  expandCollectionForDrop(summary) {
    if (!summary) return

    const details = summary.closest("details")

    if (!details || details.open) return

    details.open = true

    const collectionId = summary.closest("li[id^='collection-']")?.id?.replace("collection-", "")

    if (collectionId) this.autoExpandedIds.add(collectionId)

    bookmarkSortContainers(details).forEach((el) => {
      if (el.dataset.readonly === "true") return
      if (isEmptyBookmarkContainer(el)) return
      if (this.sortables.some((sortable) => sortable.el === el)) return

      this.sortables.push(this.createSortable(el))
    })

    if (summary !== this.sourceSummary) {
      this.setDropHighlight(summary)
    }
  },
  summaryForSortContainer(container) {
    if (!container || container.dataset.collectionId === "inbox") return null

    return container.closest("details")?.querySelector("summary") ?? null
  },
  elementUnderPointer(event) {
    const originalEvent = event.originalEvent ?? event
    const clientX = originalEvent.clientX
    const clientY = originalEvent.clientY

    if (clientX == null || clientY == null) return null

    const draggedItem = event.item

    return (
      document
        .elementsFromPoint(clientX, clientY)
        .find(
          (el) =>
            el !== draggedItem &&
            !el.classList.contains("sortable-ghost") &&
            !el.classList.contains("sortable-drag") &&
            !el.classList.contains("sortable-fallback")
        ) ?? null
    )
  },
  resolveDropContainer(event) {
    const pointerTarget = this.elementUnderPointer(event)

    if (pointerTarget) {
      const dropContainer = this.dropContainerFromPointerTarget(pointerTarget)

      if (dropContainer) {
        return dropContainer
      }
    }

    return isWritableSortContainer(event.to) ? event.to : event.from
  },
  orderedBookmarkIds(container, movedItem) {
    const movedId = movedItem.dataset.id
    const existingIds = Array.from(container.children)
      .filter((child) => child.id.startsWith("bookmark-"))
      .map((child) => child.dataset.id)
      .filter(Boolean)

    if (existingIds.includes(movedId)) {
      return existingIds
    }

    return [...existingIds, movedId]
  },
  bindDragOver() {
    if (this.onDragOver) return

    this.onDragOver = (event) => {
      this.updateDropHighlightFromTarget(event.target)
    }

    document.addEventListener("dragover", this.onDragOver)
  },
  unbindDragOver() {
    if (this.onDragOver) {
      document.removeEventListener("dragover", this.onDragOver)
      this.onDragOver = null
    }
  },
  syncAutoExpandedCollections() {
    for (const id of this.autoExpandedIds) {
      this.pushEvent("expand_collection", {id})
    }

    this.autoExpandedIds.clear()
  },
  createSortable(el) {
    const hook = this

    return new Sortable(el, {
      group: "bookmarks",
      animation: 150,
      handle: ".bookmark-drag-handle",
      draggable: "li[id^='bookmark-']",
      filter: "summary, button, input, textarea, select",
      preventOnFilter: false,
      fallbackOnBody: true,
      swapThreshold: 0.65,
      emptyInsertThreshold: 8,
      onStart(event) {
        hook.bindDragOver()
        hook.sourceSummary = hook.summaryForSortContainer(event.from)
        hook.setDropHighlight(hook.sourceSummary)
      },
      onMove(event) {
        const pointerTarget = hook.elementUnderPointer(event)

        hook.updateDropHighlightFromTarget(pointerTarget || event.related)

        return !hook.shouldRejectMoveInContainer(event, pointerTarget)
      },
      onEnd(event) {
        hook.unbindDragOver()

        const targetContainer = hook.resolveDropContainer(event)
        const sourceContainer = event.from

        hook.clearDropHighlight()
        hook.clearExpandTimer()
        hook.sourceSummary = null
        hook.syncAutoExpandedCollections()

        if (targetContainer === sourceContainer && event.oldIndex === event.newIndex) return

        hook.pushEvent("move_bookmark", {
          id: event.item.dataset.id,
          collection_id: targetCollectionId(targetContainer),
          ordered_ids: hook.orderedBookmarkIds(targetContainer, event.item),
        })
      },
    })
  },
  initSortables() {
    this.sortables = []

    bookmarkSortContainers(this.el).forEach((el) => {
      if (el.dataset.readonly === "true") return
      if (isEmptyBookmarkContainer(el)) return

      this.sortables.push(this.createSortable(el))
    })
  },
  destroySortables() {
    if (this.sortables) {
      this.sortables.forEach((sortable) => sortable.destroy())
    }

    this.sortables = []
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CollectionBookmarkSort},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
