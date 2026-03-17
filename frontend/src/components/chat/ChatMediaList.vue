<template>
  <div v-if="mediaContents.length" class="chat-media-list">
    <button
      v-for="content in mediaContents"
      :key="content.id"
      class="chat-media-item"
      type="button"
      :title="`${getAttachmentName(content)}  (${formatFileBytes(getAttachmentSize(content))})`"
      @click="emit('preview', { messageId: Number(props.messageId || 0), content })"
    >
      <span class="chat-media-item__icon" aria-hidden="true">{{ fileIcon(content) }}</span>
      <span class="chat-media-item__name" :title="getAttachmentName(content)">{{
        getAttachmentName(content)
      }}</span>
      <span class="chat-media-item__size">{{ formatFileBytes(getAttachmentSize(content)) }}</span>
    </button>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import {
  fileIconByMime,
  formatFileBytes,
  getAttachmentName,
  getAttachmentSize,
} from '@/features/chat/attachments';
import type { ChatMessageContent } from '@/types/api';

interface Props {
  messageId: number | null;
  contents?: ChatMessageContent[] | null;
}

const props = withDefaults(defineProps<Props>(), {
  messageId: null,
  contents: () => [],
});

const emit = defineEmits<{
  (e: 'preview', payload: { messageId: number; content: ChatMessageContent }): void;
}>();

const mediaContents = computed(() =>
  (props.contents || [])
    .slice()
    .filter((content) => content.kind === 'media' && content.media && props.messageId != null)
    .sort((a, b) => (a.sequence || 0) - (b.sequence || 0))
);

const fileIcon = (content: ChatMessageContent): string =>
  fileIconByMime(content.media?.mime_type || '', content.media?.filename || '');
</script>

<style scoped>
.chat-media-list {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 4px;
  margin-top: 10px;
}

.chat-media-item {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 8px;
  border: none;
  border-radius: 6px;
  background: transparent;
  color: inherit;
  text-align: left;
  cursor: pointer;
  min-width: 0;
  transition: background-color 0.12s ease;
}

.chat-media-item:hover {
  background: rgba(0, 0, 0, 0.05);
}

.chat-media-item__icon {
  flex: 0 0 auto;
  font-size: 0.95rem;
  line-height: 1;
}

.chat-media-item__name {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 0.85rem;
  font-weight: 500;
  line-height: 1.3;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #1a1a1a;
}

.chat-media-item__size {
  flex: 0 0 auto;
  font-size: 0.75rem;
  color: #888;
  white-space: nowrap;
}

@media (max-width: 480px) {
  .chat-media-list {
    grid-template-columns: 1fr;
  }
}
</style>
