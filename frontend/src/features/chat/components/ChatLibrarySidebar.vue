<template>
  <section class="sidebar" :class="{ overlay: isMobile, 'align-right': isMobile }">
    <div class="panel-header">
      <h3 style="margin: 0">Library</h3>
      <button
        class="panel-toggle"
        type="button"
        @click="emit('update:rightOpen', false)"
        aria-label="Hide library"
      >
        <SvgIcon name="chevron-right" />
      </button>
    </div>

    <div class="stack panel-body" style="gap: 14px">
      <div class="panel-pane chat-library-pane">
        <div v-if="!readonly && chatTabDirty" class="panel-actions">
          <button
            class="primary"
            type="button"
            :disabled="savingChatChanges"
            @click="emit('save-chat-changes')"
          >
            {{ savingChatChanges ? 'Saving…' : 'Save' }}
          </button>
          <button type="button" :disabled="savingChatChanges" @click="emit('cancel-chat-changes')">
            Cancel
          </button>
        </div>

        <div class="panel-section">
          <KnowledgeBlockLinksCard
            title="Chat blocks"
            :items="chatBlocks"
            :blockName="chatBlockName"
            :blockImage="chatBlockImage"
            :metaText="chatBlockMeta"
            :openable="true"
            :readonly="readonly"
            :addDisabled="readonly || savingChatChanges"
            :newDisabled="readonly || savingChatChanges"
            @add="emit('open-chat-blocks-picker')"
            @new="emit('open-new-block')"
            @open="(blockId) => emit('open-chat-block-editor', blockId)"
            @move="(block, delta) => emit('move-chat-block', block, delta)"
            @remove="(id) => emit('remove-chat-block', id)"
            @toggle="(block, enabled) => emit('set-chat-block-enabled', block.id, enabled)"
          />
        </div>

        <div class="panel-section">
          <ToolBindingsCard
            title="Tools"
            :items="chatToolBindings"
            :toolLabel="toolBindingLabel"
            :toolText="toolBindingText"
            :toolType="toolBindingType"
            :toolIsOutlet="toolBindingIsOutlet"
            :toolIsOnline="toolBindingIsOnline"
            emptyText="No tools linked."
            toggleLabel="enabled"
            :openable="true"
            :addDisabled="readonly || savingChatChanges || !toolLibrary.length"
            @add="openToolBindingPicker"
            @open="(toolInstanceId) => emit('open-chat-tool-editor', toolInstanceId)"
            :toggleDisabled="() => readonly || savingChatChanges"
            :actionsDisabled="() => readonly || savingChatChanges"
            @toggle="(binding, enabled) => emit('set-chat-tool-binding-enabled', binding.id, enabled)"
            @move="(binding, delta) => emit('move-chat-tool-binding', binding, delta)"
            @remove="(id) => emit('remove-chat-tool-binding', id)"
          >
            <template #note>
              <p v-if="!toolLibrary.length" class="muted" style="margin: 0">No editable tools available.</p>
            </template>
          </ToolBindingsCard>
        </div>

      </div>
    </div>

    <ToolBindingPickerModal
      v-model:open="toolBindingPickerOpen"
      :selected="newChatToolInstanceIds"
      title="Add chat tool"
      :tools="toolLibrary"
      :disabledToolIds="linkedToolInstanceIds"
      :saving="readonly || savingChatChanges"
      @update:selected="(value) => emit('update:newChatToolInstanceIds', value)"
      @confirm="confirmToolBindings"
    />
  </section>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import ToolBindingsCard from '@/components/ToolBindingsCard.vue';
import ToolBindingPickerModal from '@/components/ToolBindingPickerModal.vue';
import { toolBindingDisplayText } from '@/features/tools/model/toolInstances';
import type { ImageAsset, ToolInstanceOption } from '@/types/api';

type ChatBlockLink = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
};

type ChatToolBindingLink = {
  id: number;
  alias: string;
  enabled: boolean;
  sequence: number;
  tool_instance_id: number;
};

interface Props {
  isMobile: boolean;
  chatTabDirty: boolean;
  savingChatChanges: boolean;
  readonly?: boolean;
  chatBlocks: ChatBlockLink[];
  chatToolBindings: ChatToolBindingLink[];
  toolLibrary: ToolInstanceOption[];
  newChatToolInstanceIds: number[];
  chatBlockName: (blockId: number) => string;
  chatBlockImage: (blockId: number) => ImageAsset | null;
  chatBlockMeta: (block: ChatBlockLink) => string;
  toolLabel: (toolInstanceId: number) => string;
  toolIsOutlet: (toolInstanceId: number) => boolean;
  toolIsOnline: (toolInstanceId: number) => boolean;
}

const props = withDefaults(defineProps<Props>(), {
  readonly: false,
});
const toolBindingPickerOpen = ref(false);

const emit = defineEmits<{
  (e: 'update:rightOpen', value: boolean): void;
  (e: 'save-chat-changes'): void;
  (e: 'cancel-chat-changes'): void;
  (e: 'open-chat-blocks-picker'): void;
  (e: 'open-new-block'): void;
  (e: 'open-chat-block-editor', blockId: number): void;
  (e: 'move-chat-block', block: ChatBlockLink, delta: number): void;
  (e: 'remove-chat-block', blockId: number): void;
  (e: 'set-chat-block-enabled', blockId: number, enabled: boolean): void;
  (e: 'update:newChatToolInstanceIds', value: number[]): void;
  (e: 'add-chat-tool-binding', value: number[]): void;
  (e: 'open-chat-tool-editor', toolInstanceId: number): void;
  (e: 'move-chat-tool-binding', binding: ChatToolBindingLink, delta: number): void;
  (e: 'remove-chat-tool-binding', bindingId: number): void;
  (e: 'set-chat-tool-binding-enabled', bindingId: number, enabled: boolean): void;
}>();

const openToolBindingPicker = () => {
  if (props.readonly) return;
  toolBindingPickerOpen.value = true;
};

const linkedToolInstanceIds = computed(() => props.chatToolBindings.map((binding) => binding.tool_instance_id));

const confirmToolBindings = (toolInstanceIds: number[]) => {
  if (props.readonly) return;
  emit('add-chat-tool-binding', toolInstanceIds);
};

const toolBindingLabel = (binding: ChatToolBindingLink) => props.toolLabel(binding.tool_instance_id);
const toolBindingText = (binding: ChatToolBindingLink) => {
  const tool = props.toolLibrary.find((item) => item.id === binding.tool_instance_id);
  return toolBindingDisplayText(tool, binding.alias, `Tool #${binding.tool_instance_id}`);
};
const toolBindingType = (binding: ChatToolBindingLink) =>
  props.toolLibrary.find((item) => item.id === binding.tool_instance_id)?.type || '';
const toolBindingIsOutlet = (binding: ChatToolBindingLink) => props.toolIsOutlet(binding.tool_instance_id);
const toolBindingIsOnline = (binding: ChatToolBindingLink) => props.toolIsOnline(binding.tool_instance_id);
</script>

<style scoped>
.chat-library-pane {
  display: flex;
  flex-direction: column;
}

.chat-library-pane .panel-section + .panel-section {
  padding-top: 12px;
  border-top: 1px solid rgba(148, 163, 184, 0.28);
}
</style>
