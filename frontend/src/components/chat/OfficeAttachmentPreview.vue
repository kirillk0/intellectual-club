<template>
  <div :aria-busy="state === 'loading'">
    <p v-if="state === 'loading'" class="muted" role="status">{{ translate('Loading attachment…') }}</p>
    <p v-if="state === 'error'" class="muted" role="status">
      {{ translate('This browser cannot preview this file. Download it to open it in another application.') }}
    </p>
    <component
      :is="kind === 'docx' ? DocxPreview : XlsxPreview"
      v-else
      v-show="state === 'ready'"
      :file="file"
      :title="title"
      @ready="state = 'ready'"
      @error="state = 'error'"
    />
  </div>
</template>

<script setup lang="ts">
import { defineAsyncComponent, onErrorCaptured, ref } from 'vue';

import { translate } from '@/i18n';

const DocxPreview = defineAsyncComponent(() => import('./DocxPreview.vue'));
const XlsxPreview = defineAsyncComponent(() => import('./XlsxPreview.vue'));

defineProps<{ kind: 'docx' | 'xlsx'; file: Blob; title: string }>();
const state = ref<'loading' | 'ready' | 'error'>('loading');

// A missing lazy chunk should leave the attachment available for download.
onErrorCaptured(() => {
  state.value = 'error';
  return false;
});
</script>
