<template>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="emitClose">
      <div class="modal" role="dialog" aria-modal="true" style="max-width: 760px">
        <h3 style="margin: 0 0 12px">{{ title }}</h3>

        <div class="tabs" style="margin-bottom: 12px">
          <button class="tab" :class="{ active: step === 'groups' }" type="button" @click="step = 'groups'">
            Groups
          </button>
          <button class="tab" :class="{ active: step === 'tools' }" type="button" @click="step = 'tools'">
            Tools
          </button>
        </div>

        <div v-if="step === 'groups'">
          <p class="muted" style="margin-top: 0">
            Select groups that should have access. Group members will see this bot read-only.
          </p>

          <div v-if="loading" class="muted">Loading…</div>
          <div v-else class="stack" style="gap: 10px; max-height: 55vh; overflow: auto">
            <p v-if="!groups.length" class="muted">You are not a member of any groups.</p>
            <label v-for="group in groups" :key="group.id" class="flex" style="gap: 10px; align-items: center">
              <input v-model="selected" type="checkbox" :value="group.id" :disabled="saving" />
              <span>{{ group.name }}</span>
            </label>
          </div>
        </div>

        <div v-else>
          <p class="muted" style="margin-top: 0">
            Choose which tools should be shared with group members and which should be connected by each user.
          </p>

          <p v-if="hasUnsavedTools" class="muted" style="margin-top: 0">
            Unsaved tool bindings are not included here. Save the bot to include newly added tools.
          </p>

          <div style="max-height: 45vh; overflow: auto">
            <ToolBindingsCard
              :show-header="false"
              :items="persistedTools"
              :toolLabel="toolLabel"
              emptyText="No tools attached."
              :show-toggle="false"
              :show-actions="false"
              readonly
            >
              <template #item-meta-extra="{ item }">
                <div v-if="!item.enabled" class="muted" style="font-size: 0.85rem; margin-top: 4px">(disabled)</div>
              </template>

              <template #item-secondary-actions="{ item }">
                <div class="stack" style="gap: 6px">
                  <label class="flex" style="gap: 8px; align-items: center; justify-content: flex-end">
                    <input
                      v-model="toolModes[String(item.id)]"
                      type="radio"
                      :name="`tool-mode-${item.id}`"
                      value="shared"
                      :disabled="saving"
                    />
                    <span>Shared</span>
                  </label>
                  <label class="flex" style="gap: 8px; align-items: center; justify-content: flex-end">
                    <input
                      v-model="toolModes[String(item.id)]"
                      type="radio"
                      :name="`tool-mode-${item.id}`"
                      value="per_user"
                      :disabled="saving"
                    />
                    <span>Per-user</span>
                  </label>
                </div>
              </template>

              <template #item-footer="{ item }">
                <p
                  v-if="toolModes[String(item.id)] === 'shared'"
                  class="muted"
                  style="margin: 8px 0 0; font-size: 0.85rem"
                >
                  Shared tools run using your tool credentials for all group members.
                </p>
                <p v-else class="muted" style="margin: 8px 0 0; font-size: 0.85rem">
                  Per-user tools must be connected by each group member for this alias.
                </p>
              </template>
            </ToolBindingsCard>
          </div>

          <div v-if="requiresConfirmation" class="card stack" style="padding: 10px; margin-top: 12px">
            <label class="flex" style="gap: 10px; align-items: flex-start">
              <input v-model="confirmSharedTools" type="checkbox" :disabled="saving" />
              <span>I understand that shared tools will run using my credentials.</span>
            </label>
          </div>
        </div>

        <div class="modal-actions">
          <button
            class="primary"
            type="button"
            :disabled="saving || loading || (requiresConfirmation && !confirmSharedTools)"
            @click="emitSave"
          >
            {{ saving ? 'Saving…' : 'Save' }}
          </button>
          <button type="button" :disabled="saving" @click="emitClose">Cancel</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import ToolBindingsCard from '@/components/ToolBindingsCard.vue';
import type { Group } from '@/types/api';

export type BotShareToolBinding = {
  id: number;
  alias: string;
  enabled: boolean;
  sharing_mode?: string;
  tool_instance_name?: string;
  tool_instance_type?: string;
};

const props = withDefaults(
  defineProps<{
    open: boolean;
    title?: string;
    groups: Group[];
    selectedGroupIds: number[];
    toolBindings: BotShareToolBinding[];
    loading?: boolean;
    saving?: boolean;
  }>(),
  {
    title: 'Share bot',
    loading: false,
    saving: false,
  }
);

const emit = defineEmits<{
  (
    e: 'save',
    payload: { groupIds: number[]; toolModes: Record<string, 'shared' | 'per_user'> }
  ): void;
  (e: 'update:open', value: boolean): void;
}>();

const step = ref<'groups' | 'tools'>('groups');
const selected = ref<number[]>([]);
const toolModes = ref<Record<string, 'shared' | 'per_user'>>({});
const confirmSharedTools = ref(false);

const persistedTools = computed(() => (props.toolBindings || []).filter((item) => typeof item.id === 'number' && item.id > 0));
const hasUnsavedTools = computed(() => (props.toolBindings || []).some((item) => typeof item.id !== 'number' || item.id <= 0));

const toolLabel = (binding: BotShareToolBinding) => {
  const name = (binding.tool_instance_name || '').trim() || `Tool ${binding.id}`;
  const type = (binding.tool_instance_type || '').trim();
  return type ? `${name} · ${type}` : name;
};

const sharingActive = computed(() => selected.value.length > 0);
const sharedEnabledToolsCount = computed(() =>
  persistedTools.value.filter((item) => Boolean(item.enabled) && toolModes.value[String(item.id)] === 'shared').length
);
const requiresConfirmation = computed(() => sharingActive.value && sharedEnabledToolsCount.value > 0);

const resetState = () => {
  step.value = 'groups';
  selected.value = [...(props.selectedGroupIds || [])];
  const nextModes: Record<string, 'shared' | 'per_user'> = {};
  persistedTools.value.forEach((item) => {
    nextModes[String(item.id)] = item.sharing_mode === 'per_user' ? 'per_user' : 'shared';
  });
  toolModes.value = nextModes;
  confirmSharedTools.value = false;
};

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) resetState();
  }
);

watch(
  () => props.selectedGroupIds,
  (ids) => {
    if (props.open) selected.value = [...(ids || [])];
  }
);

watch(
  () => props.toolBindings,
  () => {
    if (props.open) resetState();
  }
);

watch(requiresConfirmation, (need) => {
  if (!need) confirmSharedTools.value = false;
});

const emitClose = () => emit('update:open', false);
const emitSave = () =>
  emit('save', {
    groupIds: [...selected.value],
    toolModes: { ...(toolModes.value || {}) },
  });
</script>
