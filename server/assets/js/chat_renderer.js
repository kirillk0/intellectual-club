/**
 * Client-side chat message renderer.
 *
 * Receives serialized message data from the LiveView and renders DOM nodes
 * entirely on the client.  This avoids LiveView re-rendering the whole message
 * list on every state change which caused scroll jumps and partial content
 * loads.
 */

import { marked } from "../vendor/marked.esm.js"
import DOMPurify from "../vendor/dompurify.esm.js"

// ── markdown ──────────────────────────────────────────────────────────

marked.setOptions({
  breaks: true,
  gfm: true,
})

const renderMarkdown = (text) => {
  if (!text) return ""
  const raw = marked.parse(text)
  return DOMPurify.sanitize(raw, {
    ALLOWED_TAGS: [
      "a","b","blockquote","br","code","del","div","em",
      "h1","h2","h3","h4","h5","h6","hr","i","li","ol",
      "p","pre","strong","table","tbody","td","th","thead",
      "tr","u","ul","span",
    ],
    ALLOWED_ATTR: ["href","target","rel","class","name","title"],
  })
}

const wrapTables = (html) => {
  if (!html.includes("<table")) return html
  if (html.includes("table-scroll")) return html
  return html
    .replace(/<table/g, '<div class="table-scroll"><table')
    .replace(/<\/table>/g, "</table></div>")
}

const markdownToHtml = (text) => wrapTables(renderMarkdown(text))

// ── button classes (matches core_components.ex) ──────────────────

const BTN_BASE = "inline-flex items-center justify-center gap-2 rounded-md px-3 py-2 text-sm font-medium shadow-sm transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 disabled:pointer-events-none disabled:opacity-50"
const BTN_DEFAULT = `${BTN_BASE} border border-zinc-300 bg-white text-zinc-900 hover:bg-zinc-50 focus-visible:outline-zinc-900`
const BTN_PRIMARY = `${BTN_BASE} bg-zinc-900 text-white hover:bg-zinc-800 focus-visible:outline-zinc-900`

// ── helpers ───────────────────────────────────────────────────────────

const escapeHtml = (str) => {
  if (!str) return ""
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

const sameCalendarDay = (left, right) =>
  left.getFullYear() === right.getFullYear() &&
  left.getMonth() === right.getMonth() &&
  left.getDate() === right.getDate()

const formatLocalTime = (iso) => {
  if (!iso) return null
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return null
  return new Intl.DateTimeFormat(undefined, {
    day: "2-digit", month: "2-digit", year: "numeric",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).format(date)
}

const formatLocalTimeRelative = (iso) => {
  if (!iso) return null
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return null
  const now = new Date()
  const yesterday = new Date(now)
  yesterday.setDate(yesterday.getDate() - 1)
  const timePart = new Intl.DateTimeFormat(undefined, {
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).format(date)
  if (sameCalendarDay(date, now)) return `Today, ${timePart}`
  if (sameCalendarDay(date, yesterday)) return `Yesterday, ${timePart}`
  const datePart = new Intl.DateTimeFormat(undefined, {
    day: "2-digit", month: "2-digit", year: "numeric",
  }).format(date)
  return `${datePart}, ${timePart}`
}

const tokenValue = (v) => (typeof v === "number" ? v : 0)

const textPreview = (text, limit) => {
  if (!text) return "Empty message"
  const normalized = text.replace(/\s+/g, " ").trim()
  if (!normalized) return "Empty message"
  const short = normalized.slice(0, limit)
  return normalized.length > short.length ? short + "…" : short
}

const formatCost = (cost) => {
  if (cost == null) return null
  if (typeof cost === "number") return cost.toFixed(6)
  return String(cost)
}

// ── status / type badges ─────────────────────────────────────────────

const STATUS_BADGES = {
  generating: { cls: "bg-blue-600/10 text-blue-700", label: "Generating" },
  done:       { cls: "bg-zinc-900/5 text-zinc-700", label: "Done" },
  canceled:   { cls: "bg-amber-600/10 text-amber-700", label: "Canceled" },
  error:      { cls: "bg-red-600/10 text-red-700", label: "Error" },
}

const ITEM_BADGES = {
  reasoning:   { cls: "bg-indigo-600/10 text-indigo-700", label: "Reasoning" },
  answer:      { cls: "bg-emerald-600/10 text-emerald-700", label: "Answer" },
  tool_call:   { cls: "bg-sky-600/10 text-sky-700", label: "Tool call" },
  tool_result: { cls: "bg-sky-600/10 text-sky-700", label: "Tool result" },
  error:       { cls: "bg-red-600/10 text-red-700", label: "Error" },
  other:       { cls: "bg-zinc-900/5 text-zinc-700", label: "Other" },
}

const badgeBase = "inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium"

const statusBadgeHtml = (status) => {
  const b = STATUS_BADGES[status] || STATUS_BADGES.done
  return `<span class="${badgeBase} ${b.cls}">${escapeHtml(b.label)}</span>`
}

const itemBadgeHtml = (type) => {
  const b = ITEM_BADGES[type] || ITEM_BADGES.other
  return `<span class="${badgeBase} ${b.cls}">${escapeHtml(b.label)}</span>`
}

// ── render a single message ──────────────────────────────────────────

const renderMessageHtml = (msg, meta, state) => {
  const isUser = msg.role === "user"
  const wrapperClass = isUser ? "chat-message user" : "chat-message assistant"
  const bubbleClass = isUser ? "chat-bubble bubble-user" : "chat-bubble bubble-assistant"
  const roleLabel = isUser ? "You" : "Assistant"

  // Resolve displayed text
  const isStreaming =
    state.generating_message_id === msg.id && msg.status === "generating"
  const text = isStreaming ? (state.streaming_content || "") : (msg.content || "")

  const steps = (msg.steps || []).slice().sort((a, b) => a.sequence - b.sequence)
  const hasWorking =
    !isUser && (isStreaming || steps.length > 0)
  const workingOpen = !!state.working_open_by_id[msg.id]

  // Config label
  const configLabel = msg.config_label || null

  // Timestamp
  const createdIso = msg.created_at || null
  const createdFormatted = formatLocalTime(createdIso) || "Unknown time"

  let html = `<div id="message-${msg.id}" class="${wrapperClass}">`
  html += `<div class="${bubbleClass}">`

  // Header
  html += `<div class="chat-message-header">`
  html += `<div class="chat-message-role">${escapeHtml(roleLabel)} #${msg.id}</div>`
  html += statusBadgeHtml(msg.status)
  html += `</div>`

  // Working section (top)
  if (hasWorking) {
    html += `<div class="chat-working-section chat-working-section-top">`
    html += `<div class="chat-working-block">`
    html += `<button type="button" class="chat-working-toggle" data-action="toggle-working" data-message-id="${msg.id}" aria-label="Toggle working details">`
    html += `<span>Working</span><span>${workingOpen ? "▼" : "▶"}</span></button>`

    if (workingOpen) {
      html += `<div class="chat-working-content">`
      // Streaming reasoning
      if (isStreaming) {
        html += `<div class="chat-working-text chat-markdown">`
        html += `<div class="chat-working-subtitle">Reasoning (streaming)</div>`
        html += `<div id="message-reasoning-${msg.id}">`
        if (!state.streaming_reasoning) {
          html += `<span class="text-zinc-500">No reasoning yet...</span>`
        } else {
          html += markdownToHtml(state.streaming_reasoning)
        }
        html += `</div></div>`
      }
      // Steps
      if (steps.length > 0) {
        html += renderStepsHtml(msg.id, steps)
      }
      html += `</div>` // working-content
    }
    html += `</div></div>` // working-block, working-section
  }

  // Editing mode
  if (state.editing_message_id === msg.id) {
    html += renderEditFormHtml(msg)
  } else {
    // Content
    html += `<div id="message-content-${msg.id}" class="chat-message-content chat-markdown">`
    if (!text && msg.status === "generating") {
      html += `<span class="text-zinc-500">Generating...</span>`
    } else {
      html += markdownToHtml(text)
    }
    html += `</div>`

    // Typing indicator
    if (!text && msg.status === "generating") {
      html += `<div class="chat-typing-indicator"><span></span><span></span><span></span></div>`
    }

    // Error detail
    if (msg.status === "error" && msg.error_detail) {
      html += `<div class="chat-status-error">Error: ${escapeHtml(msg.error_detail)}</div>`
    }

    // Footer
    html += renderFooterHtml(msg, meta, configLabel, createdIso, createdFormatted, state)
  }

  html += `</div>` // bubble
  html += `</div>` // message wrapper
  return html
}

const renderFooterHtml = (msg, meta, configLabel, createdIso, createdFormatted, state) => {
  let html = `<div class="chat-message-footer">`

  // Meta line
  html += `<div class="chat-message-meta">`
  if (createdIso) {
    html += `<time class="js-local-time" data-utc="${escapeHtml(createdIso)}">${escapeHtml(createdFormatted)}</time>`
  } else {
    html += `<span>${escapeHtml(createdFormatted)}</span>`
  }
  if (configLabel) {
    html += ` <span>(${escapeHtml(configLabel)})</span>`
  }
  html += ` <span>· ${tokenValue(msg.token_count)} tokens</span>`
  html += `</div>`

  // Actions
  html += `<div class="chat-message-actions">`

  if (state.copied_message_id === msg.id) {
    html += `<span class="chat-copy-hint">Copied</span>`
  }

  if (meta.prev_sibling) {
    html += `<button type="button" class="chat-icon-button" data-action="switch-branch" data-message-id="${msg.id}" data-direction="prev" aria-label="Switch to previous branch" title="Previous branch">◀</button>`
  }

  // Copy
  const copyTextB64 = btoa(unescape(encodeURIComponent(msg.content || "")))
  html += `<button type="button" class="chat-icon-button" data-action="copy-message" data-message-id="${msg.id}" data-copy-text-b64="${copyTextB64}" data-copy-target="#message-content-${msg.id}" aria-label="Copy message ${msg.id}" title="Copy">📋</button>`

  if (msg.status !== "generating") {
    html += `<button type="button" class="chat-icon-button" data-action="edit-message" data-message-id="${msg.id}" aria-label="Edit message ${msg.id}" title="Edit">✏️</button>`
    html += `<button type="button" class="chat-icon-button" data-action="branch-message" data-message-id="${msg.id}" aria-label="Branch from message ${msg.id}" title="Branch">🌿</button>`
    html += `<button type="button" class="chat-icon-button" data-action="delete-message" data-message-id="${msg.id}" aria-label="Delete message ${msg.id}" title="Delete">🗑️</button>`
  }

  if (meta.next_sibling) {
    html += `<button type="button" class="chat-icon-button" data-action="switch-branch" data-message-id="${msg.id}" data-direction="next" aria-label="Switch to next branch" title="Next branch">▶</button>`
  }

  html += `</div>` // actions
  html += `</div>` // footer
  return html
}

const renderEditFormHtml = (msg) => {
  const content = escapeHtml(msg.content || "")
  let html = `<form data-action="save-edit" data-message-id="${msg.id}" class="chat-edit-form">`
  html += `<textarea name="content" rows="4" class="block w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 shadow-sm focus:border-zinc-900 focus:ring-2 focus:ring-zinc-900/20">${content}</textarea>`
  html += `<div class="chat-edit-actions">`
  html += `<button type="button" class="${BTN_DEFAULT}" data-action="cancel-edit">Cancel</button>`
  html += `<button type="submit" class="${BTN_PRIMARY}">Save</button>`
  html += `</div></form>`
  return html
}

const renderStepsHtml = (messageId, steps) => {
  let html = `<div class="chat-step-items">`
  for (const step of steps) {
    html += `<div class="chat-step-item">`
    html += `<div class="chat-step-header">`
    html += `<div class="chat-step-title">Step ${step.sequence}</div>`
    html += `<div class="chat-working-meta">`
    if (step.input_tokens != null) html += `<span>In: ${step.input_tokens}</span>`
    if (step.output_tokens != null) html += `<span>Out: ${step.output_tokens}</span>`
    const cost = formatCost(step.cost)
    if (cost != null) html += `<span>Cost: $${escapeHtml(cost)}</span>`
    html += `</div></div>`

    const items = (step.items || []).slice().sort((a, b) => a.sequence - b.sequence)
    if (items.length > 0) {
      html += `<div class="chat-step-items">`
      for (const item of items) {
        html += renderStepItemHtml(messageId, step, item)
      }
      html += `</div>`
    }

    html += `</div>`
  }
  html += `</div>`
  return html
}

const renderStepItemHtml = (messageId, step, item) => {
  const itemText = itemTextFromContents(item)
  let html = `<div class="chat-step-item-content">`
  html += `<div class="chat-step-header">`
  html += itemBadgeHtml(item.type)
  html += `<span class="text-xs text-zinc-500">#${item.sequence}</span>`
  html += `</div>`

  if (item.type === "answer") {
    const preview = textPreview(itemText, 200)
    html += `<button type="button" class="chat-working-answer-button" data-action="open-working-answer" data-message-id="${messageId}" data-item-id="${item.id}" aria-label="Open full answer" title="Open full answer">`
    html += `<div class="chat-step-text chat-markdown">${markdownToHtml(preview)}</div>`
    html += `</button>`
  } else {
    html += `<div class="chat-step-text chat-markdown">${markdownToHtml(itemText)}</div>`
  }

  html += `</div>`
  return html
}

const itemTextFromContents = (item) => {
  if (!item.contents || !item.contents.length) return ""
  return item.contents
    .filter(c => c.kind === "text")
    .sort((a, b) => a.sequence - b.sequence)
    .map(c => c.content_text || "")
    .join("")
}

// ── composer ─────────────────────────────────────────────────────────

const renderComposerHtml = (state) => {
  const isGenerating = !!(
    state.generating_message_id &&
    state.messages.some(m => m.id === state.generating_message_id && m.status === "generating")
  )

  let html = `<div class="chat-composer">`

  // Reply banner
  if (state.has_reply_parent) {
    html += `<div class="chat-reply-banner">`
    if (state.reply_parent_id == null) {
      html += `Branching from conversation root`
    } else {
      html += `Branching from message #${state.reply_parent_id}`
    }
    html += ` <button type="button" data-action="clear-reply-parent" class="chat-link-button">Clear</button>`
    html += `</div>`
  }

  html += `<form id="chat-send-form" data-action="send-form" class="chat-input-row">`
  html += `<textarea id="chat-draft" name="message[draft]" rows="3" placeholder="Type your message"></textarea>`
  html += `<div class="chat-input-actions">`

  if (isGenerating) {
    html += `<button type="button" class="${BTN_DEFAULT}" data-action="cancel-generation" aria-label="Cancel generation">Cancel</button>`
  } else {
    html += `<button type="submit" class="${BTN_PRIMARY}" data-action="submit-send" aria-label="Send message">Send</button>`
  }

  html += `</div></form></div>`
  return html
}

// ── main render function ─────────────────────────────────────────────

export const renderMessages = (container, state) => {
  const metaById = state.branch_meta_by_id || {}
  const messages = state.messages || []

  let html = ""

  if (messages.length === 0) {
    html = `<div class="chat-empty">Send a message to start.</div>`
  } else {
    for (const msg of messages) {
      const meta = metaById[String(msg.id)] || { siblings: [], prev_sibling: null, next_sibling: null }
      html += renderMessageHtml(msg, meta, state)
    }
  }

  html += renderComposerHtml(state)

  container.innerHTML = html
}

/**
 * Patch only the streaming content + reasoning of a single message
 * without touching the rest of the DOM.
 */
export const patchStreamingContent = (container, messageId, contentHtml, reasoningHtml) => {
  const contentEl = container.querySelector(`#message-content-${messageId}`)
  if (contentEl && contentHtml != null) {
    contentEl.innerHTML = contentHtml
  }

  if (reasoningHtml != null) {
    const reasoningEl = container.querySelector(`#message-reasoning-${messageId}`)
    if (reasoningEl) {
      reasoningEl.innerHTML = reasoningHtml
    }
  }
}

/**
 * Render markdown on the client side (used for streaming updates
 * where the server sends raw text).
 */
export { markdownToHtml }
