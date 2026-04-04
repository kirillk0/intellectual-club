<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>Bookmarks</strong>
      </div>
    </StackToolbarTeleport>

    <section class="card stack">
      <div class="chat-search">
        <input
          v-model="searchTerm"
          type="search"
          class="full"
          placeholder="Search bookmarks"
          aria-label="Search bookmarks"
        />
        <button v-if="searchTerm" type="button" @click="searchTerm = ''">Clear</button>
      </div>
    </section>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="error" class="error-text">{{ error }}</p>

    <section v-else class="card stack bookmarks-list">
      <div class="list">
        <ChatListRow
          v-for="entry in visibleBookmarks"
          :key="entry.bookmark_id"
          :to="bookmarkResultLink(entry)"
          :title="chatLabel(entry.chat)"
          :config-label="entry.chat.llm_configuration_label || null"
          :meta-text="`${niceDate(entry.chat.last_activity_at || entry.chat.created_at || null)} · ${entry.chat.message_count ?? 0} msgs`"
          :secondary-meta="entry.bookmarked_at ? `Bookmarked ${niceDate(entry.bookmarked_at)}` : null"
          :preview-text="entry.preview || 'No preview available.'"
          :preview-role="entry.message_role"
        >
          <template #badges>
            <span v-if="entry.inactive" class="badge badge-muted">Inactive branch</span>
          </template>
        </ChatListRow>
      </div>

      <p v-if="emptyState" class="muted">{{ emptyState }}</p>
    </section>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';

import { api } from '@/api/client';
import ChatListRow from '@/components/ChatListRow.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { formatRelativeDateTime } from '@/utils/dates';

type BookmarkChat = {
  id: number;
  note?: string | null;
  bot_name: string;
  llm_configuration_label?: string | null;
  created_at?: string | null;
  last_activity_at?: string | null;
  message_count?: number | null;
};

type BookmarkEntry = {
  bookmark_id: number;
  bookmarked_at?: string | null;
  inactive: boolean;
  message_id: number;
  message_role?: 'user' | 'assistant' | null;
  preview?: string | null;
  chat: BookmarkChat;
};

const loading = ref(true);
const error = ref<string | null>(null);
const searchTerm = ref('');
const bookmarks = ref<BookmarkEntry[]>([]);

const normalize = (value: unknown) => String(value || '').trim().toLowerCase();

const visibleBookmarks = computed(() => {
  const query = normalize(searchTerm.value);
  if (!query) return bookmarks.value;

  return bookmarks.value.filter((entry) =>
    [
      entry.preview,
      entry.chat.bot_name,
      entry.chat.note,
      entry.chat.llm_configuration_label,
    ].some((value) => normalize(value).includes(query))
  );
});

const emptyState = computed(() => {
  if (searchTerm.value.trim()) return visibleBookmarks.value.length ? '' : 'No matches found.';
  return bookmarks.value.length ? '' : 'No bookmarks yet.';
});

function niceDate(iso: string | null) {
  return formatRelativeDateTime(iso);
}

function chatLabel(chat: BookmarkChat) {
  const bot = (chat.bot_name || '').trim() || 'No bot';
  const note = (chat.note || '').trim();
  return note ? `${bot} (${note})` : bot;
}

function bookmarkResultLink(entry: BookmarkEntry) {
  const query: Record<string, string> = {
    focusMessage: String(entry.message_id),
  };

  if (entry.inactive) {
    query.focusInactive = '1';
  }

  return {
    path: `/chats/${entry.chat.id}`,
    query,
  };
}

async function loadBookmarks() {
  loading.value = true;
  error.value = null;

  try {
    const payload = await api.get<{ bookmarks: BookmarkEntry[] }>('/api/bff/bookmarks');
    bookmarks.value = payload.bookmarks || [];
  } catch (e) {
    console.error(e);
    error.value = e instanceof Error ? e.message : 'Failed to load bookmarks.';
  } finally {
    loading.value = false;
  }
}

onMounted(() => {
  void loadBookmarks();
});
</script>

<style scoped>
.bookmarks-list {
  gap: 10px;
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
</style>
