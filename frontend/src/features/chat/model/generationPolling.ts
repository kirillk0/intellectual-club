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
