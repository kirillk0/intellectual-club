<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Chats</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
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
                :preview-text="!hasChatSearch && c.first_message_preview ? formatPreview(c.first_message_preview) : null"
                :preview-role="!hasChatSearch ? c.first_message_role : null"
                :snippet="hasChatSearch && isSearchResult(c) && c.match_type !== 'meta' ? c.snippet || null : null"
                :generating="Boolean(c.active_generation_message_id)"
                :row-role="chatResultRole(c)"
              >
                <template #badges>
                  <span v-if="hasChatSearch && isSearchResult(c)" class="badge" :class="matchBadgeClass(c.match_type)">
                    {{ matchBadgeLabel(c.match_type) }}
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
import { useRouter } from 'vue-router';
import { api } from '../api/client';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import BotSelectorModal from '@/components/BotSelectorModal.vue';
import ChatListRow from '@/components/ChatListRow.vue';
import ChatBotFiltersPanel from '@/components/ChatBotFiltersPanel.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { sortBotsByPreference, useBotSortPreference } from '@/features/bots/model/useBotSortPreference';
import { parseImageAsset } from '@/features/media/image';
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
  created_at: string | null;
  last_activity_at: string | null;
  message_count?: number | null;
  first_message_preview?: string | null;
  first_message_role?: 'user' | 'assistant' | null;
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

const CHAT_LIST_RESET_EVENT = 'chat-list:reset-to-first-page';

const router = useRouter();

const loading = ref(true);
const creating = ref(false);
const loadingBots = ref(false);
const error = ref<string | null>(null);
const chats = ref<ChatSummary[]>([]);
const pageNumber = ref(1);
const perPage = ref(20);
const totalChats = ref(0);
const hasNextPage = ref(false);
const chatSearchTerm = ref('');
const chatSearchResults = ref<ChatSearchResult[]>([]);
const chatSearchLoading = ref(false);
const chatSearchError = ref('');
const botFilter = ref<string>('');
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

const hasChatSearch = computed(() => chatSearchTerm.value.trim().length > 0);
const hasActiveBotFilter = computed(() => String(botFilter.value || '').trim().length > 0);

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
  if (!isSearchResult(chat)) return path;
  if (!chat.message_id || chat.match_type === 'meta') return path;
  const query: Record<string, string> = { focusMessage: String(chat.message_id) };
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

async function loadChats() {
  loading.value = true;
  error.value = null;
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
    }>(`/api/bff/chats?${params.toString()}`);
    chats.value = payload.chats || [];
    pageNumber.value = Number.isInteger(payload.page?.number) ? Number(payload.page?.number) : requestedPage;
    perPage.value = Number.isInteger(payload.page?.per_page) ? Number(payload.page?.per_page) : perPage.value;
    totalChats.value = Number.isInteger(payload.page?.total) ? Number(payload.page?.total) : chats.value.length;
    hasNextPage.value = Boolean(payload.page?.has_next);
    chatListStats.value = normalizeChatListStats(payload.stats);
  } catch (e) {
    error.value = e instanceof Error ? e.message : 'Failed to load chats.';
  } finally {
    loading.value = false;
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

function resetChatSearch() {
  chatSearchSeq += 1;
  chatSearchResults.value = [];
  chatSearchLoading.value = false;
  chatSearchError.value = '';
}

async function runChatSearch(term: string) {
  const seq = ++chatSearchSeq;
  chatSearchLoading.value = true;
  chatSearchError.value = '';

  try {
    const params = new URLSearchParams();
    params.set('q', term);
    params.set('per_page', String(perPage.value));
    const bot = String(botFilter.value || '').trim();
    if (bot) params.set('bot', bot);
    const payload = await api.get<{ chats: ChatSearchResult[] }>(`/api/bff/chats/search?${params.toString()}`);
    if (seq !== chatSearchSeq) return;
    chatSearchResults.value = payload.chats || [];
  } catch (e) {
    if (seq !== chatSearchSeq) return;
    console.error(e);
    chatSearchError.value = 'Failed to search chats.';
    chatSearchResults.value = [];
  } finally {
    if (seq === chatSearchSeq) chatSearchLoading.value = false;
  }
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
  (value) => {
    const term = value.trim();
    if (!term) {
      if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
      chatSearchTimer = null;
      resetChatSearch();
      return;
    }

    if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
    chatSearchTimer = window.setTimeout(() => {
      runChatSearch(term);
    }, 250);
  }
);

watch(
  () => botFilter.value,
  () => {
    if (!hasChatSearch.value) return;
    const term = chatSearchTerm.value.trim();
    if (!term) return;
    if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
    chatSearchTimer = null;
    void runChatSearch(term);
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
    await router.push(`/chats/${id}`);
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
  window.addEventListener('resize', updateIsMobile);
  window.addEventListener(CHAT_LIST_RESET_EVENT, handleChatListReset);
});

onBeforeUnmount(() => {
  window.removeEventListener('resize', updateIsMobile);
  window.removeEventListener(CHAT_LIST_RESET_EVENT, handleChatListReset);
  if (chatSearchTimer) window.clearTimeout(chatSearchTimer);
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
  border-color: #f1c1c1;
  color: #9a3f3f;
  background: #fff7f7;
}

.badge-accent {
  border-color: #bcd9ff;
  background: #f2f8ff;
  color: #2563eb;
}

</style>
