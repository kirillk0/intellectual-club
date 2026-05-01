export type BaseToolBinding = {
  id: number;
  alias: string;
  tool_instance_id: number;
  enabled: boolean;
  sequence: number;
};

export type ToolBindingValidationOptions<T extends BaseToolBinding> = {
  toolInstanceId: number;
  alias?: string;
  bindings: T[];
  messages: {
    missingTool: string;
    duplicateTool: string;
    duplicateAlias: string;
  };
};

const normalizeText = (value: unknown) => String(value ?? '').trim();

export function sortToolBindings<T extends { sequence: number; id: number }>(rows: T[]) {
  return [...(rows || [])].sort((a, b) => (a.sequence || 0) - (b.sequence || 0) || a.id - b.id);
}

export function normalizeToolBindingSequences<T extends BaseToolBinding>(rows: T[]) {
  return sortToolBindings(rows || []).map((row, idx) => ({ ...row, sequence: idx }));
}

export function cloneToolBindings<T extends BaseToolBinding>(rows: T[]) {
  return (rows || []).map((row) => ({ ...row }));
}

export function normalizeToolBindingsForCompare<T extends BaseToolBinding>(
  rows: T[],
  extraFields: (binding: T) => Record<string, unknown> = () => ({})
) {
  return sortToolBindings(rows || []).map((binding) => ({
    alias: normalizeText(binding.alias),
    tool_instance_id: Number(binding.tool_instance_id) || 0,
    enabled: Boolean(binding.enabled),
    sequence: Number(binding.sequence) || 0,
    ...extraFields(binding),
  }));
}

export function moveToolBindingInList<T extends BaseToolBinding>(rows: T[], bindingId: number, delta: number) {
  const list = sortToolBindings(rows || []);
  const idx = list.findIndex((item) => item.id === bindingId);
  if (idx < 0) return rows;

  const targetIdx = idx + delta;
  if (targetIdx < 0 || targetIdx >= list.length) return rows;

  const next = [...list];
  const current = next[idx];
  next[idx] = next[targetIdx];
  next[targetIdx] = current;
  return next.map((row, index) => ({ ...row, sequence: index }));
}

export function removeToolBindingFromList<T extends BaseToolBinding>(rows: T[], bindingId: number) {
  return normalizeToolBindingSequences((rows || []).filter((row) => row.id !== bindingId));
}

export function setToolBindingEnabledInList<T extends BaseToolBinding>(rows: T[], bindingId: number, enabled: boolean) {
  return (rows || []).map((row) => (row.id === bindingId ? { ...row, enabled } : row));
}

export function validateNewToolBinding<T extends BaseToolBinding>({
  toolInstanceId,
  alias,
  bindings,
  messages,
}: ToolBindingValidationOptions<T>) {
  if (!toolInstanceId) return messages.missingTool;
  if ((bindings || []).some((binding) => binding.tool_instance_id === toolInstanceId)) {
    return messages.duplicateTool;
  }
  if (alias && (bindings || []).some((binding) => binding.alias === alias)) return messages.duplicateAlias;
  return null;
}
