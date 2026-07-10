import { flushPromises, mount, type VueWrapper } from '@vue/test-utils';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { defineComponent, h } from 'vue';

const fileApiMocks = vi.hoisted(() => ({
  list: vi.fn(),
  upload: vi.fn(),
  remove: vi.fn(),
  update: vi.fn(),
}));

vi.mock('@/api/knowledgeBlockFiles', () => ({
  listKnowledgeBlockFiles: fileApiMocks.list,
  uploadKnowledgeBlockFile: fileApiMocks.upload,
  deleteKnowledgeBlockFile: fileApiMocks.remove,
  updateKnowledgeBlockFile: fileApiMocks.update,
}));

import {
  useKnowledgeBlockFileBindingsDraft,
  type KnowledgeBlockFilesSnapshot,
} from '@/features/catalogs/model/useKnowledgeBlockFileBindingsDraft';
import { serverStateKeys, serverStateQueryClient } from '@/features/serverState/queryClient';
import type { KnowledgeBlockAttachment } from '@/types/api';

function attachment(id: number, overrides: Partial<KnowledgeBlockAttachment> = {}): KnowledgeBlockAttachment {
  return {
    id,
    external_id: `attachment-${id}`,
    file_id: `file-${id}`,
    filename: `file-${id}.txt`,
    mime_type: 'text/plain',
    size_bytes: 10,
    sha256: `sha-${id}`,
    sequence: id - 1,
    enabled: true,
    url: `/files/${id}`,
    ...overrides,
  };
}

type FileDraft = ReturnType<typeof useKnowledgeBlockFileBindingsDraft>;

let activeWrapper: VueWrapper | null = null;

function mountDraft() {
  serverStateQueryClient.clear();
  let bindings!: FileDraft;
  const Harness = defineComponent({
    setup() {
      bindings = useKnowledgeBlockFileBindingsDraft();
      return () => h('div');
    },
  });

  activeWrapper = mount(Harness, {
    global: {
      plugins: [[VueQueryPlugin, { queryClient: serverStateQueryClient }]],
    },
  });
  return bindings;
}

function setCachedSnapshot(blockId: number, attachments: KnowledgeBlockAttachment[]) {
  const snapshot: KnowledgeBlockFilesSnapshot = { blockId, attachments };
  serverStateQueryClient.setQueryData(
    serverStateKeys.detail('knowledge-blocks', blockId, 'file-attachments'),
    snapshot
  );
}

describe('useKnowledgeBlockFileBindingsDraft canonical snapshots', () => {
  beforeEach(() => {
    fileApiMocks.list.mockReset();
    fileApiMocks.upload.mockReset();
    fileApiMocks.remove.mockReset();
    fileApiMocks.update.mockReset();
  });

  afterEach(() => {
    activeWrapper?.unmount();
    activeWrapper = null;
    serverStateQueryClient.clear();
  });

  it('does not hydrate a new block session from a late response for the previous block', async () => {
    const pending: Array<{
      blockId: number;
      signal?: AbortSignal;
      resolve: (response: { attachments: KnowledgeBlockAttachment[] }) => void;
    }> = [];
    fileApiMocks.list.mockImplementation(
      (blockId: number, options?: { signal?: AbortSignal }) =>
        new Promise<{ attachments: KnowledgeBlockAttachment[] }>((resolve) => {
          pending.push({ blockId, signal: options?.signal, resolve });
        })
    );
    const bindings = mountDraft();

    await bindings.load(1);
    await vi.waitFor(() => expect(pending.map((request) => request.blockId)).toEqual([1]));
    await bindings.load(2);
    await vi.waitFor(() => expect(pending.map((request) => request.blockId)).toEqual([1, 2]));
    expect(pending[0]?.signal?.aborted).toBe(true);

    pending[1]?.resolve({ attachments: [attachment(2)] });
    await vi.waitFor(() => expect(bindings.loaded.value).toBe(true));
    expect(bindings.draft.value.map((item) => item.id)).toEqual([2]);

    pending[0]?.resolve({ attachments: [attachment(1)] });
    await flushPromises();
    expect(bindings.draft.value.map((item) => item.id)).toEqual([2]);
  });

  it('rebases a clean local snapshot when the cache changes', async () => {
    fileApiMocks.list.mockResolvedValue({ attachments: [attachment(1)] });
    const bindings = mountDraft();
    await bindings.load(1);
    await vi.waitFor(() => expect(bindings.loaded.value).toBe(true));

    setCachedSnapshot(1, [attachment(1, { filename: 'renamed.txt' }), attachment(2)]);
    await flushPromises();

    expect(bindings.original.value.map((item) => item.filename)).toEqual(['renamed.txt', 'file-2.txt']);
    expect(bindings.draft.value.map((item) => item.filename)).toEqual(['renamed.txt', 'file-2.txt']);
    expect(bindings.dirty.value).toBe(false);
    expect(bindings.remoteUpdateAvailable.value).toBe(false);
  });

  it('keeps a dirty draft and supports keep-editing followed by reload', async () => {
    const initial = [attachment(1)];
    const firstRemote = [attachment(1, { filename: 'first-remote.txt' }), attachment(2)];
    const latestRemote = [attachment(1, { filename: 'latest-remote.txt' }), attachment(2), attachment(3)];
    fileApiMocks.list.mockResolvedValue({ attachments: initial });
    const bindings = mountDraft();
    await bindings.load(1);
    await vi.waitFor(() => expect(bindings.loaded.value).toBe(true));

    bindings.setEnabled(1, false);
    expect(bindings.dirty.value).toBe(true);
    setCachedSnapshot(1, firstRemote);
    await flushPromises();

    expect(bindings.draft.value).toHaveLength(1);
    expect(bindings.draft.value[0]?.enabled).toBe(false);
    expect(bindings.remoteUpdateAvailable.value).toBe(true);

    bindings.keepEditingRemoteFiles();
    expect(bindings.remoteUpdateAvailable.value).toBe(false);
    expect(bindings.draft.value[0]?.enabled).toBe(false);

    setCachedSnapshot(1, latestRemote);
    await flushPromises();
    expect(bindings.remoteUpdateAvailable.value).toBe(true);
    expect(bindings.draft.value[0]?.enabled).toBe(false);

    fileApiMocks.list.mockResolvedValue({ attachments: latestRemote });
    await bindings.reloadRemoteFiles();
    await flushPromises();

    expect(bindings.draft.value.map((item) => item.id)).toEqual([1, 2, 3]);
    expect(bindings.draft.value[0]?.filename).toBe('latest-remote.txt');
    expect(bindings.dirty.value).toBe(false);
    expect(bindings.remoteUpdateAvailable.value).toBe(false);
  });

  it('writes a recovery read into the canonical cache after a failed mutation', async () => {
    const initial = [attachment(1)];
    const recovered = [attachment(1, { filename: 'server-after-failure.txt' })];
    fileApiMocks.list
      .mockResolvedValueOnce({ attachments: initial })
      .mockResolvedValueOnce({ attachments: recovered });
    fileApiMocks.update.mockRejectedValue(new Error('update failed'));
    const bindings = mountDraft();
    await bindings.load(1);
    await vi.waitFor(() => expect(bindings.loaded.value).toBe(true));
    bindings.setEnabled(1, false);
    vi.spyOn(console, 'error').mockImplementation(() => undefined);

    await expect(bindings.sync(1)).rejects.toThrow('update failed');

    expect(
      serverStateQueryClient.getQueryData<KnowledgeBlockFilesSnapshot>(
        serverStateKeys.detail('knowledge-blocks', 1, 'file-attachments')
      )
    ).toEqual({ blockId: 1, attachments: recovered });
    expect(bindings.original.value[0]?.filename).toBe('server-after-failure.txt');
    expect(bindings.draft.value[0]?.enabled).toBe(false);
    expect(bindings.dirty.value).toBe(true);
  });
});
