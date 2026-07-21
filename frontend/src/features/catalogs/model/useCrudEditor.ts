import { computed, reactive, ref, watch, type Reactive } from 'vue';
import { useQuery } from '@tanstack/vue-query';
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
import { serverStateKeys, serverStateQueryClient } from '@/features/serverState/queryClient';

function deepClone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

type QueryValue = string | number | boolean | null | undefined;
type CrudFormState<TForm extends Record<string, unknown>> = Reactive<TForm>;
type CrudDirtyForm<TForm extends Record<string, unknown>> = TForm | CrudFormState<TForm>;

export type CrudEditorLayerChange = {
  type: string;
  id: number;
  operation: 'upsert' | 'delete';
};

export type CrudEditorLayerResult = {
  changes: CrudEditorLayerChange[];
};

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
  const remoteUpdateAvailable = ref(false);
  const remoteDocument = ref<JsonApiSingleResponse | null>(null);
  const externalDirtySources: Array<() => boolean> = [];
  let canonicalFingerprint = '';
  let dismissedRemoteFingerprint = '';
  let sessionVersion = 0;

  const errors = useFormErrors();

  const dirty = useJsonDirtyCompare(
    () => (options.normalizeForDirty ? options.normalizeForDirty(form) : form),
    () => (options.normalizeForDirty ? options.normalizeForDirty(base.value) : base.value)
  );

  const hasDirtyDraft = () => dirty.value || externalDirtySources.some((source) => source());

  const registerDirtySource = (source: () => boolean) => {
    externalDirtySources.push(source);
    return () => {
      const index = externalDirtySources.indexOf(source);
      if (index >= 0) externalDirtySources.splice(index, 1);
    };
  };

  const recordLayerChange = (change: CrudEditorLayerChange) => {
    stackNav.updateLayerResult<CrudEditorLayerResult>((current) => ({
      changes: [
        ...(current?.changes || []).filter(
          (item) => item.type !== change.type || item.id !== change.id
        ),
        change,
      ],
    }));
  };

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

  const createNew = () => stackNav.replace({ path: options.editPath('new'), query: editorQuery.value });

  const documentQuery = (mode: 'load' | 'save' | 'duplicate') => {
    const params = options.documentQuery?.({ mode });
    return params ? new URLSearchParams(params) : undefined;
  };

  const handleDocument = (payload: JsonApiSingleResponse, mode: 'load' | 'save' | 'duplicate') => {
    options.onDocument?.(payload, { mode });
  };

  const documentFingerprint = (payload: JsonApiSingleResponse) => JSON.stringify(payload);

  const detailQueryKey = computed(() =>
    serverStateKeys.detail(options.type, numericId.value ?? 'new', 'editor-document')
  );

  const detailQuery = useQuery<JsonApiSingleResponse>({
    queryKey: detailQueryKey,
    enabled: computed(() => numericId.value !== undefined && !deleting.value),
    queryFn: ({ queryKey, signal }) => {
      const requestedId = toIntId(String(queryKey[3] ?? ''));
      if (!requestedId) throw new Error('Invalid id.');
      return jsonApiGet(`${options.basePath}/${requestedId}`, documentQuery('load'), { signal });
    },
  });

  const applyCanonicalDocument = (
    payload: JsonApiSingleResponse,
    mode: 'load' | 'save' | 'duplicate'
  ) => {
    Object.assign(form, deepClone(options.defaultForm()), options.fromApi(payload.data));
    base.value = deepClone(form);
    handleDocument(payload, mode);
    canonicalFingerprint = documentFingerprint(payload);
    dismissedRemoteFingerprint = '';
    remoteDocument.value = null;
    remoteUpdateAvailable.value = false;
    loadError.value = null;
    loading.value = false;
    loaded.value = true;
  };

  const startSession = () => {
    sessionVersion += 1;
    errors.clear();
    loadError.value = null;
    remoteDocument.value = null;
    remoteUpdateAvailable.value = false;
    canonicalFingerprint = '';
    dismissedRemoteFingerprint = '';
    Object.assign(form, deepClone(options.defaultForm()));
    base.value = deepClone(options.defaultForm());

    if (isNew.value) {
      loading.value = false;
      loaded.value = true;
      return;
    }

    if (numericId.value === undefined) {
      loading.value = false;
      loaded.value = true;
      loadError.value = 'Invalid id.';
      return;
    }

    loading.value = true;
    loaded.value = false;
  };

  const applyQueryDocument = (payload: JsonApiSingleResponse | undefined) => {
    if (!payload || numericId.value === undefined) return;
    if (toIntId(payload.data.id) !== numericId.value) return;

    const nextFingerprint = documentFingerprint(payload);
    if (nextFingerprint === canonicalFingerprint) {
      loading.value = false;
      loaded.value = true;
      return;
    }

    if (!loaded.value || loading.value) {
      applyCanonicalDocument(payload, 'load');
      return;
    }

    if (saving.value) return;

    if (hasDirtyDraft()) {
      if (nextFingerprint === dismissedRemoteFingerprint) return;
      remoteDocument.value = payload;
      remoteUpdateAvailable.value = true;
      return;
    }

    applyCanonicalDocument(payload, 'load');
  };

  const load = async () => {
    startSession();
    if (numericId.value === undefined) return;
    await detailQuery.refetch({ cancelRefetch: true });
  };

  const reloadRemoteDocument = async () => {
    const pending = remoteDocument.value;
    if (pending) {
      applyCanonicalDocument(pending, 'load');
    }

    if (numericId.value !== undefined) {
      const result = await detailQuery.refetch({ cancelRefetch: true });
      if (result.data) applyCanonicalDocument(result.data, 'load');
    }
  };

  const keepEditingRemoteDocument = () => {
    if (remoteDocument.value) dismissedRemoteFingerprint = documentFingerprint(remoteDocument.value);
    remoteDocument.value = null;
    remoteUpdateAvailable.value = false;
  };

  watch(
    () => idParam.value,
    () => startSession(),
    { immediate: true }
  );

  watch(
    () => detailQuery.data.value,
    (payload) => {
      const observedSession = sessionVersion;
      queueMicrotask(() => {
        if (observedSession !== sessionVersion) return;
        applyQueryDocument(payload);
      });
    },
    { immediate: true }
  );

  watch(
    () => detailQuery.error.value,
    (error) => {
      if (!error || !loading.value) return;
      console.error(error);
      loadError.value = error instanceof Error ? error.message : 'Failed to load record.';
      loading.value = false;
      loaded.value = true;
    }
  );

  const save = async () => {
    if (saving.value) return false;
    const writeSession = sessionVersion;
    const writeId = numericId.value;
    errors.clear();
    loadError.value = null;
    saving.value = true;

    try {
      const attrs = options.toAttributes(form);

      if (isNew.value) {
        const created = await jsonApiCreate(options.basePath, options.type, attrs, documentQuery('save'));
        if (sessionVersion !== writeSession) return false;
        const newId = toIntId(created.data.id);
        if (newId) {
          serverStateQueryClient.setQueryData(
            serverStateKeys.detail(options.type, newId, 'editor-document'),
            created
          );
          recordLayerChange({ type: options.type, id: newId, operation: 'upsert' });
        }
        applyCanonicalDocument(created, 'save');

        if (newId) {
          if (recordsetKey.value) appendRecordsetId(recordsetKey.value, newId);
          await stackNav.replace({ path: options.editPath(newId), query: editorQuery.value });
        }
      } else {
        if (writeId === undefined) return false;
        const updated = await jsonApiUpdate(
          options.basePath,
          options.type,
          writeId,
          attrs,
          documentQuery('save')
        );
        if (sessionVersion !== writeSession || numericId.value !== writeId) return false;
        serverStateQueryClient.setQueryData(detailQueryKey.value, updated);
        applyCanonicalDocument(updated, 'save');
        recordLayerChange({ type: options.type, id: writeId, operation: 'upsert' });
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
    let deleteSucceeded = false;

    try {
      const id = numericId.value;
      await jsonApiDelete(options.basePath, id);
      deleteSucceeded = true;
      recordLayerChange({ type: options.type, id, operation: 'delete' });
      serverStateQueryClient.removeQueries({
        queryKey: serverStateKeys.detail(options.type, id, 'editor-document'),
        exact: true,
      });
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
      if (!deleteSucceeded) deleting.value = false;
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
    const duplicateSession = sessionVersion;
    const sourceId = numericId.value;
    errors.clear();
    loadError.value = null;

    try {
      const duplicated = await jsonApiCreate(
        options.duplicatePath(sourceId),
        options.type,
        {},
        documentQuery('duplicate')
      );
      if (sessionVersion !== duplicateSession || numericId.value !== sourceId) return;
      const newId = toIntId(duplicated.data?.id);
      if (newId) {
        serverStateQueryClient.setQueryData(
          serverStateKeys.detail(options.type, newId, 'editor-document'),
          duplicated
        );
        recordLayerChange({ type: options.type, id: newId, operation: 'upsert' });
      }
      applyCanonicalDocument(duplicated, 'duplicate');

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

  return {
    form,
    base,
    loaded,
    loading,
    loadError,
    remoteUpdateAvailable,
    saving,
    deleting,
    duplicating,
    errors,
    dirty,
    registerDirtySource,
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
    reloadRemoteDocument,
    keepEditingRemoteDocument,
    reset,
    save,
    remove,
    duplicate,
    goList,
    createNew,
  };
}
