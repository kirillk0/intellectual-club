<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Chats</strong>
        <div class="header-actions toolbar-actions-right" style="gap: 8px">
          <button v-if="hasActiveBotFilter" type="button" @click="setBotFilter('')">Clear filter</button>
          <button
            v-if="isFilterMobile && !filterOpen"
            class="panel-toggle"
            type="button"
            :class="{ 'active-filter': hasActiveBotFilter }"
            @click="openFilter"
            aria-label="Show bots"
            title="Show bots"
          >
            🤖
          </button>
          <button class="primary" style="white-space: nowrap" @click="openCreateChatModal" :disabled="creating">
            {{ creating ? 'Creating…' : 'New chat' }}
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <div v-else class="chat-list-layout">
      <aside
        class="sidebar chat-filter-panel"
        :class="{ overlay: isFilterMobile, 'align-left': isFilterMobile }"
        v-show="!isFilterMobile || filterOpen"
      >
        <div class="panel-header">
          <h3 style="margin: 0">Bots</h3>
          <div class="spacer"></div>
          <button
            v-if="isFilterMobile"
            class="panel-toggle"
            type="button"
            @click="closeFilter"
            aria-label="Hide bots"
            title="Hide bots"
          >
            ◀
          </button>
        </div>

        <div class="chat-search">
          <input
            v-model="botSearchTerm"
            type="search"
            class="full"
            placeholder="Search bots"
            aria-label="Search bots"
          />
          <button
            type="button"
            class="sort-toggle"
            :class="{ active: botSortModeValue === 'recent_activity' }"
            :aria-label="botSortToggleLabel"
            :title="botSortToggleLabel"
            @click="toggleBotSortMode"
          >
            <span aria-hidden="true">{{ botSortModeValue === 'recent_activity' ? '🕒' : 'A↕' }}</span>
          </button>
          <button v-if="botSearchTerm" type="button" @click="botSearchTerm = ''">Clear</button>
        </div>

        <div class="list bot-filter-list">
          <button
            type="button"
            class="row bot-filter-item"
            :class="{ active: botFilter === '' }"
            @click="setBotFilter('')"
          >
            <span class="bot-filter-name">All bots</span>
            <ImageThumbnail :label="'All bots'" :size="36" :hideWithoutImage="true" />
            <span class="muted bot-filter-count">{{ allBotsCount }}</span>
          </button>

          <button
            v-if="showNoBotOption"
            type="button"
            class="row bot-filter-item"
            :class="{ active: botFilter === 'none' }"
            @click="setBotFilter('none')"
          >
            <span class="bot-filter-name">No bot</span>
            <ImageThumbnail :label="'No bot'" :size="36" :hideWithoutImage="true" />
            <span class="muted bot-filter-count">{{ noBotChatCount }}</span>
          </button>

          <button
            v-for="opt in visibleBotFilterOptions"
            :key="opt.value"
            type="button"
            class="row bot-filter-item"
            :class="{ active: botFilter === opt.value }"
            @click="setBotFilter(opt.value)"
          >
            <span class="bot-filter-name">{{ opt.label }}</span>
            <ImageThumbnail :image="opt.image" :label="opt.label" :size="36" :hideWithoutImage="true" />
            <span class="muted bot-filter-count">{{ opt.count }}</span>
          </button>

          <p v-if="botFilterEmptyState" class="muted">{{ botFilterEmptyState }}</p>
        </div>
      </aside>

      <section class="card stack chat-list-main">
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

        <p v-if="hasChatSearch && chatSearchLoading" class="muted">Searching...</p>
        <p v-if="hasChatSearch && chatSearchError" class="error-text">{{ chatSearchError }}</p>

        <div class="list">
          <RouterLink
            v-for="c in visibleChats"
            :key="c.id"
            class="row"
            :class="chatResultClass(c)"
            :to="chatResultLink(c)"
          >
            <div class="chat-result-main">
              <div class="chat-result-title">
                <span class="chat-result-name">{{ chatLabel(c) }}</span>
                <span v-if="c.llm_configuration_label" class="chat-result-config">
                  ({{ c.llm_configuration_label }})
                </span>
              </div>
              <div class="chat-result-meta">
                <div class="muted">
                  {{ niceDate(c.last_activity_at || c.created_at) }} ·
                  {{ c.message_count ?? 0 }} msgs
                </div>
                <span
                  v-if="c.active_generation_message_id"
                  class="chat-result-generating"
                  aria-label="Generating"
                  title="Generating"
                >
                  <span class="typing-indicator" aria-hidden="true"><span></span><span></span><span></span></span>
                </span>
              </div>
              <div v-if="!hasChatSearch && c.first_message_preview" class="chat-first-preview">
                <div class="chat-first-preview-bubble" :class="previewBubbleClass(c.first_message_role)">
                  {{ formatPreview(c.first_message_preview) }}
                </div>
              </div>
              <div v-if="hasChatSearch && isSearchResult(c) && c.match_type !== 'meta' && c.snippet" class="chat-search-snippet">
                {{ c.snippet }}
              </div>
            </div>

            <div class="chat-result-badges">
              <span v-if="hasChatSearch && isSearchResult(c)" class="badge" :class="matchBadgeClass(c.match_type)">
                {{ matchBadgeLabel(c.match_type) }}
              </span>
            </div>
          </RouterLink>
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
    </div>

    <transition name="fade">
      <div v-if="isFilterMobile && filterOpen" class="panel-backdrop" @click="closeFilter"></div>
    </transition>

    <Teleport to="body">
      <BotSelectorModal
        v-if="botModalOpen"
        v-model="botModalValue"
        :bots="bots"
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
import { RouterLink, useRouter } from 'vue-router';
import { api } from '../api/client';
import { jsonApiList, toIntId, type JsonApiResource } from '@/api/jsonApi';
import BotSelectorModal from '@/components/BotSelectorModal.vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { sortBotsByPreference, useBotSortPreference } from '@/features/bots/model/useBotSortPreference';
import { parseImageAsset } from '@/features/media/image';
import type { Bot, ImageAsset } from '@/types/api';
import { formatRelativeDateTime } from '@/utils/dates';

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
  value: string;
  name: string;
  label: string;
  image: ImageAsset | null;
  count: number;
  sort_activity_at?: string | null;
  updated_at?: string | null;
  created_at?: string | null;
};

type ChatListBotStat = {
  bot_id: number;
  bot_name: string | null;
  chat_count: number;
};

type ChatListStats = {
  total_chats: number;
  no_bot_chat_count: number;
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
const botSortToggleLabel = computed(() => {
  return botSortModeValue.value === 'recent_activity'
    ? 'Sort: Recent activity. Switch to Name.'
    : 'Sort: Name. Switch to Recent activity.';
});

const isMobile = ref(false);
const isFilterMobile = ref(false);
const filterOpen = ref(true);
const previewLength = computed(() => (isMobile.value ? 100 : 200));

const hasChatSearch = computed(() => chatSearchTerm.value.trim().length > 0);
const hasActiveBotFilter = computed(() => String(botFilter.value || '').trim().length > 0);

function openFilter() {
  filterOpen.value = true;
}

function closeFilter() {
  if (!isFilterMobile.value) return;
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
  if (isFilterMobile.value) filterOpen.value = false;
}

const noBotChatCount = computed(() => {
  const count = chatListStats.value.no_bot_chat_count;
  return Number.isInteger(count) && count > 0 ? count : 0;
});
const showNoBotOption = computed(() => noBotChatCount.value > 0 || botFilter.value === 'none');

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
  isMobile.value = window.matchMedia('(max-width: 720px)').matches;
  isFilterMobile.value = window.matchMedia('(max-width: 900px)').matches;
  filterOpen.value = !isFilterMobile.value;
}

function niceDate(iso: string | null) {
  return formatRelativeDateTime(iso);
}

function chatLabel(chat: ChatSummary) {
  const bot = (chat.bot_name || '').trim() || 'No bot';
  const note = (chat.note || '').trim();
  return note ? `${bot} (${note})` : bot;
}

function previewBubbleClass(role?: ChatSummary['first_message_role']) {
  return {
    'chat-preview--user': role === 'user',
    'chat-preview--assistant': role === 'assistant',
  };
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

function chatResultClass(chat: ChatSummary | ChatSearchResult) {
  if (!isSearchResult(chat)) return {};
  if (chat.match_type === 'meta' || !chat.message_role) return {};
  return {
    'chat-result--user': chat.message_role === 'user',
    'chat-result--assistant': chat.message_role === 'assistant',
  };
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
  botModalValue.value = '';
  botModalOpen.value = true;
  await loadBots({ showError: true });
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
.chat-list-layout {
  display: grid;
  grid-template-columns: 340px 1fr;
  gap: 12px;
  align-items: start;
}

.bot-filter-list {
  gap: 6px;
}

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

.sort-toggle {
  width: 34px;
  min-width: 34px;
  height: 34px;
  border-radius: 10px;
  border: 1px solid #d2d8e2;
  background: #fff;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #4b5563;
  padding: 0;
  line-height: 1;
}

.sort-toggle:hover {
  border-color: #b7c5dc;
}

.sort-toggle.active {
  background: #f1f7ff;
  border-color: #b8d6ff;
  color: #1d4ed8;
}

.bot-filter-item {
  cursor: pointer;
  text-align: left;
  background: #fff;
  padding: 8px 10px;
  justify-content: flex-start;
}

.bot-filter-item.active {
  background: #f1f7ff;
  border-color: #b8d6ff;
}

.bot-filter-name {
  font-weight: 600;
  flex: 1 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
}

.bot-filter-count {
  margin-left: auto;
  flex: 0 0 auto;
}

.chat-search-snippet {
  margin-top: 4px;
  color: #1f2933;
  font-size: 0.9rem;
  line-height: 1.35;
}

.chat-first-preview {
  margin-top: 6px;
}

.chat-first-preview-bubble {
  display: inline-block;
  max-width: 100%;
  padding: 6px 10px;
  border-radius: 12px;
  background: #eef2f7;
  color: #1f2933;
  font-size: 0.9rem;
  line-height: 1.35;
  text-decoration: none;
}

.chat-first-preview-bubble.chat-preview--user {
  background: linear-gradient(135deg, #e7f1ff, #f5f9ff);
}

.chat-first-preview-bubble.chat-preview--assistant {
  background: #f9f9fb;
}

.row:hover .chat-first-preview-bubble {
  text-decoration: none;
}

.chat-result-title {
  display: flex;
  align-items: baseline;
  gap: 6px;
  flex-wrap: wrap;
}

.chat-result-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.chat-result-generating {
  display: inline-flex;
  align-items: center;
  min-height: 18px;
}

.chat-result-name {
  font-weight: 600;
}

.chat-result-badges {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
  justify-content: flex-end;
}

.chat-result--user {
  background: linear-gradient(135deg, #e7f1ff, #f5f9ff);
  border-color: #d7e6ff;
}

.chat-result--assistant {
  background: #f9f9fb;
  border-color: #ececf3;
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

.chat-result-config {
  color: #6b7280;
  font-size: 0.85rem;
}

@media (max-width: 900px) {
  .chat-list-layout {
    grid-template-columns: 1fr;
  }
}
</style>
