<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Chats</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button class="icon-button icon-button--labeled" type="button" aria-label="Open bookmarks" title="Bookmarks" @click="openBookmarks">
            <SvgIcon name="bookmark" />
            <span class="icon-button__label">Bookmarks</span>
          </button>
          <button
            class="icon-button icon-button--labeled primary toolbar-create-button"
            type="button"
            @click="openCreateChatModal"
            :disabled="creating"
            :aria-label="creating ? 'Creating…' : 'New chat'"
            :title="creating ? 'Creating…' : 'New chat'"
          >
            <SvgIcon name="plus" size="16" />
            <span class="icon-button__label">{{ creating ? 'Creating…' : 'New chat' }}</span>
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <div class="split-wrapper">
      <PullToRefresh :refresh="refreshChatIndex" :disabled="creating">
        <div class="catalog-split">
          <aside class="catalog-split__sidebar">
            <div class="chat-filters-stack">
              <ChatInboxViewsPanel :modelValue="archiveView" @update:modelValue="setArchiveView" />
              <ChatBotFiltersPanel
                v-model:searchTerm="botSearchTerm"
                :sortMode="botSortModeValue"
                :selectedFilter="botFilter"
                :hasActiveFilter="hasActiveBotFilter"
                :allBotsCount="allBotsCount"
                :options="visibleBotFilterOptions"
                :emptyState="botFilterEmptyState"
                @toggle-sort="toggleBotSortMode"
                @select-filter="setBotFilter"
                @clear-filter="setBotFilter('')"
              />
            </div>
          </aside>

          <main class="catalog-split__main stack">
            <section class="card stack">
              <div class="chat-search">
                <input
                  v-model="chatSearchTerm"
                  type="search"
                  class="full"
                  placeholder="Search chats"
                  aria-label="Search chats"
                />
                <button
                  type="button"
                  class="search-icon-button chat-search__exact"
                  :class="{ active: chatSearchExact }"
                  :aria-pressed="chatSearchExact"
                  :aria-label="translate('Exact')"
                  :title="translate('Match the whole phrase exactly, including spaces')"
                  @click="toggleChatSearchExact"
                >
                  <SvgIcon name="quote" size="16" />
                </button>
                <SearchClearButton v-if="chatSearchTerm" @click="chatSearchTerm = ''" />
              </div>
            </section>

            <section v-if="error && !chats.length" class="card stack chat-list-error" role="alert">
              <p class="error-text">{{ error }}</p>
            </section>

            <section v-else class="card stack chat-list-main">
              <p v-if="archiveNotice" role="status">{{ archiveNotice }}</p>
              <p v-if="error" class="error-text" role="alert">{{ error }}</p>
              <p v-if="readStateError && !snoozeChat" class="error-text" role="alert">{{ readStateError }}</p>
              <p v-if="hasChatSearch && chatSearchLoading" class="muted">Searching...</p>
              <p v-if="hasChatSearch && chatSearchError" class="error-text">{{ chatSearchError }}</p>
              <p v-if="chatSearchMetaOnlyHint" class="muted chat-search-hint">
                {{ translate('Message text was not searched: some word must have at least 3 letters or digits in a row. Only chat notes were searched.') }}
              </p>

              <InitialRoutePlaceholder
                v-if="loading && !chats.length && !hasChatSearch"
              />
              <div v-else class="chat-sections">
                <section v-for="section in renderedSections" :key="section.key" class="chat-section" :data-section="section.key" :aria-label="section.label">
                  <div v-if="section.showHeading" class="chat-section__header">
                    <h3 class="chat-section__heading">{{ section.label }} <span v-if="section.total != null" class="muted">{{ section.total }}</span></h3>
                    <button v-if="section.key === 'other' && !hasChatSearch && archiveView === 'inbox'" class="chat-section__actions-button" type="button" data-chat-actions-trigger :aria-label="translate('Other chats actions')" aria-haspopup="menu" :aria-expanded="Boolean(sectionActionsAnchor)" @click="openSectionActions($event)"><SvgIcon name="more-horizontal" size="16" /></button>
                  </div>
                  <div class="list">
                    <div v-for="entry in section.entries" :key="entry.key" class="chat-list-entry">
                      <ChatListRow
                        :to="chatLink(entry.chat)"
                        :stack="true"
                        :title="chatLabel(entry.chat)"
                        :config-label="entry.chat.llm_configuration_label || null"
                        :meta-text="chatMetaText(entry.chat)"
                        :secondary-meta="relationMeta(entry.chat)"
                        :preview-text="!hasChatSearch && entry.chat.first_message_preview ? formatPreview(entry.chat.first_message_preview) : null"
                        :preview-role="!hasChatSearch ? entry.chat.first_message_role : null"
                        :generation-state="generationStateForChat(entry.chat)"
                        :read-state="entry.chat.read_state"
                        :actions="true"
                        :actions-open="chatActionsMenu?.chat.id === entry.chat.id"
                        @navigate="openChat"
                        @open-actions="openChatActions(entry.chat, $event)"
                      >
                        <template #badges>
                          <span
                            v-if="entry.chat.shared_outgoing"
                            class="share-indicator"
                            title="Shared with groups"
                            aria-label="Shared with groups"
                          >
                            <SvgIcon name="share-outgoing" />
                          </span>
                          <span v-if="relationBadgeLabel(entry.chat)" class="badge">{{ relationBadgeLabel(entry.chat) }}</span>
                        </template>
                      </ChatListRow>
                      <ul v-if="entry.hits.length" class="chat-search-hits">
                        <li v-for="hit in entry.hits" :key="hit.message_id" class="chat-search-hit" :class="hitToneClass(hit)">
                          <RouterLink custom :to="hitLink(hit)" v-slot="{ href }">
                            <a class="chat-search-hit__link" :href="href" @click="handleHitClick($event, hitLink(hit))">
                              <div class="chat-search-hit__meta muted">
                                <span class="chat-search-hit__role">{{ hitRoleLabel(hit) }}</span>
                                <span>{{ niceDate(hit.created_at) }}</span>
                                <span v-if="!hit.active" class="badge badge-muted">{{ translate('Inactive branch') }}</span>
                              </div>
                              <div class="chat-search-hit__snippet">
                                <template v-for="(part, index) in highlightSnippet(hit.snippet)" :key="index">
                                  <mark v-if="part.match">{{ part.text }}</mark>
                                  <template v-else>{{ part.text }}</template>
                                </template>
                              </div>
                            </a>
                          </RouterLink>
                        </li>
                      </ul>
                      <div v-if="subchatCount(entry.chat) > 0" class="subchat-toggle-row">
                        <button
                          class="subchat-toggle"
                          type="button"
                          :aria-expanded="subchatsExpanded(entry.chat)"
                          @click="toggleSubchats(entry.chat.id)"
                        >
                          <SvgIcon :name="subchatsExpanded(entry.chat) ? 'arrow-down' : 'chevron-right'" size="14" />
                          <span>{{ subchatCountLabel(subchatCount(entry.chat)) }}</span>
                        </button>
                      </div>
                      <div v-if="subchatsExpanded(entry.chat)" class="subchat-list">
                        <ChatListRow
                          v-for="subchat in directSubchats(entry.chat)"
                          :key="subchat.id"
                          :to="chatLink(subchat)"
                          :stack="true"
                          :title="chatLabel(subchat)"
                          :config-label="subchat.llm_configuration_label || null"
                          :meta-text="chatMetaText(subchat)"
                          :secondary-meta="relationMeta(subchat)"
                          :preview-text="!hasChatSearch && subchat.first_message_preview ? formatPreview(subchat.first_message_preview) : null"
                          :preview-role="!hasChatSearch ? subchat.first_message_role : null"
                          :generation-state="generationStateForChat(subchat)"
                          :read-state="subchat.read_state"
                          :actions="true"
                          :actions-open="chatActionsMenu?.chat.id === subchat.id"
                          @navigate="openChat"
                          @open-actions="openChatActions(subchat, $event)"
                        >
                          <template #badges>
                            <span class="badge">{{ translate('Subchat') }}</span>
                            <span v-if="relationBadgeLabel(subchat)" class="badge">{{ relationBadgeLabel(subchat) }}</span>
                          </template>
                        </ChatListRow>
                      </div>
                    </div>
                  </div>

                  <div v-if="section.showPagination && section.sectionKey" class="pagination">
                    <button type="button" :disabled="loading || !section.hasPrevious" @click="changeSectionPage(section.sectionKey, -1)">{{ translate('Previous') }}</button>
                    <span class="muted">{{ translate('Page {page} of {total}', { page: section.page, total: section.totalPages }) }}</span>
                    <button type="button" :disabled="loading || !section.hasNext" @click="changeSectionPage(section.sectionKey, 1)">{{ translate('Next') }}</button>
                  </div>
                </section>

                <div v-if="hasChatSearch && chatSearchNextCursor && !chatSearchLoading" class="chat-search-more">
                  <button type="button" :disabled="chatSearchLoadingMore" @click="loadMoreChatSearch">
                    {{ chatSearchLoadingMore ? translate('Loading…') : translate('Show more') }}
                  </button>
                </div>
              </div>

              <p v-if="chatListEmptyState" class="muted">{{ chatListEmptyState }}</p>
              <p v-if="chatSearchEmptyState" class="muted">{{ chatSearchEmptyState }}</p>
            </section>
          </main>
        </div>
      </PullToRefresh>

      <transition name="fade">
        <div v-if="isMobile && filterOpen" class="panel-backdrop" @click="closeFilter"></div>
      </transition>

      <aside v-if="isMobile && filterOpen" class="sidebar overlay align-left chat-filters-overlay">
        <ChatInboxViewsPanel :modelValue="archiveView" @update:modelValue="setArchiveView">
          <template #header-extra>
            <button class="panel-toggle" type="button" @click="closeFilter" aria-label="Hide filters">
              <SvgIcon name="chevron-left" />
            </button>
          </template>
        </ChatInboxViewsPanel>
        <ChatBotFiltersPanel
          v-model:searchTerm="botSearchTerm"
          :sortMode="botSortModeValue"
          :selectedFilter="botFilter"
          :hasActiveFilter="hasActiveBotFilter"
          :allBotsCount="allBotsCount"
          :options="visibleBotFilterOptions"
          :emptyState="botFilterEmptyState"
          @toggle-sort="toggleBotSortMode"
          @select-filter="setBotFilter"
          @clear-filter="setBotFilter('')"
        />
      </aside>

      <button
        v-if="isMobile && !filterOpen"
        class="panel-toggle floating left"
        :class="{ 'active-filter': hasActiveBotFilter || archiveView === 'archive' }"
        type="button"
        @click="openFilter"
        aria-label="Show filters"
      >
        <SvgIcon name="filter" />
      </button>
    </div>

    <Teleport to="body">
      <BotSelectorModal
        v-if="botModalOpen"
        v-model="botModalValue"
        :options="createChatBotOptionsBase"
        :saving="creating"
        title="Select bot for new chat"
        confirm-label="Create chat"
        saving-label="Creating…"
        @cancel="closeCreateChatModal"
        @save="createChat"
      />
    </Teleport>

    <ChatListActionsMenu
      :anchor="chatActionsMenu?.anchor ?? null"
      :can-edit="chatActionsMenu?.chat.can_edit === true"
      :unread="Boolean(chatActionsMenu?.chat.read_state?.has_unread || chatActionsMenu?.chat.read_state?.manual_unread)"
      :snoozed="Boolean(chatActionsMenu?.chat.read_state?.is_snoozed)"
      :busy="readStateSaving"
      :archivable="Boolean(chatActionsMenu && !chatActionsMenu.chat.subagent)"
      :archived="Boolean(chatActionsMenu?.chat.read_state?.is_archived)"
      @archive="changeReadStateFromMenu('archive')"
      @unarchive="changeReadStateFromMenu('unarchive')"
      @mark-read="changeReadStateFromMenu('read')"
      @mark-unread="changeReadStateFromMenu('unread')"
      @snooze="openSnoozeModal"
      @unsnooze="changeReadStateFromMenu('unsnooze')"
      :deleting="deletingChatId != null && deletingChatId === chatActionsMenu?.chat.id"
      @close="closeChatActions"
      @edit-note="openChatNoteModal"
      @delete="deleteChatFromMenu"
    />

    <ChatListActionsMenu :anchor="sectionActionsAnchor" :readable="false" :section-actions="true" @close="sectionActionsAnchor = null" @archive-all="openArchiveAll" />
    <ChatArchiveAllModal v-if="archiveAllTarget" :bot="archiveAllTarget.bot" :bot-label="archiveAllTarget.label" @close="archiveAllTarget = null" @archived="finishArchiveAll" />

    <ChatSnoozeModal
      :open="snoozeChat != null"
      :saving="readStateSaving"
      :error="readStateError"
      @update:open="(open) => { if (!open) snoozeChat = null; }"
      @confirm="confirmSnooze"
    />

    <ChatNoteModal
      :open="noteChat != null"
      v-model="noteModalValue"
      :saving="savingNote"
      @cancel="closeChatNoteModal"
      @save="saveChatNote"
    />
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useQuery } from '@tanstack/vue-query';
import { RouterLink, useRoute, type RouteLocationRaw } from 'vue-router';
import { api, isHttpError } from '../api/client';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import BotSelectorModal from '@/components/BotSelectorModal.vue';
import ChatListActionsMenu, { type ChatListActionsAnchor } from '@/components/ChatListActionsMenu.vue';
import ChatListRow, { type ChatListRowActionsRequest } from '@/components/ChatListRow.vue';
import ChatNoteModal from '@/components/chat/ChatNoteModal.vue';
import ChatArchiveAllModal from '@/components/chat/ChatArchiveAllModal.vue';
import ChatSnoozeModal from '@/components/chat/ChatSnoozeModal.vue';
import { chatReadStateInput, updateChatReadState, isChatReadStateConflict, type ChatReadStateAction } from '@/features/chat/chatReadState';
import ChatBotFiltersPanel from '@/components/ChatBotFiltersPanel.vue';
import ChatInboxViewsPanel from '@/components/ChatInboxViewsPanel.vue';
import InitialRoutePlaceholder from '@/components/InitialRoutePlaceholder.vue';
import PullToRefresh from '@/components/PullToRefresh.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { useRecoverableRead } from '@/features/app/useRecoverableRead';
import { sortBotsByPreference, useBotSortPreference } from '@/features/bots/model/useBotSortPreference';
import { createChatRecord, deleteChatRecord, updateChatRecord } from '@/features/chat/chatAshApi';
import { fetchChatSummary } from '@/features/chat/chatSummaries';
import { useChatServerEvents } from '@/features/chat/chatServerEvents';
import { useChatChanges } from '@/features/chat/chatEvents';
import {
  chatListRelationLabelKey,
  chatListRelationMeta,
} from '@/features/chat/model/chatListRelations';
import { parseImageAsset } from '@/features/media/image';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { useStackLayer } from '@/features/stack/useStackLayer';
import { serverStateKeys } from '@/features/serverState/queryClient';
import { translate } from '@/i18n';
import type { Bot, ChatSummary, ImageAsset } from '@/types/api';
import { formatChatBaseTitle } from '@/utils/chatTitle';
import { formatRelativeDateTime } from '@/utils/dates';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import SearchClearButton from '@/components/SearchClearButton.vue';

type ChatSearchHit = {
  message_id: number;
  chat_id: number;
  role: 'user' | 'assistant' | null;
  created_at: string | null;
  active: boolean;
  snippet: string | null;
};

type ChatListEntry = { key: string; chat: ChatSummary; hits: ChatSearchHit[] };

type ChatListSection = {
  key: string;
  label: string;
  entries: ChatListEntry[];
  showHeading: boolean;
  showPagination: boolean;
  sectionKey?: ChatSection;
  page?: number;
  total?: number | null;
  totalPages?: number | null;
  hasNext?: boolean;
  hasPrevious?: boolean;
};

type SnippetPart = { text: string; match: boolean };

type BotFilterOption = {
  id: number | '';
  value: string;
  name: string;
  label: string;
  image: ImageAsset | null;
  count: number;
  sort_activity_at?: string | null;
  updated_at?: string | null;
  created_at?: string | null;
};

type BotSelectorOption = {
  id: number | '';
  name: string;
  image?: ImageAsset | null;
  shared_incoming?: boolean;
  shared_outgoing?: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  sort_activity_at?: string | null;
};

type ChatListBotStat = {
  bot_id: number;
  bot_name: string | null;
  chat_count: number;
};

type ChatListStats = {
  total_chats: number;
  no_bot_chat_count: number;
  no_bot_last_activity_at: string | null;
  bots: ChatListBotStat[];
};

type ChatListIdleStatePayload = {
  next_read_state_expiry?: string | null;
  revision?: string | null;
  active_generation_message_id?: number | null;
};

type ChatListGenerationStatePayload = {
  chat_generations?: Array<{ chat_id?: number; message_id?: number }>;
  active_message_ids?: number[];
};

type ChatListPayload = {
  next_read_state_expiry?: string | null;
  chats: ChatSummary[];
  sections?: Partial<Record<ChatSection, { ids?: number[]; page?: Partial<SectionPage> }>>;
  stats?: ChatListStats;
  idle_revision?: string | null;
};

type ChatSearchPayload = {
  // Unique summaries for note matches and hit chats.
  chats?: ChatSummary[];
  // Chats whose note matched, newest activity first; only on the first page.
  notes?: number[];
  // Message hits, newest first.
  hits?: ChatSearchHit[];
  next_cursor?: string | null;
  next_read_state_expiry?: string | null;
  // False when no term can use the text index and only chat notes were matched.
  text_search?: boolean;
  terms?: string[];
};

type GenerationState = 'generating' | 'reconnecting' | 'error' | 'canceled';
type ChatSection = 'drafts' | 'unread' | 'working' | 'other';
const SECTION_KEYS: ChatSection[] = ['drafts', 'unread', 'working', 'other'];
const SECTION_LABELS = { drafts: 'Drafts', unread: 'Unread', working: 'Working chats', other: 'Other chats' };
type SectionPage = { number: number; per_page: number; total: number; has_next: boolean };
const emptySectionPages = (): Record<ChatSection, SectionPage> => Object.fromEntries(
  SECTION_KEYS.map((key) => [key, { number: 1, per_page: 20, total: 0, has_next: false }])
) as Record<ChatSection, SectionPage>;
function sectionForChat(chat: ChatSummary): ChatSection {
  if (chat.read_state?.is_unread) return 'unread';
  return chat.active_generation_message_id ? 'working' : 'other';
}


type ChatActionsMenuState = {
  chat: ChatSummary;
  anchor: ChatListActionsAnchor;
};

const CHAT_LIST_POLL_SUCCESS_DELAY_MS = 1_500;
const CHAT_LIST_POLL_RETRY_DELAY_MS = 3_000;
const CHAT_LIST_IDLE_POLL_DELAY_MS = 30_000;
const CHAT_LIST_IDLE_POLL_RETRY_DELAY_MS = 30_000;
const CHAT_LIST_IDLE_IMMEDIATE_THROTTLE_MS = 1_500;
const CHAT_SEARCH_DEBOUNCE_MS = 600;
const CHAT_SEARCH_MIN_LENGTH = 3;
const CHAT_SEARCH_PAGE_SIZE = 30;
const CHAT_SEARCH_MAX_LIMIT = 100;

const route = useRoute();
const stackNav = useStackNavigation();
const layer = useStackLayer();

const openBookmarks = () => stackNav.open({ path: '/bookmarks' });

function getQueryString(value: unknown) {
  if (Array.isArray(value)) {
    const firstString = value.find((item) => typeof item === 'string');
    return firstString || '';
  }
  return typeof value === 'string' ? value : '';
}

function readChatListPageQuery(value: unknown) {
  const page = Number(getQueryString(value));
  return Number.isInteger(page) && page > 0 ? page : 1;
}

function readExactQuery(value: unknown) {
  return ['1', 'true'].includes(getQueryString(value).trim().toLowerCase());
}

function readBotFilterQuery(value: unknown) {
  const raw = getQueryString(value).trim();
  if (raw === 'none') return raw;
  const id = Number(raw);
  return Number.isInteger(id) && id > 0 ? String(id) : '';
}

function sameQueryValue(current: unknown, next: string | undefined) {
  return getQueryString(current) === (next ?? '');
}

let unmounted = false;
const loading = ref(true);
const creating = ref(false);
const error = ref<string | null>(null);
const chats = ref<ChatSummary[]>([]);
const sectionPages = ref(emptySectionPages());
const sectionIds = ref<Record<ChatSection, number[]>>({ drafts: [], unread: [], working: [], other: [] });
sectionPages.value.other.number = readChatListPageQuery(route.query.page);
sectionPages.value.unread.number = readChatListPageQuery(route.query.unreadPage);
sectionPages.value.drafts.number = readChatListPageQuery(route.query.draftsPage);
sectionPages.value.working.number = readChatListPageQuery(route.query.workingPage);
const pageNumber = computed({ get: () => sectionPages.value.other.number, set: (value) => { sectionPages.value.other.number = value; } });
const perPage = ref(20);
const totalChats = ref(0);
type ArchiveView = 'inbox' | 'archive';
const archiveView = ref<ArchiveView>(route.query.view === 'archive' ? 'archive' : 'inbox');
const sectionActionsAnchor = ref<ChatListActionsAnchor | null>(null);
const archiveAllTarget = ref<{ bot: string; label: string } | null>(null);
const archiveNotice = ref('');

function openSectionActions(event: MouseEvent) {
  closeChatActions();
  if (sectionActionsAnchor.value) { sectionActionsAnchor.value = null; return; }
  const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
  sectionActionsAnchor.value = { x: rect.right, y: rect.bottom + 4, flipY: rect.top - 4, align: 'end' };
}

function openArchiveAll() {
  sectionActionsAnchor.value = null;
  const bot = String(botFilter.value || '');
  archiveAllTarget.value = { bot, label: botFilterOptions.value.find((option) => option.value === bot)?.label || translate('All bots') };
}

async function finishArchiveAll(count: number) {
  archiveAllTarget.value = null;
  archiveNotice.value = translate('Archived chats: {count}', { count });
  chatListLoadSeq += 1;
  chatSearchSeq += 1;
  await refreshSections();
}

function setArchiveView(view: ArchiveView) {
  if (archiveView.value === view) return;
  archiveView.value = view;
  archiveNotice.value = '';
  sectionActionsAnchor.value = null;
  closeChatActions();
  resetSectionPageNumbers();
  resetChatSearch();
  chats.value = [];
  chatListIdleRevision.value = null;
  void loadChats();
  if (isMobile.value) filterOpen.value = false;
}

const chatSearchTerm = ref(getQueryString(route.query.q));
const chatSearchExact = ref(readExactQuery(route.query.exact));
// Chat summaries referenced by note matches and hits.
const chatSearchResults = ref<ChatSummary[]>([]);
const chatSearchNoteIds = ref<number[]>([]);
const chatSearchHits = ref<ChatSearchHit[]>([]);
const chatSearchNextCursor = ref<string | null>(null);
const chatSearchTerms = ref<string[]>([]);
const chatSearchLoading = ref(false);
const chatSearchLoadingMore = ref(false);
const chatSearchError = ref('');
const chatSearchTextSearch = ref(true);
const chatListIdleRevision = ref<string | null>(null);
const nextReadStateExpiry = ref<string | null>(null);
const chatListGenerationPollReconnecting = ref(false);
const expandedSubchatParentIds = ref(new Set<number>());
const botFilter = ref<string>(readBotFilterQuery(route.query.bot));
const chatListRead = useRecoverableRead<ChatListPayload>({
  key: () => `chats:index:${SECTION_KEYS.map((key) => sectionPages.value[key].number).join(':')}:${botFilter.value || 'all'}`,
});
const botSearchTerm = ref('');
const botsQuery = useQuery<Bot[]>({
  queryKey: serverStateKeys.reference('bots', 'chat-selector'),
  queryFn: async ({ signal }) => {
    const params = new URLSearchParams();
    params.set('sort', 'name');
    params.set('fields[bots]', 'name,sort_activity_at,image');
    const payload = await jsonApiList('/api/ash/bots', params, { signal });
    return (payload.data || []).map(parseBot).filter((bot): bot is Bot => Boolean(bot));
  },
});
const bots = computed(() => botsQuery.data.value ?? []);
const chatListStats = ref<ChatListStats>({
  total_chats: 0,
  no_bot_chat_count: 0,
  no_bot_last_activity_at: null,
  bots: [],
});
const botModalOpen = ref(false);
const botModalValue = ref<number | ''>('');
const chatActionsMenu = ref<ChatActionsMenuState | null>(null);
const noteChat = ref<ChatSummary | null>(null);
const noteModalValue = ref('');
const savingNote = ref(false);
const snoozeChat = ref<ChatSummary | null>(null);
const readStateSaving = ref(false);
const readStateError = ref('');
const deletingChatId = ref<number | null>(null);
const botSortMode = useBotSortPreference();
const botSortModeValue = computed({
  get: () => botSortMode.value,
  set: (value: string) => {
    botSortMode.value = value === 'recent_activity' ? 'recent_activity' : 'name';
  },
});

const isMobile = ref(false);
const isCompact = ref(false);
const filterOpen = ref(false);
const previewLength = computed(() => (isCompact.value ? 100 : 200));

const hasChatSearch = computed(() => chatSearchTerm.value.trim().length >= CHAT_SEARCH_MIN_LENGTH);
const hasActiveBotFilter = computed(() => String(botFilter.value || '').trim().length > 0);

function syncChatListRouteQuery() {
  const q = chatSearchTerm.value.trim();
  const exact = q && chatSearchExact.value ? '1' : undefined;
  const bot = String(botFilter.value || '').trim();
  const page = pageNumber.value > 1 ? String(pageNumber.value) : undefined;
  const next = { ...route.query };
  if (archiveView.value === 'archive') next.view = 'archive';
  else delete next.view;
  for (const key of ['drafts', 'unread', 'working'] as const) {
    const queryKey = `${key}Page`;
    const number = sectionPages.value[key].number;
    if (number > 1) next[queryKey] = String(number);
    else delete next[queryKey];
  }

  if (q) next.q = q;
  else delete (next as Record<string, unknown>).q;

  if (exact) next.exact = exact;
  else delete (next as Record<string, unknown>).exact;

  if (bot) next.bot = bot;
  else delete (next as Record<string, unknown>).bot;

  if (page) next.page = page;
  else delete (next as Record<string, unknown>).page;

  if (
    sameQueryValue(new URLSearchParams(window.location.search).get('view') ?? undefined, next.view as string | undefined) &&
    sameQueryValue(route.query.q, q || undefined) &&
    sameQueryValue(route.query.exact, exact) &&
    sameQueryValue(route.query.bot, bot || undefined) &&
    sameQueryValue(route.query.page, page) &&
    sameQueryValue(route.query.draftsPage, next.draftsPage as string | undefined) &&
    sameQueryValue(route.query.unreadPage, next.unreadPage as string | undefined) &&
    sameQueryValue(route.query.workingPage, next.workingPage as string | undefined)
  ) {
    return;
  }

  const params = new URLSearchParams();
  Object.entries(next).forEach(([key, value]) => {
    if (Array.isArray(value)) {
      value.forEach((item) => {
        if (item != null) params.append(key, String(item));
      });
      return;
    }
    if (value != null) params.set(key, String(value));
  });

  const queryString = params.toString();
  const path = window.location.pathname || route.path || '/';
  window.history.replaceState(
    window.history.state,
    '',
    `${path}${queryString ? `?${queryString}` : ''}${route.hash || ''}`
  );
}

watch(
  () => [route.query.q, route.query.exact, route.query.bot, route.query.page, route.query.unreadPage, route.query.workingPage, route.query.draftsPage, route.query.view],
  ([q, exact, bot, page, unreadPage, workingPage, draftsPage, view]) => {
    const nextView = view === 'archive' ? 'archive' : 'inbox';
    const viewChanged = archiveView.value !== nextView;
    archiveView.value = nextView;
    if (viewChanged) { chats.value = []; resetChatSearch(); }
    const nextQ = getQueryString(q);
    const nextExact = readExactQuery(exact);
    const nextBot = readBotFilterQuery(bot);
    const nextPage = readChatListPageQuery(page);
    const shouldLoadChats = viewChanged || botFilter.value !== nextBot || pageNumber.value !== nextPage ||
      sectionPages.value.drafts.number !== readChatListPageQuery(draftsPage) ||
      sectionPages.value.unread.number !== readChatListPageQuery(unreadPage) ||
      sectionPages.value.working.number !== readChatListPageQuery(workingPage);
    sectionPages.value.drafts.number = readChatListPageQuery(draftsPage);
    sectionPages.value.unread.number = readChatListPageQuery(unreadPage);
    sectionPages.value.working.number = readChatListPageQuery(workingPage);

    if (chatSearchTerm.value !== nextQ) chatSearchTerm.value = nextQ;
    if (chatSearchExact.value !== nextExact) chatSearchExact.value = nextExact;
    if (botFilter.value !== nextBot) botFilter.value = nextBot;
    if (pageNumber.value !== nextPage) pageNumber.value = nextPage;

    if (shouldLoadChats && (viewChanged || !hasChatSearch.value)) {
      void loadChats();
    }
  }
);

watch(
  () => [archiveView.value, chatSearchTerm.value, chatSearchExact.value, botFilter.value, ...SECTION_KEYS.map((key) => sectionPages.value[key].number)],
  () => {
    syncChatListRouteQuery();
  }
);

function toggleChatSearchExact() {
  chatSearchExact.value = !chatSearchExact.value;
}

function openFilter() {
  filterOpen.value = true;
}

function closeFilter() {
  filterOpen.value = false;
}

function toggleBotSortMode() {
  botSortModeValue.value = botSortModeValue.value === 'recent_activity' ? 'name' : 'recent_activity';
}

function setBotFilter(value: string) {
  if (botFilter.value === value) return;
  botFilter.value = value;
  resetSectionPageNumbers();
  if (!hasChatSearch.value) void loadChats();
  if (isMobile.value) filterOpen.value = false;
}

function createChatInitialBotSelection(): number | '' {
  const raw = String(botFilter.value || '').trim();
  if (raw === 'none') return '';

  const botId = Number(raw);
  if (Number.isInteger(botId) && botId > 0) return botId;

  return botSortMode.value === 'recent_activity' ? createChatBotOptions.value[0]?.id ?? '' : '';
}

const noBotChatCount = computed(() => {
  const count = chatListStats.value.no_bot_chat_count;
  return Number.isInteger(count) && count > 0 ? count : 0;
});
const showNoBotOption = computed(() => noBotChatCount.value > 0 || botFilter.value === 'none');
const noBotSortActivityAt = computed(() => chatListStats.value.no_bot_last_activity_at);

const noBotFilterOption = computed<BotFilterOption | null>(() => {
  if (!showNoBotOption.value) return null;

  return {
    id: '',
    value: 'none',
    name: 'No bot',
    label: 'No bot',
    image: null,
    count: noBotChatCount.value,
    sort_activity_at: noBotSortActivityAt.value,
    updated_at: noBotSortActivityAt.value,
    created_at: noBotSortActivityAt.value,
  };
});

const botFilterOptions = computed<BotFilterOption[]>(() => {
  const botMapById = new Map<number, Bot>();

  for (const bot of bots.value) {
    if (!bot || !Number.isInteger(bot.id) || bot.id <= 0) continue;
    botMapById.set(bot.id, bot);
  }

  const options: BotFilterOption[] = (chatListStats.value.bots || [])
    .filter((stat) => Number.isInteger(stat.bot_id) && stat.bot_id > 0 && stat.chat_count > 0)
    .map((stat) => {
      const bot = botMapById.get(stat.bot_id);
      const fallbackName = String(stat.bot_name || '').trim() || `Bot #${stat.bot_id}`;
      const optionName = String(bot?.name || fallbackName).trim() || fallbackName;
      return {
        id: stat.bot_id,
        value: String(stat.bot_id),
        name: optionName,
        label: optionName,
        image: bot?.image ?? null,
        count: stat.chat_count,
        sort_activity_at: bot?.sort_activity_at ?? null,
        updated_at: bot?.updated_at ?? null,
        created_at: bot?.created_at ?? null,
      } satisfies BotFilterOption;
    });

  if (noBotFilterOption.value) options.unshift(noBotFilterOption.value);

  return sortBotsByPreference(options, botSortMode.value);
});

const visibleBotFilterOptions = computed(() => {
  const term = botSearchTerm.value.trim().toLowerCase();
  if (!term) return botFilterOptions.value;
  return botFilterOptions.value.filter((opt) => opt.label.toLowerCase().includes(term));
});

const botFilterEmptyState = computed(() => {
  if (visibleBotFilterOptions.value.length) return '';
  if (botSearchTerm.value.trim()) return 'No matches found.';
  return 'No bots yet.';
});

const createChatBotOptionsBase = computed<BotSelectorOption[]>(() => {
  return [
    {
      id: '',
      name: 'No bot',
      sort_activity_at: noBotSortActivityAt.value,
      updated_at: noBotSortActivityAt.value,
      created_at: noBotSortActivityAt.value,
    },
    ...(bots.value ?? []).map((bot) => ({
      id: bot.id,
      name: bot.name,
      image: bot.image ?? null,
      shared_incoming: bot.shared_incoming,
      shared_outgoing: bot.shared_outgoing,
      created_at: bot.created_at ?? null,
      updated_at: bot.updated_at ?? null,
      sort_activity_at: bot.sort_activity_at ?? null,
    })),
  ];
});

const createChatBotOptions = computed<BotSelectorOption[]>(() => {
  return sortBotsByPreference(createChatBotOptionsBase.value, botSortMode.value);
});

function matchesBotFilter(chat: Pick<ChatSummary, 'bot_id'>) {
  const raw = String(botFilter.value || '').trim();
  if (!raw) return true;
  if (raw === 'none') return chat.bot_id == null;
  const id = Number(raw);
  if (!Number.isInteger(id) || id <= 0) return true;
  return chat.bot_id === id;
}

function chatSortTimestamp(chat: ChatSummary) {
  const value = chat.last_activity_at || chat.created_at || '';
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : 0;
}

function sortChatRows<T extends ChatSummary>(items: T[]): T[] {
  return [...items].sort((left, right) => {
    const activity = chatSortTimestamp(right) - chatSortTimestamp(left);
    return activity || right.id - left.id;
  });
}

function directSubchats(chat: ChatSummary): ChatSummary[] {
  return Array.isArray(chat.subchats) ? chat.subchats : [];
}

function subchatCount(chat: ChatSummary) {
  const count = Number(chat.child_subchat_count || 0);
  if (Number.isInteger(count) && count > 0) return count;
  return directSubchats(chat).length;
}

function flattenChatRows(items: ChatSummary[]): ChatSummary[] {
  return items.flatMap((chat) => [chat, ...directSubchats(chat)]);
}

function subchatsExpanded(chat: ChatSummary) {
  return expandedSubchatParentIds.value.has(chat.id);
}

function toggleSubchats(chatId: number) {
  const next = new Set(expandedSubchatParentIds.value);
  if (next.has(chatId)) next.delete(chatId);
  else next.add(chatId);
  expandedSubchatParentIds.value = next;
}

function mergeChatRows<T extends ChatSummary>(items: T[], summary: ChatSummary): T[] {
  const index = items.findIndex((item) => item.id === summary.id);
  if (index === -1) return sortChatRows([...items, summary as T]);

  const next = [...items];
  next[index] = { ...next[index], ...summary };
  return sortChatRows(next);
}

function sortSubchatRows<T extends ChatSummary>(items: T[]): T[] {
  return [...items].sort((left, right) => {
    const leftTime = Date.parse(left.created_at || '') || 0;
    const rightTime = Date.parse(right.created_at || '') || 0;
    return leftTime - rightTime || left.id - right.id;
  });
}

function upsertSubchatInRows<T extends ChatSummary>(items: T[], summary: ChatSummary): T[] {
  let changed = false;

  const next = items.map((chat) => {
    if (chat.id !== summary.parent_chat_id) return chat;

    changed = true;
    const subchats = directSubchats(chat);
    const index = subchats.findIndex((item) => item.id === summary.id);
    const nextSubchats =
      index === -1
        ? sortSubchatRows([...subchats, summary])
        : sortSubchatRows(subchats.map((item) => (item.id === summary.id ? { ...item, ...summary } : item)));

    return {
      ...chat,
      child_subchat_count: Math.max(Number(chat.child_subchat_count || 0), nextSubchats.length),
      subchats: nextSubchats,
    };
  });

  return changed ? next : items;
}

function removeSubchatFromRows<T extends ChatSummary>(items: T[], chatId: number): { rows: T[]; removed: boolean } {
  let removed = false;

  const rows = items.map((chat) => {
    const subchats = directSubchats(chat);
    if (!subchats.some((item) => item.id === chatId)) return chat;

    removed = true;
    const nextSubchats = subchats.filter((item) => item.id !== chatId);
    return {
      ...chat,
      child_subchat_count: Math.max(0, Number(chat.child_subchat_count || subchats.length) - 1),
      subchats: nextSubchats,
    };
  });

  return { rows, removed };
}

function patchExistingChatRows<T extends ChatSummary>(items: T[], summary: ChatSummary): T[] {
  const index = items.findIndex((item) => item.id === summary.id);
  if (index === -1) return items;

  const next = [...items];
  next[index] = { ...next[index], ...summary };
  return sortChatRows(next);
}

function isNewChatChangeReason(reason: unknown) {
  return ['create', 'copy', 'continue', 'branch-new-chat', 'branch-move-new-chat'].includes(String(reason || ''));
}

function applyChatSummary(summary: ChatSummary, changeReason?: unknown) {
  if (summary.subagent) {
    chats.value = upsertSubchatInRows(chats.value, summary);
    chatSearchResults.value = upsertSubchatInRows(chatSearchResults.value, summary);
    chatListIdleRevision.value = null;
    return;
  }

  const existedInPage = chats.value.some((chat) => chat.id === summary.id);

  if (matchesBotFilter(summary) && matchesArchiveView(summary)) {
    chats.value = mergeChatRows(chats.value, summary);
    if (!existedInPage && isNewChatChangeReason(changeReason)) {
      totalChats.value += 1;
    }
  } else if (existedInPage) {
    chats.value = chats.value.filter((chat) => chat.id !== summary.id);
    totalChats.value = Math.max(0, totalChats.value - 1);
  }

  chatSearchResults.value = patchExistingChatRows(chatSearchResults.value, summary);
  chatListIdleRevision.value = null;
}

function removeChatFromLists(chatId: number) {
  const existedInPage = chats.value.some((chat) => chat.id === chatId);
  const chatRows = removeSubchatFromRows(chats.value, chatId);
  const searchRows = removeSubchatFromRows(chatSearchResults.value, chatId);

  chats.value = chatRows.rows.filter((chat) => chat.id !== chatId);
  chatSearchResults.value = searchRows.rows.filter((chat) => chat.id !== chatId);
  if (existedInPage) totalChats.value = Math.max(0, totalChats.value - 1);

  chatListIdleRevision.value = null;
}

const chatSummaryRefreshTimers = new Map<number, number>();

function clearChatSummaryRefresh(chatId: number) {
  const timer = chatSummaryRefreshTimers.get(chatId);
  if (timer == null) return;
  window.clearTimeout(timer);
  chatSummaryRefreshTimers.delete(chatId);
}

function refreshChatSummary(chatId: number, changeReason?: unknown) {
  clearChatSummaryRefresh(chatId);

  const timer = window.setTimeout(async () => {
    chatSummaryRefreshTimers.delete(chatId);

    try {
      const summary = await fetchChatSummary(chatId, previewLength.value);
      if (unmounted) return;
      applyChatSummary(summary, changeReason);
      await refreshSections();
    } catch (error) {
      console.warn('Failed to refresh chat summary.', error);
    }
  }, 150);

  chatSummaryRefreshTimers.set(chatId, timer);
}

let serverRefreshTimer: number | null = null;
function queueServerRefresh() {
  if (serverRefreshTimer !== null) window.clearTimeout(serverRefreshTimer);
  serverRefreshTimer = window.setTimeout(() => {
    serverRefreshTimer = null;
    if (unmounted || !layer.active.value || document.visibilityState !== 'visible') return;
    if (loading.value || chatSearchLoading.value || chatSearchLoadingMore.value) { queueServerRefresh(); return; }
    void refreshSections();
  }, 150);
}
useChatServerEvents(queueServerRefresh);

useChatChanges((change) => {
  if (change.meta?.reason === 'draft-changed') {
    queueServerRefresh();
    return;
  }
  if (change.operation === 'delete') {
    clearChatSummaryRefresh(change.id);
    removeChatFromLists(change.id);
    void refreshSections();
    return;
  }

  refreshChatSummary(change.id, change.meta?.reason);
});

function matchesArchiveView(chat: ChatSummary) {
  // Draft subchats inherit their parent view through server-side membership.
  return chat.subagent || Boolean(chat.read_state?.is_archived) === (archiveView.value === 'archive');
}
const filteredChats = computed(() => chats.value.filter((chat) => matchesBotFilter(chat) && matchesArchiveView(chat)));
const filteredChatSearchResults = computed(() => chatSearchResults.value.filter((chat) => matchesBotFilter(chat) && matchesArchiveView(chat)));
const visibleChats = computed(() => (hasChatSearch.value ? filteredChatSearchResults.value : filteredChats.value));
const visibleGenerationChats = computed(() => flattenChatRows(visibleChats.value));
const hasVisibleGeneratingChat = computed(() =>
  visibleGenerationChats.value.some((chat) => Boolean(chat.active_generation_message_id))
);
const allBotsCount = computed(() => {
  if (chatListStats.value.total_chats > 0) return chatListStats.value.total_chats;
  return totalChats.value;
});
function sectionChats(key: ChatSection) {
  const ids = sectionIds.value;
  const byId = new Map(filteredChats.value.map((chat) => [chat.id, chat]));
  if (key === 'drafts') {
    return ids.drafts.flatMap((id) => {
      const chat = byId.get(id);
      return chat?.has_draft ? [chat] : [];
    });
  }
  // Drafts overlap the inbox, but must not pull rows from another inbox page.
  const inboxIds = new Set([...ids.unread, ...ids.working, ...ids.other]);
  // Preserve each section's order, then append rows regrouped by their newest state.
  const rows = [...new Set([...ids[key], ...inboxIds])].flatMap((id) => {
    const chat = byId.get(id);
    return chat ? [chat] : [];
  });
  return rows.filter((chat) => inboxIds.has(chat.id) && sectionForChat(chat) === key);
}

const visibleSections = computed<ChatListSection[]>(() => {
  const sections = SECTION_KEYS.map((key): ChatListSection => {
    const page = sectionPages.value[key];
    const totalPages = Math.max(1, Math.ceil(page.total / Math.max(1, page.per_page)));
    return {
      key, sectionKey: key, label: translate(SECTION_LABELS[key]),
      entries: sectionChats(key).map((chat) => ({ key: String(chat.id), chat, hits: [] })),
      page: page.number, total: page.total, hasNext: page.has_next, hasPrevious: page.number > 1,
      totalPages, showPagination: totalPages > 1, showHeading: true,
    };
  }).filter((section) => section.entries.length > 0);
  return sections;
});

// Note matches come first; adjacent hits of one chat share a header, a chat
// that reappears later gets a new one.
const searchSections = computed<ChatListSection[]>(() => {
  const byId = new Map(filteredChatSearchResults.value.map((chat) => [chat.id, chat]));
  const sections: ChatListSection[] = [];
  const noteEntries = chatSearchNoteIds.value.flatMap((id): ChatListEntry[] => {
    const chat = byId.get(id);
    return chat ? [{ key: `note-${id}`, chat, hits: [] }] : [];
  });
  if (noteEntries.length) {
    sections.push({ key: 'notes', label: translate('Chats'), entries: noteEntries, showHeading: true, showPagination: false });
  }
  const groups: ChatListEntry[] = [];
  for (const hit of chatSearchHits.value) {
    const chat = byId.get(hit.chat_id);
    if (!chat) continue;
    const last = groups[groups.length - 1];
    if (last && last.chat.id === chat.id) last.hits.push(hit);
    else groups.push({ key: `hits-${chat.id}-${hit.message_id}`, chat, hits: [hit] });
  }
  if (groups.length) {
    sections.push({ key: 'messages', label: translate('Messages'), entries: groups, showHeading: true, showPagination: false });
  }
  return sections;
});

const renderedSections = computed(() => (hasChatSearch.value ? searchSections.value : visibleSections.value));

function resetSectionPageNumbers() {
  for (const key of SECTION_KEYS) {
    sectionPages.value[key].number = 1;
  }
}

async function changeSectionPage(key: ChatSection, delta: number) {
  if (hasChatSearch.value) return;
  sectionPages.value[key].number = Math.max(1, sectionPages.value[key].number + delta);
  await loadChats({ scrollToTop: delta > 0 });
}

async function loadMoreChatSearch() {
  if (!hasChatSearch.value || chatSearchLoading.value || chatSearchLoadingMore.value || !chatSearchNextCursor.value) return;
  await runChatSearch(chatSearchTerm.value.trim(), { append: true });
}

// A batch can span a concurrent server mutation. Prefer the newest state and render each ID once.
function uniqueChatRows<T extends ChatSummary>(items: T[]): T[] {
  const byId = new Map<number, T>();
  for (const chat of items) {
    const previous = byId.get(chat.id);
    const stateVersion = chat.read_state?.state_version ?? 0;
    const previousVersion = previous?.read_state?.state_version ?? 0;
    if (!previous || stateVersion > previousVersion || (stateVersion === previousVersion &&
      (chat.read_state?.activity_revision ?? 0) >= (previous.read_state?.activity_revision ?? 0))) byId.set(chat.id, chat);
  }
  return [...byId.values()];
}

type SectionPagePayload = { page?: Partial<SectionPage>; count: number };

// `payloads` is indexed like SECTION_KEYS; `count` is the number of rows the section returned.
function applySectionPages(payloads: SectionPagePayload[], pages: Record<ChatSection, SectionPage>) {
  let clamped = false;
  payloads.forEach((payload, index) => {
    const key = SECTION_KEYS[index];
    const previous = pages[key];
    pages[key] = {
      number: payload.page?.number ?? previous.number,
      per_page: payload.page?.per_page ?? previous.per_page,
      total: payload.page?.total ?? payload.count,
      has_next: Boolean(payload.page?.has_next),
    };
    const lastPage = Math.max(1, Math.ceil(pages[key].total / Math.max(1, pages[key].per_page)));
    if (pages[key].number > lastPage) {
      pages[key].number = lastPage;
      clamped = true;
    }
  });
  return clamped;
}

const chatSearchMetaOnlyHint = computed(() =>
  hasChatSearch.value && !chatSearchError.value && !chatSearchTextSearch.value
);

const chatSearchEmptyState = computed(() => {
  if (!hasChatSearch.value) return '';
  if (chatSearchLoading.value) return '';
  if (chatSearchError.value) return '';
  return searchSections.value.length ? '' : 'No matches found.';
});

const chatListEmptyState = computed(() => {
  if (hasChatSearch.value) return '';
  if (loading.value || error.value) return '';
  if (chats.value.length === 0) return 'No chats yet.';
  return filteredChats.value.length ? '' : 'No chats match the current filters.';
});

function updateIsMobile() {
  isCompact.value = window.matchMedia('(max-width: 720px)').matches;
  const mobile = window.matchMedia('(max-width: 860px)').matches;
  isMobile.value = mobile;
  if (!mobile) filterOpen.value = false;
}

function niceDate(iso: string | null) {
  return formatRelativeDateTime(iso);
}

function chatLabel(chat: ChatSummary) {
  return formatChatBaseTitle({ botName: chat.bot_name, note: chat.note });
}

function generationStateForChat(chat: ChatSummary): GenerationState | null {
  if (chat.active_generation_message_id) {
    return chatListGenerationPollReconnecting.value ? 'reconnecting' : 'generating';
  }
  if (chat.last_message_status === 'error') return 'error';
  if (chat.last_message_status === 'canceled') return 'canceled';
  return null;
}

function countLabel(count: unknown, singular: string, plural: string) {
  const value = typeof count === 'number' && Number.isInteger(count) && count > 0 ? count : 0;
  if (value <= 0) return null;
  return `${value} ${value === 1 ? singular : plural}`;
}

function chatResourceMeta(chat: ChatSummary) {
  return [
    countLabel(chat.blocks_count, 'block', 'blocks'),
    countLabel(chat.tools_count, 'tool', 'tools'),
  ].filter((value): value is string => Boolean(value));
}

function chatMetaText(chat: ChatSummary) {
  return [
    `${niceDate(chat.last_activity_at || chat.created_at)} · ${chat.message_count ?? 0} msgs`,
    ...chatResourceMeta(chat),
  ].join(' · ');
}

function subchatCountLabel(count: number) {
  return count === 1 ? translate('1 subchat') : translate('{count} subchats', { count });
}

function relationMeta(chat: ChatSummary) {
  return chatListRelationMeta(chat, translate);
}

function relationBadgeLabel(chat: ChatSummary) {
  const labelKey = chatListRelationLabelKey(chat);
  return labelKey ? translate(labelKey) : null;
}

function chatLink(chat: ChatSummary): RouteLocationRaw {
  return { path: `/chats/${chat.id}`, query: {} };
}

function hitLink(hit: ChatSearchHit): RouteLocationRaw {
  const query: Record<string, string> = { focusMessage: String(hit.message_id) };
  if (!hit.active) query.focusInactive = '1';
  return { path: `/chats/${hit.chat_id}`, query };
}

function handleHitClick(event: MouseEvent, to: RouteLocationRaw) {
  // Modified clicks keep the native link behavior (new tab, etc.).
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.altKey || event.ctrlKey || event.shiftKey) return;
  event.preventDefault();
  openChat(to);
}

function hitRoleLabel(hit: ChatSearchHit) {
  if (hit.role === 'user') return translate('You');
  if (hit.role === 'assistant') return translate('Assistant');
  return '';
}

function hitToneClass(hit: ChatSearchHit) {
  return {
    'chat-search-hit--user': hit.role === 'user',
    'chat-search-hit--assistant': hit.role === 'assistant',
    'chat-search-hit--inactive': !hit.active,
  };
}

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

// Splits a snippet into plain and matched parts so terms can be marked without raw HTML.
function highlightSnippet(snippet: string | null): SnippetPart[] {
  const text = String(snippet || '');
  if (!text) return [];
  const terms = [...new Set(chatSearchTerms.value.map((term) => term.trim()).filter(Boolean))]
    .sort((left, right) => right.length - left.length);
  if (!terms.length) return [{ text, match: false }];
  const pattern = new RegExp(terms.map(escapeRegExp).join('|'), 'giu');
  const parts: SnippetPart[] = [];
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index == null || !match[0]) continue;
    if (match.index > last) parts.push({ text: text.slice(last, match.index), match: false });
    parts.push({ text: match[0], match: true });
    last = match.index + match[0].length;
  }
  if (last < text.length) parts.push({ text: text.slice(last), match: false });
  return parts;
}

function openChat(to: RouteLocationRaw) {
  stackNav.open(to);
}

function canEditChat(chat: ChatSummary) {
  return chat.can_edit === true;
}

function openChatActions(chat: ChatSummary, request: ChatListRowActionsRequest) {
  if (request.source === 'button' && chatActionsMenu.value?.chat.id === chat.id) {
    closeChatActions();
    return;
  }
  chatActionsMenu.value = { chat, anchor: request.anchor };
}

function closeChatActions() {
  chatActionsMenu.value = null;
}

function patchChatRowsById<T extends ChatSummary>(items: T[], chatId: number, patch: Partial<ChatSummary>): T[] {
  let changed = false;

  const next = items.map((chat) => {
    const subchats = directSubchats(chat);
    const ownsSubchat = subchats.some((item) => item.id === chatId);
    if (chat.id !== chatId && !ownsSubchat) return chat;

    changed = true;
    return {
      ...chat,
      ...(chat.id === chatId ? patch : {}),
      ...(ownsSubchat
        ? { subchats: subchats.map((item) => (item.id === chatId ? { ...item, ...patch } : item)) }
        : {}),
    };
  });

  return changed ? next : items;
}

function openSnoozeModal() {
  const chat = chatActionsMenu.value?.chat;
  closeChatActions();
  if (!chat || readStateSaving.value) return;
  readStateError.value = '';
  snoozeChat.value = chat;
}

async function refreshSections() {
  if (unmounted) return;
  if (hasChatSearch.value) await runChatSearch(chatSearchTerm.value.trim(), { silent: true });
  else await loadChats({ silent: true });
}

async function changeReadStateFromMenu(action: ChatReadStateAction) {
  const chat = chatActionsMenu.value?.chat;
  closeChatActions();
  if (chat) await mutateReadState(chat, action);
}

async function confirmSnooze(iso: string) {
  if (snoozeChat.value) await mutateReadState(snoozeChat.value, 'snooze', iso);
}

async function mutateReadState(chat: ChatSummary, action: ChatReadStateAction, snoozedUntil?: string) {
  if (readStateSaving.value) return;
  readStateSaving.value = true;
  readStateError.value = '';
  // Invalidate pending reads so a pre-mutation response cannot undo the result.
  chatListLoadSeq += 1;
  chatSearchSeq += 1;
  abortActiveChatSearch();
  chatSearchLoading.value = false;
  chatSearchLoadingMore.value = false;
  try {
    const state = chat.read_state ?? (await fetchChatSummary(chat.id)).read_state;
    if (!state) throw new Error('Missing chat read state');
    const read_state = await updateChatReadState(chat.id, chatReadStateInput(state, action,
      snoozedUntil ? { snoozed_until: snoozedUntil } : {}));
    chats.value = patchChatRowsById(chats.value, chat.id, { read_state });
    chatSearchResults.value = patchChatRowsById(chatSearchResults.value, chat.id, { read_state });
    snoozeChat.value = null;
    await refreshSections();
  } catch (error) {
    readStateError.value = translate(isChatReadStateConflict(error)
      ? 'Chat state changed. Please try again.' : 'Failed to update chat state.');
    if (isChatReadStateConflict(error)) {
      await refreshSections();
      if (snoozeChat.value) {
        const fresh = flattenChatRows([...chats.value, ...chatSearchResults.value]).find((row) => row.id === chat.id);
        // An explicit next confirmation must use fresh state, including off-page rows.
        try {
          snoozeChat.value = fresh ?? await fetchChatSummary(chat.id);
        } catch {
          // Fetch again only on the next explicit confirmation, never retry the rejected mutation.
          snoozeChat.value = { ...chat, read_state: undefined };
        }
      }
    }
  } finally {
    readStateSaving.value = false;
  }
}

function openChatNoteModal() {
  const chat = chatActionsMenu.value?.chat;
  closeChatActions();
  if (!chat || !canEditChat(chat)) return;
  noteModalValue.value = chat.note || '';
  noteChat.value = chat;
}

function closeChatNoteModal() {
  if (savingNote.value) return;
  noteChat.value = null;
}

async function saveChatNote() {
  const chat = noteChat.value;
  if (!chat || savingNote.value) return;
  savingNote.value = true;
  try {
    const note = noteModalValue.value.trim();
    await updateChatRecord(chat.id, { note });
    chats.value = patchChatRowsById(chats.value, chat.id, { note });
    chatSearchResults.value = patchChatRowsById(chatSearchResults.value, chat.id, { note });
    noteChat.value = null;
  } catch (e) {
    // Write failures are already surfaced by the API error banner; keep the modal open for a retry.
    console.error(e);
  } finally {
    savingNote.value = false;
  }
}

async function deleteChatFromMenu() {
  const chat = chatActionsMenu.value?.chat;
  if (!chat || !canEditChat(chat) || deletingChatId.value === chat.id) return;
  closeChatActions();
  if (!window.confirm(translate('Delete this chat? All messages will be removed.'))) return;

  deletingChatId.value = chat.id;
  try {
    // The published delete change removes the row through useChatChanges.
    await deleteChatRecord(chat.id);
  } catch (e) {
    console.error(e);
  } finally {
    if (deletingChatId.value === chat.id) deletingChatId.value = null;
  }
}

function formatPreview(text: string) {
  const limit = previewLength.value;
  if (text.length <= limit) return text;
  const normalized = text.endsWith('...') ? text.slice(0, -3) : text;
  return `${normalized.slice(0, limit)}...`;
}

function parseBot(resource: JsonApiResource): Bot | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const name = String(attrs.name || '').trim();
  if (!name) return null;
  return {
    id,
    name,
    image: parseImageAsset(attrs.image),
    shared_incoming: typeof attrs.shared_incoming === 'boolean' ? attrs.shared_incoming : undefined,
    shared_outgoing: typeof attrs.shared_outgoing === 'boolean' ? attrs.shared_outgoing : undefined,
    created_at: typeof attrs.created_at === 'string' ? attrs.created_at : null,
    updated_at: typeof attrs.updated_at === 'string' ? attrs.updated_at : null,
    sort_activity_at: typeof attrs.sort_activity_at === 'string' ? attrs.sort_activity_at : null,
  };
}

function normalizeChatListStats(value: unknown): ChatListStats {
  const raw = value && typeof value === 'object' ? (value as Record<string, unknown>) : {};
  const rawBots = Array.isArray(raw.bots) ? raw.bots : [];

  return {
    total_chats:
      typeof raw.total_chats === 'number' && Number.isInteger(raw.total_chats) && raw.total_chats >= 0
        ? raw.total_chats
        : 0,
    no_bot_chat_count:
      typeof raw.no_bot_chat_count === 'number' &&
      Number.isInteger(raw.no_bot_chat_count) &&
      raw.no_bot_chat_count >= 0
        ? raw.no_bot_chat_count
        : 0,
    no_bot_last_activity_at:
      typeof raw.no_bot_last_activity_at === 'string' ? raw.no_bot_last_activity_at : null,
    bots: rawBots
      .map((entry) => {
        const item = entry && typeof entry === 'object' ? (entry as Record<string, unknown>) : {};
        const botId = typeof item.bot_id === 'number' ? item.bot_id : Number(item.bot_id);
        const chatCount =
          typeof item.chat_count === 'number' ? item.chat_count : Number(item.chat_count);

        if (!Number.isInteger(botId) || botId <= 0) return null;
        if (!Number.isInteger(chatCount) || chatCount <= 0) return null;

        return {
          bot_id: botId,
          bot_name: typeof item.bot_name === 'string' ? item.bot_name : null,
          chat_count: chatCount,
        } satisfies ChatListBotStat;
      })
      .filter((entry): entry is ChatListBotStat => Boolean(entry)),
  };
}

let chatListLoadSeq = 0;
let chatListVisibleLoadSeq = 0;
async function loadChats(
  opts: { silent?: boolean; showErrorBanner?: boolean; signal?: AbortSignal; rethrowSilent?: boolean; scrollToTop?: boolean } = {}
) {
  const silent = Boolean(opts.silent);
  const seq = ++chatListLoadSeq;
  const visibleSeq = silent ? chatListVisibleLoadSeq : ++chatListVisibleLoadSeq;
  if (!silent) {
    loading.value = true;
    error.value = null;
  }

  try {
    const params = chatListSectionParams();
    params.set('preview_len', String(Math.min(previewLength.value, 500)));
    const path = `/api/bff/chat-list?${params.toString()}`;
    const request = (signal?: AbortSignal) => api.get<ChatListPayload>(path, {
      retry: false, showErrorBanner: opts.showErrorBanner ?? false, signal,
    });
    const payload = silent ? await request(opts.signal)
      : await chatListRead.run(({ signal }) => request(signal), { restart: true });
    if (seq !== chatListLoadSeq || unmounted || opts.signal?.aborted) return;

    const pagePayloads = SECTION_KEYS.map((key) => ({
      page: payload.sections?.[key]?.page,
      count: payload.sections?.[key]?.ids?.length ?? 0,
    }));
    if (applySectionPages(pagePayloads, sectionPages.value)) {
      await loadChats(opts);
      return;
    }
    sectionIds.value = Object.fromEntries(SECTION_KEYS.map((key) => [key, payload.sections?.[key]?.ids ?? []])) as Record<ChatSection, number[]>;
    chats.value = uniqueChatRows(payload.chats || []);
    nextReadStateExpiry.value = payload.next_read_state_expiry ?? null;
    totalChats.value = SECTION_KEYS.filter((key) => key !== 'drafts').reduce((total, key) => total + sectionPages.value[key].total, 0);
    chatListStats.value = normalizeChatListStats(payload.stats);
    chatListIdleRevision.value = payload.idle_revision ?? null;
    startChatListIdlePolling();

    if (opts.scrollToTop) {
      await nextTick();
      if (seq === chatListLoadSeq && layer.active.value && layer.presented.value) {
        window.scrollTo({ top: 0, behavior: 'instant' });
      }
    }
  } catch (e) {
    if (isAbortError(e)) return;
    if (seq !== chatListLoadSeq || unmounted) return;
    if (!silent) {
      error.value = e instanceof Error ? e.message : 'Failed to load chats.';
      return;
    }
    if (opts.rethrowSilent) throw e;
    console.warn('Failed to refresh chats list while polling generation state.', e);
  } finally {
    if (!silent && visibleSeq === chatListVisibleLoadSeq) {
      loading.value = false;
    }
  }
}

let chatSearchTimer: number | null = null;
let chatSearchSeq = 0;
let chatSearchAbortController: AbortController | null = null;

function abortActiveChatSearch() {
  if (!chatSearchAbortController) return;
  chatSearchAbortController.abort();
  chatSearchAbortController = null;
}

function isAbortError(error: unknown) {
  return (
    error != null &&
    typeof error === 'object' &&
    'name' in error &&
    (error as { name?: unknown }).name === 'AbortError'
  );
}

function resetChatSearch() {
  chatSearchSeq += 1;
  abortActiveChatSearch();
  chatSearchResults.value = [];
  chatSearchNoteIds.value = [];
  chatSearchHits.value = [];
  chatSearchNextCursor.value = null;
  chatSearchTerms.value = [];
  chatSearchLoading.value = false;
  chatSearchLoadingMore.value = false;
  chatSearchError.value = '';
  chatSearchTextSearch.value = true;
}

function isChatSearchTimeout(error: unknown) {
  return isHttpError(error) &&
    (error.bodyJson as { code?: unknown } | null)?.code === 'search_timeout';
}

function isInvalidSearchCursor(error: unknown) {
  return isHttpError(error) &&
    (error.bodyJson as { code?: unknown } | null)?.code === 'invalid_cursor';
}

async function runChatSearch(
  term: string,
  opts: { silent?: boolean; showErrorBanner?: boolean; signal?: AbortSignal; rethrowSilent?: boolean; cursorRetried?: boolean; append?: boolean } = {}
) {
  const seq = ++chatSearchSeq;
  abortActiveChatSearch();
  // "Show more" continues from the last page; everything else restarts from the newest hits.
  const append = Boolean(opts.append) && chatSearchNextCursor.value != null;
  const cursor = append ? chatSearchNextCursor.value : null;
  const loadedHits = chatSearchHits.value.length;

  const controller = new AbortController();
  chatSearchAbortController = controller;
  const externalSignal = opts.signal;
  let abortFromExternalSignal: (() => void) | null = null;

  if (externalSignal?.aborted) {
    controller.abort();
  } else if (externalSignal) {
    abortFromExternalSignal = () => controller.abort();
    externalSignal.addEventListener('abort', abortFromExternalSignal, { once: true });
  }

  const silent = Boolean(opts.silent);
  if (append) {
    chatSearchLoadingMore.value = true;
    chatSearchError.value = '';
  } else if (!silent) {
    chatSearchLoading.value = true;
    chatSearchError.value = '';
  }

  try {
    const params = new URLSearchParams();
    params.set('q', term);
    params.set('view', archiveView.value);
    if (chatSearchExact.value) params.set('exact', '1');
    // A silent refresh re-reads every hit already shown in one request.
    const limit = append || !silent
      ? CHAT_SEARCH_PAGE_SIZE
      : Math.min(CHAT_SEARCH_MAX_LIMIT, Math.max(CHAT_SEARCH_PAGE_SIZE, loadedHits));
    params.set('limit', String(limit));
    if (cursor) params.set('after', cursor);
    if (botFilter.value) params.set('bot', botFilter.value);
    const errorBanner = opts.showErrorBanner ?? true;
    const payload = await api.get<ChatSearchPayload | undefined>(`/api/bff/chat-list/search?${params.toString()}`, {
      // A search timeout is shown inline next to the results instead of the global banner.
      showErrorBanner: errorBanner ? (error) => !isChatSearchTimeout(error) && !isInvalidSearchCursor(error) : false,
      signal: controller.signal,
    });
    if (controller.signal.aborted || seq !== chatSearchSeq || unmounted) return;
    const chats = uniqueChatRows(payload?.chats || []);
    const hits = payload?.hits || [];
    if (append) {
      chatSearchResults.value = uniqueChatRows([...chatSearchResults.value, ...chats]);
      chatSearchHits.value = [...chatSearchHits.value, ...hits];
    } else {
      chatSearchResults.value = chats;
      chatSearchNoteIds.value = payload?.notes || [];
      chatSearchHits.value = hits;
      chatSearchTerms.value = payload?.terms || [];
      chatSearchTextSearch.value = payload?.text_search !== false;
    }
    chatSearchNextCursor.value = payload?.next_cursor ?? null;
    chatSearchError.value = '';
    if (payload && 'next_read_state_expiry' in payload) nextReadStateExpiry.value = payload.next_read_state_expiry ?? null;
  } catch (e) {
    if (controller.signal.aborted || isAbortError(e)) return;
    if (seq !== chatSearchSeq || unmounted) return;
    if (isInvalidSearchCursor(e) && !opts.cursorRetried) {
      // An expired cursor restarts from the newest hits.
      resetChatSearch();
      await runChatSearch(term, { ...opts, append: false, cursorRetried: true });
      return;
    }
    if (!silent || append) {
      if (isChatSearchTimeout(e)) {
        chatSearchError.value = 'Search took too long. Try a more specific query.';
      } else {
        console.error(e);
        chatSearchError.value = 'Failed to search chats.';
      }
      return;
    }
    if (opts.rethrowSilent) throw e;
    console.warn('Failed to refresh chat search results while polling generation state.', e);
  } finally {
    if (abortFromExternalSignal && externalSignal) {
      externalSignal.removeEventListener('abort', abortFromExternalSignal);
    }
    if (chatSearchAbortController === controller) {
      chatSearchAbortController = null;
    }
    if (seq === chatSearchSeq) {
      chatSearchLoading.value = false;
      chatSearchLoadingMore.value = false;
    }
  }
}

async function refreshChatIndex() {
  stopChatListIdlePolling();
  if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
  chatSearchTimer = null;

  // Reference data can keep retrying after wake without blocking the list gesture.
  void refreshBots({ showError: true });

  try {
    if (hasChatSearch.value) {
      await runChatSearch(chatSearchTerm.value.trim());
    } else {
      await loadChats();
    }
  } finally {
    startChatListIdlePolling();
  }
}

let chatListPollTimer: number | null = null;
let chatListPollAbortController: AbortController | null = null;
let chatListPollToken = 0;
let chatListPollingActive = false;
let chatListIdlePollTimer: number | null = null;
let chatListIdlePollAbortController: AbortController | null = null;
let chatListIdlePollToken = 0;
let chatListIdlePollingActive = false;
let chatListIdleLastImmediateAt = 0;

function stopChatListPolling() {
  chatListPollingActive = false;
  chatListGenerationPollReconnecting.value = false;
  chatListPollToken += 1;

  if (chatListPollTimer != null) {
    window.clearTimeout(chatListPollTimer);
    chatListPollTimer = null;
  }

  if (chatListPollAbortController) {
    chatListPollAbortController.abort();
    chatListPollAbortController = null;
  }
}

function stopChatListIdlePolling() {
  chatListIdlePollingActive = false;
  chatListIdlePollToken += 1;

  if (chatListIdlePollTimer != null) {
    window.clearTimeout(chatListIdlePollTimer);
    chatListIdlePollTimer = null;
  }

  if (chatListIdlePollAbortController) {
    chatListIdlePollAbortController.abort();
    chatListIdlePollAbortController = null;
  }
}

function nextActiveGenerationMessageId(
  chat: ChatSummary,
  activeByChatId: Map<number, number>,
  activeMessageIds: Set<number>
) {
  const directMessageId = activeByChatId.get(chat.id);
  if (directMessageId) return directMessageId;

  const currentMessageId = Number(chat.active_generation_message_id);
  if (Number.isInteger(currentMessageId) && activeMessageIds.has(currentMessageId)) {
    return currentMessageId;
  }

  return null;
}

function applyGenerationStatesToRows<T extends ChatSummary>(
  items: T[],
  activeByChatId: Map<number, number>,
  activeMessageIds: Set<number>
): T[] {
  let changed = false;

  const next = items.map((chat) => {
    const subchats = directSubchats(chat);
    const nextSubchats = subchats.map((subchat) => {
      const activeGenerationMessageId = nextActiveGenerationMessageId(
        subchat,
        activeByChatId,
        activeMessageIds
      );

      if ((subchat.active_generation_message_id || null) === activeGenerationMessageId) {
        return subchat;
      }

      changed = true;
      return { ...subchat, active_generation_message_id: activeGenerationMessageId };
    });

    const activeGenerationMessageId = nextActiveGenerationMessageId(
      chat,
      activeByChatId,
      activeMessageIds
    );
    const subchatsChanged = nextSubchats.some((subchat, index) => subchat !== subchats[index]);
    const chatChanged = (chat.active_generation_message_id || null) !== activeGenerationMessageId;

    if (!subchatsChanged && !chatChanged) return chat;

    changed = true;
    return {
      ...chat,
      active_generation_message_id: activeGenerationMessageId,
      subchats: nextSubchats,
    };
  });

  return changed ? (next as T[]) : items;
}

async function refreshVisibleChatGenerationStates(signal: AbortSignal) {
  const visibleChats = visibleGenerationChats.value;
  if (!visibleChats.length) return;

  const chatIds = Array.from(new Set(visibleChats.map((chat) => chat.id)));
  const messageIds = Array.from(
    new Set(
      visibleChats
        .map((chat) => Number(chat.active_generation_message_id))
        .filter((id) => Number.isInteger(id) && id > 0)
    )
  );
  const params = new URLSearchParams();
  params.set('chat_ids', chatIds.join(','));
  if (messageIds.length) params.set('message_ids', messageIds.join(','));

  const payload = await api.get<ChatListGenerationStatePayload>(
    `/api/bff/chat-list/generation-state?${params.toString()}`,
    { signal, showErrorBanner: false }
  );
  const activeByChatId = new Map<number, number>();

  for (const entry of payload.chat_generations || []) {
    const chatId = Number(entry.chat_id);
    const messageId = Number(entry.message_id);
    if (Number.isInteger(chatId) && chatId > 0 && Number.isInteger(messageId) && messageId > 0) {
      activeByChatId.set(chatId, messageId);
    }
  }

  const activeMessageIds = new Set(
    (payload.active_message_ids || [])
      .map(Number)
      .filter((id) => Number.isInteger(id) && id > 0)
  );

  const nextChats = applyGenerationStatesToRows(chats.value, activeByChatId, activeMessageIds);
  const nextSearch = applyGenerationStatesToRows(chatSearchResults.value, activeByChatId, activeMessageIds);
  if (nextChats !== chats.value || nextSearch !== chatSearchResults.value) {
    await refreshSections();
  }

}

function chatListSectionParams() {
  const params = new URLSearchParams();
  params.set('sections', SECTION_KEYS.join(','));
  params.set('view', archiveView.value);
  for (const section of SECTION_KEYS) {
    params.set(`page_${section}`, String(Math.max(1, sectionPages.value[section].number)));
  }
  params.set('per_page', String(perPage.value));
  const bot = String(botFilter.value || '').trim();
  if (bot) params.set('bot', bot);
  return params;
}

function chatListIdleProbeParams() {
  const params = chatListSectionParams();
  if (chatListIdleRevision.value) params.set('revision', chatListIdleRevision.value);
  return params;
}

function canRunChatListIdleProbe() {
  return (
    layer.active.value &&
    document.visibilityState === 'visible' &&
    !loading.value &&
    !chatSearchLoading.value &&
    !chatSearchLoadingMore.value
  );
}

async function runChatListIdleProbe(signal: AbortSignal, forceRefresh = false) {
  if (!forceRefresh && !canRunChatListIdleProbe()) return;
  if (forceRefresh && (!layer.active.value || document.visibilityState !== 'visible' || loading.value || chatSearchLoading.value || chatSearchLoadingMore.value)) return;

  const seq = chatListLoadSeq;
  const payload = await api.get<ChatListIdleStatePayload | undefined>(
    `/api/bff/chat-list/idle-state?${chatListIdleProbeParams().toString()}`,
    { signal, showErrorBanner: false }
  );
  if (signal.aborted || unmounted || seq !== chatListLoadSeq) return;
  if (!payload && !forceRefresh) return;
  if (payload && 'next_read_state_expiry' in payload) nextReadStateExpiry.value = payload.next_read_state_expiry ?? null;
  // Only an applied list response acknowledges its revision, so failed loads retry.

  if (hasChatSearch.value) {
    const term = chatSearchTerm.value.trim();
    if (term) await runChatSearch(term, { silent: true, showErrorBanner: false, signal });
    return;
  }

  await loadChats({ silent: true, showErrorBanner: false, signal });
}

function startChatListIdlePolling(opts: { immediate?: boolean } = {}) {
  if (chatListIdlePollingActive || !layer.active.value || document.visibilityState !== 'visible') return;

  chatListIdlePollingActive = true;
  const token = ++chatListIdlePollToken;
  let forceRefresh = Boolean(opts.immediate);

  const scheduleNext = (delayMs: number) => {
    if (!chatListIdlePollingActive || chatListIdlePollToken !== token) return;
    chatListIdlePollTimer = window.setTimeout(() => {
      void tick();
    }, delayMs);
  };

  const tick = async () => {
    if (!chatListIdlePollingActive || chatListIdlePollToken !== token) return;

    const controller = new AbortController();
    chatListIdlePollAbortController = controller;

    try {
      await runChatListIdleProbe(controller.signal, forceRefresh);
      forceRefresh = false;
      if (!chatListIdlePollingActive || chatListIdlePollToken !== token) return;
      scheduleNext(CHAT_LIST_IDLE_POLL_DELAY_MS);
    } catch (error) {
      if (!chatListIdlePollingActive || chatListIdlePollToken !== token) return;
      if (isAbortError(error)) return;
      console.warn('Failed to refresh chats list while idle polling.', error);
      scheduleNext(CHAT_LIST_IDLE_POLL_RETRY_DELAY_MS);
    } finally {
      if (chatListIdlePollAbortController === controller) {
        chatListIdlePollAbortController = null;
      }
    }
  };

  if (opts.immediate) {
    chatListIdleLastImmediateAt = Date.now();
    void tick();
    return;
  }

  scheduleNext(CHAT_LIST_IDLE_POLL_DELAY_MS);
}

function restartChatListIdlePolling(opts: { immediate?: boolean; throttle?: boolean } = {}) {
  // Coalesce wake events before aborting: they often arrive in one burst.
  if (
    opts.immediate &&
    opts.throttle &&
    chatListIdlePollingActive &&
    Date.now() - chatListIdleLastImmediateAt < CHAT_LIST_IDLE_IMMEDIATE_THROTTLE_MS
  ) {
    return;
  }

  stopChatListIdlePolling();
  startChatListIdlePolling(opts);
}

function startChatListPolling(opts: { immediate?: boolean } = {}) {
  if (chatListPollingActive || !layer.active.value || document.visibilityState !== 'visible' || !hasVisibleGeneratingChat.value) return;

  chatListPollingActive = true;
  const token = ++chatListPollToken;

  const scheduleNext = (delayMs: number) => {
    if (!chatListPollingActive || chatListPollToken !== token) return;
    chatListPollTimer = window.setTimeout(() => {
      void tick();
    }, delayMs);
  };

  const tick = async () => {
    if (!chatListPollingActive || chatListPollToken !== token) return;

    const controller = new AbortController();
    chatListPollAbortController = controller;

    try {
      await refreshVisibleChatGenerationStates(controller.signal);
      if (!chatListPollingActive || chatListPollToken !== token) return;
      chatListGenerationPollReconnecting.value = false;

      if (!hasVisibleGeneratingChat.value) {
        stopChatListPolling();
        return;
      }

      scheduleNext(CHAT_LIST_POLL_SUCCESS_DELAY_MS);
    } catch (error) {
      if (!chatListPollingActive || chatListPollToken !== token) return;
      if (isAbortError(error)) return;
      console.warn('Failed to refresh chats list while polling generation state.', error);
      chatListGenerationPollReconnecting.value = true;
      scheduleNext(CHAT_LIST_POLL_RETRY_DELAY_MS);
    } finally {
      if (chatListPollAbortController === controller) {
        chatListPollAbortController = null;
      }
    }
  };

  if (opts.immediate) {
    void tick();
    return;
  }

  scheduleNext(CHAT_LIST_POLL_SUCCESS_DELAY_MS);
}

function restartChatListPolling(opts: { immediate?: boolean } = {}) {
  stopChatListPolling();
  startChatListPolling(opts);
}

let snoozeDeadlineTimer: number | null = null;
let lastSnoozeRefreshAt = 0;

function stopSnoozeDeadlineTimer() {
  if (snoozeDeadlineTimer != null) window.clearTimeout(snoozeDeadlineTimer);
  snoozeDeadlineTimer = null;
}

function scheduleSnoozeDeadline() {
  stopSnoozeDeadlineTimer();
  if (unmounted || !layer.active.value || document.visibilityState !== 'visible') return;
  const deadlines = visibleGenerationChats.value
    .filter((chat) => chat.read_state?.is_snoozed && chat.read_state.snoozed_until)
    .map((chat) => Date.parse(chat.read_state!.snoozed_until!))
    .filter(Number.isFinite);
  if (nextReadStateExpiry.value && Number.isFinite(Date.parse(nextReadStateExpiry.value))) deadlines.push(Date.parse(nextReadStateExpiry.value));
  if (!deadlines.length) return;
  const remaining = Math.min(...deadlines) - Date.now();
  // Back off when offline or if the server still reports the just-expired state.
  const delay = remaining > 0 ? remaining + 50 : Math.max(50, 30_000 - (Date.now() - lastSnoozeRefreshAt));
  snoozeDeadlineTimer = window.setTimeout(async () => {
    snoozeDeadlineTimer = null;
    lastSnoozeRefreshAt = Date.now();
    if (hasChatSearch.value) await loadChats({ silent: true });
    await refreshSections();
    scheduleSnoozeDeadline();
  }, Math.min(delay, 2_147_483_647));
}

watch([visibleGenerationChats, nextReadStateExpiry], scheduleSnoozeDeadline);

function handleChatListVisibilityChange() {
  scheduleSnoozeDeadline();
  if (document.visibilityState !== 'visible' || !layer.active.value) {
    stopChatListPolling();
    stopChatListIdlePolling();
    return;
  }

  if (hasVisibleGeneratingChat.value) {
    restartChatListPolling({ immediate: true });
  }

  restartChatListIdlePolling({ immediate: true, throttle: true });
}

function handleChatListPageShow() {
  scheduleSnoozeDeadline();
  if (!layer.active.value) return;
  if (hasVisibleGeneratingChat.value) {
    restartChatListPolling({ immediate: true });
  }

  restartChatListIdlePolling({ immediate: true, throttle: true });
}

function handleChatListFocus() {
  scheduleSnoozeDeadline();
  if (document.visibilityState !== 'visible' || !layer.active.value) return;
  if (hasVisibleGeneratingChat.value) {
    restartChatListPolling({ immediate: true });
  }

  restartChatListIdlePolling({ immediate: true, throttle: true });
}

async function refreshBots(opts: { showError?: boolean } = {}) {
  const result = await botsQuery.refetch({ cancelRefetch: true });
  if (result.error && opts.showError) {
    error.value = result.error instanceof Error ? result.error.message : 'Failed to load bots.';
  }
}

watch(
  () => chatSearchTerm.value,
  (value, previousValue) => {
    chatListIdleRevision.value = null;
    resetSectionPageNumbers();
    resetChatSearch();
    const term = value.trim();
    if (term.length < CHAT_SEARCH_MIN_LENGTH) {
      const hadChatSearch = previousValue.trim().length >= CHAT_SEARCH_MIN_LENGTH;
      if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
      chatSearchTimer = null;
      if (hadChatSearch) void loadChats();
      return;
    }

    if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
    chatSearchTimer = window.setTimeout(() => {
      chatSearchTimer = null;
      void runChatSearch(term);
    }, CHAT_SEARCH_DEBOUNCE_MS);
  }
);

watch(
  () => [botFilter.value, chatSearchExact.value, archiveView.value],
  () => {
    chatListIdleRevision.value = null;
    resetChatSearch();
    if (!hasChatSearch.value) return;
    const term = chatSearchTerm.value.trim();
    if (!term) return;
    if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
    chatSearchTimer = null;
    void runChatSearch(term);
  }
);

watch(
  () => hasVisibleGeneratingChat.value,
  (hasGenerating) => {
    if (hasGenerating && layer.active.value) {
      startChatListPolling();
      return;
    }

    stopChatListPolling();
  }
);

watch(
  () => layer.active.value,
  (active, wasActive) => {
    scheduleSnoozeDeadline();
    if (!active) {
      closeChatActions();
      stopChatListPolling();
      stopChatListIdlePolling();
      return;
    }

    if (wasActive === false) {
      void refreshChatIndex();
    }

    if (hasVisibleGeneratingChat.value) {
      restartChatListPolling({ immediate: wasActive === false });
    }

    restartChatListIdlePolling({ immediate: wasActive === false, throttle: true });
  }
);

async function openCreateChatModal() {
  if (creating.value) return;
  error.value = null;
  const initialSelection = createChatInitialBotSelection();
  botModalValue.value = initialSelection;
  botModalOpen.value = true;
  await refreshBots({ showError: true });

  if (!botModalOpen.value || botModalValue.value !== initialSelection) return;
  botModalValue.value = createChatInitialBotSelection();
}

function closeCreateChatModal() {
  if (creating.value) return;
  botModalOpen.value = false;
}

async function createChat(selectedBotId: number | string | '' = '') {
  if (creating.value) return;
  creating.value = true;
  error.value = null;
  try {
    const botId = selectedBotId === '' ? null : Number(selectedBotId);
    const id = await createChatRecord({
      bot_id: typeof botId === 'number' && Number.isInteger(botId) && botId > 0 ? botId : null,
    });
    botModalOpen.value = false;
    await stackNav.open({
      path: `/chats/${id}`,
      query: { focusComposer: '1' },
    });
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to create chat.';
  } finally {
    creating.value = false;
  }
}

onMounted(() => {
  updateIsMobile();
  void loadChats();
  if (hasChatSearch.value) {
    void runChatSearch(chatSearchTerm.value.trim());
  }
  window.addEventListener('resize', updateIsMobile);
  document.addEventListener('visibilitychange', handleChatListVisibilityChange);
  window.addEventListener('pageshow', handleChatListPageShow);
  window.addEventListener('focus', handleChatListFocus);
});

onBeforeUnmount(() => {
  if (serverRefreshTimer !== null) window.clearTimeout(serverRefreshTimer);
  unmounted = true;
  stopSnoozeDeadlineTimer();
  chatListLoadSeq += 1;
  chatSearchSeq += 1;
  window.removeEventListener('resize', updateIsMobile);
  document.removeEventListener('visibilitychange', handleChatListVisibilityChange);
  window.removeEventListener('pageshow', handleChatListPageShow);
  window.removeEventListener('focus', handleChatListFocus);
  if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
  for (const timer of chatSummaryRefreshTimers.values()) window.clearTimeout(timer);
  chatSummaryRefreshTimers.clear();
  abortActiveChatSearch();
  stopChatListPolling();
  stopChatListIdlePolling();
});
</script>

<style scoped>
.chat-filters-stack,
.chat-filters-overlay {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

/* Only the bots panel stretches inside the mobile overlay. */
.chat-filters-overlay > .chat-inbox-views-panel {
  flex: 0 0 auto;
}

.chat-section__header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
.chat-section__header .chat-section__heading { margin-bottom: 0; }

/* Mirrors the hover-revealed actions trigger of chat list rows. */
.chat-section__actions-button {
  width: 28px;
  height: 28px;
  padding: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 1px solid transparent;
  border-radius: 8px;
  background: transparent;
  color: var(--color-text-muted);
}

.chat-section__actions-button:hover,
.chat-section__actions-button[aria-expanded='true'] {
  background: var(--color-surface-hover);
  border-color: var(--color-border-strong);
  color: var(--color-text);
}

.chat-section__actions-button:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 1px;
}

@media (hover: hover) and (pointer: fine) {
  .chat-section__actions-button {
    opacity: 0;
  }

  .chat-section__header:hover .chat-section__actions-button,
  .chat-section__header:focus-within .chat-section__actions-button,
  .chat-section__actions-button[aria-expanded='true'] {
    opacity: 1;
  }
}

.chat-sections { display: flex; flex-direction: column; gap: 20px; }
.chat-section { min-width: 0; }
.chat-section__heading { display: flex; align-items: center; gap: 8px; margin: 0 0 10px; font-size: 1rem; }
.chat-section__heading .muted { font-size: 0.85rem; font-weight: 400; }
.chat-section + .chat-section { border-top: 1px solid var(--color-border); padding-top: 16px; }

.chat-list-main {
  gap: 10px;
}

.pagination {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.chat-search {
  display: flex;
  align-items: center;
  gap: 8px;
}

.chat-search-hits {
  display: grid;
  gap: 4px;
  margin: 0;
  padding: 0 0 0 18px;
  list-style: none;
  border-left: 2px solid var(--color-border-muted);
}

.chat-search-hit__link {
  display: block;
  padding: 6px 10px;
  border: 1px solid var(--color-border-muted);
  border-radius: 10px;
  color: inherit;
  text-decoration: none;
  background: var(--color-surface-muted);
}

.chat-search-hit--user .chat-search-hit__link {
  background: var(--color-chat-user-bg);
  border-color: var(--color-chat-user-border);
}

.chat-search-hit--assistant .chat-search-hit__link {
  background: var(--color-chat-assistant-bg);
  border-color: var(--color-chat-assistant-border);
}

.chat-search-hit--inactive .chat-search-hit__link {
  opacity: 0.8;
}

.chat-search-hit__link:hover {
  border-color: var(--color-border-strong);
}

.chat-search-hit__link:focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
}

.chat-search-hit__meta {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  font-size: 0.8rem;
}

.chat-search-hit__role {
  font-weight: 600;
}

.chat-search-hit__snippet {
  margin-top: 2px;
  font-size: 0.9rem;
  line-height: 1.35;
  overflow-wrap: anywhere;
}

.chat-search-hit__snippet mark {
  padding: 0 1px;
  border-radius: 3px;
  background: color-mix(in srgb, var(--color-warning-border) 55%, transparent);
  color: inherit;
}

.chat-search-more {
  display: flex;
  justify-content: center;
}

.chat-list-entry {
  display: grid;
  gap: 6px;
}

.subchat-toggle-row {
  display: flex;
  padding-left: 18px;
}

.subchat-toggle {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: 28px;
  padding: 3px 8px;
  color: var(--color-text-muted);
  background: transparent;
  border: 0;
}

.subchat-toggle:hover {
  color: var(--color-text);
  background: var(--color-surface-muted);
}

.subchat-list {
  display: grid;
  gap: 6px;
  padding-left: 18px;
  border-left: 2px solid var(--color-border-muted);
}

.badge-muted {
  border-color: var(--color-danger-border);
  color: var(--color-danger-text);
  background: var(--color-danger-bg);
}

.share-indicator {
  display: inline-flex;
  align-items: center;
  color: var(--color-link);
}
</style>
