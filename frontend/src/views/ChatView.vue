<template>
  <div class="stack chat-page" v-if="vm.loaded">
    <StackToolbarTeleport>
      <ChatHeaderToolbar
        :selected-config="vm.selectedConfig"
        :applied-config="vm.appliedConfig"
        :selectable-configs="vm.selectableConfigs"
        :selected-disabled-config="vm.selectedDisabledConfig"
        :selected-disabled-config-reason="vm.selectedDisabledConfigReason"
        :config-label="vm.configLabel"
        :edit-config-label="vm.editConfigLabel"
        :config-sync-status="vm.configSyncStatus"
        :config-sync-error="vm.configSyncError"
        :menu-open="vm.menuOpen"
        :menu-style="vm.menuStyle"
        :current-bot-id="vm.currentBotId"
        :current-bot-name="vm.currentBotName"
        :chat-note="vm.chatNote"
        :duplicating="vm.duplicating"
        :exporting="vm.exporting"
        :deleting="vm.deleting"
        :show-missing-tools-banner="vm.showMissingToolsBanner"
        :missing-required-per-user-tool-aliases="vm.missingRequiredPerUserToolAliases"
        :set-menu-ref="vm.setMenuRef"
        :set-menu-anchor-ref="vm.setMenuAnchorRef"
        :set-menu-button-ref="vm.setMenuButtonRef"
        @update:selectedConfig="(value) => (vm.selectedConfig = value)"
        @change-config="vm.updateConfig"
        @toggle-menu="vm.toggleMenu"
        @open-config-editor="vm.openConfigEditor"
        @open-bot-editor="vm.openBotEditor"
        @open-bot-modal="vm.openBotModal"
        @open-note-modal="vm.openNoteModal"
        @duplicate-active-branch="vm.duplicateActiveBranch"
        @export-markdown="vm.exportMarkdown"
        @export-yaml="vm.exportYaml"
        @delete-chat="vm.removeChat"
        @open-bot-tools="vm.openBotTools"
        @dismiss-missing-tools-banner="vm.dismissMissingToolsBanner"
      />
    </StackToolbarTeleport>

    <p v-if="vm.loadError" class="error-text">{{ vm.loadError }}</p>

    <div class="split-wrapper">
      <div class="split" :style="{ gridTemplateColumns: vm.gridColumns }" style="min-height: 70vh">
        <ChatContextSidebar
          v-if="vm.leftOpen"
          :style="getContextGridStyle()"
          :is-mobile="vm.isMobile"
          :left-tab="vm.leftTab"
          :is-agent-history-mode="vm.isAgentHistoryMode"
          :agent-context-token-count="vm.agentContextTokenCount"
          :prompt-token-count="vm.promptTokenCount"
          :history-token-count="vm.historyTokenCount"
          :total-token-count="vm.totalTokenCount"
          :show-context-usage-indicator="vm.showContextUsageIndicator"
          :context-usage-percent-rounded="vm.contextUsagePercentRounded"
          :context-usage-title="vm.contextUsageTitle"
          :is-context-soft-limit-reached="vm.isContextSoftLimitReached"
          :context-usage-percent="vm.contextUsagePercent"
          :branch-search-term="vm.branchSearchTerm"
          :has-branch-search="vm.hasBranchSearch"
          :branch-search-loading="vm.branchSearchLoading"
          :branch-search-error="vm.branchSearchError"
          :branch-search-results="vm.branchSearchResults"
          :branch="vm.branch"
          :linked-blocks="vm.linkedBlocks"
          :source-labels="vm.SOURCE_LABELS"
          :bot-tools-loading="vm.botToolsLoading"
          :bot-tools-error="vm.botToolsError"
          :active-tool-instances="vm.activeToolInstances"
          :format-step-metric="vm.formatStepMetric"
          :search-hit-meta="vm.searchHitMeta"
          :message-meta-label="vm.messageMetaLabel"
          :message-text="vm.messagePrimaryText"
          :preview="vm.preview"
          :has-block-version="vm.hasBlockVersion"
          :format-block-version="vm.formatBlockVersion"
          @update:leftOpen="(value) => (vm.leftOpen = value)"
          @update:leftTab="(value) => (vm.leftTab = value)"
          @update:branchSearchTerm="(value) => (vm.branchSearchTerm = value)"
          @open-prompt-modal="vm.openPromptModal"
          @branch-item-click="vm.handleBranchItemClick"
          @search-result-click="vm.handleSearchResultClick"
          @switch-branch-target="handleContextSwitchBranchTarget"
          @open-context-block-editor="vm.openContextBlockEditor"
        />

        <section class="card chat-window" :style="getChatWindowGridStyle()" :ref="chatWindowRefEl">
          <div class="message-list">
            <ChatMessageBubble
              v-for="(msg, idx) in vm.branch"
              :key="msg.id ?? idx"
              :message="msg"
              :index="idx"
              :meta-label="vm.messageMetaLabel(msg) || '—'"
              :copied="vm.copiedMessageId === msg.id"
              :retrying="vm.retryingMessageId === msg.id"
              :branching-assistant-id="vm.branchingAssistantId"
              :working-open="vm.isWorkingOpen(msg.id)"
              :can-delete="vm.canDeleteMessage(msg, idx)"
              :delete-title="vm.deleteMessageTitle(msg, idx)"
              :register-ref="(el) => vm.setMessageRef(msg.id, el as HTMLElement | null)"
              @toggle-working="vm.toggleWorking(msg.id)"
              @copy="vm.copyMessage(msg)"
              @edit="vm.startEdit(msg)"
              @branch="vm.startBranch(msg)"
              @retry="vm.retryLastStep(msg)"
              @delete="vm.confirmAndDeleteMessage(msg, idx)"
              @switch-branch="(direction) => vm.switchBranchHandler(msg.id!, direction)"
              @step-info="
                (step) =>
                  msg.id &&
                  vm.openStepDetails({
                    messageId: msg.id,
                    step,
                    closed: msg.status !== 'generating' || Boolean(step.response_final),
                  })
              "
              @content-open="vm.openContentFull"
              @attachment-open="vm.openAttachmentPreview"
            />
          </div>
          <form
            class="chat-input-form"
            :class="{ 'chat-input-form--dragging': dragActive }"
            @submit.prevent="vm.activeGenerationId ? vm.cancelActiveGeneration() : vm.send()"
            @dragenter.prevent="handleDragEnter"
            @dragover.prevent="handleDragOver"
            @dragleave.prevent="handleDragLeave"
            @drop.prevent="handleDrop"
          >
            <div v-if="vm.pendingFiles.length" class="pending-files">
              <div
                v-for="item in vm.pendingFiles"
                :key="item.id"
                class="pending-file"
                :title="`${item.name}  (${formatPendingFileSize(item.size)})`"
              >
                <span class="pending-file__icon" aria-hidden="true">{{ fileIconByMime(item.mimeType, item.name) }}</span>
                <span class="pending-file__name">{{ item.name }}</span>
                <span class="pending-file__size">{{ formatPendingFileSize(item.size) }}</span>
                <button class="pending-file__remove" type="button" aria-label="Remove attachment" @click="vm.removePendingFile(item.id)">✕</button>
              </div>
            </div>
            <div class="chat-composer">
              <textarea
                class="chat-composer__textarea"
                v-model="vm.draft"
                placeholder="Type your message"
                @paste="handleComposerPaste"
                @keydown.enter.ctrl.exact.prevent="vm.activeGenerationId ? vm.cancelActiveGeneration() : vm.send()"
                @keydown.enter.meta.exact.prevent="vm.activeGenerationId ? vm.cancelActiveGeneration() : vm.send()"
              ></textarea>
              <div class="chat-composer__actions">
                <button
                  class="chat-composer__attach"
                  type="button"
                  aria-label="Attach files"
                  :disabled="!vm.canAttachFiles"
                  :title="vm.fileAttachTitle"
                  @click="openAttachFilesDialog"
                >
                  Attach
                </button>
                <button
                  class="chat-composer__send"
                  type="submit"
                  :disabled="
                    vm.sending ||
                    vm.isConfigSyncPending ||
                    (vm.activeGenerationId && vm.cancelingGenerationId === vm.activeGenerationId)
                  "
                  :title="vm.isConfigSyncPending ? 'Waiting for configuration sync' : undefined"
                  @pointerdown="vm.activeGenerationId ? vm.handleCancelPointerDown : null"
                >
                  {{
                    vm.activeGenerationId
                      ? vm.cancelingGenerationId === vm.activeGenerationId
                        ? 'Cancelling…'
                        : 'Cancel'
                      : vm.sending
                        ? 'Sending…'
                        : 'Send'
                  }}
                </button>
                <input
                  ref="attachInputRef"
                  class="input-file"
                  type="file"
                  multiple
                  :accept="vm.fileInputAccept || undefined"
                  :disabled="!vm.canAttachFiles"
                  @change="handleAttachInputChange"
                />
              </div>
            </div>
            <div v-if="dragActive && vm.canAttachFiles" class="drop-hint">{{ vm.fileDropHint }}</div>
          </form>
        </section>

        <ChatLibrarySidebar
          v-if="vm.rightOpen"
          :style="getLibraryGridStyle()"
          :is-mobile="vm.isMobile"
          :chat-tab-dirty="vm.chatTabDirty"
          :saving-chat-changes="vm.savingChatChanges"
          :chat-blocks="vm.chatBlocks"
          :chat-variables="vm.chatVariables"
          :chat-block-name="vm.chatBlockName"
          :chat-block-image="vm.chatBlockImage"
          :chat-block-meta="vm.chatBlockMeta"
          @update:rightOpen="(value) => (vm.rightOpen = value)"
          @save-chat-changes="vm.saveChatChanges"
          @cancel-chat-changes="vm.cancelChatChanges"
          @open-chat-blocks-picker="vm.openChatBlocksPicker"
          @open-new-block="vm.openNewBlock"
          @open-chat-block-editor="vm.openChatBlockEditor"
          @move-chat-block="vm.moveChatBlock"
          @remove-chat-block="vm.removeChatBlock"
          @touch-chat-blocks="vm.touchChatBlocks"
          @update:chatVariables="(value) => (vm.chatVariables = value)"
          @add-variable-row="vm.addVariableRow"
        />
      </div>

      <transition name="fade">
        <div v-if="vm.isMobile && (vm.leftOpen || vm.rightOpen)" class="panel-backdrop" @click="vm.closeOverlays"></div>
      </transition>

      <button
        v-if="!vm.leftOpen"
        class="panel-toggle floating left"
        type="button"
        @click="vm.leftOpen = true"
        aria-label="Show context"
      >
        ▶
      </button>
      <button
        v-if="!vm.rightOpen"
        class="panel-toggle floating right"
        type="button"
        @click="vm.rightOpen = true"
        aria-label="Show library"
      >
        ◀
      </button>
    </div>

    <Teleport to="body">
      <ChatEditMessageModal
        :open="Boolean(vm.editingMessage)"
        :mode="vm.modalMode"
        v-model="vm.editContents"
        :existing-attachments="vm.editExistingAttachments"
        :pending-files="vm.editPendingFiles"
        :error="vm.editError"
        :attachments-enabled="vm.canAttachFiles"
        :attachment-accept="vm.fileInputAccept"
        :attachment-help="vm.editAttachmentHelp"
        :saving="vm.savingEdit"
        @cancel="vm.cancelEdit"
        @add-files="vm.addEditPendingFiles"
        @remove-pending-file="vm.removeEditPendingFile"
        @remove-existing-attachment="vm.removeEditExistingAttachment"
        @save="vm.saveEdit"
      />
    </Teleport>

    <Teleport to="body">
      <ChatPromptModal
        :open="vm.promptModalOpen"
        :loading="vm.promptLoading"
        :error="vm.promptError"
        :text="vm.promptText"
        @close="vm.closePromptModal"
      />
    </Teleport>

    <Teleport to="body">
      <ChatNoteModal
        :open="vm.noteModalOpen"
        v-model="vm.noteModalValue"
        :saving="vm.savingNote"
        @cancel="vm.closeNoteModal"
        @save="vm.saveNote"
      />
    </Teleport>

    <Teleport to="body">
      <ChatStepDetailsModal
        :open="vm.stepDetailsOpen"
        :step="vm.stepDetailsStep"
        :show-billing="vm.stepDetailsShowBilling"
        :show-response="vm.stepDetailsShowResponse"
        :request-loading="vm.stepDetailsRequestLoading"
        :request-error="vm.stepDetailsRequestError"
        :request-payload="vm.stepDetailsRequestPayload"
        :response-loading="vm.stepDetailsResponseLoading"
        :response-error="vm.stepDetailsResponseError"
        :response-payload="vm.stepDetailsResponsePayload"
        @close="vm.closeStepDetails"
      />
    </Teleport>

    <Teleport to="body">
      <ChatStepRawModal
        :open="vm.contentFullOpen"
        :title="vm.contentFullTitle"
        :loading="vm.contentFullLoading"
        :error="vm.contentFullError"
        :text="vm.contentFullText"
        @close="vm.closeContentFull"
      />
    </Teleport>

    <Teleport to="body">
      <ChatAttachmentPreviewModal
        :open="vm.attachmentPreviewOpen"
        :title="vm.attachmentPreviewTitle"
        :url="vm.attachmentPreviewUrl"
        :kind="vm.attachmentPreviewKind"
        :loading="vm.attachmentPreviewLoading"
        :error="vm.attachmentPreviewError"
        :text="vm.attachmentPreviewText"
        @close="vm.closeAttachmentPreview"
      />
    </Teleport>

    <Teleport to="body">
      <BotSelectorModal
        v-if="vm.botModalOpen"
        v-model="vm.botModalValue"
        :bots="vm.bots"
        :saving="vm.savingBot"
        @cancel="vm.closeBotModal"
        @save="vm.saveBotSelection"
      />
    </Teleport>

    <KnowledgeBlocksPickerModal
      v-model:open="vm.chatBlocksPickerOpen"
      v-model:selected="vm.chatBlocksPickerSelection"
      title="Add chat blocks"
      :blocks="vm.knowledgeBlocks"
      :disabled-block-ids="vm.linkedChatBlockIds"
      @confirm="vm.addChatBlocks"
    />
  </div>
  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { reactive, ref, Teleport } from 'vue';

import BotSelectorModal from '@/components/BotSelectorModal.vue';
import KnowledgeBlocksPickerModal from '@/components/KnowledgeBlocksPickerModal.vue';
import ChatAttachmentPreviewModal from '@/components/chat/ChatAttachmentPreviewModal.vue';
import ChatEditMessageModal from '@/components/chat/ChatEditMessageModal.vue';
import ChatPromptModal from '@/components/chat/ChatPromptModal.vue';
import ChatNoteModal from '@/components/chat/ChatNoteModal.vue';
import ChatStepDetailsModal from '@/components/chat/ChatStepDetailsModal.vue';
import ChatStepRawModal from '@/components/chat/ChatStepRawModal.vue';
import ChatMessageBubble from '@/components/chat/ChatMessageBubble.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import ChatHeaderToolbar from '@/features/chat/components/ChatHeaderToolbar.vue';
import ChatContextSidebar from '@/features/chat/components/ChatContextSidebar.vue';
import ChatLibrarySidebar from '@/features/chat/components/ChatLibrarySidebar.vue';
import {
  clipboardHasStringContent,
  extractClipboardImageFiles,
  fileIconByMime,
  formatFileBytes,
} from '@/features/chat/attachments';
import { useChatViewModel } from '@/features/chat/useChatViewModel';

const vm = reactive(useChatViewModel());

const getContextGridStyle = (): Record<string, string> => (vm.isMobile ? {} : { gridColumn: '1' });

const getChatWindowGridStyle = (): Record<string, string> =>
  vm.isMobile ? {} : { gridColumn: vm.leftOpen ? '2' : '1' };

const getLibraryGridStyle = (): Record<string, string> =>
  vm.isMobile ? {} : { gridColumn: vm.leftOpen ? '3' : '2' };

const chatWindowRefEl = (el: Element | null) => {
  vm.chatWindowRef = el as HTMLElement | null;
};

const handleContextSwitchBranchTarget = (messageId: number, targetId: number) => {
  vm.switchBranchHandler(messageId, undefined, targetId);
};

const dragActive = ref(false);
const attachInputRef = ref<HTMLInputElement | null>(null);

const openAttachFilesDialog = () => {
  if (!vm.canAttachFiles) return;
  attachInputRef.value?.click();
};

const handleAttachInputChange = (event: Event) => {
  vm.onPendingFilesSelected(event);
};

const formatPendingFileSize = (size: number) => formatFileBytes(size);

const handleDragEnter = () => {
  if (!vm.canAttachFiles) return;
  dragActive.value = true;
};

const handleDragOver = () => {
  if (!vm.canAttachFiles) return;
  dragActive.value = true;
};

const handleDragLeave = (event: DragEvent) => {
  const currentTarget = event.currentTarget as HTMLElement | null;
  const relatedTarget = event.relatedTarget as Node | null;
  if (currentTarget && relatedTarget && currentTarget.contains(relatedTarget)) return;
  dragActive.value = false;
};

const handleDrop = (event: DragEvent) => {
  dragActive.value = false;
  if (!vm.canAttachFiles) return;
  const files = Array.from(event.dataTransfer?.files || []);
  if (files.length) vm.addPendingFiles(files);
};

const handleComposerPaste = (event: ClipboardEvent) => {
  if (!vm.canAttachFiles) return;
  const files = extractClipboardImageFiles(event);
  if (!files.length) return;

  vm.addPendingFiles(files);

  if (!clipboardHasStringContent(event)) {
    event.preventDefault();
  }
};


</script>

<style>
.chat-page .branch-search {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
}

.chat-page .branch-search-divider {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-top: 6px;
}

.chat-page .branch-search-label {
  font-size: 0.74rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: #6b7280;
}

.chat-page .branch-item--inactive {
  border-style: dashed;
  background: #fff7f7;
}

.chat-page .row.clickable {
  cursor: pointer;
}

.chat-page .row.clickable:hover {
  background: #f8f9fb;
  border-color: #e5e7eb;
}

.chat-page .row.clickable:focus-visible {
  outline: 2px solid #2563eb;
  outline-offset: 2px;
}

.chat-page .panel-tabs {
  display: flex;
  gap: 6px;
  padding: 4px;
  background: #f5f6f8;
  border-radius: 10px;
  border: 1px solid #eceff3;
}

.chat-page .panel-tab {
  flex: 1;
  border: none;
  background: transparent;
  padding: 6px 10px;
  border-radius: 8px;
  font-size: 0.9rem;
  cursor: pointer;
  color: #333;
}

.chat-page .panel-tab.active {
  background: #fff;
  border: 1px solid #e5e7eb;
  box-shadow: 0 1px 0 rgba(0, 0, 0, 0.04);
}

.chat-page .panel-tab:focus-visible {
  outline: 2px solid #2563eb;
  outline-offset: 2px;
}

.chat-page .panel-body {
  min-height: 0;
}

.chat-page .panel-pane {
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.chat-page .panel-actions {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}

.chat-page .panel-section {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.chat-page .panel-metrics {
  gap: 6px;
}

.chat-page .metric-item {
  font-size: 0.95rem;
  line-height: 1.4;
}

.chat-page .metric-expression {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
}

.chat-page .metric-inline-link {
  padding: 0;
}

.chat-page .context-usage-track {
  width: 100%;
  height: 10px;
  border-radius: 999px;
  background: #eef2f7;
  overflow: hidden;
}

.chat-page .context-usage-fill {
  height: 100%;
  background: #2563eb;
}

.chat-page .context-usage-fill.warn {
  background: #d97706;
}

.chat-input-form {
  display: flex;
  flex-direction: column;
  gap: 8px;
  position: relative;
  border: 1px solid transparent;
  border-radius: 14px;
  transition:
    border-color 0.18s ease,
    background-color 0.18s ease;
}

.chat-input-form--dragging {
  border-color: #2563eb;
  background: rgba(219, 234, 254, 0.32);
}

.pending-files {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 2px;
  padding: 8px 10px 4px;
}

.pending-file {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 8px;
  border-radius: 6px;
  min-width: 0;
  transition: background-color 0.12s ease;
}

.pending-file:hover {
  background: rgba(0, 0, 0, 0.04);
}

.pending-file__icon {
  flex: 0 0 auto;
  font-size: 0.95rem;
  line-height: 1;
}

.pending-file__name {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 0.85rem;
  font-weight: 500;
  line-height: 1.3;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #1a1a1a;
}

.pending-file__size {
  flex: 0 0 auto;
  font-size: 0.75rem;
  color: #888;
  white-space: nowrap;
}

.pending-file__remove {
  flex: 0 0 auto;
  width: 22px;
  height: 22px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  border: none;
  border-radius: 4px;
  background: transparent;
  color: #999;
  font-size: 0.75rem;
  cursor: pointer;
  transition: background-color 0.12s ease, color 0.12s ease;
}

.pending-file__remove:hover {
  background: rgba(0, 0, 0, 0.08);
  color: #c0392b;
}

/* --- Unified chat composer --- */
.chat-composer {
  display: flex;
  flex-direction: column;
  border: 1px solid #d0d5dd;
  border-radius: 12px;
  background: #fff;
  transition: border-color 0.18s ease, box-shadow 0.18s ease;
}

.chat-composer:focus-within {
  border-color: #a0aec0;
  box-shadow: 0 0 0 3px rgba(66, 133, 244, 0.08);
}

.chat-composer__textarea {
  flex: 1;
  border: none;
  outline: none;
  resize: vertical;
  min-height: 130px;
  padding: 12px 14px 4px;
  border-radius: 12px 12px 0 0;
  font: inherit;
  line-height: 1.5;
  background: transparent;
}

.chat-composer__actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  padding: 6px 10px;
}

.chat-composer__send {
  background: #111;
  color: #fff;
  border: none;
  border-radius: 8px;
  padding: 6px 16px;
  font-size: 0.88rem;
  font-weight: 500;
  cursor: pointer;
  transition: background-color 0.15s ease, opacity 0.15s ease;
}

.chat-composer__send:hover {
  background: #333;
}

.chat-composer__send:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.chat-composer__attach {
  background: #f5f5f5;
  color: #444;
  border: 1px solid #e0e0e0;
  border-radius: 8px;
  padding: 6px 14px;
  font-size: 0.88rem;
  font-weight: 500;
  cursor: pointer;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}

.chat-composer__attach:hover {
  background: #eaeaea;
  border-color: #ccc;
}

.drop-hint {
  font-size: 0.86rem;
  color: #1d4ed8;
  padding: 2px 4px 0;
}

.input-file {
  display: none;
}

@media (max-width: 720px) {
  .chat-composer__actions {
    padding: 4px 8px;
  }
}
</style>
