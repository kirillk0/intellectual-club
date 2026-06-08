<template>
  <div class="stack">
    <label>
      Content
      <div
        :class="[
          'knowledge-block-content-editor',
          contentError && 'knowledge-block-content-editor--error',
        ]"
      >
        <pre class="knowledge-block-content-editor__mirror" aria-hidden="true"><code
          :style="contentMirrorStyle"
          v-html="contentHighlightHtml"
        ></code></pre>
        <textarea
          ref="contentTextareaRef"
          :value="content"
          :class="[
            'full',
            'knowledge-block-content-editor__textarea',
            !content && 'knowledge-block-content-editor__textarea--empty',
          ]"
          placeholder="Write the knowledge block content..."
          spellcheck="false"
          @input="handleContentEditorInput"
          @scroll="syncContentEditorScroll"
        ></textarea>
      </div>
      <div class="muted knowledge-block-content-editor__hint">
        Lines starting with <code>//// </code> are treated as comments and removed from the compiled prompt.
      </div>
      <div v-if="contentError" class="error-text">{{ contentError }}</div>
    </label>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, ref } from 'vue';

import { COMMENT_PREFIX } from '@/features/catalogs/model/knowledgeBlockMarkdownBlocks';

const props = defineProps<{
  content: string;
  contentError: string | null;
}>();

const emit = defineEmits<{
  (e: 'update:content', value: string): void;
  (e: 'clear-content-error'): void;
}>();

const contentTextareaRef = ref<HTMLTextAreaElement | null>(null);
const contentScrollTop = ref(0);
const contentScrollLeft = ref(0);

function escapeHtml(value: string) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

const contentHighlightHtml = computed(() => {
  const text = String(props.content || '');
  if (text === '') return '&nbsp;';

  const highlighted = text
    .split('\n')
    .map((line) => {
      const escaped = escapeHtml(line) || '&nbsp;';
      return line.startsWith(COMMENT_PREFIX)
        ? `<span class="knowledge-block-content-editor__comment">${escaped}</span>`
        : `<span class="knowledge-block-content-editor__plain">${escaped}</span>`;
    })
    .join('\n');

  return text.endsWith('\n') ? `${highlighted}\n&nbsp;` : highlighted;
});

const contentMirrorStyle = computed(() => ({
  transform: `translate(${-contentScrollLeft.value}px, ${-contentScrollTop.value}px)`,
}));

function syncContentEditorScroll(event: Event) {
  const target = event.target as HTMLTextAreaElement | null;
  if (!target) return;
  syncContentEditorScrollFromTextarea(target);
}

function handleContentEditorInput(event: Event) {
  emit('clear-content-error');

  const target = event.target as HTMLTextAreaElement | null;
  if (!target) return;

  emit('update:content', target.value);
  syncContentEditorScroll(event);
}

function syncContentEditorScrollFromTextarea(textarea: HTMLTextAreaElement) {
  contentScrollTop.value = textarea.scrollTop;
  contentScrollLeft.value = textarea.scrollLeft;
}

function scrollCodeEditorToPosition(textarea: HTMLTextAreaElement, position: number) {
  const applyScroll = () => {
    if (!document.body.contains(textarea)) return;
    if (document.activeElement !== textarea) return;
    if (textarea.selectionStart !== position || textarea.selectionEnd !== position) return;

    scrollTextareaToPosition(textarea, position);
    scrollCodeEditorIntoView(textarea);
  };

  applyScroll();
  window.requestAnimationFrame(applyScroll);
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(applyScroll);
  });
  window.setTimeout(applyScroll, 120);
  window.setTimeout(applyScroll, 320);
  window.setTimeout(applyScroll, 640);
}

function scrollTextareaToPosition(textarea: HTMLTextAreaElement, position: number) {
  const targetTop = measureTextareaPositionTop(textarea, position) ?? estimateTextareaPositionTop(textarea, position);
  const viewportOffset = Math.max(24, textarea.clientHeight * 0.35);
  const maxScrollTop = Math.max(0, textarea.scrollHeight - textarea.clientHeight);

  textarea.scrollTop = Math.max(0, Math.min(maxScrollTop, targetTop - viewportOffset));
  syncContentEditorScrollFromTextarea(textarea);
}

function scrollCodeEditorIntoView(textarea: HTMLTextAreaElement) {
  const rect = textarea.getBoundingClientRect();
  const viewportHeight = window.visualViewport?.height || window.innerHeight || 720;
  const headerHeight = getAppHeaderHeight();
  const topLimit = headerHeight + 16;
  const bottomLimit = viewportHeight - 24;
  let nextTop: number | null = null;

  if (rect.top < topLimit) {
    nextTop = window.scrollY + rect.top - topLimit;
  } else if (rect.bottom > bottomLimit) {
    nextTop = window.scrollY + rect.bottom - bottomLimit;
  }

  if (nextTop === null) return;

  window.scrollTo({
    top: Math.max(0, nextTop),
    left: window.scrollX,
    behavior: 'auto',
  });
}

function estimateTextareaPositionTop(textarea: HTMLTextAreaElement, position: number) {
  const style = window.getComputedStyle(textarea);
  const fontSize = Number.parseFloat(style.fontSize) || 14;
  const lineHeight = getResolvedLineHeight(style, fontSize);
  const paddingTop = Number.parseFloat(style.paddingTop) || 0;
  const lineIndex = String(props.content || '').slice(0, position).split('\n').length - 1;
  return paddingTop + lineIndex * lineHeight;
}

function measureTextareaPositionTop(textarea: HTMLTextAreaElement, position: number) {
  const value = String(props.content || '');
  const style = window.getComputedStyle(textarea);
  const fontSize = Number.parseFloat(style.fontSize) || 14;
  const lineHeight = getResolvedLineHeight(style, fontSize);
  const resolvedLineHeight = `${lineHeight}px`;
  const overflowWrap = style.getPropertyValue('overflow-wrap');
  const mirror = document.createElement('div');
  const marker = document.createElement('span');

  Object.assign(mirror.style, {
    position: 'absolute',
    visibility: 'hidden',
    overflow: 'hidden',
    top: '0',
    left: '-9999px',
    width: `${textarea.clientWidth}px`,
    boxSizing: 'border-box',
    paddingTop: style.paddingTop,
    paddingRight: style.paddingRight,
    paddingBottom: style.paddingBottom,
    paddingLeft: style.paddingLeft,
    fontFamily: style.fontFamily,
    fontSize: style.fontSize,
    fontStyle: style.fontStyle,
    fontVariant: style.fontVariant,
    fontWeight: style.fontWeight,
    letterSpacing: style.letterSpacing,
    lineHeight: resolvedLineHeight,
    textTransform: style.textTransform,
    whiteSpace: 'pre-wrap',
    overflowWrap: !overflowWrap || overflowWrap === 'normal' ? 'break-word' : overflowWrap,
    wordBreak: style.wordBreak,
    tabSize: style.getPropertyValue('tab-size') || '8',
  });

  Object.assign(marker.style, {
    display: 'inline-block',
    width: '1px',
    height: resolvedLineHeight,
    lineHeight: resolvedLineHeight,
  });

  marker.textContent = '\u200b';
  mirror.append(document.createTextNode(value.slice(0, position)), marker);
  document.body.append(mirror);

  const top = marker.offsetTop;
  mirror.remove();
  return Number.isFinite(top) ? top : null;
}

function getResolvedLineHeight(style: CSSStyleDeclaration, fontSize: number) {
  return Number.parseFloat(style.lineHeight) || fontSize * 1.5;
}

function getAppHeaderHeight() {
  const raw = window.getComputedStyle(document.documentElement).getPropertyValue('--app-header-height');
  const parsed = Number.parseFloat(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

async function focusAtPosition(position: number) {
  await nextTick();
  const textarea = contentTextareaRef.value;
  if (!textarea) return;

  const safePosition = Math.max(0, Math.min(String(props.content || '').length, position));
  textarea.focus({ preventScroll: true });
  textarea.setSelectionRange(safePosition, safePosition);
  scrollCodeEditorToPosition(textarea, safePosition);
}

function resetScroll() {
  contentScrollTop.value = 0;
  contentScrollLeft.value = 0;
  const textarea = contentTextareaRef.value;
  if (!textarea) return;
  textarea.scrollTop = 0;
  textarea.scrollLeft = 0;
  syncContentEditorScrollFromTextarea(textarea);
}

defineExpose({
  focusAtPosition,
  resetScroll,
});
</script>

<style scoped>
.knowledge-block-content-editor {
  position: relative;
  height: clamp(360px, calc(var(--app-vh, 1vh) * 68), 640px);
  border: 1px solid var(--color-border-strong);
  border-radius: 6px;
  background: var(--color-surface);
  overflow: hidden;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}

.knowledge-block-content-editor--error {
  border-color: var(--color-danger);
  box-shadow: 0 0 0 1px color-mix(in srgb, var(--color-danger) 22%, transparent);
}

.knowledge-block-content-editor__mirror {
  position: absolute;
  inset: 0;
  margin: 0;
  pointer-events: none;
  overflow: hidden;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  z-index: 2;
}

.knowledge-block-content-editor__mirror code {
  display: block;
  min-height: 100%;
  padding: 6px 8px;
  font: inherit;
  line-height: 1.5;
  white-space: inherit;
  overflow-wrap: inherit;
}

.knowledge-block-content-editor__textarea {
  display: block;
  position: relative;
  z-index: 1;
  border: 0;
  border-radius: 0;
  background: transparent;
  color: transparent;
  text-shadow: 0 0 0 var(--color-text);
  caret-color: var(--color-text);
  -webkit-text-fill-color: transparent;
  height: 100%;
  min-height: 0;
  max-height: 100%;
  overflow: auto;
  overflow-anchor: none;
  overscroll-behavior: contain;
  resize: none;
  line-height: 1.5;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}

.knowledge-block-content-editor__textarea:focus {
  outline: none;
  box-shadow: none;
}

.knowledge-block-content-editor__textarea--empty {
  text-shadow: none;
  color: inherit;
  -webkit-text-fill-color: inherit;
}

.knowledge-block-content-editor__textarea::placeholder {
  color: var(--color-text-subtle);
  -webkit-text-fill-color: var(--color-text-subtle);
}

.knowledge-block-content-editor__hint {
  margin-top: 6px;
}

@media (max-width: 640px) {
  .knowledge-block-content-editor {
    font-size: 1rem;
  }
}

:deep(.knowledge-block-content-editor__comment) {
  color: var(--color-text-subtle);
}

:deep(.knowledge-block-content-editor__plain) {
  color: transparent;
}
</style>
