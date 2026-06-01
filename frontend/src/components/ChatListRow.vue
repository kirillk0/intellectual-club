<template>
  <RouterLink class="row chat-list-row" :class="rowToneClass" :to="to">
    <div class="chat-result-main">
      <div class="chat-result-title">
        <span class="chat-result-name">{{ title }}</span>
        <span v-if="configLabel" class="chat-result-config">({{ configLabel }})</span>
      </div>
      <div class="chat-result-meta">
        <div class="muted">{{ metaText }}</div>
        <span
          v-if="generationState"
          class="chat-result-generation-state"
          :class="`chat-result-generation-state--${generationState}`"
          :aria-label="generationStateLabel"
          :title="generationStateLabel"
        >
          <span v-if="generationState === 'generating'" class="typing-indicator" aria-hidden="true">
            <span></span><span></span><span></span>
          </span>
          <span v-else-if="generationState === 'reconnecting'" class="reconnect-indicator" aria-hidden="true"></span>
          <SvgIcon v-else-if="generationState === 'done'" name="check" size="14" />
        </span>
      </div>
      <div v-if="secondaryMeta" class="chat-result-secondary muted">{{ secondaryMeta }}</div>
      <div v-if="previewText" class="chat-first-preview">
        <div class="chat-first-preview-bubble" :class="previewToneClass">
          {{ previewText }}
        </div>
      </div>
      <div v-if="snippet" class="chat-search-snippet">
        {{ snippet }}
      </div>
    </div>

    <div class="chat-result-badges">
      <slot name="badges"></slot>
    </div>
  </RouterLink>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink, type RouteLocationRaw } from 'vue-router';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type GenerationState = 'generating' | 'reconnecting' | 'done';

interface Props {
  to: RouteLocationRaw;
  title: string;
  configLabel?: string | null;
  metaText: string;
  secondaryMeta?: string | null;
  previewText?: string | null;
  previewRole?: 'user' | 'assistant' | null;
  snippet?: string | null;
  generationState?: GenerationState | null;
  rowRole?: 'user' | 'assistant' | null;
}

const props = withDefaults(defineProps<Props>(), {
  configLabel: null,
  secondaryMeta: null,
  previewText: null,
  previewRole: null,
  snippet: null,
  generationState: null,
  rowRole: null,
});

const rowToneClass = computed(() => ({
  'chat-list-row--user': props.rowRole === 'user',
  'chat-list-row--assistant': props.rowRole === 'assistant',
}));

const previewToneClass = computed(() => ({
  'chat-preview--user': props.previewRole === 'user',
  'chat-preview--assistant': props.previewRole === 'assistant',
}));

const generationStateLabel = computed(() => {
  if (props.generationState === 'done') return 'Generation complete';
  if (props.generationState === 'reconnecting') return 'Reconnecting';
  return 'Generating';
});
</script>

<style scoped>
.chat-result-title {
  display: flex;
  align-items: baseline;
  gap: 6px;
  flex-wrap: wrap;
}

.chat-result-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.chat-result-secondary {
  margin-top: 2px;
  font-size: 0.85rem;
}

.chat-result-generation-state {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 36px;
  min-height: 18px;
}

.chat-result-generation-state--done {
  color: #15803d;
}

.chat-result-generation-state--reconnecting {
  color: #b45309;
}

.chat-result-generation-state--reconnecting .reconnect-indicator {
  width: 14px;
  height: 14px;
}

.chat-result-name {
  font-weight: 600;
}

.chat-result-config {
  color: #6b7280;
  font-size: 0.85rem;
}

.chat-result-badges {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  justify-content: flex-end;
}

.chat-search-snippet {
  margin-top: 4px;
  color: #1f2933;
  font-size: 0.9rem;
  line-height: 1.35;
}

.chat-first-preview {
  margin-top: 6px;
}

.chat-first-preview-bubble {
  display: inline-block;
  max-width: 100%;
  padding: 6px 10px;
  border-radius: 12px;
  background: #eef2f7;
  color: #1f2933;
  font-size: 0.9rem;
  line-height: 1.35;
  text-decoration: none;
}

.chat-first-preview-bubble.chat-preview--user {
  background: linear-gradient(135deg, #e7f1ff, #f5f9ff);
}

.chat-first-preview-bubble.chat-preview--assistant {
  background: #f9f9fb;
}

.chat-list-row:hover .chat-first-preview-bubble {
  text-decoration: none;
}

.chat-list-row--user {
  background: linear-gradient(135deg, #e7f1ff, #f5f9ff);
  border-color: #d7e6ff;
}

.chat-list-row--assistant {
  background: #f9f9fb;
  border-color: #ececf3;
}
</style>
