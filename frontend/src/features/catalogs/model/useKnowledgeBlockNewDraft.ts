import { ref, watch } from 'vue';
import { createRecordset, getRecordset } from './recordsets';
import { useStackNavigation } from '@/features/stack/useStackNavigation';

type MaybePromise<T> = T | Promise<T>;

type PendingNewBlockContext = {
  recordsetKey: string;
  initialIds: number[];
};

type Params = {
  linkedBlockIds: () => number[];
  onBlocksCreated: (blockIds: number[]) => MaybePromise<void>;
  resetOn?: () => unknown;
};

function normalizeIds(ids: number[]) {
  return Array.from(new Set((ids || []).filter((id): id is number => typeof id === 'number' && id > 0)));
}

export function useKnowledgeBlockNewDraft(params: Params) {
  const stackNav = useStackNavigation();
  const pendingNewBlockContext = ref<PendingNewBlockContext | null>(null);

  if (params.resetOn) {
    watch(
      () => params.resetOn?.(),
      () => {
        pendingNewBlockContext.value = null;
      }
    );
  }

  const openNewBlock = () => {
    const ids = normalizeIds(params.linkedBlockIds());
    const recordsetKey = createRecordset(ids);
    pendingNewBlockContext.value = {
      recordsetKey,
      initialIds: [...ids],
    };
    stackNav.open({
      path: '/catalogs/knowledge-blocks/new',
      query: { recordsetKey },
    });
  };

  const consumePendingNewBlockContext = async (): Promise<boolean> => {
    const pending = pendingNewBlockContext.value;
    if (!pending) return false;
    pendingNewBlockContext.value = null;

    const recordset = getRecordset(pending.recordsetKey);
    if (!recordset) return true;

    const baseline = new Set(pending.initialIds);
    const createdIds = normalizeIds(recordset.ids).filter((id) => !baseline.has(id));
    if (!createdIds.length) return true;

    await params.onBlocksCreated(createdIds);
    return true;
  };

  return {
    openNewBlock,
    consumePendingNewBlockContext,
  };
}
