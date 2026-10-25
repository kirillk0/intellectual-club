import { computed, ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  patch: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (error: unknown, fallback: string) =>
    error instanceof Error && error.message ? error.message : fallback,
}));

const publishChatChange = vi.hoisted(() => vi.fn());

vi.mock('@/features/chat/chatEvents', () => ({ publishChatChange }));

import type { ChatUploadPolicy } from '@/features/chat/attachments';
import { useChatMessageActions } from '@/features/chat/model/useChatMessageActions';
import type { Chat, ChatBranchMessage } from '@/types/api';

const noFiles: ChatUploadPolicy = { allowsFiles: false, imagesOnly: false, maxFileSizeBytes: 10_000, accept: '' };
const imagesOnly: ChatUploadPolicy = {
  allowsFiles: true,
  imagesOnly: true,
  maxFileSizeBytes: 10_000,
  accept: 'image/*',
};
const anyFiles: ChatUploadPolicy = { allowsFiles: true, imagesOnly: false, maxFileSizeBytes: 10_000, accept: '' };

const userMessage: ChatBranchMessage = {
  id: 10,
  role: 'user',
  status: 'done',
  parent_id: null,
  content: {
    items: [],
    parts: [
      {
        content_id: 1,
        sequence: 0,
        text: 'Question',
        item_type: 'user',
        step_sequence: 1,
        item_sequence: 1,
      },
    ],
    media: [],
  },
};

const assistantMessage: ChatBranchMessage = {
  id: 11,
  role: 'assistant',
  status: 'done',
  parent_id: 10,
  llm_configuration_id: 7,
  content: { items: [], parts: [], media: [] },
};

const createActions = (
  overrides: {
    selectedConfig?: number | '';
    chatUploadPolicy?: ChatUploadPolicy;
    uploadPolicyForConfig?: (configId: number) => ChatUploadPolicy;
    messageConfigLabel?: (configId?: number | null, snapshot?: string | null) => string;
  } = {}
) => {
  const branch = ref<ChatBranchMessage[]>([userMessage, assistantMessage]);
  const startPolling = vi.fn(async () => undefined);
  const scrollToLastMessage = vi.fn();
  const pushChatRoute = vi.fn();
  const applyServerConfiguration = vi.fn();
  const ensurePendingFilesUploaded = vi.fn(async () => ['upload-1']);
  const actions = useChatMessageActions({
    chatId: computed(() => 1),
    chat: ref({ id: 1, llm_configuration_id: 7 } as Chat),
    readOnly: computed(() => false),
    branch,
    selectedConfig: ref(overrides.selectedConfig ?? 7),
    fileUploadPolicy: computed(() => overrides.chatUploadPolicy ?? anyFiles),
    uploadPolicyForConfig: overrides.uploadPolicyForConfig,
    waitForConfigSync: async () => true,
    messageConfigLabel: overrides.messageConfigLabel ?? (() => ''),
    startPolling,
    scrollToLastMessage,
    ensurePendingFilesUploaded,
    removePendingFileFromCollection: async () => undefined,
    clearPendingFilesCollection: async () => undefined,
    pushChatRoute,
    applyServerConfiguration,
  });

  return {
    actions,
    branch,
    startPolling,
    scrollToLastMessage,
    pushChatRoute,
    applyServerConfiguration,
    ensurePendingFilesUploaded,
  };
};

describe('chat message branch options', () => {
  beforeEach(() => {
    apiMocks.post.mockReset();
    publishChatChange.mockReset();
  });

  it('uses the configuration snapshot in the retry warning without changing its selection', () => {
    const messageConfigLabel = vi.fn((id?: number | null, snapshot?: string | null) => snapshot || `Config #${id}`);
    const { actions } = createActions({ selectedConfig: 9, messageConfigLabel });
    const message = { ...assistantMessage, llm_configuration_label_snapshot: 'Original Model' };

    expect(actions.retryConfigurationWarning(message)).toContain('(Original Model)');
    expect(actions.retryConfigurationWarning(message)).toContain('(Config #9)');
    expect(messageConfigLabel).toHaveBeenCalledWith(7, 'Original Model');
    expect(actions.retryConfigurationWarning({ ...message, llm_configuration_id: null })).toBe('');
  });

  it('branches an assistant response in place immediately without branch options', async () => {
    const { actions, branch, startPolling } = createActions();
    const nextBranch = [userMessage, { ...assistantMessage, id: 12, status: 'generating' as const }];
    apiMocks.post.mockResolvedValue({ branch: nextBranch, generation: { message_id: 12 } });

    actions.startBranch(assistantMessage);
    await vi.waitFor(() => expect(startPolling).toHaveBeenCalledWith(12));

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/generate', { parent_id: 10 });
    expect(branch.value).toEqual(nextBranch);
    expect(actions.editingMessage.value).toBeNull();
  });

  it('branches an assistant response to a new chat immediately without branch options', async () => {
    const { actions, pushChatRoute } = createActions();
    apiMocks.post.mockResolvedValue({ chat: { id: 42 }, generation: { message_id: 50 } });

    actions.startBranchToNewChat(assistantMessage);
    await vi.waitFor(() => expect(pushChatRoute).toHaveBeenCalledWith(42));

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/branch-to-new-chat', {
      message_id: 11,
    });
    expect(actions.editingMessage.value).toBeNull();
  });

  it('resets user branch dialog options to the selected configuration with generation enabled', () => {
    const { actions } = createActions({ selectedConfig: 9 });
    actions.branchStartGeneration.value = false;
    actions.branchConfigId.value = 3;

    actions.startBranchToNewChat(userMessage);

    expect(actions.modalMode.value).toBe('branch_new_chat');
    expect(actions.branchConfigId.value).toBe(9);
    expect(actions.branchStartGeneration.value).toBe(true);
  });

  it('sends edited user branches in place with the dialog options', async () => {
    const { actions, startPolling, applyServerConfiguration } = createActions();
    apiMocks.post.mockResolvedValue({
      branch: [{ ...userMessage, id: 20 }],
      chat: { id: 1, llm_configuration_id: 8 },
      generation: null,
    });

    actions.startBranch(userMessage);
    expect(actions.modalMode.value).toBe('branch');
    expect(actions.branchConfigId.value).toBe(7);
    actions.editContents.value = ['Edited question'];
    actions.branchConfigId.value = 8;
    actions.branchStartGeneration.value = false;
    await actions.saveEdit();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/branch', {
      message_id: 10,
      content: 'Edited question',
      start_generation: false,
      llm_configuration_id: 8,
    });
    expect(applyServerConfiguration).toHaveBeenCalledWith(8);
    expect(startPolling).not.toHaveBeenCalled();
    expect(actions.editingMessage.value).toBeNull();
  });

  it('sends edited user branches to a new chat with the dialog options', async () => {
    const { actions, pushChatRoute } = createActions();
    apiMocks.post.mockResolvedValue({ chat: { id: 43 }, generation: { message_id: 50 } });

    actions.startBranchToNewChat(userMessage);
    actions.editContents.value = ['Edited question'];
    actions.branchConfigId.value = 8;
    await actions.saveEdit();

    expect(apiMocks.post).toHaveBeenCalledWith('/api/bff/chat-generation/1/branch-to-new-chat', {
      message_id: 10,
      content: 'Edited question',
      start_generation: true,
      llm_configuration_id: 8,
    });
    expect(pushChatRoute).toHaveBeenCalledWith(43);
  });

  describe('branch dialog attachments', () => {
    const image = () => new File(['png'], 'pic.png', { type: 'image/png' });
    // The chat configuration (7) accepts no files; configuration 8 accepts images.
    const policyForConfig = (configId: number) => (configId === 8 ? imagesOnly : noFiles);

    it('follows the configuration selected in the branch dialog', () => {
      const { actions } = createActions({ chatUploadPolicy: noFiles, uploadPolicyForConfig: policyForConfig });

      actions.startBranchToNewChat(userMessage);
      expect(actions.editAttachmentsEnabled.value).toBe(false);
      actions.addEditPendingFiles([image()]);
      expect(actions.editPendingFiles.value).toHaveLength(0);
      expect(actions.editErrorText.value).toBe('File uploads are disabled for the current bot and configuration.');

      actions.branchConfigId.value = 8;
      expect(actions.editAttachmentsEnabled.value).toBe(true);
      expect(actions.editAttachmentAccept.value).toBe('image/*');
      expect(actions.editAttachmentHelp.value).toContain('Only image files');
      actions.addEditPendingFiles([image()]);
      expect(actions.editPendingFiles.value).toHaveLength(1);
      expect(actions.editErrorText.value).toBe('');
    });

    it('keeps the chat policy for in-place edits', () => {
      const { actions } = createActions({ chatUploadPolicy: noFiles, uploadPolicyForConfig: () => anyFiles });

      actions.startEdit(userMessage);
      actions.branchConfigId.value = 8;

      expect(actions.editAttachmentsEnabled.value).toBe(false);
    });

    it('blocks saving files the newly selected configuration does not allow', async () => {
      const { actions, ensurePendingFilesUploaded } = createActions({
        chatUploadPolicy: noFiles,
        uploadPolicyForConfig: policyForConfig,
      });
      apiMocks.post.mockResolvedValue({ chat: { id: 44 }, generation: null });

      actions.startBranchToNewChat(userMessage);
      actions.branchConfigId.value = 8;
      actions.addEditPendingFiles([image()]);
      actions.branchConfigId.value = 7;

      expect(actions.editAttachmentPolicyError.value).toBe(
        'File uploads are disabled for the current bot and configuration.'
      );
      await actions.saveEdit();
      expect(apiMocks.post).not.toHaveBeenCalled();
      expect(ensurePendingFilesUploaded).not.toHaveBeenCalled();

      actions.branchConfigId.value = 8;
      await actions.saveEdit();

      expect(ensurePendingFilesUploaded).toHaveBeenCalledWith(actions.editPendingFiles, undefined, {
        llmConfigurationId: 8,
      });
      expect(apiMocks.post).toHaveBeenCalledWith(
        '/api/bff/chat-generation/1/branch-to-new-chat',
        expect.objectContaining({ upload_ids: ['upload-1'], llm_configuration_id: 8 })
      );
    });
  });
});
