<template>
  <section class="stack lua-tool-settings">
    <label :class="{ 'field-error': sourceError }">
      <span class="field-label-text">{{ translate('Lua source') }}</span>
      <textarea
        :value="source"
        class="full lua-tool-settings__code"
        rows="18"
        spellcheck="false"
        autocapitalize="off"
        autocomplete="off"
        :readonly="readonly"
        :aria-label="translate('Lua source')"
        :aria-invalid="Boolean(sourceError)"
        :aria-describedby="`${id}-source-hint${sourceError ? ` ${id}-source-error` : ''}`"
        data-testid="lua-source"
        @input="updateSource"
      ></textarea>
      <div v-if="sourceError" :id="`${id}-source-error`" class="error-text" role="alert">{{ sourceError }}</div>
      <div :id="`${id}-source-hint`" class="muted">
        {{ translate('Lua code runs with per-chat-family state. Define the functions declared in the manifest.') }}
      </div>
    </label>

    <label :class="{ 'field-error': manifestError }">
      <span class="field-label-text">{{ translate('Manifest JSON') }}</span>
      <textarea
        :value="manifestText"
        class="full lua-tool-settings__code"
        rows="18"
        spellcheck="false"
        autocapitalize="off"
        autocomplete="off"
        :readonly="readonly"
        :aria-label="translate('Manifest JSON')"
        :aria-invalid="Boolean(manifestError)"
        :aria-describedby="`${id}-manifest-hint${manifestError ? ` ${id}-manifest-error` : ''}`"
        data-testid="lua-manifest"
        @input="updateManifest"
      ></textarea>
      <div v-if="manifestError" :id="`${id}-manifest-error`" class="error-text" role="alert">{{ manifestError }}</div>
      <div :id="`${id}-manifest-hint`" class="muted">
        {{ translate('Define functions with name, description and input_schema, and explicitly allow HTTP methods, URL patterns and secret names in permissions.http.') }}
      </div>
    </label>

    <p class="muted">
      {{ translate('Attach secrets on the Secrets tab and reference their environment variable names in permissions.http[].secrets. Never put secret values in source code or the manifest.') }}
    </p>
  </section>
</template>

<script setup lang="ts">
import { useId } from 'vue';
import { translate } from '@/i18n';

const props = defineProps<{
  source: string;
  manifestText: string;
  sourceError?: string | null;
  manifestError?: string | null;
  readonly?: boolean;
}>();

const emit = defineEmits<{
  'update:source': [value: string];
  'update:manifestText': [value: string];
}>();

const id = useId();

function updateSource(event: Event) {
  if (props.readonly) return;
  emit('update:source', (event.target as HTMLTextAreaElement).value);
}

function updateManifest(event: Event) {
  if (props.readonly) return;
  emit('update:manifestText', (event.target as HTMLTextAreaElement).value);
}
</script>

<style scoped>
.lua-tool-settings__code {
  display: block;
  margin: 6px 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.9rem;
  line-height: 1.5;
  tab-size: 2;
  resize: vertical;
}
</style>
