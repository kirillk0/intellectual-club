<template>
  <ModalWindow
    max-width="520px"
    :cancel-disabled="saving"
    :submit-disabled="saving"
    :aria-label="title"
    submit-shortcut="auto"
    @keydown="handleModalKeydown"
    @cancel="emit('cancel')"
    @submit="emitSave"
  >
    <div class="modal-header-row">
      <h3 style="margin: 0">{{ title }}</h3>
      <button
        type="button"
        class="sort-toggle"
        :class="{ active: botSortModeValue === 'recent_activity' }"
        :aria-label="botSortToggleLabel"
        :title="botSortToggleLabel"
        @click="toggleBotSortMode"
      >
        <SvgIcon :name="botSortModeValue === 'recent_activity' ? 'sort-time' : 'sort-alpha'" />
      </button>
    </div>
    <div ref="listRef" class="stack" style="max-height: 60vh; overflow: auto">
      <label
        class="row bot-selector-option"
        :class="{ 'bot-selector-option--selected': opt.id === localValue }"
        style="gap: 10px; align-items: center"
        v-for="(opt, index) in choices"
        :key="String(opt.id)"
        :data-bot-option-index="index"
      >
        <input type="radio" name="bot-select" :value="opt.id" v-model="localValue" />
        <span
          v-if="opt.shared_incoming"
          class="muted"
          title="Shared with you"
          aria-label="Shared with you"
          ><SvgIcon name="share-incoming" /></span
        >
        <span
          v-else-if="opt.shared_outgoing"
          class="muted"
          title="Shared with groups"
          aria-label="Shared with groups"
          ><SvgIcon name="share-outgoing" /></span
        >
        <span style="flex: 1">{{ opt.name }}</span>
        <ImageThumbnail :image="opt.image" :label="opt.name" :size="36" :hideWithoutImage="true" />
      </label>
    </div>
    <div class="modal-actions">
      <div class="spacer"></div>
      <button type="button" @click="emit('cancel')" :disabled="saving">Cancel</button>
      <button class="primary" type="button" @click="emitSave" :disabled="saving">
        {{ saving ? savingLabel : confirmLabel }}
      </button>
    </div>
  </ModalWindow>
</template>

<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import ModalWindow from '@/components/ModalWindow.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import {
  sortBotsByPreference,
  useBotSortPreference,
} from '@/features/bots/model/useBotSortPreference';
import type { Bot, ImageAsset } from '@/types/api';

type BotSelectorOption = {
  id: number | string | '';
  name: string;
  image?: ImageAsset | null;
  shared_incoming?: boolean;
  shared_outgoing?: boolean;
  created_at?: string | null;
  updated_at?: string | null;
  sort_activity_at?: string | null;
  pinned?: boolean;
};

interface Props {
  modelValue: number | string | '';
  bots?: Bot[];
  options?: BotSelectorOption[];
  saving?: boolean;
  title?: string;
  confirmLabel?: string;
  savingLabel?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'update:modelValue', value: number | string | ''): void;
  (e: 'save', value: number | string | ''): void;
  (e: 'cancel'): void;
}>();

const localValue = ref<number | string | ''>(props.modelValue);
const listRef = ref<HTMLElement | null>(null);
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

watch(
  () => props.modelValue,
  (val) => {
    localValue.value = val;
  }
);

const emitSave = () => {
  if (saving.value) return;
  emit('update:modelValue', localValue.value);
  emit('save', localValue.value);
};

const focusOption = (index: number) => {
  void nextTick(() => {
    const row = listRef.value?.querySelector<HTMLElement>(`[data-bot-option-index="${index}"]`);
    const input = row?.querySelector<HTMLInputElement>('input[type="radio"]');
    row?.scrollIntoView({ block: 'nearest' });
    input?.focus({ preventScroll: true });
  });
};

const handleModalKeydown = (event: KeyboardEvent) => {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  if (event.altKey || event.ctrlKey || event.metaKey) return;

  event.preventDefault();
  event.stopPropagation();

  const options = choices.value;
  if (!options.length) return;

  const currentIndex = options.findIndex((opt) => opt.id === localValue.value);
  const fallbackIndex = event.key === 'ArrowDown' ? 0 : options.length - 1;
  const nextIndex =
    currentIndex < 0
      ? fallbackIndex
      : event.key === 'ArrowDown'
        ? (currentIndex + 1) % options.length
        : (currentIndex - 1 + options.length) % options.length;

  localValue.value = options[nextIndex]?.id ?? '';
  focusOption(nextIndex);
};

const toggleBotSortMode = () => {
  botSortModeValue.value = botSortModeValue.value === 'recent_activity' ? 'name' : 'recent_activity';
};

const choices = computed<BotSelectorOption[]>(() => {
  const base: BotSelectorOption[] = props.options?.length
    ? props.options
    : [
        { id: '', name: 'No bot' },
        ...(props.bots ?? []).map((b) => ({
          id: b.id,
          name: b.name,
          image: b.image ?? null,
          shared_incoming: b.shared_incoming,
          shared_outgoing: b.shared_outgoing,
          created_at: b.created_at ?? null,
          updated_at: b.updated_at ?? null,
          sort_activity_at: b.sort_activity_at ?? null,
        })),
      ];

  const pinned = base.filter((opt) => opt.pinned);
  const regular = base.filter((opt) => !opt.pinned);

  return [...pinned, ...sortBotsByPreference(regular, botSortMode.value)];
});

const title = computed(() => props.title ?? 'Select bot');
const confirmLabel = computed(() => props.confirmLabel ?? 'Save');
const savingLabel = computed(() => props.savingLabel ?? 'Saving…');
const saving = computed(() => Boolean(props.saving));
</script>

<style scoped>
.modal-header-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 10px;
}

.sort-toggle {
  width: 34px;
  min-width: 34px;
  height: 34px;
  border-radius: 10px;
  border: 1px solid var(--color-border-strong);
  background: var(--color-surface);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--color-text-muted);
  padding: 0;
  line-height: 1;
}

.sort-toggle:hover {
  border-color: var(--color-info-border-strong);
}

.sort-toggle.active {
  background: var(--color-info-bg);
  border-color: var(--color-info-border-strong);
  color: var(--color-info-text);
}

.bot-selector-option {
  border-radius: 8px;
}

.bot-selector-option--selected {
  background: var(--color-surface-muted);
}
</style>
