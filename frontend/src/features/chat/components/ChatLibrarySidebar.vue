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
        ▶
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
  </section>
</template>

<script setup lang="ts">
import VariablesTable from '@/components/VariablesTable.vue';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import type { ChatVariable, ImageAsset } from '@/types/api';

type ChatBlockLink = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
};

interface Props {
  isMobile: boolean;
  chatTabDirty: boolean;
  savingChatChanges: boolean;
  chatBlocks: ChatBlockLink[];
  chatVariables: Partial<ChatVariable>[];
  chatBlockName: (blockId: number) => string;
  chatBlockImage: (blockId: number) => ImageAsset | null;
  chatBlockMeta: (block: ChatBlockLink) => string;
}

defineProps<Props>();

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
  (e: 'update:chatVariables', value: Partial<ChatVariable>[]): void;
  (e: 'add-variable-row'): void;
}>();
</script>
