import type { ChatBranchMessage, ChatMessageStep, ChatMessageUsage, ChatUsageStats } from '@/types/api';
import type { PollResponse, RuntimeCursor, RuntimeDelta } from './chatViewModel.shared';

/** Keep streaming responsive without hammering persistence and tool waits. */
export function generationPollDelay(response: PollResponse): number {
  if (typeof response.poll_after_ms === 'number' && Number.isFinite(response.poll_after_ms)) {
    return Math.max(500, Math.min(2000, response.poll_after_ms));
  }
  if (
    response.availability === 'busy' ||
    [
      'initializing',
      'recovering',
      'tools',
      'waiting_provider',
      'waiting_tools',
      'persisting',
      'backoff',
      'retry_backoff',
    ].includes(response.phase || response.working?.latest_step_status || '')
  )
    return 1750;
  return 500;
}

/** Replace only the active step; completed content is already held by the client. */
export function mergeRuntimePollContent(
  current: ChatBranchMessage['content'],
  response: PollResponse
): ChatBranchMessage['content'] {
  if (response.content !== undefined) return response.content;
  if (response.runtime_delta) return appendRuntimeText(current, response.runtime_delta);
  const runtime = response.runtime_content;
  const sequence = response.runtime_step_sequence;
  if (!runtime || typeof sequence !== 'number') return current;
  return mergeStepContent(current, runtime, sequence);
}

function mergeStepContent(
  current: ChatBranchMessage['content'],
  runtime: NonNullable<ChatBranchMessage['content']>,
  sequence: number
): ChatBranchMessage['content'] {
  const merge = <
    T extends { step_sequence?: number | null; item_sequence?: number | null; sequence?: number },
  >(
    previous: T[],
    next: T[]
  ) =>
    [...previous.filter((item) => item.step_sequence !== sequence), ...next].sort(
      (a, b) =>
        (a.step_sequence || 0) - (b.step_sequence || 0) ||
        (a.item_sequence || 0) - (b.item_sequence || 0) ||
        (a.sequence || 0) - (b.sequence || 0)
    );
  return {
    items: merge(current?.items || [], runtime.items),
    parts: merge(current?.parts || [], runtime.parts),
    media: merge(current?.media || [], runtime.media),
  };
}

/** A persisted-only branch refresh must not erase the live, uncommitted step. */
export function preserveStreamingMessageContent(
  current: ChatBranchMessage | undefined,
  incoming: ChatBranchMessage
): ChatBranchMessage {
  const stepId = incoming.working?.latest_step_id;
  const sequence = incoming.working?.latest_step_sequence;
  if (
    !current?.content ||
    current.id !== incoming.id ||
    current.role !== 'assistant' || incoming.role !== 'assistant' ||
    current.status !== 'generating' || incoming.status !== 'generating' ||
    typeof stepId !== 'number' || typeof sequence !== 'number' ||
    current.working?.latest_step_id !== stepId ||
    current.working?.latest_step_sequence !== sequence ||
    incoming.working?.latest_step_status !== 'waiting_provider'
  ) return incoming;

  const sameStep = (item: { step_id?: number | null; step_sequence?: number | null }) =>
    item.step_id === stepId && item.step_sequence === sequence;
  const runtime = {
    items: current.content.items.filter(sameStep),
    parts: current.content.parts.filter(sameStep),
    media: current.content.media.filter(sameStep),
  };
  // RuntimeTrace assigns negative item IDs, including to the step's steering items.
  if (![...runtime.items, ...runtime.parts, ...runtime.media].some((item) => (item.item_id ?? 0) < 0)) {
    return incoming;
  }

  // Content may already be committed even if the step metadata was read before it.
  // Persisted steering alone is not a committed provider response.
  const persisted = incoming.content;
  if (persisted && [...persisted.items, ...persisted.parts, ...persisted.media].some(
    (item) => sameStep(item) && (item.item_id ?? 0) > 0 && item.item_type !== 'steering'
  )) return incoming;

  return { ...incoming, content: mergeStepContent(incoming.content, runtime, sequence) };
}

/** The UI chooses which block to follow; cursors for other blocks are discarded. */
export function selectRuntimeCursor(response: PollResponse): RuntimeCursor | null | undefined {
  const targets = response.runtime_targets || [];
  return (targets.find((target) => target.item_type === 'answer') ||
    targets.find((target) => target.item_type === 'handoff_summary') ||
    targets.find((target) => target.item_type === 'reasoning'))?.cursor ?? response.runtime_cursor;
}

export function validRuntimeDelta(cursor: RuntimeCursor | null | undefined, delta: RuntimeDelta): boolean {
  return !!cursor && cursor.step === delta.step_id && cursor.sequence === delta.step_sequence &&
    cursor.content === delta.sequence && cursor.offset === delta.from && delta.to >= delta.from &&
    new TextEncoder().encode(delta.text).length === delta.to - delta.from;
}

function appendRuntimeText(current: ChatBranchMessage['content'], delta: RuntimeDelta): ChatBranchMessage['content'] {
  // Reasoning is shown in the step inspector, not in the ordinary message body.
  if (!['answer', 'handoff_summary', 'steering'].includes(delta.item_type)) return current;
  const parts = [...(current?.parts || [])];
  const index = parts.findIndex((part) => part.step_id === delta.step_id && part.item_id === delta.item_id && part.content_id === delta.content_id);
  const { text, from: _from, to: _to, ...descriptor } = delta;
  if (index >= 0) parts[index] = { ...parts[index]!, text: parts[index]!.text + text };
  else if (delta.from === 0) parts.push({ ...descriptor, text });
  else throw new Error('Streaming content no longer matches its cursor.');
  return { items: current?.items || [], parts, media: current?.media || [] };
}

/** Adjust only scalar usage totals; completed steps never need to be reread. */
export function mergeRuntimeUsage(current: ChatMessageUsage | null | undefined,
  summary: Omit<ChatMessageStep, 'items'>): ChatMessageUsage {
  const previous = current?.latest_step?.id === summary.id ? current.latest_step : null;
  const total: ChatUsageStats = { ...current?.total };
  for (const key of ['input_tokens', 'output_tokens', 'cached_input_tokens', 'reasoning_tokens', 'cost'] as const) {
    const oldValue = previous?.[key];
    const newValue = summary[key];
    if (typeof newValue === 'number' || typeof oldValue === 'number') {
      total[key] = (total[key] || 0) - (oldValue || 0) + (newValue || 0);
    }
  }
  const totalCost = typeof total.cost === 'number' ? total.cost : current?.total_cost;
  const subchatCost = current?.subchat_cost;
  return { ...current, latest_step: summary, total, total_cost: totalCost,
    combined_total_cost: typeof totalCost === 'number' || typeof subchatCost === 'number'
      ? (totalCost || 0) + (subchatCost || 0) : null };
}
