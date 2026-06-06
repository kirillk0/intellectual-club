<template>
  <div class="stack">
    <KnowledgeBlockLinksCard
      title="Knowledge blocks"
      :items="items"
      :blockName="blockName"
      :blockImage="blockImage"
      :blockVersion="blockVersion"
      :addDisabled="!bindingsLoaded || bindingsLoading || saving || sharedReadonly"
      :newDisabled="saving || sharedReadonly"
      :openable="true"
      :readonly="!bindingsLoaded || bindingsLoading || saving || sharedReadonly"
      @add="openPicker"
      @new="emit('open-new-block')"
      @open="(blockId) => emit('open-block-editor', blockId)"
      @move="(item, delta) => emit('move', item.id, delta)"
      @remove="(id) => emit('remove', id)"
      @toggle="(item, enabled) => emit('set-enabled', item.id, enabled)"
    >
      <template #note>
        <div v-if="bindingsLoading" class="muted" style="margin-top: 6px">Loading…</div>
        <div v-else-if="bindingsError" class="error-text" style="margin-top: 6px">
          {{ bindingsError }}
        </div>
        <div v-else-if="isNew" class="muted" style="margin-top: 6px">
          Links will be saved when you save the bot.
        </div>
      </template>
    </KnowledgeBlockLinksCard>

    <KnowledgeBlocksPickerModal
      v-model:open="pickerOpen"
      v-model:selected="pickerSelected"
      title="Select blocks"
      :blocks="knowledgeBlocks"
      :disabledBlockIds="linkedBlockIds"
      confirmLabel="Add"
      @confirm="confirmBlocks"
    />
  </div>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue';

import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import KnowledgeBlocksPickerModal from '@/components/KnowledgeBlocksPickerModal.vue';
import type { KnowledgeBlockLinkItem } from '@/features/catalogs/model/useKnowledgeBlockBindingsDraft';
import type { ImageAsset, KnowledgeBlock } from '@/types/api';

const props = defineProps<{
  resetKey: string | number;
  items: KnowledgeBlockLinkItem[];
  knowledgeBlocks: KnowledgeBlock[];
  linkedBlockIds: number[];
  bindingsLoaded: boolean;
  bindingsLoading: boolean;
  bindingsError: string | null;
  saving: boolean;
  isNew: boolean;
  sharedReadonly: boolean;
  blockName: (blockId: number) => string;
  blockImage: (blockId: number) => ImageAsset | null;
  blockVersion: (blockId: number) => string | undefined;
}>();

const emit = defineEmits<{
  (e: 'add-blocks', blockIds: number[]): void;
  (e: 'open-new-block'): void;
  (e: 'open-block-editor', blockId: number): void;
  (e: 'move', bindingId: number, delta: number): void;
  (e: 'remove', bindingId: number): void;
  (e: 'set-enabled', bindingId: number, enabled: boolean): void;
}>();

const pickerOpen = ref(false);
const pickerSelected = ref<number[]>([]);

function resetPicker() {
  pickerOpen.value = false;
  pickerSelected.value = [];
}

watch(
  () => props.resetKey,
  () => resetPicker()
);

function openPicker() {
  pickerSelected.value = [];
  pickerOpen.value = true;
}

function confirmBlocks(blockIds: number[]) {
  emit('add-blocks', blockIds);
}

defineExpose({
  resetPicker,
});
</script>
