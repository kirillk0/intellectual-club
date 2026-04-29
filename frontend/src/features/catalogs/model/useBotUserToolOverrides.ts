import { ref, type Ref } from 'vue';

import { jsonApiCreate, jsonApiDelete, jsonApiUpdate, relationshipId, toIntId, type JsonApiResource } from '@/api/jsonApi';
import { sortToolBindings } from '@/features/tools/model/toolBindings';
import type { ToolInstanceOption } from '@/types/api';
import type { BotToolBindingRow } from './useBotToolBindings';

export type BotUserToolBindingRow = {
  id: number;
  alias: string;
  tool_instance_id: number;
  enabled: boolean;
  sequence: number;
};

export type BotUserToolBindingDraft = {
  binding_id: number | null;
  tool_instance_id: number;
  enabled: boolean;
  sequence: number;
};

export function parseBotUserToolBindingRow(resource: JsonApiResource): BotUserToolBindingRow | null {
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const toolInstanceId =
    relationshipId(resource, 'tool_instance') ??
    (typeof attrs.tool_instance_id === 'number' ? attrs.tool_instance_id : toIntId(attrs.tool_instance_id as any));

  if (!toolInstanceId) return null;

  return {
    id,
    alias: String(attrs.alias || '').trim(),
    tool_instance_id: toolInstanceId,
    enabled: Boolean(attrs.enabled),
    sequence: typeof attrs.sequence === 'number' ? attrs.sequence : Number(attrs.sequence || 0),
  };
}

export function useBotUserToolOverrides(params: {
  botId: Readonly<Ref<number | null | undefined>>;
  ownedToolLibrary: Readonly<Ref<ToolInstanceOption[]>>;
  toolLabel: (toolInstanceId: number) => string;
}) {
  const loading = ref(false);
  const error = ref<string | null>(null);
  const userToolBindings = ref<BotUserToolBindingRow[]>([]);
  const userToolBindingDrafts = ref<Record<string, BotUserToolBindingDraft>>({});
  const savingAliases = ref(new Set<string>());

  function hydrate(rows: BotUserToolBindingRow[]) {
    userToolBindings.value = sortToolBindings(rows || []);
    loading.value = false;
    error.value = null;
  }

  function resetForNewBot() {
    userToolBindings.value = [];
    userToolBindingDrafts.value = {};
    loading.value = false;
    error.value = null;
  }

  function syncDrafts(perUserBaseBindings: BotToolBindingRow[]) {
    const existingByAlias = new Map<string, BotUserToolBindingRow>();

    for (const binding of userToolBindings.value || []) {
      if (binding.alias) existingByAlias.set(binding.alias, binding);
    }

    const nextDrafts: Record<string, BotUserToolBindingDraft> = {};

    for (const binding of perUserBaseBindings || []) {
      const existing = existingByAlias.get(binding.alias);
      const previous = userToolBindingDrafts.value[binding.alias];

      nextDrafts[binding.alias] = {
        binding_id: existing?.id ?? null,
        tool_instance_id: existing?.tool_instance_id ?? previous?.tool_instance_id ?? 0,
        enabled: existing?.enabled ?? previous?.enabled ?? true,
        sequence: binding.sequence,
      };
    }

    userToolBindingDrafts.value = nextDrafts;
  }

  function userToolDraft(alias: string): BotUserToolBindingDraft {
    return (
      userToolBindingDrafts.value[alias] || {
        binding_id: null,
        tool_instance_id: 0,
        enabled: true,
        sequence: 0,
      }
    );
  }

  function setDraft(alias: string, patch: Partial<BotUserToolBindingDraft>) {
    userToolBindingDrafts.value = {
      ...userToolBindingDrafts.value,
      [alias]: {
        ...userToolDraft(alias),
        ...patch,
      },
    };
  }

  function setDraftTool(alias: string, toolInstanceId: number) {
    setDraft(alias, { tool_instance_id: toolInstanceId > 0 ? toolInstanceId : 0 });
  }

  function toggleDraftEnabled(alias: string, enabled: boolean) {
    setDraft(alias, { enabled });
  }

  function label(alias: string) {
    const draft = userToolDraft(alias);
    if (!draft.tool_instance_id) return 'No tool selected';
    return params.toolLabel(draft.tool_instance_id);
  }

  async function saveOverride(binding: BotToolBindingRow) {
    const botId = params.botId.value;
    if (!botId) return;

    const alias = binding.alias;
    const draft = userToolDraft(alias);

    if (!draft.tool_instance_id) {
      window.alert('Choose your tool first.');
      return;
    }

    if (!params.ownedToolLibrary.value.some((tool) => tool.id === draft.tool_instance_id)) {
      window.alert('Choose one of your editable tools.');
      return;
    }

    savingAliases.value = new Set([...savingAliases.value, alias]);

    try {
      const existing = userToolBindings.value.find((row) => row.alias === alias) || null;
      const payload = {
        bot_id: botId,
        tool_instance_id: draft.tool_instance_id,
        alias,
        enabled: draft.enabled,
        sequence: binding.sequence,
      };

      if (existing && existing.tool_instance_id === draft.tool_instance_id) {
        await jsonApiUpdate('/api/ash/bot-user-tool-bindings', 'bot-user-tool-bindings', existing.id, {
          alias,
          enabled: draft.enabled,
          sequence: binding.sequence,
        });

        userToolBindings.value = sortToolBindings(
          userToolBindings.value.map((row) =>
            row.id === existing.id
              ? {
                  ...row,
                  alias,
                  enabled: draft.enabled,
                  sequence: binding.sequence,
                }
              : row
          )
        );
      } else {
        if (existing) {
          await jsonApiDelete('/api/ash/bot-user-tool-bindings', existing.id);
        }

        const created = await jsonApiCreate('/api/ash/bot-user-tool-bindings', 'bot-user-tool-bindings', payload);
        const createdId = toIntId(created.data.id);

        userToolBindings.value = sortToolBindings([
          ...userToolBindings.value.filter((row) => row.alias !== alias),
          ...(createdId
            ? [
                {
                  id: createdId,
                  alias,
                  tool_instance_id: draft.tool_instance_id,
                  enabled: draft.enabled,
                  sequence: binding.sequence,
                } satisfies BotUserToolBindingRow,
              ]
            : []),
        ]);
      }
    } catch (saveError) {
      console.error(saveError);
      window.alert(saveError instanceof Error ? saveError.message : 'Failed to save your tool override.');
    } finally {
      const next = new Set(savingAliases.value);
      next.delete(alias);
      savingAliases.value = next;
    }
  }

  async function removeOverride(binding: BotToolBindingRow) {
    const alias = binding.alias;
    const existing = userToolBindings.value.find((row) => row.alias === alias);

    if (!existing) {
      setDraft(alias, { binding_id: null, tool_instance_id: 0, enabled: true, sequence: binding.sequence });
      return;
    }

    if (!window.confirm('Remove your personal tool override for this alias?')) return;

    savingAliases.value = new Set([...savingAliases.value, alias]);

    try {
      await jsonApiDelete('/api/ash/bot-user-tool-bindings', existing.id);
      userToolBindings.value = userToolBindings.value.filter((row) => row.id !== existing.id);
      setDraft(alias, { binding_id: null, tool_instance_id: 0, enabled: true, sequence: binding.sequence });
    } catch (removeError) {
      console.error(removeError);
      window.alert(removeError instanceof Error ? removeError.message : 'Failed to remove your tool override.');
    } finally {
      const next = new Set(savingAliases.value);
      next.delete(alias);
      savingAliases.value = next;
    }
  }

  return {
    loading,
    error,
    userToolBindings,
    userToolBindingDrafts,
    savingAliases,
    hydrate,
    resetForNewBot,
    syncDrafts,
    userToolDraft,
    setDraft,
    setDraftTool,
    toggleDraftEnabled,
    label,
    saveOverride,
    removeOverride,
  };
}
