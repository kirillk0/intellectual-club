import { computed, ref } from 'vue';
import type { ChatKnowledgeBlock, ChatToolBinding } from '@/types/api';

const mocks = vi.hoisted(() => ({ updateChatRecord: vi.fn() }));

vi.mock('@/features/chat/chatAshApi', () => ({ updateChatRecord: mocks.updateChatRecord }));
vi.mock('@/features/stack/useStackNavigation', () => ({ useStackNavigation: () => ({}) }));

import { useChatLibraryDraft } from '@/features/chat/model/useChatLibraryDraft';

const block = (id: number, blockId: number, sequence = 0): ChatKnowledgeBlock => ({
  id, chat_id: 1, knowledge_block_id: blockId, enabled: true, sequence,
});
const tool: ChatToolBinding = {
  id: 10, chat_id: 1, tool_instance_id: 20, alias: 'search', enabled: true, sequence: 0,
};

function createDraft() {
  const reloadChat = vi.fn().mockResolvedValue(undefined);
  const draft = useChatLibraryDraft({
    chatId: computed(() => 1),
    readOnly: computed(() => false),
    knowledgeBlocks: ref([]),
    toolLibrary: ref([]),
    stackOpen: vi.fn(),
    reloadChat,
  });
  draft.hydrate({ chatBlocks: [block(1, 11), block(2, 12, 1)], chatToolBindings: [tool] });
  return { draft, reloadChat };
}

describe('chat library refreshes', () => {
  beforeEach(() => {
    mocks.updateChatRecord.mockReset().mockResolvedValue(undefined);
  });

  it('preserves additions, removals, order and toggles during a refresh, then cancels to the latest server state', () => {
    const { draft } = createDraft();
    draft.addChatBlocks([42]);
    draft.removeChatBlock(1);
    draft.moveChatBlock(draft.chatBlocks.value[1], -1);
    draft.setChatBlockEnabled(2, false);
    draft.setChatToolBindingEnabled(10, false);
    const editedBlocks = [...draft.chatBlocks.value];

    draft.hydrate({ chatBlocks: [block(1, 11), block(3, 13, 1)], chatToolBindings: [tool] }, { preserveDraft: true });

    expect(draft.chatBlocks.value).toEqual(editedBlocks);
    expect(draft.chatToolBindings.value[0].enabled).toBe(false);
    expect(draft.chatTabDirty.value).toBe(true);
    draft.cancelChatChanges();
    expect(draft.linkedChatBlockIds.value).toEqual([11, 13]);
    expect(draft.chatToolBindings.value[0].enabled).toBe(true);
    expect(draft.chatTabDirty.value).toBe(false);
  });

  it('refreshes a clean list and resets dirty drafts when loading another chat', () => {
    const { draft } = createDraft();
    draft.hydrate({ chatBlocks: [block(3, 13)], chatToolBindings: [] }, { preserveDraft: true });
    expect(draft.linkedChatBlockIds.value).toEqual([13]);
    draft.addChatBlocks([42]);
    draft.hydrate({ chatBlocks: [], chatToolBindings: [] });
    expect(draft.linkedChatBlockIds.value).toEqual([]);
    expect(draft.chatTabDirty.value).toBe(false);
  });

  it('marks saved bindings clean and accepts their persistent IDs from the server', async () => {
    const { draft, reloadChat } = createDraft();
    draft.addChatBlocks([42]);
    reloadChat.mockImplementation(async () => {
      expect(draft.chatTabDirty.value).toBe(false);
      draft.hydrate({
        chatBlocks: [block(1, 11), block(2, 12, 1), block(3, 42, 2)],
        chatToolBindings: [tool],
      }, { preserveDraft: true });
    });

    await draft.saveChatChanges();

    expect(mocks.updateChatRecord).toHaveBeenCalledWith(1, {
      knowledge_block_bindings: [
        { id: 1, knowledge_block_id: 11, enabled: true },
        { id: 2, knowledge_block_id: 12, enabled: true },
        { knowledge_block_id: 42, enabled: true },
      ],
      tool_bindings: [{ id: 10, tool_instance_id: 20, enabled: true }],
    });
    expect(draft.chatBlocks.value[2].id).toBe(3);
    expect(draft.chatTabDirty.value).toBe(false);
    expect(draft.savingChatChanges.value).toBe(false);
  });

  it('keeps edits made while the save is in flight dirty', async () => {
    let finishSave!: () => void;
    mocks.updateChatRecord.mockReturnValue(new Promise<void>((resolve) => { finishSave = resolve; }));
    const { draft } = createDraft();
    draft.addChatBlocks([42]);
    const saving = draft.saveChatChanges();
    draft.addChatBlocks([43]);
    finishSave();
    await saving;

    expect(draft.chatTabDirty.value).toBe(true);
    draft.cancelChatChanges();
    expect(draft.linkedChatBlockIds.value).toEqual([11, 12, 42]);
  });

  it('retains the draft and original state when saving fails', async () => {
    mocks.updateChatRecord.mockRejectedValue(new Error('Save failed'));
    vi.spyOn(window, 'alert').mockImplementation(() => undefined);
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
    const { draft, reloadChat } = createDraft();
    draft.addChatBlocks([42]);

    await draft.saveChatChanges();

    expect(draft.linkedChatBlockIds.value).toEqual([11, 12, 42]);
    expect(draft.chatTabDirty.value).toBe(true);
    expect(reloadChat).not.toHaveBeenCalled();
    draft.cancelChatChanges();
    expect(draft.linkedChatBlockIds.value).toEqual([11, 12]);
  });
});
