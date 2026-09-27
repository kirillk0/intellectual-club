import type { ChatBranchMessage } from '@/types/api';
import type { PollResponse } from './chatViewModel.shared';

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
  if (!runtime.items.length && !runtime.parts.length && !runtime.media.length) return current;
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
