<template>
  <Teleport to="body">
    <transition name="fade">
      <section
        v-if="open"
        ref="overlayRef"
        class="message-tree-overlay"
        :aria-label="t('Message tree')"
        tabindex="-1"
        @keydown.esc.prevent.stop="emit('close')"
      >
        <header class="message-tree-toolbar">
          <div class="message-tree-toolbar__title">
            <SvgIcon name="branch" />
            <div>
              <h2>{{ t('Message tree') }}</h2>
              <p>{{ treeStatusText }}</p>
            </div>
          </div>
          <div class="message-tree-toolbar__actions">
            <button
              type="button"
              :title="t('Zoom out')"
              :aria-label="t('Zoom out')"
              @click="setScale(scale - scaleStep)"
            >
              -
            </button>
            <button type="button" class="message-tree-scale" :title="t('Reset zoom')" @click="resetScale">
              {{ Math.round(scale * 100) }}%
            </button>
            <button
              type="button"
              :title="t('Zoom in')"
              :aria-label="t('Zoom in')"
              @click="setScale(scale + scaleStep)"
            >
              +
            </button>
            <button type="button" @click="expandAll">{{ t('Expand all') }}</button>
            <button type="button" @click="collapseInactive">{{ t('Collapse inactive') }}</button>
            <button
              type="button"
              class="icon-button"
              :title="t('Close')"
              :aria-label="t('Close')"
              @click="emit('close')"
            >
              <SvgIcon name="x" />
            </button>
          </div>
        </header>

        <div v-if="loading" class="message-tree-state" role="status">{{ t('Loading tree…') }}</div>
        <div v-else-if="error" class="message-tree-state message-tree-state--error">
          <p>{{ error }}</p>
          <button type="button" @click="loadTree">{{ t('Retry') }}</button>
        </div>
        <div v-else ref="stageRef" class="message-tree-stage" @wheel="handleWheel">
          <div
            class="message-tree-canvas"
            :style="{ '--tree-scale': String(scale), zoom: String(scale) }"
          >
            <div v-if="visibleRows.length" class="message-tree-rows">
              <div
                v-for="row in visibleRows"
                :key="row.message.id"
                :ref="(el) => setTreeNodeRef(row.message.id, el)"
                class="message-tree-row"
                :class="{
                  'message-tree-row--active': row.active,
                  'message-tree-row--active-path': row.activePath,
                }"
                :style="{ '--depth': String(row.depth) }"
              >
                <div class="message-tree-row__rail" aria-hidden="true"></div>
                <button
                  v-if="row.childCount > 0"
                  type="button"
                  class="message-tree-toggle"
                  :class="{ 'message-tree-toggle--collapsed': row.collapsed }"
                  :aria-label="t(row.collapsed ? 'Expand node' : 'Collapse node')"
                  :title="t(row.collapsed ? 'Expand node' : 'Collapse node')"
                  :aria-expanded="!row.collapsed"
                  @click="toggleCollapsed(row.message.id)"
                >
                  <SvgIcon :name="row.collapsed ? 'chevron-right' : 'arrow-down'" size="14" />
                </button>
                <span v-else class="message-tree-toggle message-tree-toggle--empty" aria-hidden="true"></span>

                <button
                  type="button"
                  class="message-tree-node"
                  :class="[`message-tree-node--${row.message.role}`, { 'message-tree-node--active': row.active }]"
                  :title="fullText(row.message)"
                  @click="openDetails(row.message)"
                >
                  <span class="message-tree-node__meta" data-i18n-ignore>
                    #{{ row.branchNumber }} · {{ messageMetaLabel(row.message) || '—' }}
                  </span>
                  <span class="message-tree-node__snippet" data-i18n-ignore>
                    {{ previewText(row.message) }}
                  </span>
                  <span v-if="row.active" class="message-tree-node__badge">{{ t('Active branch') }}</span>
                </button>
              </div>
            </div>
            <p v-else class="message-tree-empty">{{ t('No messages yet.') }}</p>
          </div>
        </div>

        <ModalWindow
          :open="Boolean(selectedMessage)"
          modal-class="message-tree-detail-modal"
          :aria-label="t('Message details')"
          max-width="840px"
          @cancel="closeDetails"
        >
          <div v-if="selectedMessage" class="message-tree-detail">
            <header class="message-tree-detail__header">
              <div>
                <h3>{{ t('Message details') }}</h3>
                <p data-i18n-ignore>{{ messageMetaLabel(selectedMessage) || '—' }}</p>
              </div>
              <button
                type="button"
                class="icon-button"
                :title="t('Close')"
                :aria-label="t('Close')"
                @click="closeDetails"
              >
                <SvgIcon name="x" />
              </button>
            </header>
            <pre class="message-tree-detail__text" data-i18n-ignore>{{ detailText }}</pre>
            <footer class="message-tree-detail__footer">
              <span v-if="!selectedMessageActive && readonly" class="muted">{{ t('Read-only chat') }}</span>
              <button type="button" @click="closeDetails">{{ t('Close') }}</button>
              <button
                v-if="selectedMessageActive"
                type="button"
                class="primary"
                @click="goToSelectedMessage"
              >
                {{ t('Go to message') }}
              </button>
              <button
                v-else-if="!readonly"
                type="button"
                class="primary"
                @click="switchToSelectedMessage"
              >
                {{ t('Switch branch') }}
              </button>
            </footer>
          </div>
        </ModalWindow>
      </section>
    </transition>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, nextTick, ref, watch, type ComponentPublicInstance } from 'vue';

import { api, getApiErrorMessage } from '@/api/client';
import ModalWindow from '@/components/ModalWindow.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import { translate } from '@/i18n';
import type { ChatBranchMessage, ChatMessageTreePayload } from '@/types/api';

type TemplateRefValue = Element | ComponentPublicInstance | null;

type TreeRow = {
  message: ChatBranchMessage;
  depth: number;
  branchNumber: number;
  childCount: number;
  collapsed: boolean;
  active: boolean;
  activePath: boolean;
};

const props = withDefaults(
  defineProps<{
    open: boolean;
    chatId: number;
    readonly?: boolean;
    branch: ChatBranchMessage[];
    messageMetaLabel: (message: ChatBranchMessage) => string;
    messageText: (message: ChatBranchMessage) => string;
    preview: (text: string) => string;
  }>(),
  {
    readonly: false,
  }
);

const emit = defineEmits<{
  (event: 'close'): void;
  (event: 'go-to-message', messageId: number): void;
  (event: 'switch-to-message', messageId: number): void;
}>();

const scaleMin = 0.6;
const scaleMax = 1.8;
const scaleStep = 0.1;
const t = translate;

const overlayRef = ref<HTMLElement | null>(null);
const stageRef = ref<HTMLElement | null>(null);
const loading = ref(false);
const error = ref('');
const messages = ref<ChatBranchMessage[]>([]);
const loadedActiveMessageIds = ref<number[]>([]);
const collapsedIds = ref<Set<number>>(new Set());
const selectedMessage = ref<ChatBranchMessage | null>(null);
const scale = ref(1);
const treeNodeRefs = new Map<number, HTMLElement>();
let loadSeq = 0;

const toHTMLElement = (el: TemplateRefValue) => (el instanceof HTMLElement ? el : null);

const activeMessageIds = computed(() => {
  const branchIds = (props.branch || [])
    .map((message) => message.id)
    .filter((id): id is number => Number.isInteger(id));

  return branchIds.length ? branchIds : loadedActiveMessageIds.value;
});

const activeIdSet = computed(() => new Set(activeMessageIds.value));

const messagesByParent = computed(() => {
  const byParent = new Map<number | null, ChatBranchMessage[]>();
  const knownIds = new Set(messages.value.map((message) => message.id));

  for (const message of messages.value) {
    const parentId = message.parent_id != null && knownIds.has(message.parent_id) ? message.parent_id : null;
    const group = byParent.get(parentId) || [];
    group.push(message);
    byParent.set(parentId, group);
  }

  for (const group of byParent.values()) {
    group.sort(compareMessages);
  }

  return byParent;
});

const visibleRows = computed<TreeRow[]>(() => {
  const rows: TreeRow[] = [];
  const byParent = messagesByParent.value;
  const collapsed = collapsedIds.value;
  const active = activeIdSet.value;
  const activePath = new Set<number>();

  for (const message of props.branch || []) {
    if (Number.isInteger(message.id)) activePath.add(message.id);
  }

  const appendRows = (parentId: number | null, depth: number) => {
    for (const message of byParent.get(parentId) || []) {
      const childCount = (byParent.get(message.id) || []).length;
      const isCollapsed = collapsed.has(message.id);
      rows.push({
        message,
        depth,
        branchNumber: depth + 1,
        childCount,
        collapsed: isCollapsed,
        active: active.has(message.id),
        activePath: activePath.has(message.id),
      });

      if (childCount > 0 && !isCollapsed) appendRows(message.id, depth + 1);
    }
  };

  appendRows(null, 0);
  return rows;
});

const treeStatusText = computed(() => {
  if (loading.value) return translate('Loading tree…');
  if (error.value) return translate('Tree failed to load');
  if (!messages.value.length) return translate('No messages yet.');
  return translate('{count} messages · {active} active', {
    count: messages.value.length,
    active: activeMessageIds.value.length,
  });
});

const selectedMessageActive = computed(() =>
  selectedMessage.value ? activeIdSet.value.has(selectedMessage.value.id) : false
);

const detailText = computed(() => {
  if (!selectedMessage.value) return '';
  return fullText(selectedMessage.value) || translate('No text content.');
});

function compareMessages(left: ChatBranchMessage, right: ChatBranchMessage) {
  const leftTime = Date.parse(left.created_at || '') || 0;
  const rightTime = Date.parse(right.created_at || '') || 0;
  return leftTime - rightTime || left.id - right.id;
}

function setTreeNodeRef(id: number, el: TemplateRefValue) {
  const node = toHTMLElement(el);
  if (!node) {
    treeNodeRefs.delete(id);
    return;
  }

  treeNodeRefs.set(id, node);
}

function fullText(message: ChatBranchMessage) {
  return props.messageText(message).trim();
}

function previewText(message: ChatBranchMessage) {
  const text = fullText(message);
  return text ? props.preview(text) : translate('No text content.');
}

function setScale(value: number) {
  const next = Math.round(Math.min(scaleMax, Math.max(scaleMin, value)) * 100) / 100;
  scale.value = next;
}

function resetScale() {
  scale.value = 1;
}

function handleWheel(event: WheelEvent) {
  if (!event.ctrlKey && !event.metaKey) return;
  event.preventDefault();
  setScale(scale.value + (event.deltaY > 0 ? -scaleStep : scaleStep));
}

function toggleCollapsed(messageId: number) {
  const next = new Set(collapsedIds.value);
  if (next.has(messageId)) {
    next.delete(messageId);
  } else {
    next.add(messageId);
  }
  collapsedIds.value = next;
}

function expandAll() {
  collapsedIds.value = new Set();
}

function collapseInactive() {
  const active = activeIdSet.value;
  const next = new Set<number>();

  for (const message of messages.value) {
    if (!active.has(message.id) && (messagesByParent.value.get(message.id) || []).length > 0) {
      next.add(message.id);
    }
  }

  collapsedIds.value = next;
}

function openDetails(message: ChatBranchMessage) {
  selectedMessage.value = message;
}

function closeDetails() {
  selectedMessage.value = null;
}

function goToSelectedMessage() {
  const messageId = selectedMessage.value?.id;
  if (!messageId) return;
  closeDetails();
  emit('go-to-message', messageId);
}

function switchToSelectedMessage() {
  const messageId = selectedMessage.value?.id;
  if (!messageId || props.readonly) return;
  closeDetails();
  emit('switch-to-message', messageId);
}

async function scrollTreeToMessage(messageId: number | null | undefined) {
  if (!messageId) return;
  await nextTick();
  window.requestAnimationFrame(() => {
    treeNodeRefs.get(messageId)?.scrollIntoView({
      behavior: 'smooth',
      block: 'center',
      inline: 'center',
    });
  });
}

async function focusOverlay() {
  await nextTick();
  window.requestAnimationFrame(() => {
    overlayRef.value?.focus({ preventScroll: true });
  });
}

function expandActivePath() {
  const active = activeIdSet.value;
  if (!active.size) return;

  const next = new Set(collapsedIds.value);
  for (const id of active) next.delete(id);
  collapsedIds.value = next;
}

async function loadTree() {
  if (!props.open || !props.chatId) return;
  const seq = ++loadSeq;
  loading.value = true;
  error.value = '';

  try {
    const payload = await api.get<ChatMessageTreePayload>(
      `/api/bff/chat-state/${props.chatId}/message-tree`,
      { showErrorBanner: false }
    );

    if (seq !== loadSeq) return;
    messages.value = payload.messages || [];
    loadedActiveMessageIds.value = payload.active_message_ids || [];
    expandActivePath();
    await scrollTreeToMessage(activeMessageIds.value.at(-1));
  } catch (err) {
    if (seq !== loadSeq) return;
    console.error(err);
    messages.value = [];
    loadedActiveMessageIds.value = [];
    error.value = getApiErrorMessage(err, 'Failed to load tree.');
  } finally {
    if (seq === loadSeq) loading.value = false;
  }
}

watch(
  () => [props.open, props.chatId] as const,
  async ([open]) => {
    if (!open) {
      selectedMessage.value = null;
      return;
    }

    await focusOverlay();
    await loadTree();
  },
  { immediate: true }
);

watch(
  () => activeMessageIds.value.join(','),
  async () => {
    if (!props.open) return;
    expandActivePath();
    await scrollTreeToMessage(activeMessageIds.value.at(-1));
  }
);
</script>

<style scoped>
.message-tree-overlay {
  position: fixed;
  inset: 0;
  z-index: 1200;
  display: grid;
  grid-template-rows: auto 1fr;
  background: var(--color-bg);
  color: var(--color-text);
}

.message-tree-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: calc(12px + var(--app-safe-area-top, 0px)) 18px 12px;
  border-bottom: 1px solid var(--color-border-strong);
  background: var(--color-surface-elevated);
}

.message-tree-toolbar__title {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}

.message-tree-toolbar__title h2 {
  margin: 0;
  font-size: 1.05rem;
  line-height: 1.2;
}

.message-tree-toolbar__title p {
  margin: 2px 0 0;
  color: var(--color-text-muted);
  font-size: 0.86rem;
}

.message-tree-toolbar__actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
  flex-wrap: wrap;
}

.message-tree-toolbar__actions button {
  min-height: 34px;
}

.message-tree-scale {
  min-width: 62px;
}

.message-tree-stage {
  overflow: auto;
  overscroll-behavior: contain;
  background:
    linear-gradient(var(--color-border-muted) 1px, transparent 1px),
    linear-gradient(90deg, var(--color-border-muted) 1px, transparent 1px),
    var(--color-surface-subtle);
  background-size: 28px 28px;
}

.message-tree-canvas {
  --tree-scale: 1;
  width: max-content;
  min-width: 100%;
  min-height: 100%;
  padding: 24px;
  transform: scale(var(--tree-scale));
  transform-origin: 0 0;
}

@supports (zoom: 1) {
  .message-tree-canvas {
    transform: none;
  }
}

.message-tree-rows {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: min(760px, calc(100vw - 48px));
}

.message-tree-row {
  --depth: 0;
  position: relative;
  display: grid;
  grid-template-columns: 24px minmax(340px, 680px);
  gap: 8px;
  align-items: stretch;
  padding-left: calc(var(--depth) * 34px);
}

.message-tree-row__rail {
  position: absolute;
  left: calc(var(--depth) * 34px + 11px);
  top: -8px;
  bottom: -8px;
  width: 2px;
  background: var(--color-border-strong);
  opacity: 0.7;
}

.message-tree-row--active-path .message-tree-row__rail {
  background: var(--color-focus);
  opacity: 0.95;
}

.message-tree-toggle {
  position: relative;
  z-index: 1;
  width: 24px;
  min-width: 24px;
  height: 24px;
  min-height: 24px;
  align-self: center;
  display: inline-grid;
  place-items: center;
  padding: 0;
  border-radius: 999px;
  background: var(--color-surface);
}

.message-tree-toggle--empty {
  border-color: transparent;
  background: transparent;
  pointer-events: none;
}

.message-tree-node {
  position: relative;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  grid-template-areas:
    "meta badge"
    "snippet badge";
  gap: 3px 10px;
  width: 100%;
  min-height: 64px;
  padding: 10px 12px;
  border-radius: 8px;
  text-align: left;
  background: var(--color-surface);
  box-shadow: var(--shadow-soft);
}

.message-tree-node--user {
  border-color: var(--color-chat-user-border);
  background: var(--color-chat-user-bg);
}

.message-tree-node--assistant {
  border-color: var(--color-chat-assistant-border);
  background: var(--color-chat-assistant-bg);
}

.message-tree-node--active {
  border-color: var(--color-focus);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-focus) 26%, transparent);
}

.message-tree-node:hover {
  border-color: var(--color-border-strong);
  background: var(--color-surface-hover);
}

.message-tree-node:focus-visible,
.message-tree-toggle:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}

.message-tree-node__meta {
  grid-area: meta;
  min-width: 0;
  overflow: hidden;
  color: var(--color-text-muted);
  font-size: 0.78rem;
  line-height: 1.25;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.message-tree-node__snippet {
  grid-area: snippet;
  min-width: 0;
  overflow: hidden;
  color: var(--color-text);
  font-size: 0.92rem;
  line-height: 1.35;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.message-tree-node__badge {
  grid-area: badge;
  align-self: center;
  padding: 3px 7px;
  border-radius: 999px;
  background: var(--color-info-bg);
  color: var(--color-info-text);
  border: 1px solid var(--color-info-border);
  font-size: 0.74rem;
  font-weight: 650;
  white-space: nowrap;
}

.message-tree-state,
.message-tree-empty {
  display: grid;
  place-items: center;
  min-height: 220px;
  margin: 0;
  color: var(--color-text-muted);
}

.message-tree-state--error {
  gap: 12px;
  color: var(--color-danger-text);
}

.message-tree-state--error p {
  margin: 0;
}

.message-tree-detail {
  display: flex;
  flex-direction: column;
  gap: 14px;
  max-height: min(78vh, 760px);
}

.message-tree-detail__header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
}

.message-tree-detail__header h3 {
  margin: 0;
  font-size: 1rem;
}

.message-tree-detail__header p {
  margin: 3px 0 0;
  color: var(--color-text-muted);
  font-size: 0.86rem;
}

.message-tree-detail__text {
  min-height: 180px;
  max-height: min(54vh, 520px);
  margin: 0;
  padding: 12px;
  overflow: auto;
  border: 1px solid var(--color-border);
  border-radius: 8px;
  background: var(--color-surface-muted);
  color: var(--color-text);
  font: inherit;
  line-height: 1.45;
  white-space: pre-wrap;
  word-break: break-word;
}

.message-tree-detail__footer {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 8px;
}

.message-tree-detail__footer .muted {
  margin-right: auto;
}

@media (max-width: 720px) {
  .message-tree-toolbar {
    align-items: flex-start;
    flex-direction: column;
    padding-inline: 12px;
  }

  .message-tree-toolbar__actions {
    width: 100%;
    justify-content: flex-start;
  }

  .message-tree-row {
    grid-template-columns: 24px minmax(260px, calc(100vw - 78px));
    padding-left: calc(var(--depth) * 24px);
  }

  .message-tree-row__rail {
    left: calc(var(--depth) * 24px + 11px);
  }

  .message-tree-canvas {
    padding: 16px;
  }
}
</style>
