<template>
  <section class="stack web-search-providers">
    <strong>{{ translate('Provider fallback order') }}</strong>
    <p class="muted">{{ translate('Requests use providers in this order. Only failed URLs are retried.') }}</p>
    <div v-for="(provider, index) in providers" :key="index" class="card stack">
      <label>
        {{ translate(index === 0 ? 'Primary provider' : 'Fallback provider') }}
        <select :value="provider" class="full" :aria-label="`${translate('Provider')} ${index + 1}`" @change="setProvider(index, ($event.target as HTMLSelectElement).value)">
          <option v-for="option in choices" :key="option.id" :value="option.id" :disabled="providers.includes(option.id) && provider !== option.id">{{ option.label }}</option>
        </select>
      </label>
      <p v-if="provider === 'brave'" class="muted">{{ translate('Brave reads pages using the built-in Web Reader. Reading does not require a Brave API key.') }}</p>
      <div class="flex provider-actions">
        <button type="button" :disabled="index === 0" :aria-label="`${translate('Move up')} ${index + 1}`" @click="move(index, -1)">{{ translate('Move up') }}</button>
        <button type="button" :disabled="index === providers.length - 1" :aria-label="`${translate('Move down')} ${index + 1}`" @click="move(index, 1)">{{ translate('Move down') }}</button>
        <button type="button" :disabled="providers.length === 1" @click="remove(index)">{{ translate('Remove provider') }}</button>
      </div>
      <details>
        <summary>{{ translate('API endpoints') }}</summary>
        <div class="stack" style="margin-top: 8px">
          <label v-for="(schema, key) in providerSchemas[provider]?.properties || {}" :key="key">
            {{ translate(key === 'fetch_api_base_url' ? 'Fetch API base URL' : 'API base URL') }}
            <input class="full" type="url" :value="endpoint(provider, String(key))" :placeholder="String(schema.default || '')" @input="setEndpoint(provider, String(key), ($event.target as HTMLInputElement).value)" />
          </label>
        </div>
      </details>
    </div>
    <button type="button" :disabled="providers.length >= 3" @click="add">{{ translate('Add fallback provider') }}</button>
  </section>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { translate } from '@/i18n';

type ProviderSchema = { title?: string; properties?: Record<string, { default?: unknown }> };
const props = defineProps<{ modelValue: Record<string, unknown>; providerSchemas: Record<string, ProviderSchema> }>();
const emit = defineEmits<{ 'update:modelValue': [value: Record<string, unknown>] }>();
const choices = computed(() => Object.entries(props.providerSchemas).map(([id, schema]) => ({ id, label: schema.title || id })));
const providers = computed(() => Array.isArray(props.modelValue.providers) ? props.modelValue.providers.filter((id): id is string => typeof id === 'string') : ['brave']);
const options = computed<Record<string, Record<string, unknown>>>(() => {
  const value = props.modelValue.provider_options;
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Record<string, unknown>> : {};
});
function update(providers: string[]) { emit('update:modelValue', { ...props.modelValue, providers }); }
function setProvider(index: number, provider: string) {
  if (providers.value.includes(provider) && providers.value[index] !== provider) return;
  update(providers.value.map((value, position) => position === index ? provider : value));
}
function add() {
  const available = choices.value.find((option) => !providers.value.includes(option.id));
  if (available && providers.value.length < 3) update([...providers.value, available.id]);
}
function remove(index: number) { if (providers.value.length > 1) update(providers.value.filter((_, position) => position !== index)); }
function move(index: number, delta: number) {
  const next = [...providers.value];
  const destination = index + delta;
  if (destination < 0 || destination >= next.length) return;
  [next[index], next[destination]] = [next[destination]!, next[index]!];
  update(next);
}
function endpoint(provider: string, key: string) { return String(options.value[provider]?.[key] || ''); }
function setEndpoint(provider: string, key: string, value: string) {
  const entry = { ...options.value[provider] };
  if (value.trim()) entry[key] = value.trim(); else delete entry[key];
  emit('update:modelValue', { ...props.modelValue, provider_options: { ...options.value, [provider]: entry } });
}
</script>

<style scoped>
.provider-actions { gap: 8px; flex-wrap: wrap; }
</style>
