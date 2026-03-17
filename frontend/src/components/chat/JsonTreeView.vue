<template>
  <div class="json-viewer">
    <div class="json-viewer-toolbar">
      <div class="json-viewer-toolbar-left">
        <div class="json-viewer-summary">{{ valueSummary }}</div>
        <button type="button" class="json-viewer-toggle" @click="showRawText = !showRawText">
          {{ showRawText ? 'Hide raw text' : 'Show raw text' }}
        </button>
      </div>
      <a
        v-if="downloadUrl"
        class="json-viewer-download"
        :href="downloadUrl"
        :download="downloadFilename"
      >
        Download JSON
      </a>
    </div>

    <div v-if="showRawText" class="code-block json-viewer-raw">{{ serializedJson || 'null' }}</div>

    <div class="code-block json-viewer-body">
      <JsonTreeNode :value="normalizedValue" />
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';

import JsonTreeNode from '@/components/chat/JsonTreeNode.vue';

interface Props {
  value?: unknown;
  downloadFilename?: string;
}

const props = withDefaults(defineProps<Props>(), {
  value: null,
  downloadFilename: 'payload.json',
});

const normalizedValue = computed(() => (props.value === undefined ? null : props.value));

const valueSummary = computed(() => {
  const value = normalizedValue.value;

  if (Array.isArray(value)) {
    const count = value.length;
    return `${count} ${count === 1 ? 'item' : 'items'}`;
  }

  if (value !== null && typeof value === 'object') {
    const count = Object.keys(value as Record<string, unknown>).length;
    return `${count} ${count === 1 ? 'key' : 'keys'}`;
  }

  if (typeof value === 'string') {
    return `${value.length} chars`;
  }

  if (value === null) return 'null';
  return typeof value;
});

const serializedJson = computed(() => {
  try {
    return JSON.stringify(normalizedValue.value, null, 2);
  } catch (_error) {
    return '';
  }
});

const downloadUrl = ref('');
const showRawText = ref(false);

const revokeDownloadUrl = () => {
  if (!downloadUrl.value) return;
  URL.revokeObjectURL(downloadUrl.value);
  downloadUrl.value = '';
};

watch(
  serializedJson,
  (nextValue) => {
    revokeDownloadUrl();
    if (!nextValue) return;
    downloadUrl.value = URL.createObjectURL(
      new Blob([nextValue], { type: 'application/json;charset=utf-8' })
    );
  },
  { immediate: true }
);

onBeforeUnmount(() => {
  revokeDownloadUrl();
});
</script>

<style scoped>
.json-viewer {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.json-viewer-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
}

.json-viewer-toolbar-left {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
}

.json-viewer-summary {
  color: #475569;
  font-size: 0.82rem;
}

.json-viewer-toggle {
  border: 1px solid #cbd5e1;
  border-radius: 999px;
  background: #fff;
  color: #334155;
  font-size: 0.8rem;
  line-height: 1.2;
  padding: 4px 10px;
  cursor: pointer;
}

.json-viewer-toggle:hover {
  border-color: #94a3b8;
  color: #0f172a;
}

.json-viewer-download {
  color: #0f766e;
  text-decoration: none;
  font-size: 0.82rem;
}

.json-viewer-download:hover {
  text-decoration: underline;
}

.json-viewer-body {
  --json-color-default: #e2e8f0;
  --json-color-toggle: #94a3b8;
  --json-color-toggle-hover: #f8fafc;
  --json-color-key: #fb923c;
  --json-color-index: #cbd5e1;
  --json-color-punctuation: #cbd5e1;
  --json-color-summary: #94a3b8;
  --json-color-string: #6ee7b7;
  --json-color-number: #93c5fd;
  --json-color-boolean: #c4b5fd;
  --json-color-null: #94a3b8;
  max-height: 58vh;
  overflow: auto;
  white-space: normal;
}

.json-viewer-raw {
  max-height: 28vh;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-word;
}
</style>
