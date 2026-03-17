<template>
  <div class="json-node">
    <template v-if="isContainer">
      <div class="json-line" :style="lineStyle">
        <button
          class="json-toggle"
          type="button"
          :aria-label="expanded ? 'Collapse JSON block' : 'Expand JSON block'"
          @click="expanded = !expanded"
        >
          {{ expanded ? '▾' : '▸' }}
        </button>
        <span v-if="hasLabel" :class="labelClass">{{ formattedLabel }}</span>
        <span v-if="hasLabel" class="json-colon">: </span>
        <span class="json-bracket">{{ openingBracket }}</span>
        <template v-if="!expanded">
          <span class="json-summary">{{ collapsedSummary }}</span>
          <span class="json-bracket">{{ closingBracket }}</span>
        </template>
      </div>

      <template v-if="expanded">
        <div v-if="containerEntries.length === 0" class="json-line" :style="childLineStyle">
          <span class="json-toggle-spacer"></span>
          <span class="json-empty">{{ emptySummary }}</span>
        </div>

        <JsonTreeNode
          v-for="entry in containerEntries"
          :key="entry.key"
          :label="entry.label"
          :label-kind="entry.labelKind"
          :value="entry.value"
          :depth="depth + 1"
        />

        <div class="json-line" :style="lineStyle">
          <span class="json-toggle-spacer"></span>
          <span class="json-bracket">{{ closingBracket }}</span>
        </div>
      </template>
    </template>

    <template v-else-if="isLongString">
      <div class="json-line" :style="lineStyle">
        <button
          class="json-toggle"
          type="button"
          :aria-label="expanded ? 'Collapse long string' : 'Expand long string'"
          @click="expanded = !expanded"
        >
          {{ expanded ? '▾' : '▸' }}
        </button>
        <span v-if="hasLabel" :class="labelClass">{{ formattedLabel }}</span>
        <span v-if="hasLabel" class="json-colon">: </span>
        <span class="json-string">{{ longStringPreview }}</span>
        <span class="json-string-meta">{{ longStringMeta }}</span>
      </div>

      <div v-if="expanded" class="json-line" :style="childLineStyle">
        <span class="json-toggle-spacer"></span>
        <pre class="json-string-full">{{ quotedStringValue }}</pre>
      </div>
    </template>

    <template v-else>
      <div class="json-line" :style="lineStyle">
        <span class="json-toggle-spacer"></span>
        <span v-if="hasLabel" :class="labelClass">{{ formattedLabel }}</span>
        <span v-if="hasLabel" class="json-colon">: </span>
        <span :class="valueClass">{{ primitiveText }}</span>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';

defineOptions({ name: 'JsonTreeNode' });

type LabelKind = 'key' | 'index';

interface Props {
  label?: string | null;
  labelKind?: LabelKind | null;
  value: unknown;
  depth?: number;
}

type ContainerEntry = {
  key: string;
  label: string;
  labelKind: LabelKind;
  value: unknown;
};

const props = withDefaults(defineProps<Props>(), {
  label: null,
  labelKind: null,
  depth: 0,
});

const INDENT_PX = 18;
const LONG_STRING_LIMIT = 160;
const DATA_URL_PREVIEW_LIMIT = 72;
const BASE64_MARKER_LENGTH = 256;

const depth = computed(() => Math.max(0, Number(props.depth) || 0));
const lineStyle = computed(() => ({ paddingLeft: `${depth.value * INDENT_PX}px` }));
const childLineStyle = computed(() => ({ paddingLeft: `${(depth.value + 1) * INDENT_PX}px` }));

const isArray = computed(() => Array.isArray(props.value));
const isObject = computed(
  () => props.value !== null && typeof props.value === 'object' && !Array.isArray(props.value)
);
const isContainer = computed(() => isArray.value || isObject.value);
const hasLabel = computed(() => Boolean(props.label));

const formatKeyLabel = (value: string) => JSON.stringify(value);
const formatIndexLabel = (value: string) => `[${value}]`;

const formattedLabel = computed(() => {
  if (!hasLabel.value) return '';
  return props.labelKind === 'index'
    ? formatIndexLabel(props.label as string)
    : formatKeyLabel(props.label as string);
});

const labelClass = computed(() =>
  props.labelKind === 'index' ? 'json-label json-label-index' : 'json-label json-label-key'
);

const objectEntries = computed<ContainerEntry[]>(() => {
  if (!isObject.value) return [];
  return Object.entries(props.value as Record<string, unknown>).map(([key, value]) => ({
    key,
    label: key,
    labelKind: 'key',
    value,
  }));
});

const arrayEntries = computed<ContainerEntry[]>(() => {
  if (!isArray.value) return [];
  return (props.value as unknown[]).map((value, index) => ({
    key: String(index),
    label: String(index),
    labelKind: 'index',
    value,
  }));
});

const containerEntries = computed(() => (isArray.value ? arrayEntries.value : objectEntries.value));

const openingBracket = computed(() => (isArray.value ? '[' : '{'));
const closingBracket = computed(() => (isArray.value ? ']' : '}'));
const emptySummary = computed(() => (isArray.value ? 'No items' : 'No keys'));

const containerSummaryParts = computed(() => {
  if (isArray.value) {
    const count = containerEntries.value.length;
    return `${count} ${count === 1 ? 'item' : 'items'}`;
  }

  const keys = objectEntries.value.map((entry) => entry.label);
  const count = keys.length;
  const preview = keys.slice(0, 4).join(', ');

  if (!preview) {
    return `${count} ${count === 1 ? 'key' : 'keys'}`;
  }

  return `${count} ${count === 1 ? 'key' : 'keys'}: ${preview}${count > 4 ? ', ...' : ''}`;
});

const collapsedSummary = computed(() => ` ${containerSummaryParts.value} `);

const stringValue = computed(() => (typeof props.value === 'string' ? props.value : ''));
const dataUrlMatch = computed(() => stringValue.value.match(/^data:([^;]+);base64,/i));
const looksLikeDataUrl = computed(() => Boolean(dataUrlMatch.value));

const looksLikeBase64 = computed(() => {
  if (typeof props.value !== 'string') return false;
  if (stringValue.value.length < BASE64_MARKER_LENGTH) return false;
  const sample = stringValue.value.replace(/\s+/g, '').slice(0, BASE64_MARKER_LENGTH);
  if (!sample.length) return false;
  return /^[A-Za-z0-9+/=]+$/.test(sample);
});

const isLongString = computed(() => {
  if (typeof props.value !== 'string') return false;
  return (
    stringValue.value.length > LONG_STRING_LIMIT || looksLikeDataUrl.value || looksLikeBase64.value
  );
});

const initialExpanded = computed(() => {
  if (depth.value === 0) return true;
  if (isContainer.value) return false;
  return !isLongString.value;
});

const expanded = ref(initialExpanded.value);

watch(
  () => [props.value, props.label, props.labelKind, depth.value],
  () => {
    expanded.value = initialExpanded.value;
  }
);

const longStringPreview = computed(() => {
  const limit = looksLikeDataUrl.value ? DATA_URL_PREVIEW_LIMIT : LONG_STRING_LIMIT;
  const preview = stringValue.value.length > limit ? `${stringValue.value.slice(0, limit)}...` : stringValue.value;
  return JSON.stringify(preview);
});

const longStringMeta = computed(() => {
  const parts = [`${stringValue.value.length} chars`];

  if (looksLikeDataUrl.value) {
    parts.push(dataUrlMatch.value?.[1] ? `data URL ${dataUrlMatch.value[1]}` : 'data URL');
  } else if (looksLikeBase64.value) {
    parts.push('base64-like');
  }

  return `(${parts.join(' · ')})`;
});

const quotedStringValue = computed(() => JSON.stringify(stringValue.value));

const primitiveText = computed(() => {
  if (typeof props.value === 'string') return JSON.stringify(props.value);
  if (props.value === null) return 'null';
  if (typeof props.value === 'number' || typeof props.value === 'boolean') return String(props.value);
  if (typeof props.value === 'bigint') return `${props.value.toString()}n`;
  if (props.value === undefined) return 'undefined';
  return JSON.stringify(props.value) ?? String(props.value);
});

const valueClass = computed(() => {
  if (typeof props.value === 'string') return 'json-string';
  if (typeof props.value === 'number') return 'json-number';
  if (typeof props.value === 'boolean') return 'json-boolean';
  if (props.value === null) return 'json-null';
  return 'json-unknown';
});
</script>

<style scoped>
.json-node {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  font-size: 0.78rem;
  line-height: 1.45;
  color: var(--json-color-default, #e2e8f0);
}

.json-line {
  display: block;
}

.json-toggle,
.json-toggle-spacer {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 1rem;
  margin-right: 4px;
  vertical-align: top;
}

.json-toggle {
  border: none;
  padding: 0;
  background: transparent;
  color: var(--json-color-toggle, #94a3b8);
  cursor: pointer;
  font: inherit;
}

.json-toggle:hover {
  color: var(--json-color-toggle-hover, #e2e8f0);
}

.json-label-key {
  color: var(--json-color-key, #fb923c);
}

.json-label-index {
  color: var(--json-color-index, #cbd5e1);
}

.json-colon,
.json-bracket {
  color: var(--json-color-punctuation, #cbd5e1);
}

.json-summary,
.json-empty,
.json-string-meta {
  color: var(--json-color-summary, #94a3b8);
}

.json-string {
  color: var(--json-color-string, #6ee7b7);
  word-break: break-word;
}

.json-number {
  color: var(--json-color-number, #93c5fd);
}

.json-boolean {
  color: var(--json-color-boolean, #c4b5fd);
}

.json-null,
.json-unknown {
  color: var(--json-color-null, #94a3b8);
}

.json-string-full {
  margin: 0;
  white-space: pre-wrap;
  word-break: break-word;
  color: var(--json-color-string, #6ee7b7);
}
</style>
