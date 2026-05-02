import { computed, type Ref } from 'vue';

import { toIntId, type JsonApiResource } from '@/api/jsonApi';
import type { ToolInstanceOption } from '@/types/api';

const TOOL_TYPE_LABELS: Record<string, string> = {
  'mcp-http': 'MCP HTTP',
  'native-brave-search': 'Brave Search',
  'native-web-reader': 'Web Reader',
  outlet: 'Outlet',
  ssh: 'SSH',
};

export function parseToolInstanceOption(resource: JsonApiResource | null | undefined): ToolInstanceOption | null {
  if (!resource) return null;
  const id = toIntId(resource.id);
  if (!id) return null;
  const attrs = (resource.attributes || {}) as Record<string, unknown>;
  const hasOutletOnline = Object.prototype.hasOwnProperty.call(attrs, 'outlet_online');
  const hasCanEdit = Object.prototype.hasOwnProperty.call(attrs, 'can_edit');

  return {
    id,
    name: String(attrs.name || '').trim(),
    alias: String(attrs.alias || '').trim(),
    type: String(attrs.type || '').trim(),
    type_title: String(attrs.type_title || '').trim() || null,
    outlet_online: hasOutletOnline ? Boolean(attrs.outlet_online) : null,
    can_edit: hasCanEdit ? attrs.can_edit !== false : null,
  } satisfies ToolInstanceOption;
}

export function toolTypeLabel(tool: Pick<ToolInstanceOption, 'type' | 'type_title'> | null | undefined) {
  const title = String(tool?.type_title || '').trim();
  if (title) return title;

  const type = String(tool?.type || '').trim();
  if (!type) return 'Tool';

  return TOOL_TYPE_LABELS[type] || humanizeToolType(type);
}

export function mergeToolInstanceOptions(
  current: ToolInstanceOption[],
  incoming: ToolInstanceOption[]
): ToolInstanceOption[] {
  const byId = new Map<number, ToolInstanceOption>();

  for (const tool of current || []) byId.set(tool.id, tool);
  for (const tool of incoming || []) {
    const existing = byId.get(tool.id);

    byId.set(tool.id, {
      ...existing,
      ...tool,
      outlet_online: tool.outlet_online ?? existing?.outlet_online ?? false,
      can_edit: tool.can_edit ?? existing?.can_edit ?? true,
    });
  }

  return Array.from(byId.values()).sort((a, b) => a.name.localeCompare(b.name) || a.id - b.id);
}

export function useToolInstanceLibrary(toolLibrary: Ref<ToolInstanceOption[]>) {
  const toolLibraryById = computed(() => {
    const map = new Map<number, ToolInstanceOption>();
    for (const tool of toolLibrary.value || []) {
      if (typeof tool.id === 'number') map.set(tool.id, tool);
    }
    return map;
  });

  const ownedToolLibrary = computed(() => (toolLibrary.value || []).filter((tool) => tool.can_edit !== false));

  const toolLabel = (toolInstanceId: number) => {
    const tool = toolLibraryById.value.get(toolInstanceId);
    if (!tool) return `Tool #${toolInstanceId}`;
    return `${tool.name} (${toolTypeLabel(tool)})`;
  };

  const toolTypeName = (toolInstanceId: number) => {
    const tool = toolLibraryById.value.get(toolInstanceId);
    return tool ? toolTypeLabel(tool) : 'Tool';
  };

  const toolIsOutlet = (toolInstanceId: number) => toolLibraryById.value.get(toolInstanceId)?.type === 'outlet';

  const toolIsOnline = (toolInstanceId: number) => Boolean(toolLibraryById.value.get(toolInstanceId)?.outlet_online);

  return {
    toolLibraryById,
    ownedToolLibrary,
    toolLabel,
    toolTypeLabel: toolTypeName,
    toolIsOutlet,
    toolIsOnline,
  };
}

function humanizeToolType(type: string) {
  return type
    .replace(/[_-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}
