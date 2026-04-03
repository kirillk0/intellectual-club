<template>
  <section class="sidebar" :class="{ overlay: isMobile, 'align-left': isMobile }">
    <div class="panel-header">
      <h3 style="margin: 0">Context</h3>
      <button
        class="panel-toggle"
        type="button"
        @click="emit('update:leftOpen', false)"
        aria-label="Hide context"
      >
        <SvgIcon name="chevron-left" />
      </button>
    </div>

    <div class="panel-section panel-metrics">
      <template v-if="isAgentHistoryMode">
        <div class="metric-item muted metric-expression">
          <button
            class="link metric-inline-link"
            type="button"
            aria-label="Open prompt details"
            @click="emit('open-prompt-modal')"
          >
            Prompt
          </button>
          <span>{{ promptTokenCount }}</span>
          <span>·</span>
          <span>Context:</span>
          <span>{{ formatStepMetric(agentContextTokenCount) }}</span>
        </div>
      </template>
      <template v-else>
        <div class="metric-item muted metric-expression">
          <span>Context:</span>
          <button
            class="link metric-inline-link"
            type="button"
            aria-label="Open prompt details"
            @click="emit('open-prompt-modal')"
          >
            {{ promptTokenCount }}
          </button>
          <span>+</span>
          <span>{{ historyTokenCount }}</span>
          <span>=</span>
          <span>{{ totalTokenCount }}</span>
        </div>
      </template>

      <div
        v-if="showContextUsageIndicator"
        class="context-usage"
        role="progressbar"
        aria-label="Context usage"
        :aria-valuemin="0"
        :aria-valuemax="100"
        :aria-valuenow="contextUsagePercentRounded"
        :title="contextUsageTitle"
      >
        <div class="context-usage-track">
          <div
            class="context-usage-fill"
            :class="{ warn: isContextSoftLimitReached }"
            :style="{ width: `${contextUsagePercent}%` }"
          ></div>
        </div>
      </div>
    </div>

    <div class="panel-tabs" role="tablist" aria-label="Context tabs">
      <button
        class="panel-tab"
        :class="{ active: leftTab === 'messages' }"
        type="button"
        role="tab"
        :aria-selected="leftTab === 'messages'"
        @click="emit('update:leftTab', 'messages')"
      >
        Messages
      </button>
      <button
        class="panel-tab"
        :class="{ active: leftTab === 'prompt' }"
        type="button"
        role="tab"
        :aria-selected="leftTab === 'prompt'"
        @click="emit('update:leftTab', 'prompt')"
      >
        Prompt
      </button>
    </div>

    <div class="stack panel-body" style="gap: 14px">
      <div v-if="leftTab === 'messages'" class="panel-pane" role="tabpanel">
        <div class="branch-search">
          <input
            :value="branchSearchTerm"
            type="search"
            class="full"
            placeholder="Search messages"
            aria-label="Search messages"
            @input="handleSearchInput"
          />
          <button v-if="branchSearchTerm" type="button" @click="emit('update:branchSearchTerm', '')">
            Clear
          </button>
        </div>

        <div class="stack branch-list">
          <template v-if="hasBranchSearch">
            <div v-if="branchSearchLoading" class="muted">Searching...</div>
            <div v-else>
              <p v-if="branchSearchError" class="error-text">{{ branchSearchError }}</p>

              <div
                v-for="hit in branchSearchResults.active"
                :key="`active-${hit.id}`"
                class="branch-item branch-search-hit"
                :class="hit.role"
                @click="emit('search-result-click', hit, false)"
              >
                <div class="branch-item-main">
                  <div class="branch-item-meta">{{ searchHitMeta(hit) || '—' }}</div>
                  <div class="branch-item-snippet" :title="hit.content">
                    {{ hit.snippet || preview(hit.content) }}
                  </div>
                </div>
              </div>

              <div v-if="branchSearchResults.inactive.length" class="branch-search-divider">
                <div class="branch-search-label">Inactive branch</div>
                <div
                  v-for="hit in branchSearchResults.inactive"
                  :key="`inactive-${hit.id}`"
                  class="branch-item branch-search-hit branch-item--inactive"
                  :class="hit.role"
                  @click="emit('search-result-click', hit, true)"
                >
                  <div class="branch-item-main">
                    <div class="branch-item-meta">{{ searchHitMeta(hit) || '—' }}</div>
                    <div class="branch-item-snippet" :title="hit.content">
                      {{ hit.snippet || preview(hit.content) }}
                    </div>
                  </div>
                </div>
              </div>

              <p
                v-if="!branchSearchError && !branchSearchResults.active.length && !branchSearchResults.inactive.length"
                class="muted"
              >
                No matches found.
              </p>
            </div>
          </template>

          <template v-else>
            <div
              class="branch-item"
              :class="msg.role"
              v-for="(msg, idx) in branch"
              :key="idx"
              @click="emit('branch-item-click', msg.id)"
            >
                <div class="branch-item-main">
                  <div class="branch-item-meta">{{ messageMetaLabel(msg) || '—' }}</div>
                  <div class="branch-item-snippet" :title="messageText(msg)">{{ preview(messageText(msg)) }}</div>
                </div>
              <div v-if="msg.siblings && msg.siblings.length > 1" class="branch-links">
                <span
                  v-for="sib in msg.siblings"
                  :key="sib.id"
                  class="branch-link"
                  :class="{ active: sib.active }"
                  role="button"
                  tabindex="0"
                  @click.stop="!sib.active && emit('switch-branch-target', msg.id!, sib.id)"
                  @keydown.enter.prevent.stop="!sib.active && emit('switch-branch-target', msg.id!, sib.id)"
                >
                  {{ sib.active ? 'Active' : `${sib.size} more…` }}
                </span>
              </div>
            </div>
            <p v-if="!branch.length" class="muted">No messages yet.</p>
          </template>
        </div>
      </div>

      <div v-else class="panel-pane" role="tabpanel">
        <div class="panel-section">
          <h4 style="margin: 0">Blocks</h4>
          <div
            class="row clickable"
            v-for="item in linkedBlocks"
            :key="`${item.block.id}-${item.source}-${item.order}`"
            role="button"
            tabindex="0"
            @click="emit('open-context-block-editor', item.block.id)"
            @keydown.enter.prevent="emit('open-context-block-editor', item.block.id)"
            @keydown.space.prevent="emit('open-context-block-editor', item.block.id)"
          >
            <div>
              <div>{{ item.block.name }}</div>
              <div class="muted">
                {{ item.block.type }} · {{ sourceLabels[item.source] }} ·
                {{ item.block.token_count }} tokens
              </div>
            </div>
            <span v-if="hasBlockVersion(item.block.version)" class="badge">
              {{ formatBlockVersion(item.block.version) }}
            </span>
          </div>
          <p v-if="!linkedBlocks.length" class="muted">No blocks linked.</p>
        </div>

        <div class="panel-section">
          <h4 style="margin: 0">Tools</h4>
          <div v-if="botToolsLoading" class="muted">Loading tools…</div>
          <div v-else-if="botToolsError" class="muted">Failed to load tools.</div>
          <div v-else-if="activeToolInstances.length">
            <div v-for="tool in activeToolInstances" :key="tool.id" class="row">
              <div class="flex" style="gap: 6px; align-items: center; min-width: 0">
                <span
                  v-if="tool.type === 'outlet'"
                  class="status-dot"
                  :class="tool.outlet_online ? 'success' : 'danger'"
                  :title="tool.outlet_online ? 'Online' : 'Offline'"
                />
                <div style="min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">
                  {{ tool.name }}
                </div>
              </div>
            </div>
          </div>
          <p v-else class="muted">No tools active.</p>
        </div>
      </div>
    </div>
  </section>
</template>

<script setup lang="ts">
import type { ChatBranchMessage } from '@/types/api';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import type {
  ActiveToolInstance,
  BranchSearchResults,
  ChatMessageSearchHit,
  LeftPanelTab,
  LinkedBlock,
} from '@/features/chat/types';

interface Props {
  isMobile: boolean;
  leftTab: LeftPanelTab;
  isAgentHistoryMode: boolean;
  agentContextTokenCount: number | null;
  promptTokenCount: number;
  historyTokenCount: number;
  totalTokenCount: number;
  showContextUsageIndicator: boolean;
  contextUsagePercentRounded: number;
  contextUsageTitle: string;
  isContextSoftLimitReached: boolean;
  contextUsagePercent: number;
  branchSearchTerm: string;
  hasBranchSearch: boolean;
  branchSearchLoading: boolean;
  branchSearchError: string;
  branchSearchResults: BranchSearchResults;
  branch: ChatBranchMessage[];
  linkedBlocks: LinkedBlock[];
  sourceLabels: Record<string, string>;
  botToolsLoading: boolean;
  botToolsError: string;
  activeToolInstances: ActiveToolInstance[];
  formatStepMetric: (value: unknown) => string;
  searchHitMeta: (hit: ChatMessageSearchHit) => string;
  messageMetaLabel: (msg: ChatBranchMessage) => string;
  messageText: (msg: ChatBranchMessage) => string;
  preview: (text: string) => string;
  hasBlockVersion: (value: unknown) => boolean;
  formatBlockVersion: (value: unknown) => string;
}

defineProps<Props>();

const emit = defineEmits<{
  (e: 'update:leftOpen', value: boolean): void;
  (e: 'update:leftTab', value: LeftPanelTab): void;
  (e: 'update:branchSearchTerm', value: string): void;
  (e: 'open-prompt-modal'): void;
  (e: 'branch-item-click', id?: number | null): void;
  (e: 'search-result-click', hit: ChatMessageSearchHit, inactive: boolean): void;
  (e: 'switch-branch-target', messageId: number, targetId: number): void;
  (e: 'open-context-block-editor', blockId: number): void;
}>();

const handleSearchInput = (event: Event) => {
  const target = event.target as HTMLInputElement;
  emit('update:branchSearchTerm', target.value);
};
</script>
