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
          <div
            class="flex compact-actions"
            style="justify-content: space-between; align-items: center; gap: 8px"
          >
            <h4 style="margin: 0">Tools</h4>
          </div>

          <div class="card stack chat-tool-builder">
            <div class="chat-tool-builder__fields">
              <label class="stack chat-tool-builder__field">
                <span class="muted">Tool</span>
                <select
                  :value="newChatToolInstanceId"
                  class="full"
                  :disabled="savingChatChanges || !toolLibrary.length"
                  @change="handleToolSelect"
                >
                  <option :value="0">Choose tool…</option>
                  <option v-for="tool in toolLibrary" :key="tool.id" :value="tool.id">
                    {{ tool.name }} ({{ tool.type }})
                  </option>
                </select>
              </label>

              <label class="stack chat-tool-builder__field">
                <span class="muted">Alias</span>
                <input
                  :value="newChatToolAlias"
                  class="full"
                  :disabled="savingChatChanges"
                  placeholder="e.g. web"
                  @input="handleAliasInput"
                />
              </label>
            </div>

            <div class="chat-tool-builder__footer">
              <p class="muted chat-tool-builder__note">Tools are exposed as <code>alias__function</code>.</p>
              <button
                class="primary chat-tool-builder__submit"
                type="button"
                :disabled="savingChatChanges || !toolLibrary.length"
                @click="emit('add-chat-tool-binding')"
              >
                Add
              </button>
            </div>

            <p v-if="!toolLibrary.length" class="muted" style="margin: 0">
              No editable tools available.
            </p>
          </div>

          <ToolBindingsCard
            :show-header="false"
            :items="chatToolBindings"
            :toolLabel="toolBindingLabel"
            :toolIsOutlet="toolBindingIsOutlet"
            :toolIsOnline="toolBindingIsOnline"
            emptyText="No tools linked."
            toggleLabel="enabled"
            :toggleDisabled="() => savingChatChanges"
            :actionsDisabled="() => savingChatChanges"
            @toggle="(binding, enabled) => emit('set-chat-tool-binding-enabled', binding.id, enabled)"
            @move="(binding, delta) => emit('move-chat-tool-binding', binding, delta)"
            @remove="(id) => emit('remove-chat-tool-binding', id)"
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
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import ToolBindingsCard from '@/components/ToolBindingsCard.vue';
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

const handleToolSelect = (event: Event) => {
  const target = event.target as HTMLSelectElement | null;
  emit('update:newChatToolInstanceId', Number(target?.value || 0));
};

const handleAliasInput = (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  emit('update:newChatToolAlias', target?.value || '');
};

const toolBindingLabel = (binding: ChatToolBindingLink) => props.toolLabel(binding.tool_instance_id);
const toolBindingIsOutlet = (binding: ChatToolBindingLink) => props.toolIsOutlet(binding.tool_instance_id);
const toolBindingIsOnline = (binding: ChatToolBindingLink) => props.toolIsOnline(binding.tool_instance_id);
</script>

<style scoped>
.chat-tool-builder {
  padding: 10px;
  gap: 8px;
}

.chat-tool-builder__fields {
  display: grid;
  gap: 8px;
}

.chat-tool-builder__field {
  gap: 4px;
  min-width: 0;
}

.chat-tool-builder__footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
}

.chat-tool-builder__note {
  margin: 0;
  font-size: 0.8rem;
}

.chat-tool-builder__submit {
  padding: 5px 10px;
  font-size: 0.9rem;
}

@media (max-width: 520px) {
  .chat-tool-builder__footer {
    align-items: stretch;
  }

  .chat-tool-builder__submit {
    width: 100%;
  }
}
</style>
