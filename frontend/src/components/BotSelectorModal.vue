<template>
  <transition name="fade">
    <div class="modal-backdrop" @click.self="emit('cancel')">
      <div class="modal" :style="{ maxWidth: '520px' }">
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
        <div class="stack" style="max-height: 60vh; overflow: auto">
          <label
            class="row"
            style="gap: 10px; align-items: center"
            v-for="opt in choices"
            :key="String(opt.id)"
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
      </div>
    </div>
  </transition>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import ImageThumbnail from '@/components/ImageThumbnail.vue';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import {
  sortBotsByPreference,
  useBotSortPreference,
} from '@/features/bots/model/useBotSortPreference';
import type { Bot, ImageAsset } from '@/types/api';

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

interface Props {
  modelValue: number | '';
  bots?: Bot[];
  options?: BotSelectorOption[];
  saving?: boolean;
  title?: string;
  confirmLabel?: string;
  savingLabel?: string;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'update:modelValue', value: number | ''): void;
  (e: 'save', value: number | ''): void;
  (e: 'cancel'): void;
}>();

const localValue = ref<number | ''>(props.modelValue);
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
  emit('update:modelValue', localValue.value);
  emit('save', localValue.value);
};

const toggleBotSortMode = () => {
  botSortModeValue.value = botSortModeValue.value === 'recent_activity' ? 'name' : 'recent_activity';
};

const choices = computed<BotSelectorOption[]>(() => {
  const base = props.options?.length
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

  return sortBotsByPreference(base, botSortMode.value);
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
</style>
