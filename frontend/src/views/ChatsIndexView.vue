<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Chats</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <RouterLink to="/bookmarks" class="icon-button" aria-label="Open bookmarks" title="Bookmarks">
            <SvgIcon name="bookmark" />
          </RouterLink>
          <button class="primary" style="white-space: nowrap" @click="openCreateChatModal" :disabled="creating">
            {{ creating ? 'Creating…' : 'New chat' }}
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <div class="split-wrapper">
      <div class="catalog-split">
        <aside class="catalog-split__sidebar">
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
              <button v-if="chatSearchTerm" type="button" @click="chatSearchTerm = ''">Clear</button>
            </div>
          </section>

          <p v-if="loading" class="muted">Loading…</p>
          <p v-else-if="error" class="error-text">{{ error }}</p>

          <section v-else class="card stack chat-list-main">
            <p v-if="hasChatSearch && chatSearchLoading" class="muted">Searching...</p>
            <p v-if="hasChatSearch && chatSearchError" class="error-text">{{ chatSearchError }}</p>

            <div class="list">
              <ChatListRow
                v-for="c in visibleChats"
                :key="c.id"
                :to="chatResultLink(c)"
                :title="chatLabel(c)"
                :config-label="c.llm_configuration_label || null"
                :meta-text="`${niceDate(c.last_activity_at || c.created_at)} · ${c.message_count ?? 0} msgs`"
                :secondary-meta="relationMeta(c)"
                :preview-text="!hasChatSearch && c.first_message_preview ? formatPreview(c.first_message_preview) : null"
                :preview-role="!hasChatSearch ? c.first_message_role : null"
                :snippet="hasChatSearch && isSearchResult(c) && c.match_type !== 'meta' ? c.snippet || null : null"
                :generation-state="generationStateForChat(c)"
                :row-role="chatResultRole(c)"
              >
                <template #badges>
                  <span
                    v-if="c.shared_outgoing"
                    class="share-indicator"
                    title="Shared with groups"
                    aria-label="Shared with groups"
                  >
                    <SvgIcon name="share-outgoing" />
                  </span>
                  <span v-if="hasChatSearch && isSearchResult(c)" class="badge" :class="matchBadgeClass(c.match_type)">
                    {{ matchBadgeLabel(c.match_type) }}
                  </span>
                  <span v-if="c.parent_relation_kind === 'handoff'" class="badge">Continuation</span>
                  <span v-if="Number(c.child_handoff_count || 0) > 0" class="badge">
                    {{ continuationCountLabel(c.child_handoff_count || 0) }}
                  </span>
                </template>
              </ChatListRow>
            </div>

            <div v-if="!hasChatSearch && totalPages > 1" class="pagination">
              <button type="button" :disabled="loading || pageNumber <= 1" @click="goToPreviousPage">
                Previous
              </button>
              <span class="muted">Page {{ pageNumber }} of {{ totalPages }}</span>
              <button type="button" :disabled="loading || !hasNextPage" @click="goToNextPage">
                Next
              </button>
            </div>

            <p v-if="chatListEmptyState" class="muted">{{ chatListEmptyState }}</p>
            <p v-if="chatSearchEmptyState" class="muted">{{ chatSearchEmptyState }}</p>
          </section>
        </main>
      </div>

      <transition name="fade">
        <div v-if="isMobile && filterOpen" class="panel-backdrop" @click="closeFilter"></div>
      </transition>

      <aside v-if="isMobile && filterOpen" class="sidebar overlay align-left">
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
        >
          <template #header-extra>
            <button class="panel-toggle" type="button" @click="closeFilter" aria-label="Hide bots filter">
              <SvgIcon name="chevron-left" />
            </button>
          </template>
        </ChatBotFiltersPanel>
      </aside>

      <button
        v-if="isMobile && !filterOpen"
        class="panel-toggle floating left"
        :class="{ 'active-filter': hasActiveBotFilter }"
        type="button"
        @click="openFilter"
        aria-label="Show bots filter"
      >
        <SvgIcon name="bot" />
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
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';
import { api } from '../api/client';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import BotSelectorModal from '@/components/BotSelectorModal.vue';
import ChatListRow from '@/components/ChatListRow.vue';
import ChatBotFiltersPanel from '@/components/ChatBotFiltersPanel.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { sortBotsByPreference, useBotSortPreference } from '@/features/bots/model/useBotSortPreference';
import { parseImageAsset } from '@/features/media/image';
import { translate } from '@/i18n';
import type { Bot, ImageAsset } from '@/types/api';
import { formatChatBaseTitle } from '@/utils/chatTitle';
import { formatRelativeDateTime } from '@/utils/dates';
import SvgIcon from '@/components/icons/SvgIcon.vue';

type ChatSummary = {
  id: number;
  note?: string | null;
  bot_id: number | null;
  bot_name: string;
  llm_configuration_label?: string | null;
  active_generation_message_id?: number | null;
  parent_chat_id?: number | null;
  parent_message_id?: number | null;
  parent_relation_kind?: string | null;
  child_handoff_count?: number | null;
  created_at: string | null;
  last_activity_at: string | null;
  message_count?: number | null;
  first_message_preview?: string | null;
  first_message_role?: 'user' | 'assistant' | null;
  can_edit?: boolean | null;
  shared_incoming?: boolean | null;
  shared_outgoing?: boolean | null;
};

type ChatSearchResult = ChatSummary & {
  match_type: 'meta' | 'active_message' | 'inactive_message';
  snippet?: string | null;
  message_id?: number | null;
  message_role?: 'user' | 'assistant' | null;
};

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
  revision?: string | null;
  active_generation_message_id?: number | null;
};

type GenerationState = 'generating' | 'reconnecting' | 'done';

const CHAT_LIST_RESET_EVENT = 'chat-list:reset-to-first-page';
const CHAT_LIST_POLL_SUCCESS_DELAY_MS = 1_500;
const CHAT_LIST_POLL_RETRY_DELAY_MS = 3_000;
const CHAT_LIST_IDLE_POLL_DELAY_MS = 30_000;
const CHAT_LIST_IDLE_POLL_RETRY_DELAY_MS = 30_000;
const CHAT_LIST_IDLE_IMMEDIATE_THROTTLE_MS = 1_500;
const CHAT_SEARCH_DEBOUNCE_MS = 600;
const CHAT_SEARCH_MIN_LENGTH = 2;

const route = useRoute();
const router = useRouter();

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

function readBotFilterQuery(value: unknown) {
  const raw = getQueryString(value).trim();
  if (raw === 'none') return raw;
  const id = Number(raw);
  return Number.isInteger(id) && id > 0 ? String(id) : '';
}

function sameQueryValue(current: unknown, next: string | undefined) {
  return getQueryString(current) === (next ?? '');
}

const loading = ref(true);
const creating = ref(false);
const loadingBots = ref(false);
const error = ref<string | null>(null);
const chats = ref<ChatSummary[]>([]);
const pageNumber = ref(readChatListPageQuery(route.query.page));
const perPage = ref(20);
const totalChats = ref(0);
const hasNextPage = ref(false);
const chatSearchTerm = ref(getQueryString(route.query.q));
const chatSearchResults = ref<ChatSearchResult[]>([]);
const chatSearchLoading = ref(false);
const chatSearchError = ref('');
const chatListIdleRevision = ref<string | null>(null);
const chatListGenerationPollReconnecting = ref(false);
const generationCompleteChatIds = ref(new Set<number>());
const botFilter = ref<string>(readBotFilterQuery(route.query.bot));
const botSearchTerm = ref('');
const bots = ref<Bot[]>([]);
const chatListStats = ref<ChatListStats>({
  total_chats: 0,
  no_bot_chat_count: 0,
  no_bot_last_activity_at: null,
  bots: [],
});
const botModalOpen = ref(false);
const botModalValue = ref<number | ''>('');
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
  const bot = String(botFilter.value || '').trim();
  const page = pageNumber.value > 1 ? String(pageNumber.value) : undefined;
  const next = { ...route.query };

  if (q) next.q = q;
  else delete (next as Record<string, unknown>).q;

  if (bot) next.bot = bot;
  else delete (next as Record<string, unknown>).bot;

  if (page) next.page = page;
  else delete (next as Record<string, unknown>).page;

  if (
    sameQueryValue(route.query.q, q || undefined) &&
    sameQueryValue(route.query.bot, bot || undefined) &&
    sameQueryValue(route.query.page, page)
  ) {
    return;
  }

  router.replace({ query: next }).catch(() => {});
}

watch(
  () => [route.query.q, route.query.bot, route.query.page],
  ([q, bot, page]) => {
    const nextQ = getQueryString(q);
    const nextBot = readBotFilterQuery(bot);
    const nextPage = readChatListPageQuery(page);
    const shouldLoadChats = botFilter.value !== nextBot || pageNumber.value !== nextPage;

    if (chatSearchTerm.value !== nextQ) chatSearchTerm.value = nextQ;
    if (botFilter.value !== nextBot) botFilter.value = nextBot;
    if (pageNumber.value !== nextPage) pageNumber.value = nextPage;

    if (shouldLoadChats && !hasChatSearch.value) {
      void loadChats();
    }
  }
);

watch(
  () => [chatSearchTerm.value, botFilter.value, pageNumber.value],
  () => {
    syncChatListRouteQuery();
  }
);

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
  pageNumber.value = 1;
  void loadChats();
  if (isMobile.value) filterOpen.value = false;
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

  const options = (chatListStats.value.bots || [])
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

const filteredChats = computed(() => chats.value.filter(matchesBotFilter));
const filteredChatSearchResults = computed(() => chatSearchResults.value.filter(matchesBotFilter));
const visibleChats = computed(() => (hasChatSearch.value ? filteredChatSearchResults.value : filteredChats.value));
const hasVisibleGeneratingChat = computed(() =>
  visibleChats.value.some((chat) => Boolean(chat.active_generation_message_id))
);
const allBotsCount = computed(() => {
  if (chatListStats.value.total_chats > 0) return chatListStats.value.total_chats;
  return totalChats.value;
});
const totalPages = computed(() => {
  const perPageValue = perPage.value > 0 ? perPage.value : 20;
  return Math.max(1, Math.ceil(totalChats.value / perPageValue));
});

const chatSearchEmptyState = computed(() => {
  if (!hasChatSearch.value) return '';
  if (chatSearchLoading.value) return '';
  if (chatSearchError.value) return '';
  return filteredChatSearchResults.value.length ? '' : 'No matches found.';
});

const chatListEmptyState = computed(() => {
  if (hasChatSearch.value) return '';
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
  return generationCompleteChatIds.value.has(chat.id) ? 'done' : null;
}

function continuationCountLabel(count: number) {
  return count === 1 ? translate('1 continuation') : translate('{count} continuations', { count });
}

function relationMeta(chat: ChatSummary) {
  const count = Number(chat.child_handoff_count || 0);
  const parts: string[] = [];
  if (chat.parent_relation_kind === 'handoff') parts.push('Continuation');
  if (count > 0) parts.push(continuationCountLabel(count));
  return parts.length ? parts.join(' · ') : null;
}

function isSearchResult(chat: ChatSummary | ChatSearchResult): chat is ChatSearchResult {
  return hasChatSearch.value && typeof (chat as ChatSearchResult).match_type === 'string';
}

function matchBadgeLabel(matchType: ChatSearchResult['match_type']) {
  switch (matchType) {
    case 'meta':
      return 'Bot/Note';
    case 'active_message':
      return 'Active branch';
    case 'inactive_message':
      return 'Inactive branch';
    default:
      return 'Match';
  }
}

function matchBadgeClass(matchType: ChatSearchResult['match_type']) {
  return {
    'badge-muted': matchType === 'inactive_message',
    'badge-accent': matchType === 'active_message',
  };
}

function chatResultRole(chat: ChatSummary | ChatSearchResult) {
  if (!isSearchResult(chat)) return null;
  if (chat.match_type === 'meta' || !chat.message_role) return null;
  return chat.message_role;
}

function chatResultLink(chat: ChatSummary | ChatSearchResult) {
  const path = `/chats/${chat.id}`;
  const query: Record<string, string> = { returnTo: route.fullPath || '/chats' };
  if (!isSearchResult(chat)) return { path, query };
  if (!chat.message_id || chat.match_type === 'meta') return { path, query };
  query.focusMessage = String(chat.message_id);
  if (chat.match_type === 'inactive_message') {
    query.focusInactive = '1';
  }
  return { path, query };
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
let previousVisibleGeneratingChatIds = new Set<number>();

function syncVisibleGenerationState(nextChats: ChatSummary[]) {
  const nextGeneratingIds = new Set<number>();
  const nextCompleteIds = new Set(generationCompleteChatIds.value);
  let completeIdsChanged = false;

  for (const chat of nextChats) {
    if (chat.active_generation_message_id) {
      nextGeneratingIds.add(chat.id);
      if (nextCompleteIds.delete(chat.id)) completeIdsChanged = true;
      continue;
    }

    if (previousVisibleGeneratingChatIds.has(chat.id) && !nextCompleteIds.has(chat.id)) {
      nextCompleteIds.add(chat.id);
      completeIdsChanged = true;
    }
  }

  previousVisibleGeneratingChatIds = nextGeneratingIds;
  if (completeIdsChanged) generationCompleteChatIds.value = nextCompleteIds;
}

async function loadChats(
  opts: { silent?: boolean; showErrorBanner?: boolean; signal?: AbortSignal; rethrowSilent?: boolean } = {}
) {
  const seq = ++chatListLoadSeq;
  const silent = Boolean(opts.silent);
  if (!silent) {
    loading.value = true;
    error.value = null;
  }

  try {
    const requestedPage = Math.max(1, pageNumber.value);
    const params = new URLSearchParams();
    params.set('preview_len', String(Math.min(previewLength.value, 500)));
    params.set('page', String(requestedPage));
    params.set('per_page', String(perPage.value));
    const bot = String(botFilter.value || '').trim();
    if (bot) params.set('bot', bot);
    const payload = await api.get<{
      chats: ChatSummary[];
      page?: {
        number?: number;
        per_page?: number;
        total?: number;
        has_next?: boolean;
      };
      stats?: ChatListStats;
      idle_revision?: string | null;
    }>(`/api/bff/chats?${params.toString()}`, {
      showErrorBanner: opts.showErrorBanner ?? true,
      signal: opts.signal,
    });

    if (seq !== chatListLoadSeq) return;

    chats.value = payload.chats || [];
    syncVisibleGenerationState(visibleChats.value);
    pageNumber.value = Number.isInteger(payload.page?.number) ? Number(payload.page?.number) : requestedPage;
    perPage.value = Number.isInteger(payload.page?.per_page) ? Number(payload.page?.per_page) : perPage.value;
    totalChats.value = Number.isInteger(payload.page?.total) ? Number(payload.page?.total) : chats.value.length;
    hasNextPage.value = Boolean(payload.page?.has_next);
    chatListStats.value = normalizeChatListStats(payload.stats);
    chatListIdleRevision.value = typeof payload.idle_revision === 'string' ? payload.idle_revision : null;
    startChatListIdlePolling();
  } catch (e) {
    if (seq !== chatListLoadSeq) return;
    if (!silent) {
      error.value = e instanceof Error ? e.message : 'Failed to load chats.';
      return;
    }
    if (opts.rethrowSilent) throw e;
    console.warn('Failed to refresh chats list while polling generation state.', e);
  } finally {
    if (!silent && seq === chatListLoadSeq) {
      loading.value = false;
    }
  }
}

function goToPreviousPage() {
  if (loading.value || pageNumber.value <= 1) return;
  pageNumber.value -= 1;
  void loadChats();
}

function goToNextPage() {
  if (loading.value || !hasNextPage.value) return;
  pageNumber.value += 1;
  void loadChats();
}

function handleChatListReset() {
  if (pageNumber.value <= 1) return;
  pageNumber.value = 1;
  void loadChats();
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
  return error instanceof DOMException && error.name === 'AbortError';
}

function resetChatSearch() {
  chatSearchSeq += 1;
  abortActiveChatSearch();
  chatSearchResults.value = [];
  chatSearchLoading.value = false;
  chatSearchError.value = '';
}

async function runChatSearch(
  term: string,
  opts: { silent?: boolean; showErrorBanner?: boolean; signal?: AbortSignal; rethrowSilent?: boolean } = {}
) {
  const seq = ++chatSearchSeq;
  abortActiveChatSearch();

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
  if (!silent) {
    chatSearchLoading.value = true;
    chatSearchError.value = '';
  }

  try {
    const params = new URLSearchParams();
    params.set('q', term);
    params.set('per_page', String(perPage.value));
    const bot = String(botFilter.value || '').trim();
    if (bot) params.set('bot', bot);
    const payload = await api.get<{ chats: ChatSearchResult[] }>(`/api/bff/chats/search?${params.toString()}`, {
      showErrorBanner: opts.showErrorBanner ?? true,
      signal: controller.signal,
    });
    if (seq !== chatSearchSeq) return;
    chatSearchResults.value = payload.chats || [];
    syncVisibleGenerationState(visibleChats.value);
  } catch (e) {
    if (isAbortError(e)) return;
    if (seq !== chatSearchSeq) return;
    if (!silent) {
      console.error(e);
      chatSearchError.value = 'Failed to search chats.';
      chatSearchResults.value = [];
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
    if (!silent && seq === chatSearchSeq) chatSearchLoading.value = false;
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

async function refreshVisibleChatsForGeneration(signal: AbortSignal) {
  if (hasChatSearch.value) {
    const term = chatSearchTerm.value.trim();
    if (!term) return;
    await runChatSearch(term, { silent: true, showErrorBanner: false, signal, rethrowSilent: true });
    return;
  }

  await loadChats({ silent: true, showErrorBanner: false, signal, rethrowSilent: true });
}

function chatListIdleProbeParams() {
  const params = new URLSearchParams();
  params.set('page', String(Math.max(1, pageNumber.value)));
  params.set('per_page', String(perPage.value));
  const bot = String(botFilter.value || '').trim();
  if (bot) params.set('bot', bot);
  if (chatListIdleRevision.value) params.set('revision', chatListIdleRevision.value);
  return params;
}

function canRunChatListIdleProbe() {
  return document.visibilityState === 'visible' && !chatListPollingActive && !hasVisibleGeneratingChat.value;
}

async function runChatListIdleProbe(signal: AbortSignal) {
  if (!canRunChatListIdleProbe()) return;

  const payload = await api.get<ChatListIdleStatePayload | undefined>(
    `/api/bff/chats/idle-state?${chatListIdleProbeParams().toString()}`,
    {
      signal,
      showErrorBanner: false,
    }
  );

  if (!payload) return;

  if (typeof payload.revision === 'string') {
    chatListIdleRevision.value = payload.revision;
  }

  if (hasChatSearch.value) {
    const term = chatSearchTerm.value.trim();
    if (term) await runChatSearch(term, { silent: true, showErrorBanner: false, signal });
    return;
  }

  await loadChats({ silent: true, showErrorBanner: false, signal });
}

function startChatListIdlePolling(opts: { immediate?: boolean; throttle?: boolean } = {}) {
  if (chatListIdlePollingActive) return;

  chatListIdlePollingActive = true;
  const token = ++chatListIdlePollToken;

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
      await runChatListIdleProbe(controller.signal);
      if (!chatListIdlePollingActive || chatListIdlePollToken !== token) return;
      scheduleNext(CHAT_LIST_IDLE_POLL_DELAY_MS);
    } catch (error) {
      if (!chatListIdlePollingActive || chatListIdlePollToken !== token) return;
      if (error instanceof DOMException && error.name === 'AbortError') return;
      console.warn('Failed to refresh chats list while idle polling.', error);
      scheduleNext(CHAT_LIST_IDLE_POLL_RETRY_DELAY_MS);
    } finally {
      if (chatListIdlePollAbortController === controller) {
        chatListIdlePollAbortController = null;
      }
    }
  };

  if (opts.immediate) {
    const now = Date.now();
    if (!opts.throttle || now - chatListIdleLastImmediateAt >= CHAT_LIST_IDLE_IMMEDIATE_THROTTLE_MS) {
      chatListIdleLastImmediateAt = now;
      void tick();
      return;
    }
  }

  scheduleNext(CHAT_LIST_IDLE_POLL_DELAY_MS);
}

function restartChatListIdlePolling(opts: { immediate?: boolean; throttle?: boolean } = {}) {
  stopChatListIdlePolling();
  startChatListIdlePolling(opts);
}

function startChatListPolling(opts: { immediate?: boolean } = {}) {
  if (chatListPollingActive || !hasVisibleGeneratingChat.value) return;

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
      await refreshVisibleChatsForGeneration(controller.signal);
      if (!chatListPollingActive || chatListPollToken !== token) return;
      chatListGenerationPollReconnecting.value = false;

      if (!hasVisibleGeneratingChat.value) {
        stopChatListPolling();
        return;
      }

      scheduleNext(CHAT_LIST_POLL_SUCCESS_DELAY_MS);
    } catch (error) {
      if (!chatListPollingActive || chatListPollToken !== token) return;
      if (error instanceof DOMException && error.name === 'AbortError') return;
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

function handleChatListVisibilityChange() {
  if (document.visibilityState !== 'visible') {
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
  if (hasVisibleGeneratingChat.value) {
    restartChatListPolling({ immediate: true });
  }

  restartChatListIdlePolling({ immediate: true, throttle: true });
}

function handleChatListFocus() {
  if (document.visibilityState !== 'visible') return;
  if (hasVisibleGeneratingChat.value) {
    restartChatListPolling({ immediate: true });
  }

  restartChatListIdlePolling({ immediate: true, throttle: true });
}

async function loadBots(opts: { showError?: boolean } = {}) {
  if (loadingBots.value) return;
  loadingBots.value = true;
  try {
    const params = new URLSearchParams();
    params.set('sort', 'name');
    params.set('fields[bots]', 'name,sort_activity_at,image');
    const payload = await jsonApiList('/api/ash/bots', params);
    bots.value = (payload.data || []).map(parseBot).filter((bot): bot is Bot => Boolean(bot));
  } catch (e) {
    console.error(e);
    if (opts.showError) {
      error.value = e instanceof Error ? e.message : 'Failed to load bots.';
    }
  } finally {
    loadingBots.value = false;
  }
}

watch(
  () => chatSearchTerm.value,
  (value, previousValue) => {
    chatListIdleRevision.value = null;
    const term = value.trim();
    if (term.length < CHAT_SEARCH_MIN_LENGTH) {
      const hadChatSearch = previousValue.trim().length >= CHAT_SEARCH_MIN_LENGTH;
      if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
      chatSearchTimer = null;
      resetChatSearch();
      if (hadChatSearch) void loadChats();
      return;
    }

    if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
    chatSearchTimer = window.setTimeout(() => {
      runChatSearch(term);
    }, CHAT_SEARCH_DEBOUNCE_MS);
  }
);

watch(
  () => botFilter.value,
  () => {
    chatListIdleRevision.value = null;
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
    if (hasGenerating) {
      startChatListPolling();
      return;
    }

    stopChatListPolling();
  }
);

async function openCreateChatModal() {
  if (creating.value) return;
  error.value = null;
  const initialSelection = botSortMode.value === 'recent_activity' ? createChatBotOptions.value[0]?.id ?? '' : '';
  botModalValue.value = initialSelection;
  botModalOpen.value = true;
  await loadBots({ showError: true });

  if (!botModalOpen.value || botModalValue.value !== initialSelection) return;
  botModalValue.value = botSortMode.value === 'recent_activity' ? createChatBotOptions.value[0]?.id ?? '' : '';
}

function closeCreateChatModal() {
  if (creating.value) return;
  botModalOpen.value = false;
}

async function createChat(selectedBotId: number | '' = '') {
  if (creating.value) return;
  creating.value = true;
  error.value = null;
  try {
    const payload = await api.post<{ chat: { id: number } }>('/api/bff/chats', {
      bot_id: selectedBotId === '' ? null : Number(selectedBotId),
    });
    const id = payload.chat?.id;
    if (!id) throw new Error('Missing chat id');
    botModalOpen.value = false;
    await router.push({ path: `/chats/${id}`, query: { returnTo: route.fullPath || '/chats' } });
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to create chat.';
  } finally {
    creating.value = false;
  }
}

onMounted(() => {
  updateIsMobile();
  void loadChats();
  void loadBots();
  if (hasChatSearch.value) {
    void runChatSearch(chatSearchTerm.value.trim());
  }
  window.addEventListener('resize', updateIsMobile);
  window.addEventListener(CHAT_LIST_RESET_EVENT, handleChatListReset);
  document.addEventListener('visibilitychange', handleChatListVisibilityChange);
  window.addEventListener('pageshow', handleChatListPageShow);
  window.addEventListener('focus', handleChatListFocus);
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', updateIsMobile);
  window.removeEventListener(CHAT_LIST_RESET_EVENT, handleChatListReset);
  document.removeEventListener('visibilitychange', handleChatListVisibilityChange);
  window.removeEventListener('pageshow', handleChatListPageShow);
  window.removeEventListener('focus', handleChatListFocus);
  if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
  abortActiveChatSearch();
  stopChatListPolling();
  stopChatListIdlePolling();
});
</script>

<style scoped>
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

.badge-muted {
  border-color: var(--color-danger-border);
  color: var(--color-danger-text);
  background: var(--color-danger-bg);
}

.badge-accent {
  border-color: var(--color-info-border);
  background: var(--color-info-bg);
  color: var(--color-link);
}

.share-indicator {
  display: inline-flex;
  align-items: center;
  color: var(--color-link);
}
</style>
