<template>
  <div v-if="loaded" class="stack">
    <CrudHeader
      title="Knowledge Tag"
      :dirty="headerDirty"
      :position="positionNumber"
      :total="totalCount"
      :navDisabled="navDisabled"
      :showDelete="!isNew"
      :showDuplicate="false"
      :saving="saving"
      @save="save"
      @cancel="reset"
      @close="goList"
      @create="createNew"
      @prev="goPrev"
      @next="goNext"
      @delete="remove"
    />

    <p v-if="loadError" class="error-text">{{ loadError }}</p>

    <fieldset class="stack" :disabled="loading || saving || Boolean(loadError)">
      <div v-if="loading" class="loading-float" aria-live="polite">Loading…</div>
      <div class="card stack">
        <div v-if="errors.formErrors.length" class="error-text">{{ errors.formErrors.join(' ') }}</div>

        <label :class="{ 'field-error': errors.hasField('name') }">
          Name
          <input v-model="form.name" class="full" @input="errors.clearField('name')" />
          <div v-if="errors.hasField('name')" class="error-text">{{ errors.messageFor('name') }}</div>
        </label>

        <label :class="{ 'field-error': errors.hasField('parent_id') }">
          Parent
          <select v-model="parentModel" class="full" @change="errors.clearField('parent_id')">
            <option :value="''">(none)</option>
            <option v-for="t in parentOptions" :key="t.id" :value="String(t.id)">
              {{ t.full_name || t.name }}
            </option>
          </select>
          <div v-if="errors.hasField('parent_id')" class="error-text">{{ errors.messageFor('parent_id') }}</div>
        </label>
      </div>

      <div class="card stack">
        <div style="font-weight: 700">Details</div>
        <div class="muted">Full name</div>
        <div>{{ form.full_name || '(calculated on save)' }}</div>
      </div>
    </fieldset>
  </div>

  <p v-else class="muted">Loading…</p>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import CrudHeader from '@/components/CrudHeader.vue';
import { useCrudEditor } from '@/features/catalogs/model/useCrudEditor';
import { useUnsavedChangesGuard } from '@/features/catalogs/model/useUnsavedChangesGuard';
import type { JsonApiResource } from '@/api/jsonApi';
import { jsonApiList, relationshipId, toIntId } from '@/api/jsonApi';

type KnowledgeTagForm = {
  name: string;
  parent_id: number | null;
  full_name: string;
};

type KnowledgeTagOption = { id: number; name: string; full_name: string };

function fromApi(resource: JsonApiResource): Partial<KnowledgeTagForm> {
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  return {
    name: String(attrs.name || ''),
    parent_id:
      (typeof attrs.parent_id === 'number' ? attrs.parent_id : toIntId(attrs.parent_id as any)) ??
      relationshipId(resource, 'parent'),
    full_name: String(attrs.full_name || ''),
  };
}

const editor = useCrudEditor<KnowledgeTagForm>({
  type: 'knowledge-tags',
  basePath: '/api/ash/knowledge-tags',
  indexPath: '/catalogs/knowledge-tags',
  editPath: (id) => `/catalogs/knowledge-tags/${id}`,
  defaultForm: () => ({
    name: '',
    parent_id: null,
    full_name: '',
  }),
  fromApi,
  toAttributes: (form) => ({
    name: form.name,
    parent_id: form.parent_id,
  }),
  normalizeForDirty: (form) => ({
    name: form.name,
    parent_id: form.parent_id,
  }),
});

useUnsavedChangesGuard(editor.dirty);

const form = editor.form;
const errors = editor.errors;
const isNew = editor.isNew;
const loaded = editor.loaded;
const loading = editor.loading;
const loadError = editor.loadError;
const saving = editor.saving;
const dirty = editor.dirty;
const headerDirty = computed(() => dirty.value && !loading.value && !loadError.value);
const totalCount = editor.totalCount;
const positionNumber = editor.positionNumber;
const navDisabled = editor.navDisabled;
const goPrev = editor.goPrev;
const goNext = editor.goNext;
const save = editor.save;
const reset = editor.reset;
const remove = editor.remove;
const createNew = editor.createNew;
const goList = editor.goList;

const allTags = ref<KnowledgeTagOption[]>([]);

const parentOptions = computed(() => {
  const selfId = editor.numericId.value;
  const list = allTags.value || [];
  if (!selfId) return list;
  return list.filter((t) => t.id !== selfId);
});

const parentModel = computed({
  get: () => (form.parent_id ? String(form.parent_id) : ''),
  set: (value: string) => {
    form.parent_id = value ? Number(value) : null;
  },
});

async function loadTagOptions() {
  try {
    const qs = new URLSearchParams();
    qs.set('sort', 'full_name');
    const payload = await jsonApiList('/api/ash/knowledge-tags', qs);
    allTags.value = (payload.data || [])
      .map((r) => {
        const id = toIntId(r.id);
        if (!id) return null;
        const attrs = (r.attributes || {}) as Record<string, unknown>;
        return {
          id,
          name: String(attrs.name || ''),
          full_name: String(attrs.full_name || ''),
        } satisfies KnowledgeTagOption;
      })
      .filter((t): t is KnowledgeTagOption => Boolean(t));
  } catch (e) {
    console.warn('Failed to load tag options', e);
  }
}

onMounted(() => {
  loadTagOptions();
});

watch(
  () => editor.numericId.value,
  () => {
    if (!loaded.value) return;
    loadTagOptions();
  }
);
</script>
