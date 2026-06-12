<template>
  <ModalWindow
    :open="open"
    backdrop-class="modal-backdrop--mobile-stretch"
    modal-class="tool-binding-picker"
    aria-label="Select tools"
    :cancel-disabled="saving"
    :submit-disabled="confirmDisabled"
    submit-shortcut="auto"
    @cancel="close"
    @submit="confirm"
  >
        <div class="picker-header">
          <strong>{{ title }}</strong>
        </div>

        <div class="picker-body">
          <div class="split-wrapper picker-split-wrapper">
            <div class="catalog-split picker-split">
              <aside class="catalog-split__sidebar">
                <section class="card stack picker-types-card">
                  <div class="picker-filter-header">
                    <strong>Type</strong>
                    <button
                      type="button"
                      class="link"
                      :disabled="saving || loading || !hasActiveTypeFilter"
                      @click="clearType"
                    >
                      Clear
                    </button>
                  </div>

                  <p v-if="loading" class="muted">Loading…</p>
                  <div v-else-if="toolTypeOptions.length" class="type-filter-list" aria-label="Filter by type">
                    <button
                      type="button"
                      class="type-filter-option"
                      :class="{ active: !selectedToolType }"
                      :disabled="saving"
                      :aria-pressed="!selectedToolType"
                      @click="clearType"
                    >
                      <span class="type-filter-option__label">
                        <span class="type-filter-option__name">All types</span>
                      </span>
                      <span class="type-filter-option__count">{{ tools.length }}</span>
                    </button>

                    <button
                      v-for="option in toolTypeOptions"
                      :key="option.type"
                      type="button"
                      class="type-filter-option"
                      :class="{ active: selectedToolType === option.type }"
                      :disabled="saving"
                      :aria-pressed="selectedToolType === option.type"
                      @click="selectType(option.type)"
                    >
                      <span class="type-filter-option__label">
                        <ToolTypeBadge :type="option.type" :typeTitle="option.title" />
                      </span>
                      <span class="type-filter-option__count">{{ option.count }}</span>
                    </button>
                  </div>
                  <p v-else class="muted">No tool types.</p>
                </section>
              </aside>

              <main class="catalog-split__main stack picker-main">
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
                  <button
                    v-if="selectedLocal.length"
                    type="button"
                    :disabled="saving"
                    @click="emit('update:selected', [])"
                  >
                    Clear selection
                  </button>
                  <button
                    v-if="isMobile && !typesOverlayOpen"
                    class="panel-toggle"
                    :class="{ 'active-filter': hasActiveTypeFilter }"
                    type="button"
                    :disabled="saving || loading"
                    @click="openTypesOverlay"
                    aria-label="Show type filter"
                  >
                    <SvgIcon name="filter" />
                  </button>
                </div>

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
              </main>
            </div>

            <transition name="fade">
              <div v-if="isMobile && typesOverlayOpen" class="panel-backdrop" @click="closeTypesOverlay"></div>
            </transition>

            <aside v-if="isMobile && typesOverlayOpen" class="sidebar overlay align-left picker-types-overlay">
              <div class="panel-header" style="justify-content: space-between; margin-bottom: 6px">
                <strong>Type</strong>
                <div style="display: inline-flex; align-items: center; gap: 8px">
                  <button
                    type="button"
                    class="link"
                    :disabled="saving || loading || !hasActiveTypeFilter"
                    @click="clearType"
                  >
                    Clear
                  </button>
                  <button class="panel-toggle" type="button" @click="closeTypesOverlay" aria-label="Hide type filter">
                    <SvgIcon name="chevron-left" />
                  </button>
                </div>
              </div>

              <p v-if="loading" class="muted">Loading…</p>
              <div v-else-if="toolTypeOptions.length" class="type-filter-list" aria-label="Filter by type">
                <button
                  type="button"
                  class="type-filter-option"
                  :class="{ active: !selectedToolType }"
                  :disabled="saving"
                  :aria-pressed="!selectedToolType"
                  @click="clearType"
                >
                  <span class="type-filter-option__label">
                    <span class="type-filter-option__name">All types</span>
                  </span>
                  <span class="type-filter-option__count">{{ tools.length }}</span>
                </button>

                <button
                  v-for="option in toolTypeOptions"
                  :key="option.type"
                  type="button"
                  class="type-filter-option"
                  :class="{ active: selectedToolType === option.type }"
                  :disabled="saving"
                  :aria-pressed="selectedToolType === option.type"
                  @click="selectType(option.type)"
                >
                  <span class="type-filter-option__label">
                    <ToolTypeBadge :type="option.type" :typeTitle="option.title" />
                  </span>
                  <span class="type-filter-option__count">{{ option.count }}</span>
                </button>
              </div>
              <p v-else class="muted">No tool types.</p>
            </aside>
          </div>
        </div>

        <div class="modal-actions picker-actions">
          <div class="spacer"></div>
          <button type="button" :disabled="saving" @click="close">Cancel</button>
          <button class="primary" type="button" :disabled="confirmDisabled" @click="confirm">
            {{ saving ? 'Adding…' : confirmLabelWithCount }}
          </button>
        </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import ModalWindow from '@/components/ModalWindow.vue';
import { toolTypeLabel } from '@/features/tools/model/toolInstances';
import ToolBindingListItem from '@/components/ToolBindingListItem.vue';
import ToolTypeBadge from '@/components/ToolTypeBadge.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type ToolOption = {
  id: number;
  name: string;
  alias: string;
  type: string;
  type_title?: string | null;
  outlet_online?: boolean | null;
};

type ToolTypeOption = {
  type: string;
  title: string;
  count: number;
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
    confirmLabel: 'Add',
  }
);

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void;
  (e: 'update:selected', value: number[]): void;
  (e: 'confirm', value: number[]): void;
}>();

const query = ref('');
const selectedToolType = ref('');
const isMobile = ref(false);
const typesOverlayOpen = ref(false);
const selectedLocal = computed(() => props.selected ?? []);
const hasActiveTypeFilter = computed(() => selectedToolType.value.trim().length > 0);

const isDisabled = (id: number) => (props.disabledToolIds || []).includes(id);
const normalize = (text: unknown) => String(text ?? '').trim().toLowerCase();
const toolTypeName = (tool: ToolOption) => toolTypeLabel(tool);
const toolName = (tool: ToolOption) => String(tool.name || '').trim() || `Tool #${tool.id}`;
const toolAlias = (tool: ToolOption) => String(tool.alias || '').trim();
const normalizeType = (value: unknown) => String(value ?? '').trim();

const toolTypeOptions = computed<ToolTypeOption[]>(() => {
  const byType = new Map<string, ToolTypeOption>();

  for (const tool of props.tools || []) {
    const type = normalizeType(tool.type);
    if (!type) continue;

    const existing = byType.get(type);
    if (existing) {
      existing.count += 1;
      continue;
    }

    byType.set(type, {
      type,
      title: toolTypeName(tool),
      count: 1,
    });
  }

  return Array.from(byType.values()).sort(
    (a, b) => a.title.localeCompare(b.title) || a.type.localeCompare(b.type)
  );
});

const visibleTools = computed(() => {
  const q = normalize(query.value);
  const type = normalizeType(selectedToolType.value);
  const tools = props.tools || [];

  return tools.filter((tool) => {
    if (type && normalizeType(tool.type) !== type) return false;
    if (!q) return true;

    return [tool.alias, tool.name, toolTypeName(tool), tool.type, `Tool #${tool.id}`].some((value) =>
      normalize(value).includes(q)
    );
  });
});

const enabledSelection = computed(() => selectedLocal.value.filter((id) => !isDisabled(id)));

const confirmLabelWithCount = computed(() => {
  const base = props.confirmLabel ?? 'Add';
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

function updateIsMobile() {
  isMobile.value = window.matchMedia('(max-width: 860px)').matches;
}

function openTypesOverlay() {
  typesOverlayOpen.value = true;
}

function closeTypesOverlay() {
  typesOverlayOpen.value = false;
}

function selectType(type: string) {
  if (props.saving) return;
  const normalized = normalizeType(type);
  selectedToolType.value = selectedToolType.value === normalized ? '' : normalized;
  if (isMobile.value) closeTypesOverlay();
}

function clearType() {
  if (props.saving) return;
  selectedToolType.value = '';
  if (isMobile.value) closeTypesOverlay();
}

watch(
  () => props.open,
  (open) => {
    if (!open) {
      closeTypesOverlay();
      return;
    }

    query.value = '';
    selectedToolType.value = '';
    closeTypesOverlay();
  }
);

watch(
  () => toolTypeOptions.value,
  (options) => {
    if (!selectedToolType.value) return;
    if (!options.some((option) => option.type === selectedToolType.value)) {
      selectedToolType.value = '';
    }
  }
);

watch(
  () => isMobile.value,
  (mobile) => {
    if (!mobile) closeTypesOverlay();
  }
);

onMounted(() => {
  updateIsMobile();
  window.addEventListener('resize', updateIsMobile);
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', updateIsMobile);
});
</script>

<style scoped>
:global(.tool-binding-picker) {
  container-type: inline-size;
  width: min(880px, 96vw);
  height: min(90vh, 760px);
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
  gap: 8px;
}

.picker-header {
  justify-content: space-between;
}

.picker-filter-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.picker-body {
  flex: 1;
  min-height: 0;
  overflow: hidden;
}

.picker-split-wrapper {
  min-height: 0;
  height: 100%;
}

.picker-split {
  height: 100%;
  min-height: 0;
  align-items: stretch;
}

.picker-split .catalog-split__sidebar {
  height: 100%;
  min-height: 0;
}

.picker-types-card {
  min-height: 0;
  height: 100%;
  overflow: hidden;
}

.picker-main {
  min-height: 0;
}

.picker-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow: auto;
  overscroll-behavior: contain;
  -webkit-overflow-scrolling: touch;
}

.picker-types-overlay {
  top: calc(env(safe-area-inset-top) + 8px);
  bottom: calc(env(safe-area-inset-bottom) + 8px);
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

.type-filter-list {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  gap: 4px;
  min-height: 0;
  overflow: auto;
  padding: 2px;
}

.type-filter-option {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 8px;
  width: 100%;
  min-height: 36px;
  padding: 7px 8px;
  border: 0;
  border-radius: 6px;
  background: transparent;
  color: inherit;
  text-align: left;
  cursor: pointer;
}

.type-filter-option:hover,
.type-filter-option:focus-visible,
.type-filter-option.active {
  background: var(--color-info-bg-strong);
  outline: none;
}

.type-filter-option:disabled {
  cursor: not-allowed;
  opacity: 0.65;
}

.type-filter-option__label {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
  overflow: hidden;
}

.type-filter-option__name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.type-filter-option__count {
  flex: 0 0 auto;
  min-width: 1.5em;
  color: var(--color-text-subtle);
  font-size: 0.85rem;
  text-align: right;
}

@media (max-width: 720px) {
  :global(.modal-backdrop--mobile-stretch) {
    padding: 0;
    align-items: stretch;
    justify-content: stretch;
  }

  :global(.tool-binding-picker) {
    width: 100%;
    height: calc(var(--app-vh, 1vh) * 100);
    max-height: calc(var(--app-vh, 1vh) * 100);
    border-radius: 0;
    padding-top: calc(12px + env(safe-area-inset-top));
    padding-right: 12px;
    padding-bottom: calc(12px + env(safe-area-inset-bottom));
    padding-left: 12px;
  }
}

</style>
