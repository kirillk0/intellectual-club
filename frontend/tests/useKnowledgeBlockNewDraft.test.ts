const workflowMocks = vi.hoisted(() => ({
  createRecordset: vi.fn(),
  openForResult: vi.fn(),
}));

vi.mock('@/features/catalogs/model/recordsets', () => ({
  createRecordset: workflowMocks.createRecordset,
}));

vi.mock('@/features/stack/useStackNavigation', () => ({
  useStackNavigation: () => ({
    openForResult: workflowMocks.openForResult,
  }),
}));

import type { CrudEditorLayerResult } from '@/features/catalogs/model/useCrudEditor';
import { useKnowledgeBlockNewDraft } from '@/features/catalogs/model/useKnowledgeBlockNewDraft';

describe('useKnowledgeBlockNewDraft typed result workflow', () => {
  beforeEach(() => {
    workflowMocks.createRecordset.mockReset();
    workflowMocks.createRecordset.mockReturnValue('recordset-test');
    workflowMocks.openForResult.mockReset();
  });

  it('uses the last operation per block and reports only changes from the initial IDs', async () => {
    const onBlocksCreated = vi.fn().mockResolvedValue(undefined);
    const onBlocksRemoved = vi.fn().mockResolvedValue(undefined);
    const result: CrudEditorLayerResult = {
      changes: [
        { type: 'knowledge-blocks', id: 1, operation: 'upsert' },
        { type: 'knowledge-blocks', id: 1, operation: 'delete' },
        { type: 'knowledge-blocks', id: 2, operation: 'delete' },
        { type: 'knowledge-blocks', id: 2, operation: 'upsert' },
        { type: 'knowledge-blocks', id: 3, operation: 'upsert' },
        { type: 'knowledge-blocks', id: 3, operation: 'delete' },
        { type: 'knowledge-blocks', id: 4, operation: 'delete' },
        { type: 'knowledge-blocks', id: 4, operation: 'upsert' },
        { type: 'knowledge-blocks', id: 5, operation: 'upsert' },
        { type: 'bots', id: 6, operation: 'upsert' },
      ],
    };
    workflowMocks.openForResult.mockResolvedValue({ status: 'completed', value: result });
    const draft = useKnowledgeBlockNewDraft({
      linkedBlockIds: () => [1, 2, 2],
      onBlocksCreated,
      onBlocksRemoved,
    });

    await draft.openNewBlock();

    expect(workflowMocks.createRecordset).toHaveBeenCalledWith([1, 2]);
    expect(workflowMocks.openForResult).toHaveBeenCalledWith({
      path: '/catalogs/knowledge-blocks/new',
      query: { recordsetKey: 'recordset-test' },
    });
    expect(onBlocksCreated).toHaveBeenCalledTimes(1);
    expect(onBlocksCreated).toHaveBeenCalledWith([4, 5]);
    expect(onBlocksRemoved).toHaveBeenCalledTimes(1);
    expect(onBlocksRemoved).toHaveBeenCalledWith([1]);
  });

  it('does not change the parent draft when the child workflow is cancelled', async () => {
    const onBlocksCreated = vi.fn().mockResolvedValue(undefined);
    const onBlocksRemoved = vi.fn().mockResolvedValue(undefined);
    workflowMocks.openForResult.mockResolvedValue({ status: 'cancelled' });
    const draft = useKnowledgeBlockNewDraft({
      linkedBlockIds: () => [1, 2],
      onBlocksCreated,
      onBlocksRemoved,
    });

    await draft.openNewBlock();

    expect(onBlocksCreated).not.toHaveBeenCalled();
    expect(onBlocksRemoved).not.toHaveBeenCalled();
  });
});
