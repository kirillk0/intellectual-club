<template>
  <div v-if="vm.loaded && vm.chatUnavailable" class="chat-unavailable">
    <section class="chat-unavailable__panel">
      <div class="chat-unavailable__icon" aria-hidden="true">
        <SvgIcon name="chat" />
      </div>
      <div class="chat-unavailable__copy">
        <h1>Chat unavailable</h1>
        <p>This chat was deleted, the share was revoked, or you do not have access to it.</p>
      </div>
      <button class="primary" type="button" @click="vm.backToChats">Back to chats</button>
    </section>
  </div>
  <div class="stack chat-page" v-else-if="vm.loaded && vm.chat">
    <StackToolbarTeleport>
      <ChatHeaderToolbar
        :back-to="vm.chatsReturnTarget"
        :selected-config="vm.selectedConfig"
        :applied-config="vm.appliedConfig"
        :selectable-configs="vm.selectableConfigs"
        :default-config="vm.defaultConfig"
        :regular-selectable-configs="vm.regularSelectableConfigs"
        :more-configs="vm.moreConfigs"
        :selected-disabled-config="vm.selectedDisabledConfig"
        :selected-disabled-config-reason="vm.selectedDisabledConfigReason"
        :config-label="vm.configLabel"
        :edit-config-label="vm.editConfigLabel"
        :config-sync-status="vm.configSyncStatus"
        :config-sync-error="vm.configSyncError"
        :is-generating="Boolean(vm.activeGenerationId)"
        :menu-open="vm.menuOpen"
        :menu-style="vm.menuStyle"
        :current-bot-id="vm.currentBotId"
        :current-bot-name="vm.currentBotName"
        :chat-base-title="vm.chatBaseTitle"
        :chat-full-title="vm.chatFullTitle"
        :chat-note="vm.chatNote"
        :creating-chat="vm.creatingChat"
        :deleting="vm.deleting"
        :can-edit="vm.canEdit"
        :handoff-pending="vm.handoffPending"
        :handoff-disabled="vm.handoffDisabled"
        :show-missing-tools-banner="vm.showMissingToolsBanner"
        :missing-required-per-user-tool-aliases="vm.missingRequiredPerUserToolAliases"
        :set-menu-ref="vm.setMenuRef"
        :set-menu-anchor-ref="vm.setMenuAnchorRef"
        :set-menu-button-ref="vm.setMenuButtonRef"
        @update:selectedConfig="(value) => (vm.selectedConfig = value)"
        @change-config="vm.updateConfig"
        @toggle-menu="vm.toggleMenu"
        @open-new-chat="vm.openNewChatModal"
        @open-config-editor="vm.openConfigEditor"
        @open-bot-editor="vm.openBotEditor"
        @open-bot-modal="vm.openBotModal"
        @open-note-modal="vm.openNoteModal"
        @open-share="vm.openShareModal"
        @handoff="vm.handoffChat"
        @delete-chat="vm.removeChat"
        @open-bot-tools="vm.openBotTools"
        @dismiss-missing-tools-banner="vm.dismissMissingToolsBanner"
      />
    </StackToolbarTeleport>

    <p v-if="vm.loadError" class="error-text">{{ vm.loadError }}</p>
    <h1 class="chat-print-title">{{ vm.chatFullTitle || vm.chatBaseTitle || 'Chat' }}</h1>

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
          :readonly="vm.sharedReadonly"
          :branch="vm.branch"
          :linked-blocks="vm.linkedBlocks"
          :source-labels="vm.SOURCE_LABELS"
          :bot-tools-loading="vm.botToolsLoading"
          :bot-tools-error="vm.botToolsError"
          :active-tool-bindings="vm.activeToolBindings"
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
          @open-context-tool-editor="vm.openContextToolEditor"
        />

        <section class="card chat-window" :style="getChatWindowGridStyle()" :ref="chatWindowRefEl">
          <div class="message-list">
            <RouterLink
              v-if="vm.parentRelation"
              class="chat-relation-banner chat-relation-banner--parent"
              :to="chatRoute(vm.parentRelation.chat_id)"
            >
              <span>Continuation of</span>
              <strong>{{ relationTitle(vm.parentRelation) }}</strong>
            </RouterLink>

            <template v-for="(msg, idx) in vm.branch" :key="msg.id ?? idx">
              <ChatMessageBubble
                :message="msg"
                :index="idx"
                :meta-label="vm.messageMetaLabel(msg) || '—'"
                :copied="vm.copiedMessageId === msg.id"
                :retrying="vm.retryingMessageId === msg.id"
                :bookmarking="vm.isBookmarkingMessage(msg.id)"
                :readonly="vm.sharedReadonly"
                :poll-reconnecting="vm.generationPollReconnecting && msg.id === vm.activeGenerationId"
                :branching-assistant-id="vm.branchingAssistantId"
                :branching-new-chat-message-id="vm.branchingNewChatMessageId"
                :working-open="vm.isWorkingOpen(msg.id)"
                :working-state="vm.workingStateFor(msg.id)"
                :can-delete="vm.canDeleteMessage(msg, idx)"
                :delete-title="vm.deleteMessageTitle(msg, idx)"
                :register-ref="(el) => vm.setMessageRef(msg.id, el)"
                @toggle-working="vm.toggleWorking(msg.id)"
                @working-step-select="(stepId) => vm.selectWorkingStep(msg.id, stepId)"
                @copy="vm.copyMessage(msg)"
                @toggle-bookmark="vm.toggleBookmark(msg)"
                @edit="vm.startEdit(msg)"
                @branch="vm.startBranch(msg)"
                @branch-new-chat="vm.startBranchToNewChat(msg)"
                @retry="vm.retryLastStep(msg)"
                @delete="vm.confirmAndDeleteMessage(msg, idx)"
                @switch-branch="(direction) => vm.switchBranchHandler(msg.id!, direction)"
                @step-info="
                  (step) =>
                    msg.id &&
                    vm.openStepDetails({
                      messageId: msg.id,
                      messageStatus: msg.status,
                      step,
                      closed: msg.status !== 'generating' || Boolean(step.response_final),
                    })
                "
                @content-open="vm.openContentFull"
                @attachment-open="vm.openAttachmentPreview"
              />
              <RouterLink
                v-for="relation in vm.childRelationsForMessage(msg.id)"
                :key="`handoff-${msg.id}-${relation.chat_id}`"
                class="chat-relation-banner chat-relation-banner--child"
                :to="chatRoute(relation.chat_id)"
              >
                <span>Continued in</span>
                <strong>{{ relationTitle(relation) }}</strong>
              </RouterLink>
              <div
                v-if="vm.handoffPending && idx === vm.branch.length - 1"
                :ref="setHandoffPendingBannerRef"
                class="chat-relation-banner chat-relation-banner--child chat-relation-banner--pending"
                role="status"
                aria-live="polite"
              >
                <span class="chat-relation-banner__spinner" aria-hidden="true"></span>
                <strong>Creating continuation…</strong>
              </div>
            </template>

            <div v-if="vm.fallbackChildRelations.length" class="chat-relation-fallback">
              <RouterLink
                v-for="relation in vm.fallbackChildRelations"
                :key="`handoff-fallback-${relation.chat_id}`"
                class="chat-relation-banner chat-relation-banner--child"
                :to="chatRoute(relation.chat_id)"
              >
                <span>Continued in</span>
                <strong>{{ relationTitle(relation) }}</strong>
              </RouterLink>
            </div>
            <div
              v-if="vm.handoffPending && !vm.branch.length"
              :ref="setHandoffPendingBannerRef"
              class="chat-relation-banner chat-relation-banner--child chat-relation-banner--pending"
              role="status"
              aria-live="polite"
            >
              <span class="chat-relation-banner__spinner" aria-hidden="true"></span>
              <strong>Creating continuation…</strong>
            </div>
          </div>
          <div v-if="vm.sharedReadonly" class="chat-readonly-panel">
            <div>
              <strong>Shared read-only chat</strong>
              <p class="muted">You can read live updates and artifacts. Continue to make your own copy.</p>
            </div>
            <button
              class="primary"
              type="button"
              :disabled="vm.continuingConversation"
              @click="vm.continueConversation"
            >
              {{ vm.continuingConversation ? 'Continuing…' : 'Continue conversation' }}
            </button>
          </div>
          <form
            v-else
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
                role="button"
                tabindex="0"
                :aria-label="`Preview attachment ${item.name}`"
                @click="vm.openPendingAttachmentPreview(item.id, 'composer')"
                @keydown.enter.prevent="vm.openPendingAttachmentPreview(item.id, 'composer')"
                @keydown.space.prevent="vm.openPendingAttachmentPreview(item.id, 'composer')"
              >
                <span class="pending-file__icon" aria-hidden="true"><SvgIcon :name="fileIconByMime(item.mimeType, item.name)" /></span>
                <div class="pending-file__meta">
                  <span class="pending-file__name">{{ item.name }}</span>
                  <span class="pending-file__status">{{ describePendingFileStatus(item) }}</span>
                  <div
                    v-if="item.uploadStatus !== 'idle' || item.progress > 0"
                    class="pending-file__progress"
                    aria-hidden="true"
                  >
                    <span class="pending-file__progress-bar" :style="{ width: `${pendingFileProgress(item)}%` }"></span>
                  </div>
                </div>
                <button
                  class="pending-file__remove"
                  type="button"
                  aria-label="Remove attachment"
                  @click.stop="vm.removePendingFile(item.id)"
                >✕</button>
              </div>
            </div>
            <div class="chat-composer">
              <textarea
                ref="composerTextareaRef"
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
	                    Boolean(vm.activeGenerationId && vm.cancelingGenerationId === vm.activeGenerationId)
                  "
                  :title="vm.isConfigSyncPending ? 'Waiting for configuration sync' : undefined"
                  @pointerdown="vm.activeGenerationId ? vm.handleCancelPointerDown : null"
                >
                  {{ vm.sendButtonLabel }}
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
          :readonly="vm.sharedReadonly"
          :chat-blocks="vm.chatBlocks"
          :chat-tool-bindings="vm.chatToolBindings"
          :tool-library="vm.toolLibrary"
          :new-chat-tool-instance-ids="vm.newChatToolInstanceIds"
          :chat-block-name="vm.chatBlockName"
          :chat-block-image="vm.chatBlockImage"
          :chat-block-meta="vm.chatBlockMeta"
          :tool-label="vm.toolLabel"
          :tool-is-outlet="vm.toolIsOutlet"
          :tool-is-online="vm.toolIsOnline"
          @update:rightOpen="(value) => (vm.rightOpen = value)"
          @save-chat-changes="vm.saveChatChanges"
          @cancel-chat-changes="vm.cancelChatChanges"
          @open-chat-blocks-picker="vm.openChatBlocksPicker"
          @open-new-block="vm.openNewBlock"
          @open-chat-block-editor="vm.openChatBlockEditor"
          @open-chat-tool-editor="vm.openChatToolEditor"
          @update:newChatToolInstanceIds="(value) => (vm.newChatToolInstanceIds = value)"
          @add-chat-tool-binding="vm.addChatToolBinding"
          @move-chat-block="vm.moveChatBlock"
          @move-chat-tool-binding="vm.moveChatToolBinding"
          @remove-chat-block="vm.removeChatBlock"
          @remove-chat-tool-binding="vm.removeChatToolBinding"
          @set-chat-block-enabled="vm.setChatBlockEnabled"
          @set-chat-tool-binding-enabled="vm.setChatToolBindingEnabled"
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
        <SvgIcon name="chevron-right" />
      </button>
      <button
        v-if="!vm.rightOpen"
        class="panel-toggle floating right"
        type="button"
        @click="vm.rightOpen = true"
        aria-label="Show library"
      >
        <SvgIcon name="chevron-left" />
      </button>
    </div>

    <Teleport to="body">
      <ShareWithGroupsModal
        v-model:open="vm.shareModalOpen"
        title="Share chat"
        :groups="vm.shareGroups"
        :selected-group-ids="vm.sharedGroupIds"
        :disabled-group-ids="vm.shareDisabledGroupIds"
        :disabled-group-reasons="vm.shareDisabledGroupReasons"
        :loading="vm.shareLoading"
        :saving="vm.shareSaving"
        @save="vm.saveShareGroups"
      />
    </Teleport>

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
        :save-label="vm.editSaveLabel"
        @cancel="vm.cancelEdit"
        @add-files="vm.addEditPendingFiles"
        @remove-pending-file="vm.removeEditPendingFile"
        @remove-existing-attachment="vm.removeEditExistingAttachment"
        @preview-existing-attachment="vm.openExistingAttachmentPreview"
        @preview-pending-file="(id) => vm.openPendingAttachmentPreview(id, 'edit')"
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
      <BotSelectorModal
        v-if="vm.newChatModalOpen"
        v-model="vm.newChatBotValue"
        :options="vm.createChatBotOptions"
        :saving="vm.creatingChat"
        title="Select bot for new chat"
        confirm-label="Create chat"
        saving-label="Creating…"
        @cancel="vm.closeNewChatModal"
        @save="vm.createChat"
      />
    </Teleport>

    <Teleport to="body">
      <ChatStepDetailsModal
        :open="vm.stepDetailsOpen"
        :step="vm.stepDetailsStep"
        :message-id="vm.stepDetailsMessageId"
        :message-status="vm.stepDetailsMessageStatus"
        :show-billing="vm.stepDetailsShowBilling"
        :show-response="vm.stepDetailsShowResponse"
        :retry-from-step-pending="vm.stepDetailsRetryFromStepPending"
        :request-loading="vm.stepDetailsRequestLoading"
        :request-error="vm.stepDetailsRequestError"
        :request-payload="vm.stepDetailsRequestPayload"
        :response-loading="vm.stepDetailsResponseLoading"
        :response-error="vm.stepDetailsResponseError"
        :response-payload="vm.stepDetailsResponsePayload"
        @close="vm.closeStepDetails"
        @retry-from-step="vm.retryFromStep"
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
        :can-navigate="vm.attachmentPreviewCanNavigate"
        :loading="vm.attachmentPreviewLoading"
        :download-pending="vm.attachmentPreviewDownloadPending"
        :error="vm.attachmentPreviewError"
        :text="vm.attachmentPreviewText"
        @prev="vm.showPreviousAttachmentPreview"
        @next="vm.showNextAttachmentPreview"
        @download="vm.downloadAttachmentPreview"
        @close="vm.closeAttachmentPreview"
      />
    </Teleport>

    <Teleport to="body">
      <BotSelectorModal
        v-if="vm.botModalOpen"
        v-model="vm.botModalValue"
        :options="vm.botSelectionOptions"
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
  <div v-else-if="vm.loaded" class="chat-unavailable">
    <section class="chat-unavailable__panel">
      <div class="chat-unavailable__icon" aria-hidden="true">
        <SvgIcon name="chat" />
      </div>
      <div class="chat-unavailable__copy">
        <h1>Chat unavailable</h1>
        <p>{{ vm.loadError || 'This chat could not be loaded.' }}</p>
      </div>
      <button class="primary" type="button" @click="vm.backToChats">Back to chats</button>
    </section>
  </div>
  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { nextTick, reactive, ref, Teleport, watch, type ComponentPublicInstance } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import BotSelectorModal from '@/components/BotSelectorModal.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import KnowledgeBlocksPickerModal from '@/components/KnowledgeBlocksPickerModal.vue';
import ChatAttachmentPreviewModal from '@/components/chat/ChatAttachmentPreviewModal.vue';
import ChatEditMessageModal from '@/components/chat/ChatEditMessageModal.vue';
import ChatPromptModal from '@/components/chat/ChatPromptModal.vue';
import ChatNoteModal from '@/components/chat/ChatNoteModal.vue';
import ChatStepDetailsModal from '@/components/chat/ChatStepDetailsModal.vue';
import ChatStepRawModal from '@/components/chat/ChatStepRawModal.vue';
import ChatMessageBubble from '@/components/chat/ChatMessageBubble.vue';
import ShareWithGroupsModal from '@/components/ShareWithGroupsModal.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import ChatHeaderToolbar from '@/features/chat/components/ChatHeaderToolbar.vue';
import ChatContextSidebar from '@/features/chat/components/ChatContextSidebar.vue';
import ChatLibrarySidebar from '@/features/chat/components/ChatLibrarySidebar.vue';
import {
  clipboardHasStringContent,
  describePendingFileUploadStatus,
  extractClipboardImageFiles,
  fileIconByMime,
  formatFileBytes,
  pendingFileProgressPercent,
} from '@/features/chat/attachments';
import { useChatViewModel } from '@/features/chat/useChatViewModel';
import type { ChatRelationSummary } from '@/types/api';

const vm = reactive(useChatViewModel());
const route = useRoute();
const router = useRouter();
const composerTextareaRef = ref<HTMLTextAreaElement | null>(null);

const FOCUS_COMPOSER_QUERY_PARAM = 'focusComposer';
type TemplateRefValue = Element | ComponentPublicInstance | null;

const toHTMLElement = (el: TemplateRefValue) => (el instanceof HTMLElement ? el : null);

function isFocusComposerQueryEnabled(value: unknown) {
  if (Array.isArray(value)) return value.some(isFocusComposerQueryEnabled);
  return value === '1' || value === 'true';
}

async function clearFocusComposerQuery() {
  const query = { ...route.query };
  delete query[FOCUS_COMPOSER_QUERY_PARAM];
  await router.replace({ path: route.path, query, hash: route.hash }).catch(() => {});
}

async function focusComposerFromRouteQuery() {
  if (!isFocusComposerQueryEnabled(route.query[FOCUS_COMPOSER_QUERY_PARAM])) return;
  if (!vm.loaded || !vm.chat || vm.sharedReadonly) return;

  await nextTick();
  composerTextareaRef.value?.focus({ preventScroll: true });
  await clearFocusComposerQuery();
}

watch(
  () => [
    route.query[FOCUS_COMPOSER_QUERY_PARAM],
    vm.loaded,
    vm.chat?.id,
    vm.sharedReadonly,
  ],
  () => {
    void focusComposerFromRouteQuery();
  },
  { immediate: true }
);

const getContextGridStyle = (): Record<string, string> => (vm.isMobile ? {} : { gridColumn: '1' });

const getChatWindowGridStyle = (): Record<string, string> =>
  vm.isMobile ? {} : { gridColumn: vm.leftOpen ? '2' : '1' };

const getLibraryGridStyle = (): Record<string, string> =>
  vm.isMobile ? {} : { gridColumn: vm.leftOpen ? '3' : '2' };

const chatWindowRefEl = (el: TemplateRefValue) => {
  vm.chatWindowRef = toHTMLElement(el);
};

const handoffPendingBannerRef = ref<HTMLElement | null>(null);

const setHandoffPendingBannerRef = (el: TemplateRefValue) => {
  handoffPendingBannerRef.value = toHTMLElement(el);
};

watch(
  () => vm.handoffPending,
  async (pending) => {
    if (!pending) return;
    await nextTick();
    handoffPendingBannerRef.value?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }
);

const handleContextSwitchBranchTarget = (messageId: number, targetId: number) => {
  if (vm.sharedReadonly) return;
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
const describePendingFileStatus = describePendingFileUploadStatus;
const pendingFileProgress = pendingFileProgressPercent;

const relationTitle = (relation: ChatRelationSummary) =>
  String(relation.note || `Chat #${relation.chat_id}`).trim() || `Chat #${relation.chat_id}`;

const chatRoute = (chatId: number) => ({
  path: `/chats/${chatId}`,
  query: { returnTo: vm.chatsReturnTarget },
});

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
  color: var(--color-text-muted);
}

.chat-page .branch-item--inactive {
  border-style: dashed;
  background: var(--color-danger-bg);
}

.chat-page .row.clickable {
  cursor: pointer;
}

.chat-page .row.clickable:hover {
  background: var(--color-surface-muted);
  border-color: var(--color-border-strong);
}

.chat-page .row.clickable:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}

.chat-page .panel-tabs {
  display: flex;
  gap: 6px;
  padding: 4px;
  background: var(--color-surface-muted);
  border-radius: 10px;
  border: 1px solid var(--color-border);
}

.chat-page .panel-tab {
  flex: 1;
  border: none;
  background: transparent;
  padding: 6px 10px;
  border-radius: 8px;
  font-size: 0.9rem;
  cursor: pointer;
  color: var(--color-text-muted);
}

.chat-page .panel-tab.active {
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  box-shadow: var(--shadow-soft);
}

.chat-page .panel-tab:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}

.chat-page .chat-readonly-panel {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px;
  border-top: 1px solid var(--color-border-strong);
  background: var(--color-surface-muted);
}

.chat-page .chat-readonly-panel p {
  margin: 3px 0 0;
}

.chat-page .chat-relation-banner {
  align-self: stretch;
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  margin: 0 8px;
  padding: 8px 10px;
  border: 1px solid var(--color-info-border);
  border-radius: 8px;
  background: var(--color-info-bg);
  color: var(--color-text);
  font-size: 0.9rem;
  text-decoration: none;
}

.chat-page .chat-relation-banner:hover {
  border-color: var(--color-info-border-strong);
  background: var(--color-info-bg-strong);
}

.chat-page .chat-relation-banner span {
  flex: 0 0 auto;
  color: var(--color-text-muted);
}

.chat-page .chat-relation-banner strong {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-weight: 600;
}

.chat-page .chat-relation-banner--parent {
  margin-bottom: 6px;
}

.chat-page .chat-relation-banner--child {
  margin-top: -4px;
  margin-bottom: 6px;
}

.chat-page .chat-relation-banner--pending {
  border-color: var(--color-info-border);
  background: var(--color-info-bg);
}

.chat-page .chat-relation-banner--pending:hover {
  border-color: var(--color-info-border);
  background: var(--color-info-bg);
}

.chat-page .chat-relation-banner__spinner {
  width: 14px;
  height: 14px;
  border: 2px solid var(--color-info-border);
  border-top-color: var(--color-focus);
  border-radius: 999px;
  animation: chat-relation-spin 0.8s linear infinite;
}

.chat-page .chat-relation-fallback {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

@keyframes chat-relation-spin {
  to {
    transform: rotate(360deg);
  }
}

.chat-unavailable {
  min-height: calc(100vh - var(--app-header-height, 56px));
  display: grid;
  place-items: center;
  padding: 24px;
  background: var(--color-bg);
}

.chat-unavailable__panel {
  width: min(520px, 100%);
  display: grid;
  justify-items: center;
  gap: 16px;
  padding: 28px;
  border: 1px solid var(--color-border-strong);
  border-radius: 8px;
  background: var(--color-surface);
  text-align: center;
}

.chat-unavailable__icon {
  width: 44px;
  height: 44px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  background: var(--color-surface-muted);
  color: var(--color-text-muted);
  font-size: 22px;
}

.chat-unavailable__copy {
  display: grid;
  gap: 6px;
}

.chat-unavailable__copy h1 {
  margin: 0;
  font-size: 1.25rem;
  line-height: 1.2;
}

.chat-unavailable__copy p {
  margin: 0;
  color: var(--color-text-muted);
}

@media (max-width: 720px) {
  .chat-page .chat-readonly-panel {
    align-items: stretch;
    flex-direction: column;
  }
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
  background: var(--color-surface-muted);
  overflow: hidden;
}

.chat-page .context-usage-fill {
  height: 100%;
  background: var(--color-focus);
}

.chat-page .context-usage-fill.warn {
  background: var(--color-warning-text);
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
  border-color: var(--color-focus);
  background: color-mix(in srgb, var(--color-info-bg) 70%, transparent);
}

.pending-files {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 2px;
  padding: 8px 10px 4px;
}

.pending-file {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  padding: 6px 8px;
  border-radius: 6px;
  min-width: 0;
  cursor: pointer;
  outline: none;
  transition: background-color 0.12s ease;
}

.pending-file:hover {
  background: var(--color-surface-muted);
}

.pending-file:focus-visible {
  background: var(--color-info-bg);
  box-shadow: inset 0 0 0 1px var(--color-focus);
}

.pending-file__icon {
  flex: 0 0 auto;
  font-size: 0.95rem;
  line-height: 1;
}

.pending-file__name {
  font-size: 0.85rem;
  font-weight: 500;
  line-height: 1.3;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--color-text);
}

.pending-file__meta {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.pending-file__status {
  font-size: 0.73rem;
  color: var(--color-text-muted);
  line-height: 1.25;
}

.pending-file__progress {
  position: relative;
  width: 100%;
  height: 5px;
  border-radius: 999px;
  background: rgba(148, 163, 184, 0.25);
  overflow: hidden;
}

.pending-file__progress-bar {
  position: absolute;
  inset: 0 auto 0 0;
  width: 0;
  border-radius: inherit;
  background: linear-gradient(90deg, #0f766e, #22c55e);
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
  color: var(--color-text-subtle);
  font-size: 0.75rem;
  cursor: pointer;
  transition: background-color 0.12s ease, color 0.12s ease;
}

.pending-file__remove:hover {
  background: var(--color-surface-hover);
  color: var(--color-danger);
}

/* --- Unified chat composer --- */
.chat-composer {
  display: flex;
  flex-direction: column;
  border: 1px solid var(--color-border-strong);
  border-radius: 12px;
  background: var(--color-surface);
  transition: border-color 0.18s ease, box-shadow 0.18s ease;
}

.chat-composer:focus-within {
  border-color: var(--color-focus);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-focus) 18%, transparent);
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
  border-top: 1px solid var(--color-border-strong);
  border-radius: 0 0 12px 12px;
}

.chat-composer__send {
  background: var(--color-primary);
  color: var(--color-primary-contrast);
  border: none;
  border-radius: 8px;
  padding: 6px 16px;
  font-size: 0.88rem;
  font-weight: 500;
  cursor: pointer;
  transition: background-color 0.15s ease, opacity 0.15s ease;
}

.chat-composer__send:hover {
  background: var(--color-primary-hover);
}

.chat-composer__send:disabled {
  background: var(--color-text-muted);
  opacity: 0.45;
  cursor: not-allowed;
}

.chat-composer__send:disabled:hover {
  background: var(--color-text-muted);
}

.chat-composer__attach {
  background: var(--color-surface-muted);
  color: var(--color-text-muted);
  border: 1px solid var(--color-border-strong);
  border-radius: 8px;
  padding: 6px 14px;
  font-size: 0.88rem;
  font-weight: 500;
  cursor: pointer;
  transition: background-color 0.15s ease, border-color 0.15s ease;
}

.chat-composer__attach:hover {
  background: var(--color-surface-hover);
  border-color: var(--color-border-strong);
}

.drop-hint {
  font-size: 0.86rem;
  color: var(--color-link);
  padding: 2px 4px 0;
}

.input-file {
  display: none;
}

.chat-print-title {
  display: none;
}

@media (max-width: 720px) {
  .chat-composer__actions {
    padding: 4px 8px;
  }
}

@media print {
  @page {
    margin: 14mm 12mm;
  }

  body:has(.chat-page) {
    background: #fff;
    color: #111;
  }

  body:has(.chat-page) .app-header,
  body:has(.chat-page) .backend-status-banner,
  body:has(.chat-page) .floating-dropdown,
  body:has(.chat-page) .panel-backdrop {
    display: none !important;
  }

  body:has(.chat-page) .app-shell,
  body:has(.chat-page) .app-main,
  body:has(.chat-page) .stack-nav,
  body:has(.chat-page) .stack-layer {
    display: block !important;
    min-height: 0 !important;
    height: auto !important;
    padding: 0 !important;
    overflow: visible !important;
    background: #fff !important;
    box-shadow: none !important;
  }

  body:has(.chat-page) .stack-nav--active .stack-layer--active {
    position: static !important;
  }

  .chat-page {
    display: block !important;
    min-height: 0 !important;
    height: auto !important;
  }

  .chat-print-title {
    display: block;
    margin: 0 0 12mm;
    color: #111;
    font-size: 18pt;
    font-weight: 650;
    line-height: 1.25;
    break-after: avoid;
  }

  .chat-page .split-wrapper,
  .chat-page .split {
    display: block !important;
    min-height: 0 !important;
    height: auto !important;
    overflow: visible !important;
  }

  .chat-page .sidebar,
  .chat-page .panel-toggle,
  .chat-page .chat-input-form,
  .chat-page .chat-readonly-panel {
    display: none !important;
  }

  .chat-page .chat-window.card {
    display: block !important;
    border: 0 !important;
    border-radius: 0 !important;
    padding: 0 !important;
    background: #fff !important;
    box-shadow: none !important;
    overflow: visible !important;
  }

  .chat-page .message-list {
    min-height: 0 !important;
    border: 0 !important;
    border-radius: 0 !important;
    padding: 0 !important;
    overflow: visible !important;
  }

  .chat-page .message {
    display: block !important;
    margin: 0 0 7mm !important;
    padding: 0 !important;
    break-inside: auto;
  }

  .chat-page .message .bubble {
    margin: 0 !important;
    border: 1px solid #d7dce3 !important;
    border-radius: 6px !important;
    padding: 7mm 8mm !important;
    background: #fff !important;
    color: #111 !important;
    box-shadow: none !important;
    break-inside: auto;
  }

  .chat-page .message .bubble::before {
    display: block;
    margin-bottom: 3mm;
    color: #4b5563;
    font-size: 8pt;
    font-weight: 650;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .chat-page .message.user .bubble::before {
    content: 'User';
  }

  .chat-page .message.assistant .bubble::before {
    content: 'Assistant';
  }

  .chat-page .message.user .bubble {
    border-left: 3px solid #2563eb !important;
  }

  .chat-page .message.assistant .bubble {
    border-left: 3px solid #6b7280 !important;
  }

  .chat-page .working-block,
  .chat-page .message-actions,
  .chat-page .copy-hint,
  .chat-page .retry-link,
  .chat-page .typing-indicator,
  .chat-page .code-copy-button {
    display: none !important;
  }

  .chat-page .message-footer {
    display: block !important;
    margin-top: 5mm !important;
    padding-top: 2.5mm !important;
    border-top: 1px solid #e5e7eb !important;
  }

  .chat-page .message-meta,
  .chat-page .message-answer-time {
    color: #5f6673 !important;
    font-size: 8.5pt !important;
  }

  .chat-page .message .bubble .message-content {
    font-size: 10.5pt;
    line-height: 1.45;
  }

  .chat-page .message .bubble .message-content :where(h1, h2, h3, h4, h5, h6) {
    break-after: avoid;
  }

  .chat-page .message .bubble a {
    color: #111 !important;
    text-decoration: underline;
  }

  .chat-page .message .bubble pre,
  .chat-page .message .bubble code {
    border: 1px solid #d7dce3;
    background: #f6f8fa !important;
    color: #111 !important;
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;
  }

  .chat-page .message .bubble pre {
    white-space: pre-wrap;
    overflow: visible !important;
  }

  .chat-page .message .bubble pre code {
    border: 0;
    background: transparent !important;
  }

  .chat-page .message .bubble .table-scroll {
    overflow: visible !important;
  }

  .chat-page .message .bubble .table-scroll table {
    table-layout: auto;
  }
}
</style>
