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
import {hooks as colocatedHooks} from "phoenix-colocated/intellectual_club"
import topbar from "../vendor/topbar"
import {copyRichTextWithFallback} from "./clipboard"
import {renderMessages, markdownToHtml} from "./chat_renderer"

const decodeBase64Utf8 = (base64) => {
  try {
    const binary = atob(base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return new TextDecoder().decode(bytes)
  } catch (_error) {
    return ""
  }
}

const formatLocalTime = (iso) => {
  if (!iso) return null
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return null

  return new Intl.DateTimeFormat(undefined, {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(date)
}

const sameCalendarDay = (left, right) =>
  left.getFullYear() === right.getFullYear() &&
  left.getMonth() === right.getMonth() &&
  left.getDate() === right.getDate()

const formatLocalTimeRelative = (iso) => {
  if (!iso) return null
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return null

  const now = new Date()
  const yesterday = new Date(now)
  yesterday.setDate(yesterday.getDate() - 1)

  const timePart = new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(date)

  if (sameCalendarDay(date, now)) return `Today, ${timePart}`
  if (sameCalendarDay(date, yesterday)) return `Yesterday, ${timePart}`

  const datePart = new Intl.DateTimeFormat(undefined, {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date)

  return `${datePart}, ${timePart}`
}

const renderLocalTimes = (root) => {
  const scope = root || document
  scope.querySelectorAll(".js-local-time[data-utc]").forEach((node) => {
    const iso = node.getAttribute("data-utc")
    const localStyle = node.getAttribute("data-local-style")
    const formatted =
      localStyle === "relative" ? formatLocalTimeRelative(iso) : formatLocalTime(iso)
    if (!formatted) return

    node.textContent = formatted
    if (iso) node.setAttribute("title", iso)
  })
}

const serializeFormState = (formEl) => {
  const formData = new FormData(formEl)
  const entries = []

  for (const [name, value] of formData.entries()) {
    if (name.startsWith("_")) continue

    if (value instanceof File) {
      entries.push([name, `${value.name}:${value.size}:${value.type}`])
    } else {
      entries.push([name, String(value)])
    }
  }

  entries.sort((a, b) => {
    const [nameA, valueA] = a
    const [nameB, valueB] = b
    if (nameA !== nameB) return nameA.localeCompare(nameB)
    return valueA.localeCompare(valueB)
  })

  return JSON.stringify(entries)
}

const hooks = {
  ...colocatedHooks,
  CopyMessage: {
    mounted() {
      this.copying = false

      this.onClick = async (event) => {
        event.preventDefault()
        event.stopPropagation()

        if (this.copying) return
        this.copying = true

        try {
          const plainText = decodeBase64Utf8(this.el.dataset.copyTextB64 || "")
          const targetSelector =
            typeof this.el.dataset.copyTarget === "string" ? this.el.dataset.copyTarget : ""
          const messageId = this.el.dataset.messageId

          const target = targetSelector ? document.querySelector(targetSelector) : null
          const htmlFragment = target ? target.innerHTML : ""

          const htmlDoc = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><div>${htmlFragment}</div></body></html>`

          const copied = await copyRichTextWithFallback(plainText, htmlDoc)

          if (copied && messageId) {
            this.pushEvent("copy_message", {message_id: messageId})
          }
        } finally {
          this.copying = false
        }
      }

      this.el.addEventListener("click", this.onClick)
    },
    destroyed() {
      this.el.removeEventListener("click", this.onClick)
    },
  },
  LocalTime: {
    mounted() {
      renderLocalTimes(this.el)
    },
    updated() {
      renderLocalTimes(this.el)
    },
  },
  ChatView: {
    mounted() {
      this.panelStorageKey = "chat_panels_state_v1"
      this.mobileQuery = window.matchMedia("(max-width: 900px)")
      this.visualViewport = window.visualViewport || null
      // Chat ID derived from the page URL (e.g. /chats/7).
      this.chatId = this._parseChatId()
      // Last chat state received from server (used for client-side re-renders).
      this.chatState = null
      // Saved draft text so we can restore it after re-renders.
      this.savedDraft = ""
      this.state = {
        leftOpen: true,
        rightOpen: true,
        leftTab: this.el.dataset.defaultLeftTab === "prompt" ? "prompt" : "messages",
        isMobile: this.mobileQuery.matches,
      }
      this.desktopState = {
        leftOpen: true,
        rightOpen: true,
      }

      this.restoreState()
      this.cacheNodes()

      this.scrollToLastMessageTop = (behavior = "auto") => {
        if (!this.chatScroller) return

        const messages = this.chatScroller.querySelectorAll('[id^="message-"]')
        const lastMessage = messages.length ? messages[messages.length - 1] : null
        if (!lastMessage) return

        try {
          const scrollerRect = this.chatScroller.getBoundingClientRect()
          const messageRect = lastMessage.getBoundingClientRect()
          const nextTop = messageRect.top - scrollerRect.top + this.chatScroller.scrollTop

          this.chatScroller.scrollTo({
            top: nextTop,
            behavior,
          })
        } catch (_error) {
          // Ignore scroll issues.
        }
      }

      this.scrollToLastMessageTopSoon = () => {
        const raf = window.requestAnimationFrame || ((cb) => setTimeout(cb, 0))
        raf(() => {
          this.scrollToLastMessageTop("auto")
          raf(() => this.scrollToLastMessageTop("auto"))
        })
      }

      this.applyState()
      this.el.classList.add("chat-view-ready")
      this.syncViewportHeight()
      renderLocalTimes(this.el)

      // ── Restore cached state for instant remount ──
      this._restoreFromCache()

      // ── Submit handler for client-rendered forms ──
      this.onSubmit = (event) => {
        const form = event.target
        if (!form || !form.matches) return
        if (!this.chatScroller || !this.chatScroller.contains(form)) return

        const action = form.dataset.action
        if (action === "send-form") {
          event.preventDefault()
          this.handleSendForm(form)
        } else if (action === "save-edit") {
          event.preventDefault()
          const textarea = form.querySelector("textarea[name='content']")
          const content = textarea ? textarea.value : ""
          this.pushEvent("save_edit_message", {
            message_id: form.dataset.messageId,
            edit_message: { content },
          })
        }
      }
      this.el.addEventListener("submit", this.onSubmit)

      // ── Click handler for panels, tabs, AND message actions ──
      this.onClick = (event) => {
        // Panel actions
        const actionTarget = event.target.closest("[data-panel-action]")
        if (actionTarget && this.el.contains(actionTarget)) {
          event.preventDefault()
          this.handlePanelAction(actionTarget.getAttribute("data-panel-action"))
          return
        }

        // Left tab buttons
        const tabTarget = event.target.closest("[data-left-tab-target]")
        if (tabTarget && this.el.contains(tabTarget)) {
          event.preventDefault()
          const nextTab = tabTarget.getAttribute("data-left-tab-target")
          if (nextTab === "messages" || nextTab === "prompt") {
            this.state.leftTab = nextTab
            this.persistState()
            this.applyState()
          }
          return
        }

        // Message area actions (client-rendered buttons with data-action)
        const actionEl = event.target.closest("[data-action]")
        if (actionEl && this.chatScroller && this.chatScroller.contains(actionEl)) {
          this.handleMessageAction(event, actionEl)
        }
      }

      this.onViewportChange = (event) => {
        const nextIsMobile = Boolean(event.matches)
        if (nextIsMobile === this.state.isMobile) return

        if (nextIsMobile) {
          this.desktopState.leftOpen = this.state.leftOpen
          this.desktopState.rightOpen = this.state.rightOpen
          this.state.leftOpen = false
          this.state.rightOpen = false
        } else {
          this.state.leftOpen = this.desktopState.leftOpen
          this.state.rightOpen = this.desktopState.rightOpen
        }

        this.state.isMobile = nextIsMobile
        this.persistState()
        this.applyState()
        this.syncViewportHeight()
      }

      this.onResize = () => {
        this.syncViewportHeight()
      }

      this.onViewportResize = () => {
        this.syncViewportHeight()
      }

      this.el.addEventListener("click", this.onClick)
      window.addEventListener("resize", this.onResize)
      if (this.visualViewport && this.visualViewport.addEventListener) {
        this.visualViewport.addEventListener("resize", this.onViewportResize)
        this.visualViewport.addEventListener("scroll", this.onViewportResize)
      }

      if (this.mobileQuery.addEventListener) {
        this.mobileQuery.addEventListener("change", this.onViewportChange)
      } else {
        this.mobileQuery.addListener(this.onViewportChange)
      }

      // ── Chat state event: full re-render of messages ──
      this.handleEvent("chat_state", (payload) => {
        // Detect if this is a reconnect re-mount with identical data.
        const isReconnect = this._isIdenticalState(this.chatState, payload)
        this.chatState = payload
        this._saveToCache(payload)

        if (isReconnect) {
          // Data unchanged: skip full re-render, just refresh streaming if needed
          this._patchAfterReconnect(payload)
        } else {
          this.renderChatMessages(payload)
        }
      })

      // ── Streaming update: patch single message content ──
      this.handleEvent("streaming_update", ({ message_id, content, reasoning }) => {
        if (!this.chatScroller) return

        if (content != null) {
          const contentEl = this.chatScroller.querySelector(`#message-content-${message_id}`)
          if (contentEl) {
            if (!content) {
              contentEl.innerHTML = '<span class="text-zinc-500">Generating...</span>'
            } else {
              contentEl.innerHTML = markdownToHtml(content)
            }
          }
        }

        if (reasoning != null) {
          const reasoningEl = this.chatScroller.querySelector(`#message-reasoning-${message_id}`)
          if (reasoningEl) {
            if (!reasoning) {
              reasoningEl.innerHTML = '<span class="text-zinc-500">No reasoning yet...</span>'
            } else {
              reasoningEl.innerHTML = markdownToHtml(reasoning)
            }
          }
        }

        // Keep cache up to date with streaming state
        if (this.chatState) {
          if (content != null) this.chatState.streaming_content = content
          if (reasoning != null) this.chatState.streaming_reasoning = reasoning
          this._saveToCache(this.chatState)
        }
      })

      // ── Clear draft event ──
      this.handleEvent("chat_clear_draft", (payload) => {
        this.savedDraft = ""
        this._saveDraftToCache("")
        const targetId = payload && typeof payload.id === "string" ? payload.id : null
        const draftEl = this.chatScroller && this.chatScroller.querySelector("#chat-draft")
        if (draftEl) {
          if (targetId && draftEl.id !== targetId) return
          draftEl.value = ""
        }
      })

      // ── Save draft & scroll on visibility change (for tab backgrounding) ──
      this.onVisibilityChange = () => {
        if (document.visibilityState === "hidden") {
          this._snapshotVolatileState()
        }
      }
      document.addEventListener("visibilitychange", this.onVisibilityChange)
    },
    destroyed() {
      // Snapshot before destruction so the next mount can restore.
      this._snapshotVolatileState()

      this.el.removeEventListener("click", this.onClick)
      this.el.removeEventListener("submit", this.onSubmit)
      window.removeEventListener("resize", this.onResize)
      document.removeEventListener("visibilitychange", this.onVisibilityChange)
      if (this.visualViewport && this.onViewportResize) {
        this.visualViewport.removeEventListener("resize", this.onViewportResize)
        this.visualViewport.removeEventListener("scroll", this.onViewportResize)
      }
      if (!this.mobileQuery || !this.onViewportChange) return

      if (this.mobileQuery.removeEventListener) {
        this.mobileQuery.removeEventListener("change", this.onViewportChange)
      } else {
        this.mobileQuery.removeListener(this.onViewportChange)
      }
    },

    // ── Render chat messages from server state ──
    renderChatMessages(payload) {
      if (!this.chatScroller) {
        this.cacheNodes()
      }
      if (!this.chatScroller) return

      // Save scroll position and draft before re-render
      const prevScrollTop = this.chatScroller.scrollTop
      const prevScrollHeight = this.chatScroller.scrollHeight
      const prevMessageCount = this.chatScroller.querySelectorAll('[id^="message-"]').length

      const draftEl = this.chatScroller.querySelector("#chat-draft")
      if (draftEl) {
        this.savedDraft = draftEl.value || ""
      }

      // Render
      renderMessages(this.chatScroller, payload)

      // Restore draft
      const newDraftEl = this.chatScroller.querySelector("#chat-draft")
      if (newDraftEl && this.savedDraft) {
        newDraftEl.value = this.savedDraft
      }

      // Bind Ctrl+Enter on the composer
      this.bindComposerKeys()

      // Render local times
      renderLocalTimes(this.chatScroller)

      // Scroll logic: if new messages were added, scroll to bottom.
      // Otherwise, preserve scroll position.
      const newMessageCount = this.chatScroller.querySelectorAll('[id^="message-"]').length
      if (newMessageCount > prevMessageCount) {
        this.scrollToLastMessageTopSoon()
      } else {
        // Try to keep the same position (content may have changed height)
        const heightDelta = this.chatScroller.scrollHeight - prevScrollHeight
        this.chatScroller.scrollTop = prevScrollTop + Math.max(0, heightDelta)
      }
    },

    // ── Bind Ctrl+Enter on textarea ──
    bindComposerKeys() {
      const textarea = this.chatScroller && this.chatScroller.querySelector("#chat-draft")
      if (!textarea || textarea._chatComposerBound) return

      textarea._chatComposerBound = true
      textarea.addEventListener("keydown", (event) => {
        if (event.isComposing) return
        if (event.key !== "Enter") return
        if (!(event.ctrlKey || event.metaKey)) return
        if (event.altKey) return

        // Find the send form and submit
        const form = textarea.closest("form") || this.chatScroller.querySelector('[data-action="send-form"]')
        if (!form) return

        const submitButton = form.querySelector('button[type="submit"]')
        if (!submitButton || submitButton.disabled) return

        event.preventDefault()
        event.stopPropagation()

        // Submit via the LiveView pushEvent mechanism
        this.handleSendForm(form)
      })
    },

    // ── Handle message area actions ──
    handleMessageAction(event, actionEl) {
      const action = actionEl.dataset.action
      const messageId = actionEl.dataset.messageId
      const direction = actionEl.dataset.direction

      switch (action) {
        case "toggle-working":
          event.preventDefault()
          this.pushEvent("toggle_working", { message_id: messageId })
          break

        case "copy-message": {
          event.preventDefault()
          const plainText = decodeBase64Utf8(actionEl.dataset.copyTextB64 || "")
          const targetSelector = actionEl.dataset.copyTarget || ""
          const target = targetSelector ? document.querySelector(targetSelector) : null
          const htmlFragment = target ? target.innerHTML : ""
          const htmlDoc = `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body><div>${htmlFragment}</div></body></html>`

          copyRichTextWithFallback(plainText, htmlDoc).then((copied) => {
            if (copied && messageId) {
              this.pushEvent("copy_message", { message_id: messageId })
            }
          })
          break
        }

        case "edit-message":
          event.preventDefault()
          this.pushEvent("start_edit_message", { message_id: messageId })
          break

        case "cancel-edit":
          event.preventDefault()
          this.pushEvent("cancel_edit_message", {})
          break

        case "save-edit": {
          event.preventDefault()
          const form = actionEl.closest("form") || actionEl
          const textarea = form.querySelector("textarea[name='content']")
          const content = textarea ? textarea.value : ""
          this.pushEvent("save_edit_message", {
            message_id: form.dataset.messageId,
            edit_message: { content },
          })
          break
        }

        case "branch-message":
          event.preventDefault()
          this.pushEvent("branch_message", { message_id: messageId })
          break

        case "delete-message":
          event.preventDefault()
          if (window.confirm("Delete this message?")) {
            this.pushEvent("delete_message", { message_id: messageId })
          }
          break

        case "switch-branch":
          event.preventDefault()
          this.pushEvent("switch_branch", {
            message_id: messageId,
            direction: direction,
          })
          break

        case "switch-branch-target":
          event.preventDefault()
          this.pushEvent("switch_branch_target", {
            message_id: messageId,
            target_id: actionEl.dataset.targetId,
          })
          break

        case "open-working-answer":
          event.preventDefault()
          this.pushEvent("open_working_answer", {
            message_id: messageId,
            item_id: actionEl.dataset.itemId,
          })
          break

        case "clear-reply-parent":
          event.preventDefault()
          this.pushEvent("clear_reply_parent", {})
          break

        case "cancel-generation":
          event.preventDefault()
          this.pushEvent("cancel", {})
          break

        case "send-form":
        case "submit-send":
          // Form submit is handled by the submit event listener
          break

        default:
          break
      }
    },

    // ── Handle send form submission ──
    handleSendForm(form) {
      const textarea = form.querySelector("#chat-draft")
      const draft = textarea ? textarea.value : ""
      this.savedDraft = ""
      this.pushEvent("send", { message: { draft } })
    },

    cacheNodes() {
      this.shell = this.el.querySelector("#chat-shell")
      this.leftPanel = this.el.querySelector('[data-panel="left"]')
      this.rightPanel = this.el.querySelector('[data-panel="right"]')
      this.chatScroller = this.el.querySelector(".chat-message-list")
      this.backdrop = this.el.querySelector(".chat-panel-backdrop")
      this.openLeftButtons = Array.from(this.el.querySelectorAll('[data-panel-action="open-left"]'))
      this.openRightButtons = Array.from(this.el.querySelectorAll('[data-panel-action="open-right"]'))
      this.closeLeftButtons = Array.from(this.el.querySelectorAll('[data-panel-action="close-left"]'))
      this.closeRightButtons = Array.from(this.el.querySelectorAll('[data-panel-action="close-right"]'))
      this.leftTabButtons = Array.from(this.el.querySelectorAll("[data-left-tab-target]"))
      this.leftTabPanels = Array.from(this.el.querySelectorAll("[data-left-tab-panel]"))
    },
    syncViewportHeight() {
      const rect = this.el.getBoundingClientRect()
      const main = this.el.closest("main")
      const paddingBottom = main ? Number.parseFloat(getComputedStyle(main).paddingBottom) || 0 : 0
      const bottomGap = paddingBottom + 12
      const viewportHeight = this.visualViewport?.height || window.innerHeight
      const available = Math.max(240, viewportHeight - rect.top - bottomGap)
      this.el.style.setProperty("--chat-view-height", `${available}px`)
    },
    setHidden(node, hidden) {
      if (!node) return
      node.classList.toggle("chat-panel-hidden", hidden)
      if ("hidden" in node) node.hidden = hidden
    },
    persistState() {
      try {
        if (!this.state.isMobile) {
          this.desktopState.leftOpen = this.state.leftOpen
          this.desktopState.rightOpen = this.state.rightOpen
        }

        localStorage.setItem(
          this.panelStorageKey,
          JSON.stringify({
            version: 1,
            leftOpen: this.desktopState.leftOpen,
            rightOpen: this.desktopState.rightOpen,
            leftTab: this.state.leftTab,
          }),
        )
      } catch (_error) {
        // Ignore persistence issues.
      }
    },
    restoreState() {
      try {
        const raw = localStorage.getItem(this.panelStorageKey)
        if (!raw) {
          if (this.state.isMobile) {
            this.state.leftOpen = false
            this.state.rightOpen = false
          }

          return
        }
        const parsed = JSON.parse(raw)
        if (parsed?.version !== 1) return

        if (typeof parsed.leftOpen === "boolean") this.desktopState.leftOpen = parsed.leftOpen
        if (typeof parsed.rightOpen === "boolean") this.desktopState.rightOpen = parsed.rightOpen
        if (parsed.leftTab === "messages" || parsed.leftTab === "prompt") {
          this.state.leftTab = parsed.leftTab
        }

        if (!this.state.isMobile) {
          this.state.leftOpen = this.desktopState.leftOpen
          this.state.rightOpen = this.desktopState.rightOpen
        } else {
          this.state.leftOpen = false
          this.state.rightOpen = false
        }
      } catch (_error) {
        // Ignore restore issues.
      }
    },
    shellColumns() {
      if (this.state.isMobile) return "1fr"
      if (this.state.leftOpen && this.state.rightOpen) {
        return "260px minmax(0, 1fr) 260px"
      }
      if (this.state.leftOpen) return "260px minmax(0, 1fr)"
      if (this.state.rightOpen) return "minmax(0, 1fr) 260px"
      return "minmax(0, 1fr)"
    },
    applyState() {
      this.setHidden(this.leftPanel, !this.state.leftOpen)
      this.setHidden(this.rightPanel, !this.state.rightOpen)

      const mobileBackdropVisible = this.state.isMobile && (this.state.leftOpen || this.state.rightOpen)
      this.setHidden(this.backdrop, !mobileBackdropVisible)

      this.openLeftButtons.forEach((button) => {
        const hidden = this.state.leftOpen
        this.setHidden(button, hidden)
      })

      this.openRightButtons.forEach((button) => {
        const hidden = this.state.rightOpen
        this.setHidden(button, hidden)
      })

      this.closeLeftButtons.forEach((button) => {
        const hidden = !this.state.leftOpen
        this.setHidden(button, hidden)
      })

      this.closeRightButtons.forEach((button) => {
        const hidden = !this.state.rightOpen
        this.setHidden(button, hidden)
      })

      this.leftTabButtons.forEach((button) => {
        const tab = button.getAttribute("data-left-tab-target")
        const active = tab === this.state.leftTab
        button.classList.toggle("chat-tab-active", active)
        button.setAttribute("aria-selected", active ? "true" : "false")
        button.tabIndex = active ? 0 : -1
      })

      this.leftTabPanels.forEach((panel) => {
        const tab = panel.getAttribute("data-left-tab-panel")
        this.setHidden(panel, tab !== this.state.leftTab)
      })

      if (this.shell) this.shell.style.gridTemplateColumns = this.shellColumns()
    },
    handlePanelAction(action) {
      switch (action) {
        case "open-left":
          this.state.leftOpen = true
          if (this.state.isMobile) this.state.rightOpen = false
          break
        case "open-right":
          this.state.rightOpen = true
          if (this.state.isMobile) this.state.leftOpen = false
          break
        case "close-left":
          this.state.leftOpen = false
          break
        case "close-right":
          this.state.rightOpen = false
          break
        case "close-all":
          this.state.leftOpen = false
          this.state.rightOpen = false
          break
        default:
          return
      }

      this.persistState()
      this.applyState()
    },

    // ── Window-level cache for surviving remounts ──

    _cacheKey() {
      return this.chatId ? `__chatViewCache_${this.chatId}` : null
    },

    _parseChatId() {
      // Extract chat ID from URL: /chats/7
      const match = window.location.pathname.match(/\/chats\/(\d+)/)
      return match ? match[1] : null
    },

    _getCache() {
      const key = this._cacheKey()
      if (!key) return null
      try {
        return window[key] || null
      } catch (_e) {
        return null
      }
    },

    _saveToCache(chatState) {
      const key = this._cacheKey()
      if (!key) return
      try {
        if (!window[key]) window[key] = {}
        window[key].chatState = chatState
        window[key].ts = Date.now()
      } catch (_e) {
        // Ignore.
      }
    },

    _saveDraftToCache(draft) {
      const key = this._cacheKey()
      if (!key) return
      try {
        if (!window[key]) window[key] = {}
        window[key].draft = draft
      } catch (_e) {
        // Ignore.
      }
    },

    _saveScrollToCache(scrollTop) {
      const key = this._cacheKey()
      if (!key) return
      try {
        if (!window[key]) window[key] = {}
        window[key].scrollTop = scrollTop
      } catch (_e) {
        // Ignore.
      }
    },

    /**
     * Snapshot draft & scroll position into the cache. Called on
     * visibilitychange(hidden) and destroyed() so the next mount
     * can restore them.
     */
    _snapshotVolatileState() {
      if (this.chatScroller) {
        this._saveScrollToCache(this.chatScroller.scrollTop)
        const draftEl = this.chatScroller.querySelector("#chat-draft")
        if (draftEl) {
          this.savedDraft = draftEl.value || ""
          this._saveDraftToCache(this.savedDraft)
        }
      }
    },

    /**
     * On mount, try to immediately render from cache so the user
     * sees content before the server push arrives.
     */
    _restoreFromCache() {
      const cache = this._getCache()
      if (!cache) return

      // Restore draft
      if (typeof cache.draft === "string") {
        this.savedDraft = cache.draft
      }

      // Restore chat state (render messages from cache)
      if (cache.chatState) {
        this.chatState = cache.chatState
        this.renderChatMessages(cache.chatState)

        // Restore scroll position after cache render
        if (typeof cache.scrollTop === "number" && this.chatScroller) {
          const raf = window.requestAnimationFrame || ((cb) => setTimeout(cb, 0))
          raf(() => {
            if (this.chatScroller) {
              this.chatScroller.scrollTop = cache.scrollTop
            }
          })
        }
      }
    },

    /**
     * Check if a new server state is identical to the current cached
     * state. Used to skip full re-renders on reconnect.
     */
    _isIdenticalState(prev, next) {
      if (!prev || !next) return false

      // Compare message IDs, status and content.
      const prevMsgs = prev.messages || []
      const nextMsgs = next.messages || []

      if (prevMsgs.length !== nextMsgs.length) return false

      for (let i = 0; i < prevMsgs.length; i++) {
        const pm = prevMsgs[i]
        const nm = nextMsgs[i]
        if (pm.id !== nm.id) return false
        if (pm.status !== nm.status) return false
        if (pm.content !== nm.content) return false
      }

      // Compare all UI state that affects rendering.
      if (prev.generating_message_id !== next.generating_message_id) return false
      if (prev.editing_message_id !== next.editing_message_id) return false
      if (prev.has_reply_parent !== next.has_reply_parent) return false
      if (prev.reply_parent_id !== next.reply_parent_id) return false
      if (prev.copied_message_id !== next.copied_message_id) return false

      // Compare working_open_by_id (object of {messageId: bool}).
      if (JSON.stringify(prev.working_open_by_id || {}) !== JSON.stringify(next.working_open_by_id || {})) return false

      return true
    },

    /**
     * After a reconnect where the message list hasn't changed, just
     * update the streaming content if generation is active.
     */
    _patchAfterReconnect(payload) {
      if (!this.chatScroller) return

      const genId = payload.generating_message_id
      if (!genId) return

      // Update streaming content from the fresh server state
      const contentEl = this.chatScroller.querySelector(`#message-content-${genId}`)
      if (contentEl) {
        const content = payload.streaming_content || ""
        if (!content) {
          contentEl.innerHTML = '<span class="text-zinc-500">Generating...</span>'
        } else {
          contentEl.innerHTML = markdownToHtml(content)
        }
      }

      const reasoningEl = this.chatScroller.querySelector(`#message-reasoning-${genId}`)
      if (reasoningEl) {
        const reasoning = payload.streaming_reasoning || ""
        if (!reasoning) {
          reasoningEl.innerHTML = '<span class="text-zinc-500">No reasoning yet...</span>'
        } else {
          reasoningEl.innerHTML = markdownToHtml(reasoning)
        }
      }
    },
  },
  NotebookTabs: {
    mounted() {
      this.activeTab = null
      this.initialTab = this.el.getAttribute("data-notebook-initial-tab")

      this.cacheNodes()

      this.onClick = (event) => {
        const tabButton = event.target.closest("[data-notebook-tab]")
        if (!tabButton || !this.el.contains(tabButton)) return

        event.preventDefault()
        this.setActive(tabButton.dataset.notebookTab)
      }

      this.el.addEventListener("click", this.onClick)

      const defaultTab = this.resolveDefaultTab(this.initialTab)
      this.setActive(defaultTab)
    },
    updated() {
      const previousTab = this.activeTab || this.initialTab
      this.cacheNodes()
      this.setActive(this.resolveDefaultTab(previousTab))
    },
    destroyed() {
      this.el.removeEventListener("click", this.onClick)
    },
    cacheNodes() {
      this.tabButtons = Array.from(this.el.querySelectorAll("[data-notebook-tab]"))
      this.panels = Array.from(this.el.querySelectorAll("[data-notebook-panel]"))
    },
    resolveDefaultTab(candidate) {
      if (candidate && this.tabButtons.some((button) => button.dataset.notebookTab === candidate)) {
        return candidate
      }

      return this.tabButtons[0]?.dataset.notebookTab || null
    },
    setActive(tabName) {
      if (!tabName) return

      this.activeTab = tabName

      this.tabButtons.forEach((button) => {
        const active = button.dataset.notebookTab === tabName
        button.classList.toggle("notebook-tab-active", active)
        button.setAttribute("aria-selected", active ? "true" : "false")
        button.tabIndex = active ? 0 : -1
      })

      this.panels.forEach((panel) => {
        const active = panel.dataset.notebookPanel === tabName
        panel.classList.toggle("notebook-panel-hidden", !active)
        panel.hidden = !active
      })
    },
  },
  DirtyForm: {
    mounted() {
      this.confirmMessage =
        this.el.getAttribute("data-dirty-confirm") ||
        "You have unsaved changes. Leave this page?"
      this.initialState = serializeFormState(this.el)
      this.submitting = false
      this.ignoreNextPopstate = false

      this.onSubmit = () => {
        this.submitting = true
      }

      this.onInput = () => {
        this.updateDirtyState()
      }

      this.onBeforeUnload = (event) => {
        if (!this.isDirty() || this.submitting) return
        event.preventDefault()
        event.returnValue = this.confirmMessage
      }

      this.onPageLoadingStop = () => {
        this.submitting = false
      }

      this.onPopstate = () => {
        if (this.ignoreNextPopstate) {
          this.ignoreNextPopstate = false
          return
        }

        if (!this.isDirty() || this.submitting) return

        if (!window.confirm(this.confirmMessage)) {
          this.ignoreNextPopstate = true
          window.history.forward()
        }
      }

      this.onDocumentClick = (event) => {
        if (!this.isDirty() || this.submitting) return
        if (event.defaultPrevented) return
        if (event.button !== 0) return
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

        const link = event.target.closest("a[href]")
        if (!link) return
        if (link.getAttribute("target") === "_blank") return
        if (link.hasAttribute("download")) return
        if (link.dataset.dirtyBypass === "true") return

        const href = link.getAttribute("href") || ""
        if (href.startsWith("#")) return

        if (!window.confirm(this.confirmMessage)) {
          event.preventDefault()
          event.stopImmediatePropagation()
        }
      }

      this.handleEvent("dirty_form_saved", ({form_id}) => {
        if (form_id && form_id !== this.el.id) return

        this.initialState = serializeFormState(this.el)
        this.submitting = false
        this.updateDirtyState()
      })

      this.el.addEventListener("submit", this.onSubmit)
      this.el.addEventListener("input", this.onInput)
      this.el.addEventListener("change", this.onInput)

      window.addEventListener("beforeunload", this.onBeforeUnload)
      window.addEventListener("popstate", this.onPopstate)
      window.addEventListener("phx:page-loading-stop", this.onPageLoadingStop)
      document.addEventListener("click", this.onDocumentClick, true)

      this.updateDirtyState()
    },
    updated() {
      this.updateDirtyState()
    },
    destroyed() {
      this.el.removeEventListener("submit", this.onSubmit)
      this.el.removeEventListener("input", this.onInput)
      this.el.removeEventListener("change", this.onInput)

      window.removeEventListener("beforeunload", this.onBeforeUnload)
      window.removeEventListener("popstate", this.onPopstate)
      window.removeEventListener("phx:page-loading-stop", this.onPageLoadingStop)
      document.removeEventListener("click", this.onDocumentClick, true)
    },
    isDirty() {
      return serializeFormState(this.el) !== this.initialState
    },
    updateDirtyState() {
      const formId = this.el.id
      if (!formId) return

      const dirty = this.isDirty()
      const saveButtons = document.querySelectorAll(
        `[data-dirty-form="${formId}"][data-dirty-role="save"]`
      )

      saveButtons.forEach((button) => {
        button.disabled = !dirty
      })
    },
  },
}

const installSoftLiveViewRecovery = (liveSocket) => {
  if (!liveSocket || typeof liveSocket.reloadWithJitter !== "function") return

  const socket = typeof liveSocket.getSocket === "function" ? liveSocket.getSocket() : null
  if (!socket || typeof socket.connect !== "function" || typeof socket.disconnect !== "function") return

  const originalReloadWithJitter = liveSocket.reloadWithJitter.bind(liveSocket)

  const isVisible = () => document.visibilityState === "visible"

  let softRecoveryInProgress = false
  let softRecoveryAttempts = 0
  let softRecoveryWindowStartedAt = 0
  let deferredRecovery = false
  let hardReloadFallbackTimer = null

  const SOFT_RECOVERY_WINDOW_MS = 300_000
  const MAX_SOFT_RECOVERY_ATTEMPTS = 5
  const HARD_RELOAD_FALLBACK_MS = 30_000
  const SOFT_CLOSE_CODE = 1001

  const resetSoftRecoveryWindowIfNeeded = () => {
    const now = Date.now()
    if (!softRecoveryWindowStartedAt || now - softRecoveryWindowStartedAt > SOFT_RECOVERY_WINDOW_MS) {
      softRecoveryWindowStartedAt = now
      softRecoveryAttempts = 0
    }
  }

  const mainViewConnected = () => {
    const main = liveSocket.main
    return main && typeof main.isConnected === "function" ? main.isConnected() : false
  }

  const scheduleHardReloadFallback = (view, log) => {
    clearTimeout(hardReloadFallbackTimer)

    hardReloadFallbackTimer = setTimeout(() => {
      if (!isVisible()) return

      const socketConnected =
        typeof liveSocket.isConnected === "function" ? liveSocket.isConnected() : false
      if (socketConnected && mainViewConnected()) return

      originalReloadWithJitter(view, log)
    }, HARD_RELOAD_FALLBACK_MS)
  }

  const softRecover = (view, log) => {
    resetSoftRecoveryWindowIfNeeded()

    if (!isVisible()) {
      deferredRecovery = true
      return
    }

    if (softRecoveryInProgress) return

    softRecoveryInProgress = true
    softRecoveryAttempts += 1

    // Disconnect & reconnect without a full page reload. This avoids losing scroll position
    // on browsers that aggressively suspend background tabs (notably Safari).
    try {
      socket.disconnect(
        () => {
          softRecoveryInProgress = false

          if (!isVisible()) {
            deferredRecovery = true
            return
          }

          socket.connect()
        },
        SOFT_CLOSE_CODE,
        "soft reconnect"
      )
    } catch (_error) {
      softRecoveryInProgress = false
      originalReloadWithJitter(view, log)
      return
    }

    scheduleHardReloadFallback(view, log)
  }

  liveSocket.reloadWithJitter = (view, log) => {
    // Keep the default behavior for pending navigation, otherwise links can get stuck.
    if (typeof liveSocket.hasPendingLink === "function" && liveSocket.hasPendingLink()) {
      originalReloadWithJitter(view, log)
      return
    }

    resetSoftRecoveryWindowIfNeeded()
    if (softRecoveryAttempts >= MAX_SOFT_RECOVERY_ATTEMPTS && isVisible()) {
      originalReloadWithJitter(view, log)
      return
    }

    softRecover(view, log)
  }

  const ensureConnectedWhenVisible = () => {
    if (!isVisible()) return

    if (deferredRecovery) {
      deferredRecovery = false
      softRecover(liveSocket.main, null)
      return
    }

    if (typeof socket.isConnected === "function" && !socket.isConnected()) {
      try {
        socket.connect()
      } catch (_error) {
        // Ignore and let LiveView handle recovery.
      }
    }
  }

  document.addEventListener("visibilitychange", ensureConnectedWhenVisible)

  // Prevent LiveView from force-reloading on bfcache restores (common on Safari). We can typically
  // recover by reconnecting the socket, which preserves scroll position.
  window.addEventListener(
    "pageshow",
    (event) => {
      if (!event.persisted) return
      event.stopImmediatePropagation()
      deferredRecovery = true
      ensureConnectedWhenVisible()
    },
    true
  )
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // Wait 20 minutes before considering the connection dead.  This works in
  // tandem with the server-side socket timeout (20 min) to keep the LiveView
  // process alive while mobile Safari suspends background tabs.
  disconnectedTimeout: 1_200_000,
  params: {_csrf_token: csrfToken},
  hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

installSoftLiveViewRecovery(liveSocket)

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
