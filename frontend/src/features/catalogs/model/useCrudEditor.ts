import { computed, onMounted, reactive, ref, watch, type Reactive } from 'vue';
import { useRoute } from 'vue-router';
import type { JsonApiResource, JsonApiSingleResponse } from '@/api/jsonApi';
import {
  jsonApiCreate,
  jsonApiDelete,
  jsonApiGet,
  jsonApiUpdate,
  toIntId,
} from '@/api/jsonApi';
import { useNavigationStack } from '@/features/stack/navigationStack';
import { useStackNavigation } from '@/features/stack/useStackNavigation';
import { appendRecordsetId, removeRecordsetId } from './recordsets';
import { useCrudRecordsetNavigation } from './useCrudRecordsetNavigation';
import { useFormErrors } from './useFormErrors';
import { useJsonDirtyCompare } from './useJsonDirtyCompare';
import { publishJsonApiEntityChange } from '@/features/entities/entityChanges';

function deepClone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

type QueryValue = string | number | boolean | null | undefined;
type CrudFormState<TForm extends Record<string, unknown>> = Reactive<TForm>;
type CrudDirtyForm<TForm extends Record<string, unknown>> = TForm | CrudFormState<TForm>;

function pickQuery(query: Record<string, QueryValue>) {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(query)) {
    if (v === null || v === undefined) continue;
    out[k] = String(v);
  }
  return out;
}

function pickLocationQueryValue(raw: unknown): string | undefined {
  if (Array.isArray(raw)) {
    const first = raw.find((item) => item !== null && item !== undefined);
    return first === null || first === undefined ? undefined : String(first);
  }
  if (raw === null || raw === undefined) return undefined;
  return String(raw);
}

export function useCrudEditor<TForm extends Record<string, unknown>>(options: {
  idParam?: string;
  type: string;
  basePath: string;
  indexPath: string;
  editPath: (id: number | 'new') => string;
  defaultForm: () => TForm;
  fromApi: (resource: JsonApiResource) => Partial<TForm>;
  toAttributes: (form: CrudFormState<TForm>) => Record<string, unknown>;
  normalizeForDirty?: (form: CrudDirtyForm<TForm>) => unknown;
  duplicatePath?: (id: number) => string;
  preserveQueryKeys?: string[];
  documentQuery?: (context: { mode: 'load' | 'save' | 'duplicate' }) => URLSearchParams | undefined;
  onDocument?: (
    payload: JsonApiSingleResponse,
    context: { mode: 'load' | 'save' | 'duplicate' }
  ) => void;
}) {
  const route = useRoute();
  const stack = useNavigationStack();
  const stackNav = useStackNavigation();

  const idKey = options.idParam ?? 'id';

  const idParam = computed(() => route.params[idKey] as string | undefined);
  const isNew = computed(() => !idParam.value || idParam.value === 'new');

  const numericId = computed(() => {
    if (isNew.value) return undefined;
    const id = toIntId(idParam.value);
    return id ?? undefined;
  });

  const recordsetKey = computed(
    () => pickLocationQueryValue(route.query.recordsetKey) ?? pickLocationQueryValue(route.query.navKey)
  );
  const explicitReturnTo = computed(() => pickLocationQueryValue(route.query.returnTo) ?? null);
  const returnTo = computed(() => explicitReturnTo.value);

  const form = reactive<TForm>(options.defaultForm());
  const base = ref<TForm>(deepClone(options.defaultForm()));

  const loaded = ref(false);
  const loading = ref(false);
  const saving = ref(false);
  const deleting = ref(false);
  const duplicating = ref(false);
  const loadError = ref<string | null>(null);

  const errors = useFormErrors();

  const dirty = useJsonDirtyCompare(
    () => (options.normalizeForDirty ? options.normalizeForDirty(form) : form),
    () => (options.normalizeForDirty ? options.normalizeForDirty(base.value) : base.value)
  );

  const editorQuery = computed(() => {
    const query = pickQuery({
      recordsetKey: recordsetKey.value,
    });

    for (const key of options.preserveQueryKeys || []) {
      const value = pickLocationQueryValue(route.query[key]);
      if (value === undefined) continue;
      query[key] = value;
    }

    return query;
  });

  const navigateTo = (id: number) => {
    if (stack.active.value) {
      return stackNav.replace({ path: options.editPath(id), query: editorQuery.value });
    }
    return stackNav.push({ path: options.editPath(id), query: editorQuery.value });
  };

  const { totalCount, positionNumber, navDisabled, goPrev, goNext } = useCrudRecordsetNavigation({
    recordsetKey,
    currentId: numericId,
    isNew,
    navigate: navigateTo,
  });

  const reset = () => {
    Object.assign(form, deepClone(base.value));
    errors.clear();
  };

  const goList = () => {
    if (stack.active.value) {
      stackNav.close();
      return;
    }
    return stackNav.push(returnTo.value || options.indexPath);
  };

  const createNew = () => stackNav.push({ path: options.editPath('new'), query: editorQuery.value });

  const documentQuery = (mode: 'load' | 'save' | 'duplicate') => {
    const params = options.documentQuery?.({ mode });
    return params ? new URLSearchParams(params) : undefined;
  };

  const handleDocument = (payload: JsonApiSingleResponse, mode: 'load' | 'save' | 'duplicate') => {
    options.onDocument?.(payload, { mode });
  };

  const load = async () => {
    errors.clear();
    loadError.value = null;
    loading.value = true;

    try {
      if (isNew.value) {
        Object.assign(form, options.defaultForm());
        base.value = deepClone(options.defaultForm());
        return;
      }

      if (numericId.value === undefined) {
        Object.assign(form, options.defaultForm());
        base.value = deepClone(options.defaultForm());
        loadError.value = 'Invalid id.';
        return;
      }

      const payload = await jsonApiGet(`${options.basePath}/${numericId.value}`, documentQuery('load'));
      const resource = payload.data;
      Object.assign(form, options.fromApi(resource));
      base.value = deepClone(form);
      handleDocument(payload, 'load');
    } catch (error) {
      console.error(error);
      loadError.value = error instanceof Error ? error.message : 'Failed to load record.';
    } finally {
      loading.value = false;
      loaded.value = true;
    }
  };

  const save = async () => {
    if (saving.value) return false;
    errors.clear();
    loadError.value = null;
    saving.value = true;

    try {
      const attrs = options.toAttributes(form);

      if (isNew.value) {
        const created = await jsonApiCreate(options.basePath, options.type, attrs, documentQuery('save'));
        const newId = toIntId(created.data.id);
        Object.assign(form, options.fromApi(created.data));
        base.value = deepClone(form);
        handleDocument(created, 'save');
        publishJsonApiEntityChange('upsert', created.data);

        if (newId) {
          if (recordsetKey.value) appendRecordsetId(recordsetKey.value, newId);
          await stackNav.replace({ path: options.editPath(newId), query: editorQuery.value });
        }
      } else {
        if (numericId.value === undefined) return false;
        const updated = await jsonApiUpdate(
          options.basePath,
          options.type,
          numericId.value,
          attrs,
          documentQuery('save')
        );
        Object.assign(form, options.fromApi(updated.data));
        base.value = deepClone(form);
        handleDocument(updated, 'save');
        publishJsonApiEntityChange('upsert', updated.data);
      }

      return true;
    } catch (error) {
      if (errors.setFromApiError(error)) return false;
      console.error(error);
      alert('Failed to save record.');
      return false;
    } finally {
      saving.value = false;
    }
  };

  const remove = async () => {
    if (deleting.value) return;
    if (isNew.value || numericId.value === undefined) return;
    if (!window.confirm('Delete this record?')) return;
    errors.clear();
    loadError.value = null;
    deleting.value = true;

    try {
      const id = numericId.value;
      await jsonApiDelete(options.basePath, id);
      publishJsonApiEntityChange('delete', { type: options.type, id: String(id) });
      if (recordsetKey.value) removeRecordsetId(recordsetKey.value, id);
      if (stack.active.value) {
        stackNav.close();
      } else {
        await stackNav.replace(returnTo.value || options.indexPath);
      }
    } catch (error) {
      console.error(error);
      alert('Failed to delete record.');
    } finally {
      deleting.value = false;
    }
  };

  const duplicate = async () => {
    if (duplicating.value) return;
    if (isNew.value || numericId.value === undefined) return;
    if (!options.duplicatePath) {
      alert('Duplicate is not available for this record.');
      return;
    }
    duplicating.value = true;
    errors.clear();
    loadError.value = null;

    try {
      const duplicated = await jsonApiCreate(
        options.duplicatePath(numericId.value),
        options.type,
        {},
        documentQuery('duplicate')
      );
      const newId = toIntId(duplicated.data?.id);
      Object.assign(form, options.fromApi(duplicated.data));
      base.value = deepClone(form);
      handleDocument(duplicated, 'duplicate');
      publishJsonApiEntityChange('upsert', duplicated.data);

      if (newId) {
        if (recordsetKey.value) appendRecordsetId(recordsetKey.value, newId);
        await stackNav.replace({ path: options.editPath(newId), query: editorQuery.value });
      }
    } catch (error) {
      if (errors.setFromApiError(error)) return;
      console.error(error);
      alert('Failed to duplicate record.');
    } finally {
      duplicating.value = false;
    }
  };

  onMounted(() => {
    load();
  });

  watch(
    () => idParam.value,
    () => {
      void load();
    }
  );

  return {
    form,
    base,
    loaded,
    loading,
    loadError,
    saving,
    deleting,
    duplicating,
    errors,
    dirty,
    idParam,
    isNew,
    numericId,
    recordsetKey,
    returnTo,
    editorQuery,
    totalCount,
    positionNumber,
    navDisabled,
    goPrev,
    goNext,
    load,
    reset,
    save,
    remove,
    duplicate,
    goList,
    createNew,
  };
}
