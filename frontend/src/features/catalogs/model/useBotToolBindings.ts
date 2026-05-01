import { computed, ref } from 'vue';

import { relationshipId, relatedResource, toIntId, type JsonApiIncludedIndex, type JsonApiResource } from '@/api/jsonApi';
import {
  cloneToolBindings,
  moveToolBindingInList,
  normalizeToolBindingsForCompare,
  normalizeToolBindingSequences,
  removeToolBindingFromList,
  setToolBindingEnabledInList,
  sortToolBindings,
  validateNewToolBinding,
  type BaseToolBinding,
} from '@/features/tools/model/toolBindings';

export type BotToolBindingRow = BaseToolBinding & {
  sharing_mode: string;
};

export function parseBotToolBindingRow(
  resource: JsonApiResource,
  includedIndex?: JsonApiIncludedIndex
): BotToolBindingRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const toolInstanceId =
    relationshipId(resource, 'tool_instance') ??
    (typeof attrs.tool_instance_id === 'number' ? attrs.tool_instance_id : toIntId(attrs.tool_instance_id as any));

  if (!toolInstanceId) return null;

  const toolInstanceResource = includedIndex ? relatedResource(resource, 'tool_instance', includedIndex) : null;
  const toolInstanceAttrs = (toolInstanceResource?.attributes || {}) as Record<string, unknown>;
  const alias = String(attrs.alias || toolInstanceAttrs.alias || '').trim();

  return {
    id,
    alias,
    tool_instance_id: toolInstanceId,
    sharing_mode: String(attrs.sharing_mode || 'shared'),
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
  };
}

export function useBotToolBindings() {
  const originalToolBindings = ref<BotToolBindingRow[]>([]);
  const toolBindings = ref<BotToolBindingRow[]>([]);
  const loading = ref(false);
  const loaded = ref(false);
  const error = ref<string | null>(null);
  let tempToolBindingId = -1;

  const sortedToolBindings = computed(() => sortToolBindings(toolBindings.value || []));
  const perUserBaseBindings = computed(() =>
    sortedToolBindings.value.filter((binding) => binding.sharing_mode === 'per_user')
  );

  const dirty = computed(
    () =>
      JSON.stringify(
        normalizeToolBindingsForCompare(originalToolBindings.value, (binding) => ({
          sharing_mode: binding.sharing_mode || 'shared',
        }))
      ) !==
      JSON.stringify(
        normalizeToolBindingsForCompare(toolBindings.value, (binding) => ({
          sharing_mode: binding.sharing_mode || 'shared',
        }))
      )
  );

  const payload = computed(() => {
    if (!loaded.value) return undefined;

    return sortedToolBindings.value.map((binding) => ({
      ...(binding.id > 0 ? { id: binding.id } : {}),
      tool_instance_id: binding.tool_instance_id,
      sharing_mode: binding.sharing_mode || 'shared',
      enabled: Boolean(binding.enabled),
    }));
  });

  function hydrate(rows: BotToolBindingRow[]) {
    const normalized = normalizeToolBindingSequences(rows || []);
    originalToolBindings.value = cloneToolBindings(normalized);
    toolBindings.value = cloneToolBindings(normalized);
    tempToolBindingId = -1;
    loading.value = false;
    error.value = null;
    loaded.value = true;
  }

  function reset() {
    toolBindings.value = cloneToolBindings(originalToolBindings.value);
    tempToolBindingId = -1;
  }

  function add(toolInstanceId: number, alias: string) {
    const normalizedAlias = String(alias || '').trim();
    const normalizedToolInstanceId = Number(toolInstanceId || 0);

    const validationError = validateNewToolBinding({
      toolInstanceId: normalizedToolInstanceId,
      alias: normalizedAlias,
      bindings: toolBindings.value,
      messages: {
        missingTool: 'Choose a tool instance.',
        duplicateTool: 'Tool is already attached to this bot.',
        duplicateAlias: 'Alias is already used in this bot.',
      },
    });

    if (validationError) {
      window.alert(validationError);
      return false;
    }

    const next = normalizeToolBindingSequences(toolBindings.value);
    toolBindings.value = normalizeToolBindingSequences([
      ...next,
      {
        id: tempToolBindingId--,
        alias: normalizedAlias,
        tool_instance_id: normalizedToolInstanceId,
        sharing_mode: 'shared',
        enabled: true,
        sequence: next.length,
      },
    ]);

    return true;
  }

  function remove(bindingId: number) {
    const binding = toolBindings.value.find((row) => row.id === bindingId);
    toolBindings.value = removeToolBindingFromList(toolBindings.value, bindingId);
    return binding || null;
  }

  function toggle(bindingId: number, enabled: boolean) {
    toolBindings.value = setToolBindingEnabledInList(toolBindings.value, bindingId, enabled);
  }

  function move(bindingId: number, delta: number) {
    toolBindings.value = moveToolBindingInList(toolBindings.value, bindingId, delta);
  }

  return {
    originalToolBindings,
    toolBindings,
    loading,
    loaded,
    error,
    sortedToolBindings,
    perUserBaseBindings,
    dirty,
    payload,
    hydrate,
    reset,
    add,
    remove,
    toggle,
    move,
  };
}
