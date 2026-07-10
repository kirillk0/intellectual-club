import { createRecordset } from './recordsets';
import type { CrudEditorLayerResult } from './useCrudEditor';
import { useStackNavigation } from '@/features/stack/useStackNavigation';

type MaybePromise<T> = T | Promise<T>;

type Params = {
  linkedBlockIds: () => number[];
  onBlocksCreated: (blockIds: number[]) => MaybePromise<void>;
  onBlocksRemoved?: (blockIds: number[]) => MaybePromise<void>;
};

function normalizeIds(ids: number[]) {
  return Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0)));
}

export function useKnowledgeBlockNewDraft(params: Params) {
  const stackNav = useStackNavigation();

  const openNewBlock = async () => {
    const initialIds = normalizeIds(params.linkedBlockIds());
    const initialIdSet = new Set(initialIds);
    const recordsetKey = createRecordset(initialIds);
    const result = await stackNav.openForResult<CrudEditorLayerResult>({
      path: '/catalogs/knowledge-blocks/new',
      query: { recordsetKey },
    });

    if (result.status !== 'completed') return;

    const finalOperationById = new Map<number, 'upsert' | 'delete'>();
    for (const change of result.value.changes || []) {
      if (change.type !== 'knowledge-blocks') continue;
      finalOperationById.set(change.id, change.operation);
    }

    const createdIds: number[] = [];
    const removedIds: number[] = [];

    for (const [id, operation] of finalOperationById) {
      if (operation === 'upsert' && !initialIdSet.has(id)) createdIds.push(id);
      if (operation === 'delete' && initialIdSet.has(id)) removedIds.push(id);
    }

    if (createdIds.length) await params.onBlocksCreated(normalizeIds(createdIds));
    if (removedIds.length) await params.onBlocksRemoved?.(normalizeIds(removedIds));
  };

  return {
    openNewBlock,
  };
}
