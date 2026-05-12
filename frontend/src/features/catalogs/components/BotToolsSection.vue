<template>
  <div class="stack">
    <p v-if="sharedReadonly" class="muted">
      This shared bot is read-only. You can still connect your own tools for aliases configured as per-user.
    </p>
    <p v-else-if="isNew" class="muted">Save the bot before attaching tools.</p>

    <div v-if="sharedReadonly" class="card stack" style="padding: 10px">
      <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
        <strong>Your tool overrides</strong>
        <span class="muted" style="font-size: 0.85rem">Only for per-user aliases</span>
      </div>

      <p v-if="userToolBindingsLoading" class="muted">Loading…</p>
      <p v-else-if="userToolBindingsError" class="error-text">{{ userToolBindingsError }}</p>
      <p v-else-if="!perUserBaseBindings.length" class="muted">
        This bot does not have any per-user tool aliases.
      </p>
      <div v-else class="stack" style="gap: 10px">
        <div v-for="bt in perUserBaseBindings" :key="`user-binding-${bt.id}`" class="card" style="padding: 10px">
          <div class="stack" style="gap: 10px">
            <div class="flex" style="justify-content: space-between; gap: 10px; align-items: center">
              <div style="min-width: 0">
                <div style="font-weight: 700">{{ bt.alias }}</div>
                <div class="muted" style="font-size: 0.85rem">
                  {{ bt.enabled ? 'Required by the bot when enabled.' : 'Currently disabled on the shared bot.' }}
                </div>
              </div>
              <label class="flex" style="gap: 6px; white-space: nowrap">
                <input
                  type="checkbox"
                  :checked="userToolDraft(bt.alias).enabled"
                  :disabled="userToolBindingSavingAliases.has(bt.alias)"
                  @change="handleUserToolEnabled(bt.alias, $event)"
                />
                enabled
              </label>
            </div>

            <label class="stack" style="gap: 6px">
              <span class="muted">Your tool</span>
              <select
                :value="userToolDraft(bt.alias).tool_instance_id"
                class="full"
                :disabled="userToolBindingSavingAliases.has(bt.alias) || !matchingAliasTools(bt.alias).length"
                @change="handleUserToolSelect(bt.alias, $event)"
              >
                <option :value="0">Choose your tool…</option>
                <option v-for="tool in matchingAliasTools(bt.alias)" :key="tool.id" :value="tool.id">
                  {{ tool.alias }} · {{ tool.name }} ({{ tool.type }})
                </option>
              </select>
            </label>

            <p v-if="!matchingAliasTools(bt.alias).length" class="muted" style="margin: 0; font-size: 0.85rem">
              Create or edit one of your tools with this alias to connect it here.
            </p>

            <div class="muted" style="font-size: 0.85rem">
              <template v-if="userToolDraft(bt.alias).binding_id">
                Connected: {{ userToolBindingLabel(bt.alias) }}
              </template>
              <template v-else>
                No personal tool connected for this alias yet.
              </template>
            </div>

            <div class="flex" style="gap: 8px; align-items: center">
              <button
                type="button"
                class="primary"
                :disabled="userToolBindingSavingAliases.has(bt.alias) || !userToolDraft(bt.alias).tool_instance_id"
                @click="emit('save-user-tool-binding', bt)"
              >
                Save override
              </button>
              <button
                type="button"
                class="danger"
                :disabled="userToolBindingSavingAliases.has(bt.alias) || !userToolDraft(bt.alias).binding_id"
                @click="emit('remove-user-tool-binding', bt)"
              >
                Remove override
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <p v-if="toolBindingsLoading" class="muted">Loading…</p>
    <p v-else-if="toolBindingsError" class="error-text">{{ toolBindingsError }}</p>

    <ToolBindingsCard
      v-else
      title="Tool bindings"
      :items="displayToolBindings"
      :toolLabel="toolBindingLabel"
      :toolText="toolBindingText"
      :toolIsOutlet="toolBindingIsOutlet"
      :toolIsOnline="toolBindingIsOnline"
      emptyText="No tools attached."
      toggleLabel="enabled"
      :readonly="sharedReadonly"
      :addDisabled="isNew || toolLibraryLoading || toolBindingsSaving || sharedReadonly"
      :toggleDisabled="() => toolBindingsSaving"
      :actionsDisabled="() => toolBindingsSaving"
      @add="openToolBindingPicker"
      @toggle="(binding, enabled) => emit('toggle-tool-binding', binding.id, enabled)"
      @move="(binding, delta) => emit('move-tool-binding', binding.id, delta)"
      @remove="(id) => emit('remove-tool-binding', id)"
    >
      <template #header-actions>
        <button
          type="button"
          :disabled="isNew || toolLibraryLoading || toolBindingsSaving || sharedReadonly"
          @click="openToolBindingPicker"
        >
          Add
        </button>
      </template>

      <template #note>
        <p v-if="toolLibraryError" class="error-text" style="margin: 0">{{ toolLibraryError }}</p>
      </template>
    </ToolBindingsCard>

    <ToolBindingPickerModal
      v-model:open="toolBindingPickerOpen"
      v-model:toolInstanceId="newToolInstanceId"
      title="Add tool binding"
      :tools="toolLibrary"
      :loading="toolLibraryLoading"
      :saving="toolBindingsSaving"
      :error="toolLibraryError"
      @confirm="confirmToolBinding"
    />
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';

import ToolBindingPickerModal from '@/components/ToolBindingPickerModal.vue';
import ToolBindingsCard from '@/components/ToolBindingsCard.vue';
import type { BotUserToolBindingDraft } from '@/features/catalogs/model/useBotUserToolOverrides';
import type { BotToolBindingRow } from '@/features/catalogs/model/useBotToolBindings';
import { markShadowedToolBindings } from '@/features/tools/model/toolBindings';
import type { ToolInstanceOption } from '@/types/api';

const props = defineProps<{
  isNew: boolean;
  sharedReadonly: boolean;
  resetKey: string | number;
  toolLibrary: ToolInstanceOption[];
  ownedToolLibrary: ToolInstanceOption[];
  toolLibraryLoading: boolean;
  toolLibraryError: string | null;
  toolBindingsLoading: boolean;
  toolBindingsError: string | null;
  toolBindingsSaving: boolean;
  sortedToolBindings: BotToolBindingRow[];
  perUserBaseBindings: BotToolBindingRow[];
  userToolBindingsLoading: boolean;
  userToolBindingsError: string | null;
  userToolBindingSavingAliases: Set<string>;
  toolBindingLabel: (binding: BotToolBindingRow) => string;
  toolBindingText: (binding: BotToolBindingRow) => string;
  toolBindingIsOutlet: (binding: BotToolBindingRow) => boolean;
  toolBindingIsOnline: (binding: BotToolBindingRow) => boolean;
  userToolDraft: (alias: string) => BotUserToolBindingDraft;
  userToolBindingLabel: (alias: string) => string;
  addToolBinding: (toolInstanceId: number, alias: string) => boolean;
}>();

const emit = defineEmits<{
  (e: 'load-tool-library'): void;
  (e: 'move-tool-binding', bindingId: number, delta: number): void;
  (e: 'remove-tool-binding', bindingId: number): void;
  (e: 'toggle-tool-binding', bindingId: number, enabled: boolean): void;
  (e: 'set-user-tool-draft-tool', alias: string, toolInstanceId: number): void;
  (e: 'toggle-user-tool-draft-enabled', alias: string, enabled: boolean): void;
  (e: 'save-user-tool-binding', binding: BotToolBindingRow): void;
  (e: 'remove-user-tool-binding', binding: BotToolBindingRow): void;
}>();

const toolBindingPickerOpen = ref(false);
const newToolInstanceId = ref(0);
const displayToolBindings = computed(() => {
  const marked = markShadowedToolBindings(
    props.sortedToolBindings,
    'Another enabled bot tool with this alias has priority.'
  );

  if (!props.sharedReadonly) return marked;

  return marked.map((binding) => {
    const draft = props.userToolDraft(binding.alias);
    const hasUserOverride = Boolean(draft.binding_id || draft.tool_instance_id);

    if (binding.enabled && binding.sharing_mode !== 'per_user' && hasUserOverride) {
      return {
        ...binding,
        shadowed: true,
        shadowedReason: 'Your tool override has priority for this alias.',
      };
    }

    return binding;
  });
});

function resetPicker() {
  toolBindingPickerOpen.value = false;
  newToolInstanceId.value = 0;
}

watch(
  () => props.resetKey,
  () => resetPicker()
);

function openToolBindingPicker() {
  if (props.isNew || props.sharedReadonly) return;
  if (!props.toolLibrary.length && !props.toolLibraryLoading) emit('load-tool-library');
  toolBindingPickerOpen.value = true;
}

function confirmToolBinding() {
  const toolInstanceId = Number(newToolInstanceId.value || 0);
  const alias = props.toolLibrary.find((tool) => tool.id === toolInstanceId)?.alias || '';
  const added = props.addToolBinding(toolInstanceId, alias);
  if (added) resetPicker();
}

function matchingAliasTools(alias: string) {
  return (props.ownedToolLibrary || []).filter((tool) => tool.alias === alias);
}

function handleUserToolSelect(alias: string, event: Event) {
  const target = event.target as HTMLSelectElement | null;
  emit('set-user-tool-draft-tool', alias, Number(target?.value || 0));
}

function handleUserToolEnabled(alias: string, event: Event) {
  const target = event.target as HTMLInputElement | null;
  emit('toggle-user-tool-draft-enabled', alias, Boolean(target?.checked));
}

defineExpose({
  resetPicker,
});
</script>
