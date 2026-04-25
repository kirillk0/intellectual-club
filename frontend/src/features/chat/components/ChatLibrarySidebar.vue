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
      <div class="panel-pane">
        <div v-if="chatTabDirty" class="panel-actions">
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
            :addDisabled="savingChatChanges"
            :newDisabled="savingChatChanges"
            @add="emit('open-chat-blocks-picker')"
            @new="emit('open-new-block')"
            @open="(blockId) => emit('open-chat-block-editor', blockId)"
            @move="(block, delta) => emit('move-chat-block', block, delta)"
            @remove="(id) => emit('remove-chat-block', id)"
            @toggle="emit('touch-chat-blocks')"
          />
        </div>

        <div class="panel-section">
          <ToolBindingsCard
            title="Tools"
            :items="chatToolBindings"
            :toolLabel="toolBindingLabel"
            :toolIsOutlet="toolBindingIsOutlet"
            :toolIsOnline="toolBindingIsOnline"
            emptyText="No tools linked."
            toggleLabel="enabled"
            :addDisabled="savingChatChanges || !toolLibrary.length"
            @add="openToolBindingPicker"
            :toggleDisabled="() => savingChatChanges"
            :actionsDisabled="() => savingChatChanges"
            @toggle="(binding, enabled) => emit('set-chat-tool-binding-enabled', binding.id, enabled)"
            @move="(binding, delta) => emit('move-chat-tool-binding', binding, delta)"
            @remove="(id) => emit('remove-chat-tool-binding', id)"
          >
            <template #note>
              <p v-if="!toolLibrary.length" class="muted" style="margin: 0">No editable tools available.</p>
            </template>
          </ToolBindingsCard>
        </div>

        <div class="panel-section">
          <div
            class="flex compact-actions"
            style="justify-content: space-between; align-items: center; gap: 8px"
          >
            <h4 style="margin: 0">Variables</h4>
          </div>
          <VariablesTable
            v-if="chatVariables.length"
            :modelValue="chatVariables"
            @update:modelValue="(value) => emit('update:chatVariables', value)"
          />
          <div v-else class="flex" style="justify-content: flex-start">
            <button class="link" type="button" @click="emit('add-variable-row')">+ Add variable</button>
          </div>
        </div>
      </div>
    </div>

    <ToolBindingPickerModal
      v-model:open="toolBindingPickerOpen"
      :toolInstanceId="newChatToolInstanceId"
      :alias="newChatToolAlias"
      title="Add chat tool"
      :tools="toolLibrary"
      :saving="savingChatChanges"
      @update:toolInstanceId="(value) => emit('update:newChatToolInstanceId', value)"
      @update:alias="(value) => emit('update:newChatToolAlias', value)"
      @confirm="confirmToolBinding"
    />
  </section>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import VariablesTable from '@/components/VariablesTable.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import ToolBindingsCard from '@/components/ToolBindingsCard.vue';
import ToolBindingPickerModal from '@/components/ToolBindingPickerModal.vue';
import type { ChatVariable, ImageAsset, ToolInstanceOption } from '@/types/api';

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
  chatBlocks: ChatBlockLink[];
  chatToolBindings: ChatToolBindingLink[];
  chatVariables: Partial<ChatVariable>[];
  toolLibrary: ToolInstanceOption[];
  newChatToolInstanceId: number;
  newChatToolAlias: string;
  chatBlockName: (blockId: number) => string;
  chatBlockImage: (blockId: number) => ImageAsset | null;
  chatBlockMeta: (block: ChatBlockLink) => string;
  toolLabel: (toolInstanceId: number) => string;
  toolIsOutlet: (toolInstanceId: number) => boolean;
  toolIsOnline: (toolInstanceId: number) => boolean;
}

const props = defineProps<Props>();
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
  (e: 'touch-chat-blocks'): void;
  (e: 'update:newChatToolInstanceId', value: number): void;
  (e: 'update:newChatToolAlias', value: string): void;
  (e: 'add-chat-tool-binding'): void;
  (e: 'move-chat-tool-binding', binding: ChatToolBindingLink, delta: number): void;
  (e: 'remove-chat-tool-binding', bindingId: number): void;
  (e: 'set-chat-tool-binding-enabled', bindingId: number, enabled: boolean): void;
  (e: 'update:chatVariables', value: Partial<ChatVariable>[]): void;
  (e: 'add-variable-row'): void;
}>();

const openToolBindingPicker = () => {
  toolBindingPickerOpen.value = true;
};

const confirmToolBinding = () => {
  const toolInstanceId = Number(props.newChatToolInstanceId || 0);
  const alias = String(props.newChatToolAlias || '').trim();

  if (
    !toolInstanceId ||
    !alias ||
    alias.includes('__') ||
    !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(alias) ||
    props.chatToolBindings.some((binding) => binding.alias === alias)
  ) {
    emit('add-chat-tool-binding');
    return;
  }

  toolBindingPickerOpen.value = false;
  emit('add-chat-tool-binding');
};

const toolBindingLabel = (binding: ChatToolBindingLink) => props.toolLabel(binding.tool_instance_id);
const toolBindingIsOutlet = (binding: ChatToolBindingLink) => props.toolIsOutlet(binding.tool_instance_id);
const toolBindingIsOnline = (binding: ChatToolBindingLink) => props.toolIsOnline(binding.tool_instance_id);
</script>
