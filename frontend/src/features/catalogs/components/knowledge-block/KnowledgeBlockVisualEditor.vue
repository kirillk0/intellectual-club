<template>
  <div class="stack knowledge-block-visual">
    <div
      v-if="visualBlocks.length"
      :class="[
        'knowledge-block-visual__surface',
        contentError && 'knowledge-block-visual__surface--error',
      ]"
    >
      <template v-for="block in visualBlocks" :key="visualBlockKey(block)">
        <div v-if="block.kind === 'blank'" class="knowledge-block-visual__blank" aria-hidden="true"></div>
        <section
          v-else
          :class="[
            'knowledge-block-visual__block',
            `knowledge-block-visual__block--${block.kind}`,
            isActiveVisualBlock(block) && 'knowledge-block-visual__block--active',
            !disabled && 'knowledge-block-visual__block--editable',
          ]"
          :tabindex="disabled || isActiveVisualBlock(block) ? undefined : 0"
          :role="disabled || isActiveVisualBlock(block) ? undefined : 'button'"
          @click="handleVisualBlockClick(block, $event)"
          @keydown="handleVisualBlockKeydown(block, $event)"
        >
          <div v-if="isActiveVisualBlock(block)" class="knowledge-block-visual__block-toolbar">
            <span class="knowledge-block-visual__block-kind">
              {{ block.kind === 'comment' ? 'Comment' : 'Markdown' }}
            </span>
            <div class="knowledge-block-visual__block-actions">
              <button
                type="button"
                class="knowledge-block-visual__source-button"
                @pointerdown.prevent.stop
                @click.stop="openCodeAtBlock(block)"
              >
                Edit source
              </button>
              <button
                type="button"
                class="knowledge-block-visual__source-button"
                @pointerdown.prevent.stop
                @click.stop="finishVisualEditing"
              >
                Done
              </button>
            </div>
          </div>
          <textarea
            v-if="isActiveVisualBlock(block)"
            ref="visualTextareaRef"
            :class="[
              'knowledge-block-visual__textarea',
              block.kind === 'comment' && 'knowledge-block-visual__textarea--comment',
            ]"
            :value="activeVisualEdit?.value || ''"
            spellcheck="false"
            @beforeinput="captureVisualInputScroll"
            @input="updateActiveVisualBlock"
            @keydown="captureVisualInputScroll"
            @keydown.escape.prevent="finishVisualEditing"
            @keydown.ctrl.enter.prevent="finishVisualEditing"
            @keydown.meta.enter.prevent="finishVisualEditing"
            @click.stop
            @blur="finishVisualEditing"
          ></textarea>
          <div v-else-if="block.kind === 'comment'" class="knowledge-block-visual__comment-body" data-i18n-ignore>
            {{ commentBodyFromSource(block.source) }}
          </div>
          <div
            v-else
            class="knowledge-block-visual__rendered"
            data-i18n-ignore
            v-html="renderVisualMarkdownBlock(block)"
          ></div>
        </section>
      </template>
    </div>
    <div v-else class="muted knowledge-block-visual__empty">Nothing to preview.</div>
    <div v-if="contentError" class="error-text">{{ contentError }}</div>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue';

import {
  commentBodyFromSource,
  commentSourceFromBody,
  parseKnowledgeBlockMarkdownBlocks,
  replaceKnowledgeBlockRange,
  type KnowledgeBlockMarkdownBlock,
} from '@/features/catalogs/model/knowledgeBlockMarkdownBlocks';
import { renderChatMessageHtml } from '@/utils/chatMarkdown';

const props = defineProps<{
  content: string;
  contentError: string | null;
  disabled: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:content', value: string): void;
  (e: 'clear-content-error'): void;
  (e: 'edit-source', position: number): void;
}>();

type ActiveVisualEdit = {
  kind: 'markdown' | 'comment';
  start: number;
  end: number;
  key: string;
  value: string;
  trailingLineBreaks: string;
};

type ScrollSnapshot = {
  windowX: number;
  windowY: number;
  elements: Array<{
    element: HTMLElement;
    scrollLeft: number;
    scrollTop: number;
  }>;
};

const visualTextareaRef = ref<HTMLTextAreaElement | HTMLTextAreaElement[] | null>(null);
const activeVisualEdit = ref<ActiveVisualEdit | null>(null);
const visualBlocks = computed(() => parseKnowledgeBlockMarkdownBlocks(props.content));
let visualInputScrollSnapshot: ScrollSnapshot | null = null;

function trailingLineBreaks(source: string) {
  return source.match(/(?:\r\n|\n|\r)+$/u)?.[0] || '';
}

function lineBreakTokens(source: string) {
  return source.match(/\r\n|\n|\r/gu) || [];
}

function ensureTrailingLineBreaks(source: string, requiredSuffix: string) {
  if (!source || !requiredSuffix) return source;

  const required = lineBreakTokens(requiredSuffix);
  const existing = lineBreakTokens(trailingLineBreaks(source));
  if (existing.length >= required.length) return source;

  return `${source}${required.slice(existing.length).join('')}`;
}

function editableMarkdownSource(source: string) {
  const suffix = trailingLineBreaks(source);
  const tokens = lineBreakTokens(suffix);
  if (tokens.length <= 1) return source;

  return `${source.slice(0, source.length - suffix.length)}${tokens[0]}`;
}

function isActiveVisualBlock(block: KnowledgeBlockMarkdownBlock) {
  return Boolean(
    activeVisualEdit.value &&
      block.kind === activeVisualEdit.value.kind &&
      block.start === activeVisualEdit.value.start
  );
}

function visualBlockKey(block: KnowledgeBlockMarkdownBlock) {
  return isActiveVisualBlock(block) ? activeVisualEdit.value?.key || block.key : block.key;
}

function renderVisualMarkdownBlock(block: KnowledgeBlockMarkdownBlock) {
  return renderChatMessageHtml(block.source, { highlightCode: true });
}

async function startVisualEdit(block: KnowledgeBlockMarkdownBlock, sourceElement?: HTMLElement | null) {
  if (props.disabled || block.kind === 'blank') return;

  const scrollSnapshot = captureScrollSnapshot(sourceElement);
  const editableSource =
    block.kind === 'comment'
      ? commentBodyFromSource(block.source)
      : editableMarkdownSource(block.source);

  activeVisualEdit.value = {
    kind: block.kind,
    start: block.start,
    end: block.kind === 'comment' ? block.end : block.start + editableSource.length,
    key: block.key,
    value: editableSource,
    trailingLineBreaks:
      block.kind === 'comment'
        ? trailingLineBreaks(block.source)
        : trailingLineBreaks(editableSource),
  };

  await nextTick();
  const textarea = getVisualTextareaElement();
  if (!textarea) return;

  resizeVisualTextarea(textarea);
  restoreScrollSnapshot(scrollSnapshot);
  focusVisualTextarea(textarea, scrollSnapshot);
  resizeVisualTextareaSoon(textarea, scrollSnapshot);
}

function handleVisualBlockClick(block: KnowledgeBlockMarkdownBlock, event: MouseEvent) {
  const target = event.target as HTMLElement | null;
  if (target?.closest('button, textarea')) return;

  event.preventDefault();
  void startVisualEdit(block, event.currentTarget as HTMLElement | null);
}

function handleVisualBlockKeydown(block: KnowledgeBlockMarkdownBlock, event: KeyboardEvent) {
  if (event.target !== event.currentTarget) return;
  if (event.key !== 'Enter' && event.key !== ' ') return;

  event.preventDefault();
  void startVisualEdit(block, event.currentTarget as HTMLElement | null);
}

function captureVisualInputScroll(event: Event) {
  const target = event.target as HTMLTextAreaElement | null;
  if (!target) return;
  if (event instanceof KeyboardEvent && !isTextEditingKey(event)) return;
  visualInputScrollSnapshot = captureScrollSnapshot(target);
}

function isTextEditingKey(event: KeyboardEvent) {
  if (event.metaKey || event.ctrlKey || event.altKey) return false;
  return event.key.length === 1 || event.key === 'Enter' || event.key === 'Backspace' || event.key === 'Delete';
}

function updateActiveVisualBlock(event: Event) {
  const active = activeVisualEdit.value;
  const target = event.target as HTMLTextAreaElement | null;
  if (!active || !target) return;

  const scrollSnapshot = visualInputScrollSnapshot ?? captureScrollSnapshot(target);
  visualInputScrollSnapshot = null;
  const nextValue = target.value;
  let nextSource = active.kind === 'comment' ? commentSourceFromBody(nextValue) : nextValue;
  const currentContent = props.content;
  const removedSource = currentContent.slice(active.start, active.end);
  const requiredTrailingLineBreaks = trailingLineBreaks(removedSource) || active.trailingLineBreaks;

  nextSource = ensureTrailingLineBreaks(nextSource, requiredTrailingLineBreaks);

  emit('update:content', replaceKnowledgeBlockRange(currentContent, active.start, active.end, nextSource));
  emit('clear-content-error');

  if (active.kind === 'comment' && !nextSource) {
    activeVisualEdit.value = null;
    return;
  }

  activeVisualEdit.value = {
    ...active,
    end: active.start + nextSource.length,
    value: nextValue,
  };
  resizeVisualTextareaSoon(target, scrollSnapshot);
}

function finishVisualEditing() {
  activeVisualEdit.value = null;
}

function openCodeAtBlock(block: KnowledgeBlockMarkdownBlock) {
  activeVisualEdit.value = null;
  emit('edit-source', Math.max(0, block.start));
}

function getVisualTextareaElement() {
  const textarea = visualTextareaRef.value;
  return Array.isArray(textarea) ? textarea[0] ?? null : textarea;
}

function resizeVisualTextareaSoon(textarea?: HTMLTextAreaElement | null, scrollSnapshot?: ScrollSnapshot | null) {
  const initialSelectionStart = textarea?.selectionStart;
  const initialSelectionEnd = textarea?.selectionEnd;
  const resize = () => {
    const element = textarea && document.body.contains(textarea) ? textarea : getVisualTextareaElement();
    if (!element) return;
    if (
      scrollSnapshot &&
      document.activeElement === element &&
      initialSelectionStart !== null &&
      initialSelectionStart !== undefined &&
      initialSelectionEnd !== null &&
      initialSelectionEnd !== undefined &&
      (element.selectionStart !== initialSelectionStart || element.selectionEnd !== initialSelectionEnd)
    ) {
      return;
    }

    resizeVisualTextarea(element);
    if (
      scrollSnapshot &&
      document.activeElement === element &&
      element.selectionStart === initialSelectionStart &&
      element.selectionEnd === initialSelectionEnd
    ) {
      restoreScrollSnapshot(scrollSnapshot);
    }
  };

  resize();
  window.requestAnimationFrame(resize);
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(resize);
  });
  window.setTimeout(resize, 120);
}

function resizeVisualTextarea(textarea: HTMLTextAreaElement) {
  const style = window.getComputedStyle(textarea);
  const fontSize = Number.parseFloat(style.fontSize) || 14;
  const lineHeight = getResolvedLineHeight(style, fontSize);
  const paddingY = (Number.parseFloat(style.paddingTop) || 0) + (Number.parseFloat(style.paddingBottom) || 0);
  const borderY = (Number.parseFloat(style.borderTopWidth) || 0) + (Number.parseFloat(style.borderBottomWidth) || 0);
  const minHeight = Math.ceil(lineHeight + paddingY + borderY);
  const viewportHeight = window.visualViewport?.height || window.innerHeight || 720;
  const maxHeight = Math.max(minHeight, Math.min(720, viewportHeight * 0.68));
  const previousScrollTop = textarea.scrollTop;
  const previousScrollLeft = textarea.scrollLeft;
  const scrollSnapshot = document.activeElement === textarea ? captureScrollSnapshot(textarea) : null;

  textarea.style.height = 'auto';

  const contentHeight = textarea.scrollHeight + (style.boxSizing === 'border-box' ? borderY : 0);
  const nextHeight = Math.ceil(Math.max(minHeight, Math.min(maxHeight, contentHeight)));

  textarea.style.height = `${nextHeight}px`;
  textarea.style.overflowY = contentHeight > maxHeight ? 'auto' : 'hidden';
  textarea.scrollTop = Math.min(previousScrollTop, Math.max(0, textarea.scrollHeight - textarea.clientHeight));
  textarea.scrollLeft = previousScrollLeft;

  if (scrollSnapshot) restoreScrollSnapshot(scrollSnapshot);
}

function focusVisualTextarea(textarea: HTMLTextAreaElement, scrollSnapshot: ScrollSnapshot) {
  try {
    textarea.focus({ preventScroll: true });
  } catch {
    textarea.focus();
  }

  restoreScrollSnapshot(scrollSnapshot);
  window.requestAnimationFrame(() => {
    if (document.activeElement === textarea) restoreScrollSnapshot(scrollSnapshot);
  });
}

function captureScrollSnapshot(anchor?: HTMLElement | null): ScrollSnapshot {
  const elements: ScrollSnapshot['elements'] = [];
  const seen = new Set<HTMLElement>();
  let element = anchor?.parentElement ?? null;

  while (element && element !== document.body) {
    if (
      !seen.has(element) &&
      (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth)
    ) {
      elements.push({
        element,
        scrollLeft: element.scrollLeft,
        scrollTop: element.scrollTop,
      });
      seen.add(element);
    }
    element = element.parentElement;
  }

  return {
    windowX: window.scrollX,
    windowY: window.scrollY,
    elements,
  };
}

function restoreScrollSnapshot(snapshot: ScrollSnapshot) {
  for (const item of snapshot.elements) {
    if (!document.body.contains(item.element)) continue;
    item.element.scrollLeft = item.scrollLeft;
    item.element.scrollTop = item.scrollTop;
  }
  window.scrollTo(snapshot.windowX, snapshot.windowY);
}

function getResolvedLineHeight(style: CSSStyleDeclaration, fontSize: number) {
  return Number.parseFloat(style.lineHeight) || fontSize * 1.5;
}

watch(
  () => props.disabled,
  (disabled) => {
    if (disabled) finishVisualEditing();
  }
);

defineExpose({
  reset: finishVisualEditing,
});
</script>

<style scoped>
.knowledge-block-visual {
  min-height: 280px;
}

.knowledge-block-visual__surface {
  min-height: 280px;
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  padding: 8px;
  background: var(--color-surface);
  overflow: auto;
}

.knowledge-block-visual__surface--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.knowledge-block-visual__empty {
  min-height: 280px;
  border: 1px dashed var(--color-border-strong);
  border-radius: 6px;
  padding: 14px 16px;
  background: var(--color-surface-subtle);
}

.knowledge-block-visual__block {
  position: relative;
  min-width: 0;
  border: 1px solid transparent;
  border-radius: 6px;
  padding: 6px 8px;
}

.knowledge-block-visual__block--editable {
  cursor: text;
}

.knowledge-block-visual__block--editable:hover {
  border-color: var(--color-border);
  background: var(--color-surface-subtle);
}

.knowledge-block-visual__block--active {
  border-color: var(--color-focus);
  background: var(--color-surface);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-focus) 22%, transparent);
}

.knowledge-block-visual__block--comment {
  color: var(--color-text-subtle);
  background: var(--color-surface-subtle);
}

.knowledge-block-visual__blank {
  height: 10px;
}

.knowledge-block-visual__block-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 6px;
}

.knowledge-block-visual__block-kind {
  color: var(--color-text-muted);
  font-size: 0.75rem;
  font-weight: 650;
  text-transform: uppercase;
}

.knowledge-block-visual__block-actions {
  display: flex;
  align-items: center;
  gap: 6px;
}

.knowledge-block-visual__source-button {
  padding: 3px 7px;
  font-size: 0.78rem;
}

.knowledge-block-visual__textarea {
  display: block;
  width: 100%;
  min-height: 0;
  overflow-anchor: none;
  resize: vertical;
  overflow-y: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.92rem;
  line-height: 1.5;
}

.knowledge-block-visual__textarea--comment {
  color: var(--color-text-muted);
  background: var(--color-surface-muted);
}

.knowledge-block-visual__comment-body {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  word-break: break-word;
}

:deep(.knowledge-block-visual__rendered :where(h1, h2, h3, h4, h5, h6)) {
  margin: 10px 0 8px;
  font-weight: 650;
  line-height: 1.25;
}

:deep(.knowledge-block-visual__rendered h1) {
  font-size: 1.25rem;
}

:deep(.knowledge-block-visual__rendered h2) {
  font-size: 1.15rem;
}

:deep(.knowledge-block-visual__rendered h3) {
  font-size: 1.05rem;
}

:deep(.knowledge-block-visual__rendered :where(h4, h5, h6)) {
  font-size: 1rem;
}

:deep(.knowledge-block-visual__rendered :where(p, li, blockquote, h1, h2, h3, h4, h5, h6, td, th)) {
  overflow-wrap: anywhere;
  word-break: break-word;
}

:deep(.knowledge-block-visual__rendered p) {
  margin: 0 0 8px;
}

:deep(.knowledge-block-visual__rendered p:last-child) {
  margin-bottom: 0;
}

:deep(.knowledge-block-visual__rendered ul),
:deep(.knowledge-block-visual__rendered ol) {
  margin: 0 0 8px 18px;
  padding: 0;
}

:deep(.knowledge-block-visual__rendered blockquote) {
  margin: 0 0 8px;
  padding-left: 12px;
  border-left: 3px solid var(--color-border-strong);
  color: var(--color-text-muted);
}

:deep(.knowledge-block-visual__rendered code) {
  background: var(--color-surface-hover);
  border-radius: 6px;
  padding: 2px 6px;
  font-size: 0.95em;
}

:deep(.knowledge-block-visual__rendered pre) {
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  margin: 0 0 8px;
  padding: 10px;
  overflow-x: auto;
  border-radius: 10px;
  background: var(--color-code-bg);
  color: var(--color-code-text);
  font-size: 0.82rem;
  line-height: 1.4;
}

:deep(.knowledge-block-visual__rendered pre code) {
  display: block;
  padding: 0;
  border-radius: 0;
  background: transparent;
  color: inherit;
  font-size: inherit;
  line-height: inherit;
}

:deep(.knowledge-block-visual__rendered table) {
  width: 100%;
  border-collapse: collapse;
}

:deep(.knowledge-block-visual__rendered th),
:deep(.knowledge-block-visual__rendered td) {
  border: 1px solid var(--color-border-strong);
  padding: 6px 8px;
  text-align: left;
}

:deep(.knowledge-block-visual__rendered math.tml-display) {
  margin: 0 0 8px;
  overflow-x: auto;
  overflow-y: hidden;
}

:deep(.knowledge-block-visual__rendered math) {
  max-width: 100%;
}
</style>
