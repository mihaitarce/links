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

const DROP_HIGHLIGHT_CLASS = "collection-drop-target"
const AUTO_EXPAND_DELAY_MS = 2000
const COLLECTIONS_GROUP = "collections"
const BOOKMARKS_GROUP = "bookmarks"

const sidebarRoot = (el) => el.closest("#bookmarks-sidebar") || el

const collectionSortContainers = (root) => root.querySelectorAll("[data-collection-sortable]")

const collectionAcceptsDrops = (collection) => collection?.dataset.readonly !== "true"

const isCollaborationMount = (collection) => collection?.dataset.collaborationMount === "true"

const sortZoneAcceptsCollections = (zone) => zone?.dataset.readonly !== "true"

const sortZoneAcceptsCollectionCopy = (zone) =>
  zone?.dataset.parentId === "root" || sortZoneAcceptsCollections(zone)

const collectionDraggedFromReadonly = (dragged, from) => {
  if (isCollaborationMount(dragged) && from?.dataset.parentId === "root") return false

  return (
    dragged?.dataset.readonly === "true" ||
    dragged?.closest("li[id^='collection-']")?.dataset.readonly === "true" ||
    from?.dataset.readonly === "true"
  )
}

const revertAutoExpandedCollections = (root, autoExpandedIds) => {
  for (const id of autoExpandedIds) {
    const collection = root.querySelector(`#collection-${id}`)
    const details = collection?.querySelector(":scope > details") || collection?.querySelector("details")

    if (details) details.open = false
  }
}

const sortableSpillOptions = (hook) => ({
  revertOnSpill: false,
  removeOnSpill: false,
  onSpill() {
    hook.spilled = true
  },
})

const bookmarkSpillOptions = (hook) => ({
  revertOnSpill: true,
  removeOnSpill: false,
  onSpill() {
    hook.spilled = true
  },
})

const revertSortableItem = ({item, from, oldIndex}) => {
  if (!from || !item) return

  const sibling = from.children[oldIndex]

  if (item.parentNode === from && sibling === item) return

  from.insertBefore(item, sibling || null)
}

const finishCollectionDragUi = (hook, {spilled = false} = {}) => {
  hook.unbindDropHighlight()
  hook.clearExpandTimer()
  clearCopyDragMode(hook)

  if (spilled) {
    revertAutoExpandedCollections(hook.el, hook.autoExpandedIds)
    hook.autoExpandedIds.clear()
  } else {
    hook.syncAutoExpandedCollections()
  }

  hook.clearDropHighlight()
  hook.draggedItem = null
}

const finishBookmarkDragUi = (hook, {spilled = false} = {}) => {
  hook.unbindDropHighlight()
  hook.clearExpandTimer()
  clearCopyDragMode(hook)

  if (spilled) {
    revertAutoExpandedCollections(hook.sidebar(), hook.autoExpandedIds)
    hook.autoExpandedIds.clear()
  } else {
    hook.syncAutoExpandedCollections()
  }

  hook.clearDropHighlight()
}

const startCopyDragMode = (hook, event) => {
  hook.copyMode = Boolean(event.originalEvent?.shiftKey)
  document.body.classList.toggle("dnd-copy-mode", hook.copyMode)
}

const clearCopyDragMode = (hook) => {
  hook.copyMode = false
  document.body.classList.remove("dnd-copy-mode")
}
const CollectionSort = {
  mounted() {
    this.sortables = []
    this.dropTarget = null
    this.nestTargetCollection = null
    this.draggedItem = null
    this.expandTimer = null
    this.expandTargetId = null
    this.autoExpandedIds = new Set()
    this.onCollectionEnter = this.onCollectionEnter.bind(this)
    this.onCollectionLeave = this.onCollectionLeave.bind(this)
    this.initSortables()
  },
  updated() {
    this.destroySortables()
    this.initSortables()
  },
  destroyed() {
    this.destroySortables()
  },
  sortableCollections() {
    return this.el.querySelectorAll("li[id^='collection-']")
  },
  setDropHighlight(collection) {
    if (!collectionAcceptsDrops(collection)) return

    const summary = collection.querySelector("details > summary")

    if (this.dropTarget === summary) return

    this.clearDropHighlight()

    if (summary) {
      summary.classList.add(DROP_HIGHLIGHT_CLASS)
      this.dropTarget = summary
      this.nestTargetCollection = collection
    }
  },
  clearDropHighlight() {
    if (this.dropTarget) {
      this.dropTarget.classList.remove(DROP_HIGHLIGHT_CLASS)
      this.dropTarget = null
    }

    this.nestTargetCollection = null
  },
  clearExpandTimer() {
    if (this.expandTimer) {
      clearTimeout(this.expandTimer)
      this.expandTimer = null
    }

    this.expandTargetId = null
  },
  scheduleExpand(collection) {
    if (collection === this.draggedItem) return

    const details = collection.querySelector("details")

    if (!details || details.open) return

    const collectionId = collection.id.replace("collection-", "")

    if (this.expandTargetId === collectionId && this.expandTimer) return

    this.clearExpandTimer()
    this.expandTargetId = collectionId

    this.expandTimer = setTimeout(() => {
      this.expandTimer = null
      this.expandTargetId = null
      this.expandCollectionForDrop(collection)
    }, AUTO_EXPAND_DELAY_MS)
  },
  expandCollectionForDrop(collection) {
    const details = collection.querySelector("details")

    if (!details || details.open) return

    details.open = true

    const collectionId = collection.id.replace("collection-", "")

    if (collectionId) this.autoExpandedIds.add(collectionId)

    collectionSortContainers(this.el).forEach((el) => {
      if (this.sortables.some((sortable) => sortable.el === el)) return

      this.sortables.push(this.createCollectionSortable(el))
    })

    this.unbindDropHighlight()
    this.bindDropHighlight()
  },
  syncAutoExpandedCollections() {
    for (const id of this.autoExpandedIds) {
      this.pushEvent("expand_collection", {id})
    }

    this.autoExpandedIds.clear()
  },
  onCollectionEnter(event) {
    const collection = event.currentTarget

    if (collection !== this.draggedItem) {
      this.setDropHighlight(collection)
      this.scheduleExpand(collection)
    }
  },
  onCollectionLeave(event) {
    const collection = event.currentTarget
    const related = event.relatedTarget

    if (related && collection.contains(related)) return

    const summary = collection.querySelector("details > summary")

    if (this.dropTarget === summary) {
      this.clearDropHighlight()
    }

    if (this.expandTargetId === collection.id.replace("collection-", "")) {
      this.clearExpandTimer()
    }
  },
  bindDropHighlight() {
    this.sortableCollections().forEach((collection) => {
      if (collection === this.draggedItem) return

      collection.addEventListener("dragenter", this.onCollectionEnter)
      collection.addEventListener("dragleave", this.onCollectionLeave)
    })
  },
  unbindDropHighlight() {
    this.sortableCollections().forEach((collection) => {
      collection.removeEventListener("dragenter", this.onCollectionEnter)
      collection.removeEventListener("dragleave", this.onCollectionLeave)
    })
  },
  childCollectionIds(collection) {
    const childZone = collection.querySelector("details > [data-collection-sortable]")

    if (!childZone) return []

    return this.orderedCollectionIds(childZone)
  },
  nestTargetParentId(collection) {
    return collection.dataset.nestParentId
  },
  pushNestMove(hook, movedId, nestTarget, copyMode) {
    const parentId = hook.nestTargetParentId(nestTarget)
    const childIds = hook.childCollectionIds(nestTarget).filter((id) => id !== movedId)
    const payload = {
      id: movedId,
      parent_id: parentId,
      ordered_ids: [movedId, ...childIds],
    }

    hook.pushEvent(copyMode ? "copy_collection" : "move_collection", payload)
  },
  ensureNestTargetExpanded(collection) {
    const details = collection.querySelector("details")

    if (!details || details.open) return

    details.open = true

    const collectionId = collection.id.replace("collection-", "")

    if (collectionId) {
      this.pushEvent("expand_collection", {id: collectionId})
    }
  },
  orderedCollectionIds(container) {
    return Array.from(container.children)
      .filter((child) => child.id?.startsWith("collection-"))
      .map((child) => child.id.replace("collection-", ""))
  },
  createCollectionSortable(el) {
    const hook = this

    return new Sortable(el, {
      group: COLLECTIONS_GROUP,
      animation: 150,
      draggable: "> li[id^='collection-']",
      handle: "li[id^='collection-'] > details > summary, li[id^='collection-'][data-revoked='true'] > .collection-tree-row",
      filter: "button, input, textarea, select, a, #collections-empty-state",
      preventOnFilter: true,
      fallbackOnBody: true,
      swapThreshold: 0.4,
      invertSwap: true,
      ...sortableSpillOptions(hook),
      onMove(event) {
        const {dragged, to, from} = event

        if (hook.copyMode) {
          return sortZoneAcceptsCollectionCopy(to)
        }

        if (isCollaborationMount(dragged)) {
          return to.dataset.parentId === "root"
        }

        if (from.dataset.readonly === "true" || dragged.dataset.readonly === "true") {
          return false
        }

        return sortZoneAcceptsCollections(to)
      },
      onStart(event) {
        hook.spilled = false
        hook.draggedItem = event.item
        startCopyDragMode(hook, event)

        if (!isCollaborationMount(event.item) || hook.copyMode) {
          hook.bindDropHighlight()
        }
      },
      onEnd(event) {
        const spilled = hook.spilled
        const copyMode = hook.copyMode
        hook.spilled = false
        const nestTarget = hook.nestTargetCollection
        const movedId = event.item.id.replace("collection-", "")

        if (nestTarget && nestTarget !== event.item) {
          if (!copyMode && (!collectionAcceptsDrops(nestTarget) || isCollaborationMount(event.item))) {
            revertSortableItem(event)
            finishCollectionDragUi(hook, {spilled: true})
            return
          }

          if (copyMode && !collectionAcceptsDrops(nestTarget)) {
            revertSortableItem(event)
            finishCollectionDragUi(hook, {spilled: true})
            return
          }

          if (copyMode) revertSortableItem(event)
          finishCollectionDragUi(hook)
          hook.ensureNestTargetExpanded(nestTarget)
          hook.pushNestMove(hook, movedId, nestTarget, copyMode)
          return
        }

        if (spilled) {
          revertSortableItem(event)
          finishCollectionDragUi(hook, {spilled: true})
          return
        }

        if (!copyMode && collectionDraggedFromReadonly(event.item, event.from)) {
          revertSortableItem(event)
          finishCollectionDragUi(hook, {spilled: true})
          return
        }

        if (copyMode) revertSortableItem(event)
        finishCollectionDragUi(hook)

        if (event.from === event.to && event.oldIndex === event.newIndex) return

        const targetContainer = event.to

        if (copyMode && !sortZoneAcceptsCollectionCopy(targetContainer)) {
          return
        }

        const orderedIds = hook.orderedCollectionIds(targetContainer)
        const payload = {
          id: movedId,
          parent_id: targetContainer.dataset.parentId,
          ordered_ids: orderedIds,
        }

        hook.pushEvent(copyMode ? "copy_collection" : "move_collection", payload)
      },
    })
  },
  initSortables() {
    this.sortables = []

    collectionSortContainers(this.el).forEach((el) => {
      if (this.sortables.some((sortable) => sortable.el === el)) return

      this.sortables.push(this.createCollectionSortable(el))
    })
  },
  destroySortables() {
    this.unbindDropHighlight()
    this.clearDropHighlight()
    this.clearExpandTimer()
    this.autoExpandedIds.clear()
    this.nestTargetCollection = null
    this.draggedItem = null

    if (this.sortables) {
      this.sortables.forEach((sortable) => sortable.destroy())
    }

    this.sortables = []
  },
}

const BookmarkSort = {
  mounted() {
    this.sortable = null
    this.dropTarget = null
    this.dropTargetCollection = null
    this.expandTimer = null
    this.expandTargetId = null
    this.autoExpandedIds = new Set()
    this.onCollectionEnter = this.onCollectionEnter.bind(this)
    this.onCollectionLeave = this.onCollectionLeave.bind(this)
    this.initSortable()
  },
  updated() {
    this.destroySortable()
    this.initSortable()
  },
  destroyed() {
    this.destroySortable()
  },
  sidebar() {
    return sidebarRoot(this.el)
  },
  sortableCollections() {
    return this.sidebar().querySelectorAll("li[id^='collection-']")
  },
  setDropHighlight(collection) {
    if (!collectionAcceptsDrops(collection)) return

    const summary = collection.querySelector("details > summary")

    if (this.dropTarget === summary) return

    this.clearDropHighlight()

    if (summary) {
      summary.classList.add(DROP_HIGHLIGHT_CLASS)
      this.dropTarget = summary
      this.dropTargetCollection = collection
    }
  },
  clearDropHighlight() {
    if (this.dropTarget) {
      this.dropTarget.classList.remove(DROP_HIGHLIGHT_CLASS)
      this.dropTarget = null
    }

    this.dropTargetCollection = null
  },
  clearExpandTimer() {
    if (this.expandTimer) {
      clearTimeout(this.expandTimer)
      this.expandTimer = null
    }

    this.expandTargetId = null
  },
  scheduleExpand(collection) {
    const details = collection.querySelector("details")

    if (!details || details.open) return

    const collectionId = collection.id.replace("collection-", "")

    if (this.expandTargetId === collectionId && this.expandTimer) return

    this.clearExpandTimer()
    this.expandTargetId = collectionId

    this.expandTimer = setTimeout(() => {
      this.expandTimer = null
      this.expandTargetId = null
      this.expandCollectionForDrop(collection)
    }, AUTO_EXPAND_DELAY_MS)
  },
  expandCollectionForDrop(collection) {
    const details = collection.querySelector("details")

    if (!details || details.open) return

    details.open = true

    const collectionId = collection.id.replace("collection-", "")

    if (collectionId) this.autoExpandedIds.add(collectionId)

    this.unbindDropHighlight()
    this.bindDropHighlight()
  },
  syncAutoExpandedCollections() {
    for (const id of this.autoExpandedIds) {
      this.pushEvent("expand_collection", {id})
    }

    this.autoExpandedIds.clear()
  },
  onCollectionEnter(event) {
    const collection = event.currentTarget.closest("li[id^='collection-']")

    if (!collection) return

    this.setDropHighlight(collection)
    this.scheduleExpand(collection)
  },
  onCollectionLeave(event) {
    const summary = event.currentTarget
    const collection = summary.closest("li[id^='collection-']")
    const related = event.relatedTarget

    if (related && summary.contains(related)) return

    if (this.dropTarget === summary) {
      this.clearDropHighlight()
    }

    if (collection && this.expandTargetId === collection.id.replace("collection-", "")) {
      this.clearExpandTimer()
    }
  },
  bindDropHighlight() {
    this.sortableCollections().forEach((collection) => {
      const summary = collection.querySelector(":scope > details > summary")

      if (!summary) return

      summary.addEventListener("dragenter", this.onCollectionEnter)
      summary.addEventListener("dragleave", this.onCollectionLeave)
    })
  },
  unbindDropHighlight() {
    this.sortableCollections().forEach((collection) => {
      const summary = collection.querySelector(":scope > details > summary")

      if (!summary) return

      summary.removeEventListener("dragenter", this.onCollectionEnter)
      summary.removeEventListener("dragleave", this.onCollectionLeave)
    })
  },
  bookmarkIdsInCollection(collection) {
    const collectionId = collection.dataset.bookmarkCollectionId
    const zone = collectionId && collection.querySelector(`#nested-zone-${collectionId}`)

    if (!zone || zone.classList.contains("collection-bookmark-drop-hidden")) return []

    return this.orderedBookmarkIds(zone)
  },
  ensureDropTargetExpanded(collection) {
    const details = collection.querySelector("details")

    if (!details || details.open) return

    details.open = true

    const collectionId = collection.id.replace("collection-", "")

    if (collectionId) {
      this.pushEvent("expand_collection", {id: collectionId})
    }
  },
  pushBookmarkNestMove(hook, movedId, targetCollection, copyMode) {
    if (!collectionAcceptsDrops(targetCollection)) return

    const collectionId = targetCollection.dataset.bookmarkCollectionId
    const bookmarkIds = hook.bookmarkIdsInCollection(targetCollection).filter((id) => id !== movedId)
    const payload = {
      id: movedId,
      collection_id: collectionId,
      ordered_ids: [movedId, ...bookmarkIds],
    }

    hook.pushEvent(copyMode ? "copy_bookmark" : "move_bookmark", payload)
  },
  orderedBookmarkIds(container) {
    return Array.from(container.children)
      .filter((child) => child.id?.startsWith("bookmark-"))
      .map((child) => child.id.replace("bookmark-", ""))
  },
  finishDrag(hook, {spilled = false} = {}) {
    finishBookmarkDragUi(hook, {spilled})
  },
  initSortable() {
    const hook = this

    if (this.el.dataset.readonly === "true") return

    this.sortable = new Sortable(this.el, {
      group: BOOKMARKS_GROUP,
      animation: 150,
      draggable: "> li[id^='bookmark-']",
      filter: "input, textarea, select, a, label, #inbox-empty-state",
      preventOnFilter: true,
      fallbackOnBody: true,
      ...bookmarkSpillOptions(hook),
      onMove(event) {
        return event.to.dataset.readonly !== "true"
      },
      onStart(event) {
        hook.spilled = false
        startCopyDragMode(hook, event)
        hook.bindDropHighlight()
      },
      onEnd(event) {
        const spilled = hook.spilled
        const copyMode = hook.copyMode
        hook.spilled = false
        const targetCollection = hook.dropTargetCollection
        const movedId = event.item.id.replace("bookmark-", "")

        if (targetCollection) {
          if (!collectionAcceptsDrops(targetCollection)) {
            revertSortableItem(event)
            hook.finishDrag(hook, {spilled: true})
            return
          }

          if (copyMode) revertSortableItem(event)
          hook.finishDrag(hook)
          hook.ensureDropTargetExpanded(targetCollection)
          hook.pushBookmarkNestMove(hook, movedId, targetCollection, copyMode)
          return
        }

        if (spilled) {
          hook.finishDrag(hook, {spilled: true})
          return
        }

        if (copyMode) revertSortableItem(event)
        hook.finishDrag(hook)

        if (event.from === event.to && event.oldIndex === event.newIndex) return

        const payload = {
          id: movedId,
          collection_id: event.to.dataset.collectionId,
          ordered_ids: hook.orderedBookmarkIds(event.to),
        }

        hook.pushEvent(copyMode ? "copy_bookmark" : "move_bookmark", payload)
      },
    })
  },
  destroySortable() {
    this.unbindDropHighlight()
    this.clearDropHighlight()
    this.clearExpandTimer()
    this.autoExpandedIds.clear()
    this.dropTargetCollection = null

    if (this.sortable) {
      this.sortable.destroy()
      this.sortable = null
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocketPath =
  document.querySelector("meta[name='live-socket-path']")?.getAttribute("content") || "/live"
const liveSocket = new LiveSocket(liveSocketPath, Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CollectionSort, BookmarkSort},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

window.addEventListener("phx:copy", (event) => {
  const text = event.detail?.text

  if (!text) return

  navigator.clipboard.writeText(text).catch(() => {})
})

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
