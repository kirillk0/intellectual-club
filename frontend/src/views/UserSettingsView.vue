<template>
  <div class="stack">
    <StackToolbarTeleport>
      <div class="toolbar fill">
        <strong>User settings</strong>
        <div class="toolbar-actions-right">
          <button class="primary" type="button" :disabled="!dirty || saving || loading" @click="saveAll">
            {{ saving ? 'Saving…' : 'Save' }}
          </button>
        </div>
      </div>
    </StackToolbarTeleport>

    <p v-if="loading" class="muted">Loading…</p>
    <p v-else-if="loadError" class="error-text">{{ loadError }}</p>

    <template v-else>
      <section class="card stack">
        <h3 style="margin: 0">Language</h3>
        <label>
          Language preference
          <select v-model="preferredLocaleDraft" class="full" :disabled="saving">
            <option value="">System/browser</option>
            <option value="en">English</option>
            <option value="ru">Russian</option>
          </select>
        </label>
      </section>

      <section class="card stack">
        <h3 style="margin: 0">Appearance</h3>
        <label>
          Theme preference
          <select v-model="preferredThemeDraft" class="full" :disabled="saving">
            <option value="system">System</option>
            <option value="dark">Dark</option>
            <option value="light">Light</option>
          </select>
        </label>
      </section>

      <section class="card stack">
        <KnowledgeBlockLinksCard
          title="Knowledge blocks"
          :items="cardItems"
          :blockName="blockName"
          :blockImage="blockImage"
          :blockVersion="blockVersion"
          :openable="true"
          :readonly="saving"
          :addDisabled="saving"
          :newDisabled="saving"
          @add="openPicker"
          @new="openNewBlock"
          @open="openBlockEditor"
          @move="move"
          @remove="remove"
          @toggle="toggle"
        >
          <template #note>
            <div class="muted">These blocks are appended to every prompt for your account.</div>
          </template>
        </KnowledgeBlockLinksCard>
      </section>

      <KnowledgeBlocksPickerModal
        v-model:open="pickerOpen"
        v-model:selected="pickerSelection"
        title="Add knowledge blocks"
        :blocks="knowledgeBlocks"
        :disabledBlockIds="linkedBlockIds"
        @confirm="addBlocks"
      />

      <section class="card stack">
        <h3 style="margin: 0">Security</h3>
        <p v-if="passwordFormErrors._form?.length" class="error-text">
          {{ passwordFormErrors._form.join(' ') }}
        </p>

        <label :class="{ 'field-error': hasPasswordFieldError('current_password') }">
          Current password
          <input
            v-model="passwordForm.current_password"
            class="full"
            type="password"
            autocomplete="current-password"
            spellcheck="false"
            @input="clearPasswordFieldError('current_password')"
          />
          <div v-if="hasPasswordFieldError('current_password')" class="error-text">
            {{ passwordFieldError('current_password') }}
          </div>
        </label>

        <label :class="{ 'field-error': hasPasswordFieldError('new_password') }">
          New password
          <input
            v-model="passwordForm.new_password"
            class="full"
            type="password"
            autocomplete="new-password"
            spellcheck="false"
            @input="clearPasswordFieldError('new_password')"
          />
          <div v-if="hasPasswordFieldError('new_password')" class="error-text">
            {{ passwordFieldError('new_password') }}
          </div>
        </label>

        <label :class="{ 'field-error': passwordMismatch || hasPasswordFieldError('new_password_confirm') }">
          Confirm new password
          <input
            v-model="passwordForm.new_password_confirm"
            class="full"
            type="password"
            autocomplete="new-password"
            spellcheck="false"
            @input="clearPasswordFieldError('new_password_confirm')"
          />
          <div v-if="passwordMismatch" class="error-text">Passwords do not match.</div>
          <div v-else-if="hasPasswordFieldError('new_password_confirm')" class="error-text">
            {{ passwordFieldError('new_password_confirm') }}
          </div>
        </label>

        <div class="flex" style="justify-content: flex-end">
          <button class="primary" type="button" :disabled="!canChangePassword || changingPassword" @click="changePassword">
            {{ changingPassword ? 'Changing…' : 'Change password' }}
          </button>
        </div>
      </section>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import KnowledgeBlockLinksCard from '@/components/KnowledgeBlockLinksCard.vue';
import KnowledgeBlocksPickerModal from '@/components/KnowledgeBlocksPickerModal.vue';
import StackToolbarTeleport from '@/components/StackToolbarTeleport.vue';
import { api, isHttpError } from '@/api/client';
import { applySessionUser, useSessionAuth } from '@/features/auth/session';
import { normalizePreferredTheme, type PreferredTheme } from '@/features/app/theme';
import { parseImageAsset } from '@/features/media/image';
import {
  jsonApiCreate,
  jsonApiDelete,
  jsonApiList,
  jsonApiUpdate,
  relationshipId,
  toIntId,
  type JsonApiResource,
} from '@/api/jsonApi';
import type { KnowledgeBlock, SessionUser, UserKnowledgeBlock } from '@/types/api';

type PasswordField = 'current_password' | 'new_password' | 'new_password_confirm' | '_form';
type PasswordFieldErrors = Record<PasswordField, string[]>;
type UserKnowledgeBlockLink = {
  id: number;
  block: number;
  enabled: boolean;
  sequence: number;
};
type LocaleDraft = '' | 'en' | 'ru';
type ThemeDraft = PreferredTheme;

const router = useRouter();
const route = useRoute();
const { currentUser } = useSessionAuth();

const loading = ref(false);
const saving = ref(false);
const changingPassword = ref(false);
const loadError = ref('');

const knowledgeBlocks = ref<KnowledgeBlock[]>([]);
const userBlocks = ref<UserKnowledgeBlock[]>([]);
const pickerOpen = ref(false);
const pickerSelection = ref<number[]>([]);
let nextTempId = -1;

const baseBlocksSnapshot = ref('');
const preferredLocaleDraft = ref<LocaleDraft>('');
const basePreferredLocaleDraft = ref<LocaleDraft>('');
const preferredThemeDraft = ref<ThemeDraft>('system');
const basePreferredThemeDraft = ref<ThemeDraft>('system');

const passwordForm = reactive({
  current_password: '',
  new_password: '',
  new_password_confirm: '',
});

const passwordFormErrors = ref<PasswordFieldErrors>({
  current_password: [],
  new_password: [],
  new_password_confirm: [],
  _form: [],
});

const normalizeUserBlocks = (rows: UserKnowledgeBlock[]) =>
  [...(rows || [])]
    .map((row) => ({
      id: typeof row.id === 'number' ? row.id : null,
      knowledge_block_id: row.knowledge_block_id,
      enabled: Boolean(row.enabled),
      sequence: Number(row.sequence) || 0,
    }))
    .sort((a, b) => a.sequence - b.sequence || String(a.id).localeCompare(String(b.id)));

const snapshotUserBlocks = (rows: UserKnowledgeBlock[]) => JSON.stringify(normalizeUserBlocks(rows));

const blocksDirty = computed(() => snapshotUserBlocks(userBlocks.value) !== baseBlocksSnapshot.value);
const languageDirty = computed(() => preferredLocaleDraft.value !== basePreferredLocaleDraft.value);
const themeDirty = computed(() => preferredThemeDraft.value !== basePreferredThemeDraft.value);
const settingsDirty = computed(() => languageDirty.value || themeDirty.value);
const dirty = computed(() => blocksDirty.value || settingsDirty.value);

const sortedUserBlocks = computed(() => [...(userBlocks.value || [])].sort((a, b) => a.sequence - b.sequence));

const linkedBlockIds = computed(() =>
  userBlocks.value
    .map((row) => row.knowledge_block_id)
    .filter((id): id is number => Number.isFinite(id))
);

const cardItems = computed<UserKnowledgeBlockLink[]>(() =>
  userBlocks.value.map((row) => ({
    id: row.id,
    block: row.knowledge_block_id,
    enabled: row.enabled,
    sequence: row.sequence,
  }))
);

const passwordMismatch = computed(
  () =>
    passwordForm.new_password_confirm.length > 0 &&
    passwordForm.new_password !== passwordForm.new_password_confirm
);

const canChangePassword = computed(
  () =>
    passwordForm.current_password.length > 0 &&
    passwordForm.new_password.length > 0 &&
    passwordForm.new_password_confirm.length > 0 &&
    !passwordMismatch.value
);

const hasPasswordFieldError = (field: PasswordField) => (passwordFormErrors.value[field] || []).length > 0;

const passwordFieldError = (field: PasswordField) => (passwordFormErrors.value[field] || []).join(' ');

const clearPasswordErrors = () => {
  passwordFormErrors.value = {
    current_password: [],
    new_password: [],
    new_password_confirm: [],
    _form: [],
  };
};

const clearPasswordFieldError = (field: PasswordField) => {
  if (!hasPasswordFieldError(field)) return;
  passwordFormErrors.value = {
    ...passwordFormErrors.value,
    [field]: [],
  };
};

const localeDraftFromUser = (user: SessionUser | null | undefined): LocaleDraft => {
  const locale = user?.preferred_locale;
  return locale === 'en' || locale === 'ru' ? locale : '';
};

const themeDraftFromUser = (user: SessionUser | null | undefined): ThemeDraft =>
  normalizePreferredTheme(user?.preferred_theme);

const resetLocaleDraft = () => {
  const draft = localeDraftFromUser(currentUser.value);
  preferredLocaleDraft.value = draft;
  basePreferredLocaleDraft.value = draft;
};

const resetThemeDraft = () => {
  const draft = themeDraftFromUser(currentUser.value);
  preferredThemeDraft.value = draft;
  basePreferredThemeDraft.value = draft;
};

const pushPasswordError = (field: PasswordField, message: string) => {
  const next = { ...passwordFormErrors.value };
  next[field] = [...(next[field] || []), message];
  passwordFormErrors.value = next;
};

const parseKnowledgeBlock = (resource: JsonApiResource): KnowledgeBlock | null => {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const tokenCountRaw = attrs.token_count;
  const tokenCount =
    typeof tokenCountRaw === 'number'
      ? tokenCountRaw
      : Number.isFinite(Number(tokenCountRaw))
        ? Number(tokenCountRaw)
        : 0;

  return {
    id,
    name: String(attrs.name || '').trim() || `Block #${id}`,
    image: parseImageAsset(attrs.image),
    version: attrs.version == null ? null : String(attrs.version),
    token_count: tokenCount,
  };
};

const parseUserKnowledgeBlock = (
  resource: JsonApiResource,
  fallback?: Partial<UserKnowledgeBlock>
): UserKnowledgeBlock | null => {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;

  const knowledgeBlockId =
    relationshipId(resource, 'knowledge_block') ??
    (typeof attrs.knowledge_block_id === 'number'
      ? attrs.knowledge_block_id
      : toIntId(attrs.knowledge_block_id as string | number | null | undefined)) ??
    (typeof fallback?.knowledge_block_id === 'number' ? fallback.knowledge_block_id : null);

  if (!knowledgeBlockId) return null;

  const sequence =
    typeof attrs.sequence === 'number'
      ? attrs.sequence
      : Number.isFinite(Number(attrs.sequence))
        ? Number(attrs.sequence)
        : typeof fallback?.sequence === 'number'
          ? fallback.sequence
          : 0;

  return {
    id,
    knowledge_block_id: knowledgeBlockId,
    enabled: typeof attrs.enabled === 'boolean' ? attrs.enabled : Boolean(fallback?.enabled),
    sequence,
  };
};

const blockMap = computed(() => {
  const map = new Map<number, KnowledgeBlock>();
  for (const block of knowledgeBlocks.value || []) {
    map.set(block.id, block);
  }
  return map;
});

const blockName = (blockId: number) => blockMap.value.get(blockId)?.name || `Block #${blockId}`;
const blockImage = (blockId: number) => blockMap.value.get(blockId)?.image || null;

const blockVersion = (blockId: number) => {
  const raw = (blockMap.value.get(blockId)?.version || '').trim();
  return raw || undefined;
};

const openPicker = () => {
  pickerSelection.value = [];
  pickerOpen.value = true;
};

const openBlockEditor = (blockId: number) => {
  if (!blockId) return;
  router.push({ path: `/catalogs/knowledge-blocks/${blockId}`, query: { returnTo: route.fullPath } });
};

const openNewBlock = () => {
  router.push({ path: '/catalogs/knowledge-blocks/new', query: { returnTo: route.fullPath } });
};

const addBlocks = (blockIds: number[]) => {
  const existing = new Set(linkedBlockIds.value);
  const toAdd = (blockIds || []).filter((id) => id && !existing.has(id));
  if (!toAdd.length) return;

  const baseSequence = Math.max(-1, ...userBlocks.value.map((row) => row.sequence || 0)) + 1;
  const added = toAdd.map((knowledgeBlockId, idx) => ({
    id: nextTempId--,
    knowledge_block_id: knowledgeBlockId,
    enabled: true,
    sequence: baseSequence + idx,
  }));

  userBlocks.value = [...userBlocks.value, ...added];
};

const move = (item: UserKnowledgeBlockLink, delta: number) => {
  const rows = sortedUserBlocks.value;
  const index = rows.findIndex((row) => row.id === item.id);
  if (index < 0) return;

  const target = index + delta;
  if (target < 0 || target >= rows.length) return;

  const next = [...rows];
  const tmp = next[index].sequence;
  next[index].sequence = next[target].sequence;
  next[target].sequence = tmp;
  userBlocks.value = next;
};

const remove = (id: number) => {
  userBlocks.value = userBlocks.value.filter((row) => row.id !== id);
};

const toggle = (item: UserKnowledgeBlockLink, enabled: boolean) => {
  userBlocks.value = userBlocks.value.map((row) =>
    row.id === item.id ? { ...row, enabled } : row
  );
};

const saveAll = async () => {
  if (saving.value || !dirty.value) return;
  saving.value = true;

  try {
    if (blocksDirty.value) {
      const desired = sortedUserBlocks.value.map((row, idx) => ({ ...row, sequence: idx }));
      const desiredPersistedIds = new Set(
        desired.map((row) => row.id).filter((id): id is number => typeof id === 'number' && id > 0)
      );
      const persistedBase = normalizeUserBlocks(JSON.parse(baseBlocksSnapshot.value || '[]'));
      const removedIds = persistedBase
        .map((row) => row.id)
        .filter((id): id is number => typeof id === 'number' && id > 0 && !desiredPersistedIds.has(id));

      await Promise.all(removedIds.map((id) => jsonApiDelete('/api/ash/user-knowledge-blocks', id)));

      const upserted = await Promise.all(
        desired.map(async (row, idx) => {
          if (typeof row.id === 'number' && row.id > 0) {
            const updated = await jsonApiUpdate(
              '/api/ash/user-knowledge-blocks',
              'user-knowledge-blocks',
              row.id,
              {
                enabled: Boolean(row.enabled),
                sequence: idx,
              }
            );
            return parseUserKnowledgeBlock(updated.data, row);
          }

          const created = await jsonApiCreate('/api/ash/user-knowledge-blocks', 'user-knowledge-blocks', {
            knowledge_block_id: row.knowledge_block_id,
            enabled: Boolean(row.enabled),
            sequence: idx,
          });
          return parseUserKnowledgeBlock(created.data, row);
        })
      );

      userBlocks.value = upserted.filter((row): row is UserKnowledgeBlock => Boolean(row));
      baseBlocksSnapshot.value = snapshotUserBlocks(userBlocks.value);
    }

    if (settingsDirty.value) {
      const payload = await api.patch<{ user: SessionUser }>('/api/bff/me', {
        preferred_locale: preferredLocaleDraft.value || null,
        preferred_theme: preferredThemeDraft.value,
      });
      applySessionUser(payload.user);
      preferredLocaleDraft.value = localeDraftFromUser(payload.user);
      basePreferredLocaleDraft.value = preferredLocaleDraft.value;
      preferredThemeDraft.value = themeDraftFromUser(payload.user);
      basePreferredThemeDraft.value = preferredThemeDraft.value;
    }
  } catch (error) {
    console.error(error);
    alert('Failed to save user settings.');
  } finally {
    saving.value = false;
  }
};

const applyPasswordErrors = (value: unknown) => {
  if (!value || typeof value !== 'object') return false;
  const payload = value as { errors?: unknown; detail?: unknown };
  const errors = payload.errors;
  if (!errors || typeof errors !== 'object') return false;

  clearPasswordErrors();

  for (const [key, messages] of Object.entries(errors as Record<string, unknown>)) {
    const field = key as PasswordField;
    const normalizedMessages = Array.isArray(messages)
      ? messages.map((msg) => String(msg || '').trim()).filter(Boolean)
      : [String(messages || '').trim()].filter(Boolean);

    if (!normalizedMessages.length) continue;
    for (const message of normalizedMessages) {
      if (
        field === 'current_password' ||
        field === 'new_password' ||
        field === 'new_password_confirm' ||
        field === '_form'
      ) {
        pushPasswordError(field, message);
      } else {
        pushPasswordError('_form', message);
      }
    }
  }

  if (!passwordFormErrors.value._form.length && typeof payload.detail === 'string' && payload.detail.trim()) {
    pushPasswordError('_form', payload.detail.trim());
  }

  return true;
};

const changePassword = async () => {
  if (changingPassword.value || !canChangePassword.value) return;

  clearPasswordErrors();
  changingPassword.value = true;

  try {
    await api.post('/api/bff/me/change-password', {
      current_password: passwordForm.current_password,
      new_password: passwordForm.new_password,
      new_password_confirm: passwordForm.new_password_confirm,
    });

    passwordForm.current_password = '';
    passwordForm.new_password = '';
    passwordForm.new_password_confirm = '';
    alert('Password changed.');
  } catch (error) {
    if (isHttpError(error) && applyPasswordErrors(error.bodyJson)) return;
    console.error(error);
    alert('Failed to change password.');
  } finally {
    changingPassword.value = false;
  }
};

const loadSettings = async () => {
  loading.value = true;
  loadError.value = '';

  try {
    const blockParams = new URLSearchParams();
    blockParams.set('sort', 'name');
    blockParams.set('fields[knowledge-blocks]', 'name,version,token_count,image');

    const [blocksPayload, userBlocksPayload] = await Promise.all([
      jsonApiList('/api/ash/knowledge-blocks', blockParams),
      jsonApiList('/api/ash/user-knowledge-blocks'),
    ]);

    knowledgeBlocks.value = (blocksPayload.data || [])
      .map(parseKnowledgeBlock)
      .filter((row): row is KnowledgeBlock => Boolean(row));

    userBlocks.value = (userBlocksPayload.data || [])
      .map((resource) => parseUserKnowledgeBlock(resource))
      .filter((row): row is UserKnowledgeBlock => Boolean(row));

    baseBlocksSnapshot.value = snapshotUserBlocks(userBlocks.value);
    resetLocaleDraft();
    resetThemeDraft();
  } catch (error) {
    console.error(error);
    loadError.value = error instanceof Error ? error.message : 'Failed to load user settings.';
  } finally {
    loading.value = false;
  }
};

onMounted(() => {
  loadSettings();
});

watch(
  () => currentUser.value?.preferred_locale,
  () => {
    if (!languageDirty.value) resetLocaleDraft();
  }
);

watch(
  () => currentUser.value?.preferred_theme,
  () => {
    if (!themeDirty.value) resetThemeDraft();
  }
);
</script>
