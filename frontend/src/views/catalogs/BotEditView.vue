<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="Bot"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew && !sharedReadonly"
      :showDuplicate="!isNew"
      :saving="saving"
      @save="save"
      @cancel="cancelChanges"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
      @duplicate="duplicate"
    >
      <template #menu-extra>
        <button v-if="!isNew && !sharedReadonly" class="menu-item" type="button" @click="openShareModal">
          Share…
        </button>
      </template>
    </CrudHeader>

    <p v-if="loadError" class="error-text">{{ loadError }}</p>
    <div v-if="sharedReadonly" class="card share-banner">
      <strong>Shared with you.</strong> This bot is read-only. Duplicate it to create an editable copy.
    </div>

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>
      <div class="card stack">
        <div v-if="errors.formErrors.length" class="error-text">{{ errors.formErrors.join(' ') }}</div>

        <label :class="{ 'field-error': errors.hasField('name') }">
          Name
          <input v-model="form.name" class="full" :disabled="sharedReadonly" @input="errors.clearField('name')" />
          <div v-if="errors.hasField('name')" class="error-text">{{ errors.messageFor('name') }}</div>
        </label>
      </div>

      <div class="card stack">
        <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
          <div class="stack" style="gap: 2px">
            <strong>Image</strong>
            <div class="muted" style="font-size: 0.85rem">Used as the bot avatar.</div>
          </div>
          <div class="flex" style="gap: 8px">
            <button type="button" :disabled="isNew || saving || sharedReadonly" @click="triggerImageUpload">Upload</button>
            <button type="button" class="danger" :disabled="!form.image || saving || sharedReadonly" @click="removeImage">
              Remove
            </button>
          </div>
        </div>

        <input ref="imageInput" type="file" accept="image/*" style="display: none" @change="handleImageSelected" />

        <div v-if="form.image" class="row" style="align-items: center; gap: 12px">
          <ImageThumbnail :image="form.image" :label="form.name" :size="56" />
          <div class="stack" style="gap: 2px; min-width: 0">
            <div style="font-weight: 600; overflow: hidden; text-overflow: ellipsis">{{ form.image.filename }}</div>
            <div class="muted" style="font-size: 0.85rem">{{ form.image.mime_type }}</div>
            <div class="muted" style="font-size: 0.85rem">{{ formatBytes(form.image.size_bytes) }}</div>
          </div>
        </div>
        <div v-else class="muted">No image uploaded.</div>
        <div v-if="isNew" class="muted" style="font-size: 0.85rem">Save the bot before uploading an image.</div>
      </div>

      <div class="card stack">
        <div class="tabs">
          <button class="tab" :class="{ active: botTab === 'blocks' }" type="button" @click="botTab = 'blocks'">
            Blocks
          </button>
          <button
            class="tab"
            :class="{ active: botTab === 'firstMessages' }"
            type="button"
            @click="botTab = 'firstMessages'"
          >
            First messages
          </button>
          <button class="tab" :class="{ active: botTab === 'tools' }" type="button" @click="botTab = 'tools'">
            Tools
          </button>
          <button class="tab" :class="{ active: botTab === 'context' }" type="button" @click="botTab = 'context'">
            Context
          </button>
          <button class="tab" :class="{ active: botTab === 'configTags' }" type="button" @click="botTab = 'configTags'">
            Config tags
          </button>
          <button
            class="tab"
            :class="{ active: botTab === 'variables' }"
            type="button"
            @click="botTab = 'variables'"
          >
            Variables
          </button>
        </div>

        <div v-if="botTab === 'blocks'" class="stack">
          <KnowledgeBlockLinksCard
            title="Knowledge blocks"
            :items="bindings.draft.value"
            :blockName="blockName"
            :blockImage="blockImage"
            :blockVersion="blockVersion"
            :addDisabled="!bindings.loaded.value || bindings.loading.value || saving.value || sharedReadonly"
            :newDisabled="saving.value || sharedReadonly"
            :openable="true"
            :readonly="!bindings.loaded.value || bindings.loading.value || saving.value || sharedReadonly"
            @add="openPicker"
            @new="openNewBlock"
            @open="openBlockEditor"
            @move="(item, delta) => bindings.move(item.id, delta)"
            @remove="(id) => bindings.remove(id)"
            @toggle="(item) => bindings.setEnabled(item.id, item.enabled)"
          >
            <template #note>
              <div v-if="bindings.loading.value" class="muted" style="margin-top: 6px">Loading…</div>
              <div v-else-if="bindings.error.value" class="error-text" style="margin-top: 6px">
                {{ bindings.error.value }}
              </div>
              <div v-else-if="isNew" class="muted" style="margin-top: 6px">
                Links will be saved when you save the bot.
              </div>
            </template>
          </KnowledgeBlockLinksCard>
        </div>

        <div v-else-if="botTab === 'tools'" class="stack">
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
              <p v-if="!ownedToolLibrary.length" class="muted">
                You do not have any editable tools yet. Create a tool in the catalog to connect it here.
              </p>

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
                        @change="toggleUserToolDraftEnabled(bt.alias, $event)"
                      />
                      enabled
                    </label>
                  </div>

                  <label class="stack" style="gap: 6px">
                    <span class="muted">Your tool</span>
                    <select
                      :value="userToolDraft(bt.alias).tool_instance_id"
                      class="full"
                      :disabled="userToolBindingSavingAliases.has(bt.alias) || !ownedToolLibrary.length"
                      @change="setUserToolDraftTool(bt.alias, $event)"
                    >
                      <option :value="0">Choose your tool…</option>
                      <option v-for="tool in ownedToolLibrary" :key="tool.id" :value="tool.id">
                        {{ tool.name }} ({{ tool.type }})
                      </option>
                    </select>
                  </label>

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
                      @click="saveUserToolBinding(bt)"
                    >
                      Save override
                    </button>
                    <button
                      type="button"
                      class="danger"
                      :disabled="userToolBindingSavingAliases.has(bt.alias) || !userToolDraft(bt.alias).binding_id"
                      @click="removeUserToolBinding(bt)"
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
            :items="sortedToolBindings"
            :toolLabel="toolBindingLabel"
            :toolIsOutlet="toolBindingIsOutlet"
            :toolIsOnline="toolBindingIsOnline"
            emptyText="No tools attached."
            toggleLabel="enabled"
            :readonly="sharedReadonly"
            :addDisabled="isNew || toolLibraryLoading || toolBindingsSaving || sharedReadonly"
            :toggleDisabled="() => toolBindingsSaving"
            :actionsDisabled="() => toolBindingsSaving"
            @add="openToolBindingPicker"
            @toggle="handleToolBindingToggle"
            @move="moveToolBinding"
            @remove="removeToolBindingById"
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
        </div>

        <div
          v-else-if="botTab === 'firstMessages'"
          :class="['stack', errors.hasField('first_messages') && 'field-error']"
        >
          <div v-if="errors.hasField('first_messages')" class="error-text">{{ errors.messageFor('first_messages') }}</div>
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <strong>First messages</strong>
            <button type="button" @click="addFirstMessage" :disabled="saving || sharedReadonly">Add</button>
          </div>

          <div v-if="form.first_messages.length" class="stack" style="gap: 10px">
            <div
              v-for="(msg, idx) in form.first_messages"
              :key="`fm-${idx}`"
              class="row"
              style="align-items: flex-start"
            >
              <div style="flex: 1; min-width: 0">
                <textarea
                  v-model="form.first_messages[idx]"
                  class="full"
                  rows="3"
                  placeholder="Message"
                  :disabled="sharedReadonly"
                  @input="errors.clearField('first_messages')"
                ></textarea>
                <div class="muted" style="font-size: 0.85rem">Order {{ idx + 1 }}</div>
              </div>
              <div class="flex" style="gap: 8px; align-items: center">
                <button type="button" :disabled="sharedReadonly || idx === 0" @click="moveFirstMessage(idx, -1)">↑</button>
                <button
                  type="button"
                  :disabled="sharedReadonly || idx === form.first_messages.length - 1"
                  @click="moveFirstMessage(idx, 1)"
                >
                  ↓
                </button>
                <button type="button" :disabled="sharedReadonly" @click="removeFirstMessage(idx)">✕</button>
              </div>
            </div>
          </div>
          <p v-else class="muted">No first messages yet.</p>
        </div>

        <div v-else-if="botTab === 'context'" class="stack">
          <label :class="{ 'field-error': errors.hasField('max_tool_rounds') }">
            Max tool rounds
            <input
              v-model.number="form.max_tool_rounds"
              type="number"
              min="0"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('max_tool_rounds')"
            />
            <div v-if="errors.hasField('max_tool_rounds')" class="error-text">
              {{ errors.messageFor('max_tool_rounds') }}
            </div>
          </label>

          <label :class="{ 'field-error': errors.hasField('context_soft_limit_percent') }">
            Context soft limit (%)
            <input
              v-model.number="form.context_soft_limit_percent"
              type="number"
              min="1"
              max="100"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('context_soft_limit_percent')"
            />
            <div v-if="errors.hasField('context_soft_limit_percent')" class="error-text">
              {{ errors.messageFor('context_soft_limit_percent') }}
            </div>
          </label>

          <div class="stack" style="gap: 6px">
            <label style="display: flex; align-items: center; gap: 10px">
              <input v-model="form.supports_file_processing" type="checkbox" :disabled="sharedReadonly" />
              Supports file processing
            </label>
            <div class="muted">Allow any file types in chats for this bot.</div>
          </div>

          <label :class="{ 'field-error': errors.hasField('max_file_size_bytes') }">
            Max file size (MB)
            <input
              v-model.number="form.max_file_size_mb"
              type="number"
              min="1"
              class="full"
              :disabled="sharedReadonly"
              @input="errors.clearField('max_file_size_bytes')"
            />
            <div v-if="errors.hasField('max_file_size_bytes')" class="error-text">
              {{ errors.messageFor('max_file_size_bytes') }}
            </div>
          </label>
        </div>

        <div v-else-if="botTab === 'configTags'" class="stack">
          <div class="flex" style="justify-content: space-between; align-items: center; gap: 10px">
            <strong>Compatible configuration tags</strong>
            <button
              type="button"
              @click="compatibleTagsPickerOpen = true"
              :disabled="saving || configurationTagsLoading || sharedReadonly"
            >
              Add tags
            </button>
          </div>

          <div class="muted">
            If the list is empty, chats with this bot will not filter the configuration selector.
          </div>

          <p v-if="configurationTagsLoading" class="muted">Loading…</p>
          <p v-else-if="configurationTagsError" class="error-text">{{ configurationTagsError }}</p>

          <div v-else-if="attachedCompatibleTags.length" class="list">
            <div v-for="tag in attachedCompatibleTags" :key="tag.id" class="row" style="align-items: center; gap: 8px">
              <div style="font-weight: 600; min-width: 0; overflow: hidden; text-overflow: ellipsis">
                {{ tag.name }}
              </div>
              <button type="button" :disabled="saving || sharedReadonly" @click="removeCompatibleTag(tag.id)">Remove</button>
            </div>
          </div>
          <p v-else class="muted">No compatible tags selected.</p>

          <p v-if="compatibleTagBindingsLoading" class="muted">Loading bindings…</p>
          <p v-else-if="compatibleTagBindingsError" class="error-text">{{ compatibleTagBindingsError }}</p>
          <p v-if="compatibleTagBindingsDirty" class="muted">Tag changes will be saved when you save the bot.</p>
        </div>

        <div v-else class="stack">
          <strong>Variables</strong>
          <VariablesTable :modelValue="variablesRows" :readonly="sharedReadonly" @update:modelValue="setVariablesRows" />
          <div class="muted">
            Variables are exposed to prompts as <code v-text="'{{key}}'"></code>.
          </div>
        </div>
      </div>
    </fieldset>

    <KnowledgeBlocksPickerModal
      v-model:open="pickerOpen"
      v-model:selected="pickerSelected"
      title="Select blocks"
      :blocks="knowledgeBlocks"
      :disabledBlockIds="linkedBlockIds"
      confirmLabel="Add selected"
      @confirm="addSelectedBlocks"
    />

    <LlmConfigurationTagsPickerModal
      v-model:open="compatibleTagsPickerOpen"
      title="Select compatible tags"
      :tags="allConfigurationTags"
      :selectedTagIds="draftCompatibleTagIds"
      :loading="configurationTagsLoading"
      :error="configurationTagsError"
      @toggle="toggleCompatibleTag"
    />

    <ToolBindingPickerModal
      v-model:open="toolBindingPickerOpen"
      v-model:toolInstanceId="newToolInstanceId"
      v-model:alias="newToolAlias"
      title="Add tool binding"
      :tools="toolLibrary"
      :loading="toolLibraryLoading"
      :saving="toolBindingsSaving"
      :error="toolLibraryError"
      @confirm="addToolBinding"
    />

    <BotShareWizardModal
      v-model:open="shareModalOpen"
      :groups="shareGroups"
      :selectedGroupIds="sharedGroupIds"
      :toolBindings="shareToolBindings"
      :loading="shareLoading"
      :saving="shareSaving"
      @save="saveSharing"
    />
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { RouterLink, useRoute } from 'vue-router';
import { api, getApiErrorMessage } from '@/api/client';
import BotShareWizardModal, { type BotShareToolBinding } from '@/components/BotShareWizardModal.vue';
import CrudHeader from '@/components/CrudHeader.vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import VariablesTable from '@/components/VariablesTable.vue';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import ToolBindingsCard from '@/components/ToolBindingsCard.vue';
import ToolBindingPickerModal from '@/components/ToolBindingPickerModal.vue';
import KnowledgeBlocksPickerModal from '@/components/KnowledgeBlocksPickerModal.vue';
import LlmConfigurationTagsPickerModal from '@/components/LlmConfigurationTagsPickerModal.vue';
import { deleteBotImage, uploadBotImage } from '@/api/images';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import {
  useKnowledgeBlockBindingsDraft,
  type KnowledgeBlockLinkItem,
} from '@/features/catalogs/model/useKnowledgeBlockBindingsDraft';
import { useKnowledgeBlockNewDraft } from '@/features/catalogs/model/useKnowledgeBlockNewDraft';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import { createRecordset } from '@/features/catalogs/model/recordsets';
import { parseImageAsset } from '@/features/media/image';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import {
  createJsonApiIncludedIndex,
  jsonApiCreate,
  jsonApiDelete,
  jsonApiList,
  jsonApiUpdate,
  relatedResource,
  relatedResources,
  relationshipId,
  toIntId,
  type JsonApiResource,
  type JsonApiSingleResponse,
} from '@/api/jsonApi';
import type { Group, ImageAsset, KnowledgeBlock } from '@/types/api';

type BotForm = {
  name: string;
  image: ImageAsset | null;
  first_messages: string[];
  variables: Record<string, string>;
  max_tool_rounds: number;
  context_soft_limit_percent: number;
  supports_file_processing: boolean;
  max_file_size_mb: number;
  can_edit: boolean;
  shared_incoming: boolean;
  shared_outgoing: boolean;
};

type ConfigurationTagRow = { id: number; name: string };
type CompatibleTagBindingRow = { id: number; llm_configuration_tag_id: number; tag_name: string };
type ToolInstanceOption = {
  id: number;
  name: string;
  type: string;
  outlet_online: boolean | null;
  can_edit: boolean | null;
};
type ToolBindingRow = {
  id: number;
  alias: string;
  tool_instance_id: number;
  sharing_mode: string;
  enabled: boolean;
  sequence: number;
};
type UserToolBindingRow = {
  id: number;
  alias: string;
  tool_instance_id: number;
  enabled: boolean;
  sequence: number;
};
type UserToolBindingDraft = {
  binding_id: number | null;
  tool_instance_id: number;
  enabled: boolean;
  sequence: number;
};

type ShareStateResponse = {
  group_ids?: number[];
  tool_modes?: Record<string, string>;
};

const route = useRoute();
const stackNav = useStackNavigation();
const stack = useNavigationStack();

const BOT_DOCUMENT_INCLUDE = [
  'knowledge_block_bindings.knowledge_block',
  'compatible_configuration_tag_bindings.llm_configuration_tag',
  'tool_bindings.tool_instance',
  'user_tool_bindings.tool_instance',
].join(',');

function normalizeTagIds(ids: number[]) {
  return Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0))).sort(
    (a, b) => a - b
  );
}

function fromApi(resource: JsonApiResource): Partial<BotForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const rawFirst = Array.isArray(attrs.first_messages) ? (attrs.first_messages as unknown[]) : [];
  const first_messages = rawFirst.map((m) => String(m || '')).filter((m) => m.trim() !== '');
  const variables = attrs.variables && typeof attrs.variables === 'object' ? (attrs.variables as any) : {};
  return {
    name: String(attrs.name || ''),
    image: parseImageAsset(attrs.image),
    first_messages,
    variables,
    max_tool_rounds:
      typeof attrs.max_tool_rounds === 'number' ? attrs.max_tool_rounds : Number(attrs.max_tool_rounds || 100),
    context_soft_limit_percent:
      typeof attrs.context_soft_limit_percent === 'number'
        ? attrs.context_soft_limit_percent
        : Number(attrs.context_soft_limit_percent || 80),
    supports_file_processing: Boolean(attrs.supports_file_processing),
    max_file_size_mb:
      typeof attrs.max_file_size_bytes === 'number'
        ? Math.max(1, Math.round(attrs.max_file_size_bytes / (1024 * 1024)))
        : 500,
    can_edit: attrs.can_edit !== false,
    shared_incoming: Boolean(attrs.shared_incoming),
    shared_outgoing: Boolean(attrs.shared_outgoing),
  };
}

function botDocumentQuery() {
  const qs = new URLSearchParams();
  qs.set('include', BOT_DOCUMENT_INCLUDE);
  return qs;
}

function parseConfigurationTagRow(resource: JsonApiResource | null | undefined): ConfigurationTagRow | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return { id, name: String(attrs.name || '').trim() };
}

function parseKnowledgeBlockOption(resource: JsonApiResource | null | undefined): KnowledgeBlock | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    id,
    name: String(attrs.name || ''),
    image: parseImageAsset(attrs.image),
    type: typeof attrs.type === 'string' ? attrs.type : null,
    version: typeof attrs.version === 'string' ? attrs.version : null,
    token_count: typeof attrs.token_count === 'number' ? attrs.token_count : toIntId(attrs.token_count as any),
  } satisfies KnowledgeBlock;
}

function parseToolInstanceOption(resource: JsonApiResource | null | undefined): ToolInstanceOption | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const hasOutletOnline = Object.prototype.hasOwnProperty.call(attrs, 'outlet_online');
  const hasCanEdit = Object.prototype.hasOwnProperty.call(attrs, 'can_edit');

  return {
    id,
    name: String(attrs.name || '').trim(),
    type: String(attrs.type || '').trim(),
    outlet_online: hasOutletOnline ? Boolean(attrs.outlet_online) : null,
    can_edit: hasCanEdit ? attrs.can_edit !== false : null,
  } satisfies ToolInstanceOption;
}

function parseKnowledgeBlockBindingItem(
  resource: JsonApiResource,
  includedIndex: ReturnType<typeof createJsonApiIncludedIndex>
): KnowledgeBlockLinkItem | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const blockId =
    parseKnowledgeBlockOption(relatedResource(resource, 'knowledge_block', includedIndex))?.id ??
    relationshipId(resource, 'knowledge_block') ??
    toIntId(attrs.knowledge_block_id as any);

  if (!blockId) return null;

  return {
    id,
    block: blockId,
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
  };
}

function parseCompatibleTagBindingRow(
  resource: JsonApiResource,
  includedIndex: ReturnType<typeof createJsonApiIncludedIndex>
): CompatibleTagBindingRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const tagId =
    relationshipId(resource, 'llm_configuration_tag') ??
    (typeof attrs.llm_configuration_tag_id === 'number'
      ? attrs.llm_configuration_tag_id
      : toIntId(attrs.llm_configuration_tag_id as any));

  if (!tagId) return null;

  return {
    id,
    llm_configuration_tag_id: tagId,
    tag_name:
      parseConfigurationTagRow(relatedResource(resource, 'llm_configuration_tag', includedIndex))?.name ??
      String(attrs.tag_name || '').trim(),
  };
}

function parseToolBindingRow(resource: JsonApiResource): ToolBindingRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const toolInstanceId =
    relationshipId(resource, 'tool_instance') ??
    (typeof attrs.tool_instance_id === 'number' ? attrs.tool_instance_id : toIntId(attrs.tool_instance_id as any));

  if (!toolInstanceId) return null;

  return {
    id,
    alias: String(attrs.alias || '').trim(),
    tool_instance_id: toolInstanceId,
    sharing_mode: String(attrs.sharing_mode || 'shared'),
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
  };
}

function parseUserToolBindingRow(resource: JsonApiResource): UserToolBindingRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const toolInstanceId =
    relationshipId(resource, 'tool_instance') ??
    (typeof attrs.tool_instance_id === 'number' ? attrs.tool_instance_id : toIntId(attrs.tool_instance_id as any));

  if (!toolInstanceId) return null;

  return {
    id,
    alias: String(attrs.alias || '').trim(),
    tool_instance_id: toolInstanceId,
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
  };
}

function sortToolBindings<T extends { sequence: number; id: number }>(rows: T[]) {
  return [...rows].sort((a, b) => (a.sequence || 0) - (b.sequence || 0) || a.id - b.id);
}

function normalizeToolBindingSequences<T extends ToolBindingRow>(rows: T[]) {
  return sortToolBindings(rows).map((row, idx) => ({ ...row, sequence: idx }));
}

function normalizeToolBindingsForCompare(rows: ToolBindingRow[]) {
  return sortToolBindings(rows).map((binding) => ({
    alias: String(binding.alias || '').trim(),
    tool_instance_id: Number(binding.tool_instance_id) || 0,
    sharing_mode: binding.sharing_mode || 'shared',
    enabled: Boolean(binding.enabled),
    sequence: Number(binding.sequence) || 0,
  }));
}

function cloneToolBindings(rows: ToolBindingRow[]) {
  return rows.map((row) => ({ ...row }));
}

const editor = useCrudEditor<BotForm>({
  type: 'bots',
  basePath: '/api/ash/bots',
  indexPath: '/catalogs/bots',
  editPath: (id) => `/catalogs/bots/${id}`,
  defaultForm: () => ({
    name: '',
    image: null,
    first_messages: [],
    variables: {},
    max_tool_rounds: 100,
    context_soft_limit_percent: 80,
    supports_file_processing: false,
    max_file_size_mb: 500,
    can_edit: true,
    shared_incoming: false,
    shared_outgoing: false,
  }),
  fromApi,
  toAttributes: (form) => ({
    name: form.name,
    first_messages: (form.first_messages || []).map((m) => String(m || '').trim()).filter((m) => m !== ''),
    variables: form.variables || {},
    max_tool_rounds: form.max_tool_rounds,
    context_soft_limit_percent: form.context_soft_limit_percent,
    supports_file_processing: form.supports_file_processing,
    max_file_size_bytes: Math.max(1, Number(form.max_file_size_mb || 500)) * 1024 * 1024,
    ...(compatibleTagBindingsPayload.value === undefined
      ? {}
      : { compatible_configuration_tag_bindings: compatibleTagBindingsPayload.value }),
    ...(bindings.payload.value === undefined ? {} : { knowledge_block_bindings: bindings.payload.value }),
    ...(toolBindingsPayload.value === undefined ? {} : { tool_bindings: toolBindingsPayload.value }),
  }),
  normalizeForDirty: (form) => ({
    name: form.name,
    first_messages: form.first_messages,
    variables: form.variables,
    max_tool_rounds: form.max_tool_rounds,
    context_soft_limit_percent: form.context_soft_limit_percent,
    supports_file_processing: form.supports_file_processing,
    max_file_size_mb: form.max_file_size_mb,
    can_edit: form.can_edit,
    shared_incoming: form.shared_incoming,
    shared_outgoing: form.shared_outgoing,
  }),
  duplicatePath: (id) => `/api/ash/bots/${id}/duplicate`,
  documentQuery: () => botDocumentQuery(),
  onDocument: (payload) => {
    applyBotDocument(payload);
  },
});

const bindings = useKnowledgeBlockBindingsDraft({});

const allConfigurationTags = ref<ConfigurationTagRow[]>([]);
const configurationTagsCatalogLoaded = ref(false);
const configurationTagsLoading = ref(false);
const configurationTagsError = ref<string | null>(null);
const compatibleTagBindingsLoading = ref(false);
const compatibleTagBindingsError = ref<string | null>(null);
const currentCompatibleTagBindings = ref<CompatibleTagBindingRow[]>([]);
const draftCompatibleTagIds = ref<number[]>([]);
const compatibleTagsPickerOpen = ref(false);

const attachedCompatibleTags = computed(() => {
  const tagMap = new Map<number, ConfigurationTagRow>();
  for (const tag of allConfigurationTags.value) tagMap.set(tag.id, tag);
  for (const binding of currentCompatibleTagBindings.value) {
    const name = String(binding.tag_name || '').trim();
    if (!name) continue;
    tagMap.set(binding.llm_configuration_tag_id, { id: binding.llm_configuration_tag_id, name });
  }
  return draftCompatibleTagIds.value.map((id) => tagMap.get(id) || { id, name: `Tag #${id}` });
});

function mergeConfigurationTags(tags: ConfigurationTagRow[]) {
  const byId = new Map<number, ConfigurationTagRow>();

  for (const tag of allConfigurationTags.value) byId.set(tag.id, tag);
  for (const tag of tags) byId.set(tag.id, tag);

  allConfigurationTags.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

const compatibleTagBindingsDirty = computed(() => {
  const original = normalizeTagIds(currentCompatibleTagBindings.value.map((binding) => binding.llm_configuration_tag_id));
  const draft = normalizeTagIds(draftCompatibleTagIds.value);
  return JSON.stringify(original) !== JSON.stringify(draft);
});

const compatibleTagBindingsPayload = computed(() => {
  const existingByTagId = new Map<number, CompatibleTagBindingRow>();
  for (const binding of currentCompatibleTagBindings.value) existingByTagId.set(binding.llm_configuration_tag_id, binding);

  return normalizeTagIds(draftCompatibleTagIds.value).map((tagId) => {
    const existing = existingByTagId.get(tagId);
    return existing ? { id: existing.id, llm_configuration_tag_id: tagId } : { llm_configuration_tag_id: tagId };
  });
});

function resetCompatibleTagBindings(bindings: CompatibleTagBindingRow[] = []) {
  currentCompatibleTagBindings.value = bindings;
  draftCompatibleTagIds.value = normalizeTagIds(bindings.map((binding) => binding.llm_configuration_tag_id));
  compatibleTagBindingsError.value = null;
}

async function loadConfigurationTags() {
  configurationTagsLoading.value = true;
  configurationTagsError.value = null;

  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('editable_only', 'true');
    qs.set('fields[llm-configuration-tags]', 'name');
    const payload = await jsonApiList('/api/ash/llm-configuration-tags', qs);
    mergeConfigurationTags(
      (payload.data || [])
        .map((resource) => {
          const id = toIntId(resource.id);
          if (!id) return null;
          const attrs = (resource.attributes || {}) as Record<string, unknown>;
          return { id, name: String(attrs.name || '').trim() } satisfies ConfigurationTagRow;
        })
        .filter((tag): tag is ConfigurationTagRow => Boolean(tag))
    );
    configurationTagsCatalogLoaded.value = true;
  } catch (error) {
    console.error(error);
    const message = error instanceof Error ? error.message : 'Failed to load tags.';
    if (message.startsWith('HTTP 403') || message.startsWith('HTTP 401')) {
      configurationTagsError.value = null;
    } else {
      configurationTagsError.value = message;
    }
    configurationTagsCatalogLoaded.value = false;
  } finally {
    configurationTagsLoading.value = false;
  }
}

function applyBotDocument(payload: JsonApiSingleResponse) {
  const includedIndex = createJsonApiIncludedIndex(payload.included);
  const root = payload.data;

  const knowledgeBlockBindingResources = relatedResources(root, 'knowledge_block_bindings', includedIndex);
  bindings.hydrate(
    knowledgeBlockBindingResources
      .map((resource) => parseKnowledgeBlockBindingItem(resource, includedIndex))
      .filter((item): item is KnowledgeBlockLinkItem => Boolean(item))
  );
  mergeKnowledgeBlocks(
    knowledgeBlockBindingResources
      .map((resource) => parseKnowledgeBlockOption(relatedResource(resource, 'knowledge_block', includedIndex)))
      .filter((block): block is KnowledgeBlock => Boolean(block))
  );

  const tagBindingResources = relatedResources(root, 'compatible_configuration_tag_bindings', includedIndex);
  mergeConfigurationTags(
    tagBindingResources
      .map((resource) => parseConfigurationTagRow(relatedResource(resource, 'llm_configuration_tag', includedIndex)))
      .filter((tag): tag is ConfigurationTagRow => Boolean(tag))
  );
  resetCompatibleTagBindings(
    tagBindingResources
      .map((resource) => parseCompatibleTagBindingRow(resource, includedIndex))
      .filter((binding): binding is CompatibleTagBindingRow => Boolean(binding))
  );
  compatibleTagBindingsLoading.value = false;
  compatibleTagBindingsError.value = null;

  const toolBindingResources = relatedResources(root, 'tool_bindings', includedIndex);
  const userToolBindingResources = relatedResources(root, 'user_tool_bindings', includedIndex);

  mergeToolLibrary(
    [...toolBindingResources, ...userToolBindingResources]
      .map((resource) => parseToolInstanceOption(relatedResource(resource, 'tool_instance', includedIndex)))
      .filter((tool): tool is ToolInstanceOption => Boolean(tool))
  );

  hydrateToolBindings(
    toolBindingResources.map(parseToolBindingRow).filter((binding): binding is ToolBindingRow => Boolean(binding))
  );

  userToolBindings.value = sortToolBindings(
    userToolBindingResources
      .map(parseUserToolBindingRow)
      .filter((binding): binding is UserToolBindingRow => Boolean(binding))
  );
  userToolBindingsLoading.value = false;
  userToolBindingsError.value = null;
}

const toggleCompatibleTag = (tagId: number) => {
  const next = new Set(draftCompatibleTagIds.value);
  if (next.has(tagId)) next.delete(tagId);
  else next.add(tagId);
  draftCompatibleTagIds.value = normalizeTagIds(Array.from(next));
};

const removeCompatibleTag = (tagId: number) => {
  draftCompatibleTagIds.value = draftCompatibleTagIds.value.filter((id) => id !== tagId);
};

const dirty = computed(
  () => editor.dirty.value || bindings.dirty.value || compatibleTagBindingsDirty.value || toolBindingsDirty.value
);
const saving = computed(() => editor.saving.value);
const guardDirty = computed(() => dirty.value && !saving.value);
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);

useUnsavedChangesGuard(guardDirty);

const form = editor.form;
const errors = editor.errors;
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const sharedReadonly = computed(() => !isNew.value && form.can_edit === false);
const botTab = ref<'blocks' | 'firstMessages' | 'tools' | 'context' | 'configTags' | 'variables'>('blocks');
const save = async () => {
  if (saving.value) return;
  await editor.save();
};
const cancelChanges = () => {
  editor.reset();
  bindings.reset();
  resetCompatibleTagBindings(currentCompatibleTagBindings.value.map((binding) => ({ ...binding })));
  toolBindings.value = cloneToolBindings(originalToolBindings.value);
  newToolInstanceId.value = 0;
  newToolAlias.value = '';
  toolBindingPickerOpen.value = false;
};
const remove = editor.remove;
const duplicate = editor.duplicate;
const createNew = editor.createNew;
const goList = editor.goList;
const imageInput = ref<HTMLInputElement | null>(null);

const triggerImageUpload = () => imageInput.value?.click();

const formatBytes = (value: number) => {
  const n = Number(value || 0);
  if (n < 1024) return `${n} B`;
  const kb = n / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  const mb = kb / 1024;
  return `${mb.toFixed(1)} MB`;
};

const handleImageSelected = async (event: Event) => {
  const target = event.target as HTMLInputElement | null;
  const file = target?.files?.[0];
  if (target) target.value = '';
  if (!file || isNew.value || editor.numericId.value == null) return;

  try {
    const response = await uploadBotImage(editor.numericId.value, file);
    form.image = response.image;
  } catch (error) {
    console.error(error);
    alert(getApiErrorMessage(error, 'Failed to upload image.'));
  }
};

const removeImage = async () => {
  if (!form.image || isNew.value || editor.numericId.value == null) return;
  if (!window.confirm('Remove image?')) return;

  try {
    const response = await deleteBotImage(editor.numericId.value);
    form.image = response.image;
  } catch (error) {
    console.error(error);
    alert('Failed to remove image.');
  }
};

const addFirstMessage = () => {
  form.first_messages = [...(form.first_messages || []), ''];
};

const removeFirstMessage = (idx: number) => {
  const next = [...(form.first_messages || [])];
  next.splice(idx, 1);
  form.first_messages = next;
};

const moveFirstMessage = (idx: number, delta: number) => {
  const list = [...(form.first_messages || [])];
  const target = idx + delta;
  if (target < 0 || target >= list.length) return;
  const [item] = list.splice(idx, 1);
  list.splice(target, 0, item);
  form.first_messages = list;
};

type VarRow = { key: string; value: string };

const mapToVarRows = (vars: Record<string, unknown> | null | undefined): VarRow[] => {
  return Object.entries(vars || {})
    .map(([key, value]) => ({ key: String(key || ''), value: String(value ?? '') }))
    .sort((a, b) => a.key.localeCompare(b.key));
};

const varRowsToMap = (rows: VarRow[] | null | undefined): Record<string, string> => {
  const next: Record<string, string> = {};
  for (const row of rows || []) {
    const key = String(row.key || '').trim();
    if (!key) continue;
    next[key] = String(row.value ?? '');
  }
  return next;
};

const stableVarMap = (vars: Record<string, string>) => JSON.stringify(Object.entries(vars).sort(([a], [b]) => a.localeCompare(b)));

const variablesRows = ref<VarRow[]>([]);

watch(
  () => form.variables,
  (value) => {
    const incoming = varRowsToMap(mapToVarRows((value || {}) as Record<string, unknown>));
    const current = varRowsToMap(variablesRows.value);
    if (stableVarMap(incoming) === stableVarMap(current)) return;
    variablesRows.value = mapToVarRows((value || {}) as Record<string, unknown>);
  },
  { immediate: true, deep: true }
);

const setVariablesRows = (rows: VarRow[]) => {
  variablesRows.value = (rows || []).map((row) => ({ key: String(row.key || ''), value: String(row.value ?? '') }));
  form.variables = varRowsToMap(variablesRows.value);
};

const knowledgeBlocks = ref<KnowledgeBlock[]>([]);

function mergeKnowledgeBlocks(blocks: KnowledgeBlock[]) {
  const byId = new Map<number, KnowledgeBlock>();

  for (const block of knowledgeBlocks.value) byId.set(block.id, block);
  for (const block of blocks) byId.set(block.id, block);

  knowledgeBlocks.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

async function loadKnowledgeBlocks() {
  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('fields[knowledge-blocks]', 'name,version,type,token_count,image');
    const payload = await jsonApiList('/api/ash/knowledge-blocks', qs);
    mergeKnowledgeBlocks(
      (payload.data || [])
        .map((resource) => parseKnowledgeBlockOption(resource))
        .filter((block): block is KnowledgeBlock => Boolean(block))
    );
  } catch (e) {
    console.warn('Failed to load knowledge blocks', e);
  }
}

const linkedBlockIds = computed(() => bindings.linkedBlockIds.value);

const blocksById = computed(() => {
  const map = new Map<number, KnowledgeBlock>();
  for (const b of knowledgeBlocks.value || []) map.set(b.id, b);
  return map;
});

const blockName = (id: number) => blocksById.value.get(id)?.name || `Block #${id}`;
const blockImage = (id: number) => blocksById.value.get(id)?.image || null;
const blockVersion = (id: number) => blocksById.value.get(id)?.version || '';

const pickerOpen = ref(false);
const pickerSelected = ref<number[]>([]);

watch(
  () => editor.idParam.value,
  () => {
    pickerOpen.value = false;
    pickerSelected.value = [];
    compatibleTagsPickerOpen.value = false;
    toolBindingPickerOpen.value = false;
    newToolInstanceId.value = 0;
    newToolAlias.value = '';
  }
);

const openPicker = () => {
  pickerSelected.value = [];
  pickerOpen.value = true;
};

const addSelectedBlocks = (ids: number[]) => bindings.addBlocks(ids);

const openBlockEditor = (blockId: number) => {
  const ids = linkedBlockIds.value;
  const navKey = createRecordset(ids, { returnTo: route.fullPath });
  stackNav.open({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { navKey, returnTo: route.fullPath } });
};

const newBlockDraft = useKnowledgeBlockNewDraft({
  linkedBlockIds: () => linkedBlockIds.value,
  onBlocksCreated: async (createdIds) => {
    await loadKnowledgeBlocks();
    bindings.addBlocks(createdIds);
  },
  resetOn: () => editor.idParam.value,
});

const openNewBlock = newBlockDraft.openNewBlock;

watch(
  () => stack.active.value,
  (active, wasActive) => {
    if (active) return;
    if (wasActive !== true) return;
    void newBlockDraft.consumePendingNewBlockContext();
  }
);

watch(
  () => compatibleTagsPickerOpen.value,
  (open) => {
    if (!open) return;
    if (configurationTagsCatalogLoaded.value || configurationTagsLoading.value || sharedReadonly.value) return;
    void loadConfigurationTags();
  }
);

onMounted(() => {
  void loadKnowledgeBlocks();
  void loadToolLibrary();
});

const toolLibraryLoading = ref(false);
const toolLibraryError = ref<string | null>(null);
const toolLibrary = ref<ToolInstanceOption[]>([]);

function mergeToolLibrary(tools: ToolInstanceOption[]) {
  const byId = new Map<number, ToolInstanceOption>();

  for (const tool of toolLibrary.value) byId.set(tool.id, tool);
  for (const tool of tools) {
    const existing = byId.get(tool.id);

    byId.set(tool.id, {
      ...existing,
      ...tool,
      outlet_online: tool.outlet_online ?? existing?.outlet_online ?? false,
      can_edit: tool.can_edit ?? existing?.can_edit ?? true,
    });
  }

  toolLibrary.value = Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

async function loadToolLibrary() {
  toolLibraryLoading.value = true;
  toolLibraryError.value = null;

  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'name');
    qs.set('fields[tool-instances]', 'name,type,outlet_online,can_edit');
    const payload = await jsonApiList('/api/ash/tool-instances', qs);
    mergeToolLibrary(
      (payload.data || [])
        .map((resource) => parseToolInstanceOption(resource))
        .filter((tool): tool is ToolInstanceOption => Boolean(tool))
    );
  } catch (e) {
    console.error(e);
    toolLibraryError.value = e instanceof Error ? e.message : 'Failed to load tools.';
  } finally {
    toolLibraryLoading.value = false;
  }
}

const toolLibraryById = computed(() => {
  const map = new Map<number, ToolInstanceOption>();
  for (const t of toolLibrary.value || []) map.set(t.id, t);
  return map;
});
const ownedToolLibrary = computed(() => (toolLibrary.value || []).filter((tool) => tool.can_edit !== false));

function toolInstanceLabel(toolInstanceId: number) {
  const tool = toolLibraryById.value.get(toolInstanceId);
  if (!tool) return `Tool #${toolInstanceId}`;
  return `${tool.name} (${tool.type})`;
}

function toolInstanceIsOutlet(toolInstanceId: number) {
  return toolLibraryById.value.get(toolInstanceId)?.type === 'outlet';
}

function toolInstanceOnline(toolInstanceId: number) {
  return Boolean(toolLibraryById.value.get(toolInstanceId)?.outlet_online);
}

function baseToolBindingLabel(binding: ToolBindingRow) {
  if (sharedReadonly.value && binding.sharing_mode === 'per_user') {
    return 'Connected per user';
  }

  return toolInstanceLabel(binding.tool_instance_id);
}

const toolBindingLabel = (binding: ToolBindingRow) => baseToolBindingLabel(binding);
const toolBindingIsOutlet = (binding: ToolBindingRow) => toolInstanceIsOutlet(binding.tool_instance_id);
const toolBindingIsOnline = (binding: ToolBindingRow) => toolInstanceOnline(binding.tool_instance_id);

const toolBindingsLoading = ref(false);
const toolBindingsError = ref<string | null>(null);
const originalToolBindings = ref<ToolBindingRow[]>([]);
const toolBindings = ref<ToolBindingRow[]>([]);
const toolBindingsLoaded = ref(false);
const toolBindingsSaving = computed(() => saving.value);
const userToolBindingsLoading = ref(false);
const userToolBindingsError = ref<string | null>(null);
const userToolBindings = ref<UserToolBindingRow[]>([]);
const userToolBindingDrafts = ref<Record<string, UserToolBindingDraft>>({});
const userToolBindingSavingAliases = ref(new Set<string>());
let tempToolBindingId = -1;

const sortedToolBindings = computed(() => sortToolBindings(toolBindings.value || []));
const perUserBaseBindings = computed(() => sortedToolBindings.value.filter((binding) => binding.sharing_mode === 'per_user'));
const toolBindingsDirty = computed(
  () =>
    JSON.stringify(normalizeToolBindingsForCompare(originalToolBindings.value)) !==
    JSON.stringify(normalizeToolBindingsForCompare(toolBindings.value))
);
const toolBindingsPayload = computed(() => {
  if (!toolBindingsLoaded.value) return undefined;

  return sortedToolBindings.value.map((binding) => ({
    ...(binding.id > 0 ? { id: binding.id } : {}),
    tool_instance_id: binding.tool_instance_id,
    alias: String(binding.alias || '').trim(),
    sharing_mode: binding.sharing_mode || 'shared',
    enabled: Boolean(binding.enabled),
  }));
});

function hydrateToolBindings(rows: ToolBindingRow[]) {
  const normalized = normalizeToolBindingSequences(rows || []);
  originalToolBindings.value = cloneToolBindings(normalized);
  toolBindings.value = cloneToolBindings(normalized);
  tempToolBindingId = -1;
  toolBindingsLoading.value = false;
  toolBindingsError.value = null;
  toolBindingsLoaded.value = true;
}

function syncUserToolBindingDrafts() {
  const existingByAlias = new Map<string, UserToolBindingRow>();

  for (const binding of userToolBindings.value || []) {
    if (binding.alias) existingByAlias.set(binding.alias, binding);
  }

  const nextDrafts: Record<string, UserToolBindingDraft> = {};

  for (const binding of perUserBaseBindings.value) {
    const existing = existingByAlias.get(binding.alias);
    const previous = userToolBindingDrafts.value[binding.alias];

    nextDrafts[binding.alias] = {
      binding_id: existing?.id ?? null,
      tool_instance_id: existing?.tool_instance_id ?? previous?.tool_instance_id ?? 0,
      enabled: existing?.enabled ?? previous?.enabled ?? true,
      sequence: binding.sequence,
    };
  }

  userToolBindingDrafts.value = nextDrafts;
}

function userToolDraft(alias: string): UserToolBindingDraft {
  return (
    userToolBindingDrafts.value[alias] || {
      binding_id: null,
      tool_instance_id: 0,
      enabled: true,
      sequence: 0,
    }
  );
}

watch(
  () => editor.numericId.value,
  (botId) => {
    if (botId) return;
    bindings.hydrate([]);
    resetCompatibleTagBindings([]);
    compatibleTagBindingsLoading.value = false;
    hydrateToolBindings([]);
    userToolBindings.value = [];
    userToolBindingsLoading.value = false;
    userToolBindingsError.value = null;
  },
  { immediate: true }
);

function setUserToolDraft(alias: string, patch: Partial<UserToolBindingDraft>) {
  userToolBindingDrafts.value = {
    ...userToolBindingDrafts.value,
    [alias]: {
      ...userToolDraft(alias),
      ...patch,
    },
  };
}

function setUserToolDraftTool(alias: string, event: Event) {
  const target = event.target as HTMLSelectElement | null;
  const nextToolId = target ? Number(target.value || 0) : 0;
  setUserToolDraft(alias, { tool_instance_id: nextToolId > 0 ? nextToolId : 0 });
}

function toggleUserToolDraftEnabled(alias: string, event: Event) {
  const target = event.target as HTMLInputElement | null;
  setUserToolDraft(alias, { enabled: Boolean(target?.checked) });
}

function userToolBindingLabel(alias: string) {
  const draft = userToolDraft(alias);
  if (!draft.tool_instance_id) return 'No tool selected';
  return toolInstanceLabel(draft.tool_instance_id);
}

watch(
  () => editor.numericId.value,
  () => {
    syncUserToolBindingDrafts();
  },
  { immediate: true }
);

watch([perUserBaseBindings, userToolBindings], () => {
  syncUserToolBindingDrafts();
});

const newToolInstanceId = ref(0);
const newToolAlias = ref('');
const toolBindingPickerOpen = ref(false);

function openToolBindingPicker() {
  if (isNew.value || sharedReadonly.value) return;
  if (!toolLibrary.value.length && !toolLibraryLoading.value) void loadToolLibrary();
  toolBindingPickerOpen.value = true;
}

async function addToolBinding() {
  if (isNew.value || sharedReadonly.value) return;

  const toolInstanceId = Number(newToolInstanceId.value || 0);
  const alias = String(newToolAlias.value || '').trim();

  if (!toolInstanceId) {
    alert('Choose a tool instance.');
    return;
  }

  if (!alias) {
    alert('Alias is required.');
    return;
  }

  if (alias.includes('__')) {
    alert('Alias must not contain "__".');
    return;
  }

  if (toolBindings.value.some((binding) => binding.alias === alias)) {
    alert('Alias is already used in this bot.');
    return;
  }

  const next = normalizeToolBindingSequences(toolBindings.value);
  toolBindings.value = normalizeToolBindingSequences([
    ...next,
    {
      id: tempToolBindingId--,
      alias,
      tool_instance_id: toolInstanceId,
      sharing_mode: 'shared',
      enabled: true,
      sequence: next.length,
    },
  ]);

  newToolInstanceId.value = 0;
  newToolAlias.value = '';
  toolBindingPickerOpen.value = false;
}

function removeToolBinding(binding: ToolBindingRow) {
  toolBindings.value = normalizeToolBindingSequences(toolBindings.value.filter((row) => row.id !== binding.id));
  userToolBindings.value = userToolBindings.value.filter((row) => row.alias !== binding.alias);
}

function toggleToolBinding(binding: ToolBindingRow, nextEnabled: boolean) {
  toolBindings.value = toolBindings.value.map((row) => (row.id === binding.id ? { ...row, enabled: nextEnabled } : row));
}

function removeToolBindingById(id: number) {
  const binding = toolBindings.value.find((row) => row.id === id);
  if (!binding) return;
  removeToolBinding(binding);
}

function handleToolBindingToggle(binding: ToolBindingRow, enabled: boolean) {
  toggleToolBinding(binding, enabled);
}

function moveToolBinding(binding: ToolBindingRow, delta: number) {
  const list = sortedToolBindings.value;
  const idx = list.findIndex((x) => x.id === binding.id);
  if (idx < 0) return;
  const targetIdx = idx + delta;
  if (targetIdx < 0 || targetIdx >= list.length) return;

  const next = [...list];
  const current = next[idx];
  next[idx] = next[targetIdx];
  next[targetIdx] = current;
  toolBindings.value = next.map((row, index) => ({ ...row, sequence: index }));
}

async function saveUserToolBinding(binding: ToolBindingRow) {
  const botId = editor.numericId.value;
  if (!botId) return;

  const alias = binding.alias;
  const draft = userToolDraft(alias);

  if (!draft.tool_instance_id) {
    alert('Choose your tool first.');
    return;
  }

  if (!ownedToolLibrary.value.some((tool) => tool.id === draft.tool_instance_id)) {
    alert('Choose one of your editable tools.');
    return;
  }

  userToolBindingSavingAliases.value = new Set([...userToolBindingSavingAliases.value, alias]);

  try {
    const existing = userToolBindings.value.find((row) => row.alias === alias) || null;
    const payload = {
      bot_id: botId,
      tool_instance_id: draft.tool_instance_id,
      alias,
      enabled: draft.enabled,
      sequence: binding.sequence,
    };

    if (existing && existing.tool_instance_id === draft.tool_instance_id) {
      await jsonApiUpdate('/api/ash/bot-user-tool-bindings', 'bot-user-tool-bindings', existing.id, {
        alias,
        enabled: draft.enabled,
        sequence: binding.sequence,
      });

      userToolBindings.value = sortToolBindings(
        userToolBindings.value.map((row) =>
          row.id === existing.id
            ? {
                ...row,
                alias,
                enabled: draft.enabled,
                sequence: binding.sequence,
              }
            : row
        )
      );
    } else {
      if (existing) {
        await jsonApiDelete('/api/ash/bot-user-tool-bindings', existing.id);
      }

      const created = await jsonApiCreate('/api/ash/bot-user-tool-bindings', 'bot-user-tool-bindings', payload);
      const createdId = toIntId(created.data.id);

      userToolBindings.value = sortToolBindings([
        ...userToolBindings.value.filter((row) => row.alias !== alias),
        ...(createdId
          ? [
              {
                id: createdId,
                alias,
                tool_instance_id: draft.tool_instance_id,
                enabled: draft.enabled,
                sequence: binding.sequence,
              } satisfies UserToolBindingRow,
            ]
          : []),
      ]);
    }
  } catch (error) {
    console.error(error);
    alert(error instanceof Error ? error.message : 'Failed to save your tool override.');
  } finally {
    const next = new Set(userToolBindingSavingAliases.value);
    next.delete(alias);
    userToolBindingSavingAliases.value = next;
  }
}

async function removeUserToolBinding(binding: ToolBindingRow) {
  const alias = binding.alias;
  const existing = userToolBindings.value.find((row) => row.alias === alias);

  if (!existing) {
    setUserToolDraft(alias, { binding_id: null, tool_instance_id: 0, enabled: true, sequence: binding.sequence });
    return;
  }

  if (!window.confirm('Remove your personal tool override for this alias?')) return;

  userToolBindingSavingAliases.value = new Set([...userToolBindingSavingAliases.value, alias]);

  try {
    await jsonApiDelete('/api/ash/bot-user-tool-bindings', existing.id);
    userToolBindings.value = userToolBindings.value.filter((row) => row.id !== existing.id);
    setUserToolDraft(alias, { binding_id: null, tool_instance_id: 0, enabled: true, sequence: binding.sequence });
  } catch (error) {
    console.error(error);
    alert(error instanceof Error ? error.message : 'Failed to remove your tool override.');
  } finally {
    const next = new Set(userToolBindingSavingAliases.value);
    next.delete(alias);
    userToolBindingSavingAliases.value = next;
  }
}

const shareModalOpen = ref(false);
const shareLoading = ref(false);
const shareSaving = ref(false);
const shareGroups = ref<Group[]>([]);
const sharedGroupIds = ref<number[]>([]);

const shareToolBindings = computed<BotShareToolBinding[]>(() =>
  sortedToolBindings.value.map((binding) => ({
    id: binding.id,
    alias: binding.alias,
    enabled: binding.enabled,
    sharing_mode: binding.sharing_mode,
    tool_instance_name: toolLibraryById.value.get(binding.tool_instance_id)?.name || '',
    tool_instance_type: toolLibraryById.value.get(binding.tool_instance_id)?.type || '',
  }))
);

async function loadShareContext() {
  if (isNew.value || sharedReadonly.value || editor.numericId.value == null) return;

  shareLoading.value = true;
  try {
    const [groupsPayload, sharePayload] = await Promise.all([
      api.get<{ groups: Group[] }>('/api/bff/me/groups'),
      api.get<ShareStateResponse>(`/api/bff/bots/${editor.numericId.value}/shares`),
    ]);

    shareGroups.value = Array.isArray(groupsPayload.groups) ? groupsPayload.groups : [];
    sharedGroupIds.value = Array.isArray(sharePayload.group_ids)
      ? sharePayload.group_ids.filter((id): id is number => typeof id === 'number')
      : [];
  } catch (error) {
    console.error(error);
    alert(error instanceof Error ? error.message : 'Failed to load sharing settings.');
  } finally {
    shareLoading.value = false;
  }
}

async function openShareModal() {
  await loadShareContext();
  shareModalOpen.value = true;
}

async function saveSharing(payload: { groupIds: number[]; toolModes: Record<string, 'shared' | 'per_user'> }) {
  if (editor.numericId.value == null) return;

  shareSaving.value = true;
  try {
    const response = await api.put<ShareStateResponse>(`/api/bff/bots/${editor.numericId.value}/shares`, {
      group_ids: payload.groupIds,
      tool_modes: payload.toolModes,
    });

    sharedGroupIds.value = Array.isArray(response.group_ids)
      ? response.group_ids.filter((id): id is number => typeof id === 'number')
      : [];
    shareModalOpen.value = false;
    await editor.load();
  } catch (error) {
    console.error(error);
    alert(error instanceof Error ? error.message : 'Failed to save sharing settings.');
  } finally {
    shareSaving.value = false;
  }
}
</script>

<style scoped>
.share-banner {
  display: flex;
  gap: 8px;
  align-items: center;
  border-color: #bfd6f6;
  background: #f5f9ff;
}
</style>
