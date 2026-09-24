<template>
  <section class="fork-context" :aria-label="translate('Inherited live context')">
    <h2>{{ translate('Inherited live context') }}</h2>
    <p class="muted">{{ translate('Read-only context from the source conversation. It may change when the source is edited.') }}</p>
    <p v-if="context.status === 'unavailable'" role="status">
      {{ translate('Inherited context is unavailable. The source may have been deleted or access was revoked.') }}
    </p>
    <details v-else open>
      <summary>{{ translate('Inherited messages') }} ({{ context.messages.length }})</summary>
      <article v-for="message in context.messages" :key="message.key" class="fork-context__message">
        <header>
          <strong>{{ translate(message.role === 'user' ? 'User' : 'Assistant') }}</strong>
          <a v-if="safeSourceUrl(message.source_url)" :href="message.source_url!">
            {{ translate('Open source conversation') }}
          </a>
        </header>
        <div v-for="(item, itemIndex) in message.content" :key="itemIndex">
          <small v-if="itemLabel(item.type)" class="muted">{{ translate(itemLabel(item.type)) }}</small>
          <!-- Render projected text literally: no HTML, remote embeds or inferred local file IDs. -->
          <p v-for="(part, partIndex) in item.parts" :key="partIndex" class="fork-context__text">{{ part.text }}</p>
          <div v-for="(attachment, attachmentIndex) in item.attachments" :key="attachmentIndex" class="fork-context__attachment">
            <a v-if="attachment.enabled && safeFileUrl(attachment.url)" :href="attachment.url!" target="_blank" rel="noopener noreferrer">
              <img v-if="safeImage(attachment.mime_type)" :src="attachment.url!" :alt="attachment.name" loading="lazy" />
              <span>{{ attachment.name }}</span>
            </a>
            <span v-else>{{ attachment.name }} — {{ translate('Attachment unavailable') }}</span>
          </div>
        </div>
      </article>
    </details>
  </section>
</template>

<script setup lang="ts">
import { translate } from '@/i18n';
import type { ForkContext } from '@/types/api';

defineProps<{ context: ForkContext }>();

const safeSourceUrl = (url: string | null) => typeof url === 'string' && /^\/chats\/[1-9]\d*$/.test(url);
const safeFileUrl = (url: string | null) => typeof url === 'string' && /^\/api\/bff\/chat-messages\/[1-9]\d*\/contents\/[1-9]\d*\/file$/.test(url);
const safeImage = (mime: string) => ['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif'].includes(mime);
const itemLabel = (type: string) => ({ tool_call: 'Tool call', tool_result: 'Tool result', steering: 'Steering', reasoning: 'Reasoning' })[type] || '';
</script>

<style scoped>
.fork-context { border: 1px dashed var(--border, #888); border-radius: 0.75rem; padding: 1rem; }
.fork-context h2 { font-size: 1rem; margin: 0 0 0.5rem; }
.fork-context summary { cursor: pointer; }
.fork-context__message { margin-top: 1rem; padding-top: 0.75rem; border-top: 1px solid var(--border, #888); }
.fork-context__message header { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: baseline; }
.fork-context__text { white-space: pre-wrap; overflow-wrap: anywhere; }
.fork-context__attachment img { display: block; max-width: 100%; max-height: 20rem; object-fit: contain; }
</style>
