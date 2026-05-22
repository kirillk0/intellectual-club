<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="close">
      <div class="modal tool-binding-picker" role="dialog" aria-modal="true" aria-label="Select tools">
        <div class="picker-header">
          <strong>{{ title }}</strong>
          <button type="button" :disabled="saving" aria-label="Close" @click="close">Close</button>
        </div>

        <div class="picker-controls">
          <input
            v-model="query"
            type="search"
            class="full"
            placeholder="Search tools"
            aria-label="Search tools"
            :disabled="saving"
          />
          <button v-if="query" type="button" :disabled="saving" @click="query = ''">Clear</button>
        </div>

        <div class="picker-body">
          <p v-if="loading" class="muted" style="margin: 0">Loading tools…</p>
          <p v-else-if="error" class="error-text" style="margin: 0">{{ error }}</p>
          <p v-else-if="!tools.length" class="muted" style="margin: 0">No editable tools available.</p>
          <p v-else-if="!visibleTools.length" class="muted" style="margin: 0">No tools found.</p>

          <div v-else class="list picker-list">
            <ToolBindingListItem
              v-for="tool in visibleTools"
              :key="tool.id"
              :name="toolName(tool)"
              :alias="toolAlias(tool)"
              :type="tool.type"
              :typeTitle="toolTypeName(tool)"
              :isOutlet="tool.type === 'outlet'"
              :isOnline="Boolean(tool.outlet_online)"
              as="label"
              :class="{ disabled: isDisabled(tool.id) }"
            >
              <template #leading>
              <input
                class="picker-row__checkbox"
                type="checkbox"
                :disabled="saving || isDisabled(tool.id)"
                :checked="selectedLocal.includes(tool.id)"
                aria-label="Select tool"
                @change="toggle(tool.id)"
              />
              </template>
            </ToolBindingListItem>
          </div>
        </div>

        <div class="modal-actions picker-actions">
          <button class="primary" type="button" :disabled="confirmDisabled" @click="confirm">
            {{ saving ? 'Adding…' : confirmLabelWithCount }}
          </button>
          <button type="button" :disabled="saving" @click="close">Cancel</button>
          <div class="spacer"></div>
          <button
            v-if="selectedLocal.length"
            type="button"
            :disabled="saving"
            @click="emit('update:selected', [])"
          >
            Clear selection
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, ref, watch, Teleport } from 'vue';
import { toolTypeLabel } from '@/features/tools/model/toolInstances';
import ToolBindingListItem from '@/components/ToolBindingListItem.vue';

type ToolOption = {
  id: number;
  name: string;
  alias: string;
  type: string;
  type_title?: string | null;
  outlet_online?: boolean | null;
};

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    tools: ToolOption[];
    selected: number[];
    disabledToolIds?: number[];
    loading?: boolean;
    saving?: boolean;
    error?: string | null;
    confirmLabel?: string;
  }>(),
  {
    title: 'Select tools',
    disabledToolIds: () => [],
    loading: false,
    saving: false,
    error: null,
    confirmLabel: 'Add selected',
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'update:selected', value: number[]): void;
  (e: 'confirm', value: number[]): void;
}>();

const query = ref('');
const selectedLocal = computed(() => props.selected ?? []);

const isDisabled = (id: number) => (props.disabledToolIds || []).includes(id);
const normalize = (text: unknown) => String(text ?? '').trim().toLowerCase();
const toolTypeName = (tool: ToolOption) => toolTypeLabel(tool);
const toolName = (tool: ToolOption) => String(tool.name || '').trim() || `Tool #${tool.id}`;
const toolAlias = (tool: ToolOption) => String(tool.alias || '').trim();
const visibleTools = computed(() => {
  const q = normalize(query.value);
  const tools = props.tools || [];
  if (!q) return tools;

  return tools.filter((tool) =>
    [tool.alias, tool.name, toolTypeName(tool), tool.type, `Tool #${tool.id}`].some((value) =>
      normalize(value).includes(q)
    )
  );
});

const enabledSelection = computed(() => selectedLocal.value.filter((id) => !isDisabled(id)));

const confirmLabelWithCount = computed(() => {
  const base = props.confirmLabel ?? 'Add selected';
  if (!enabledSelection.value.length) return base;
  return `${base} (${enabledSelection.value.length})`;
});

const confirmDisabled = computed(
  () => props.saving || props.loading || !props.tools.length || !enabledSelection.value.length
);

const close = () => {
  if (props.saving) return;
  emit('update:open', false);
};

const confirm = () => {
  if (confirmDisabled.value) return;
  emit('confirm', enabledSelection.value);
  close();
};

const toggle = (id: number) => {
  if (props.saving || isDisabled(id)) return;
  const set = new Set(selectedLocal.value);
  if (set.has(id)) set.delete(id);
  else set.add(id);
  emit('update:selected', Array.from(set));
};

watch(
  () => props.open,
  (open) => {
    if (open) query.value = '';
  }
);
</script>

<style scoped>
.tool-binding-picker {
  container-type: inline-size;
  width: min(640px, 96vw);
  max-height: 90vh;
  overflow: hidden;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.picker-header,
.picker-controls {
  display: flex;
  align-items: center;
  gap: 12px;
}

.picker-header {
  justify-content: space-between;
}

.picker-body {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.picker-list {
  flex: 1 1 auto;
  min-height: 0;
  max-height: min(58vh, 520px);
  overflow: auto;
  overscroll-behavior: contain;
  -webkit-overflow-scrolling: touch;
}

.picker-actions {
  margin-top: 0;
}

.disabled {
  opacity: 0.6;
}

.picker-row__checkbox {
  width: 18px;
  height: 18px;
  margin: 0;
}

@media (max-width: 720px) {
  .modal-backdrop {
    padding: 0;
    align-items: stretch;
    justify-content: stretch;
  }

  .tool-binding-picker {
    width: 100%;
    height: calc(var(--app-vh, 1vh) * 100);
    max-height: calc(var(--app-vh, 1vh) * 100);
    border-radius: 0;
    padding-top: calc(12px + env(safe-area-inset-top));
    padding-right: 12px;
    padding-bottom: calc(12px + env(safe-area-inset-bottom));
    padding-left: 12px;
  }

  .picker-list {
    max-height: none;
  }
}

</style>
