import { flushPromises } from '@vue/test-utils';
import { ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (_error: unknown, fallback: string) => fallback,
}));

import { useChatInspectors } from '@/features/chat/model/useChatInspectors';
import type { ExistingChatAttachment } from '@/features/chat/attachments';

const createInspectors = (queueAttachments: ExistingChatAttachment[] = []) =>
  useChatInspectors({
    compiledPromptText: ref(''),
    loadError: ref(''),
    replaceBranch: vi.fn(),
    branchMessageById: vi.fn().mockReturnValue(null),
    retryConfigurationWarning: vi.fn().mockReturnValue(''),
    startPolling: vi.fn().mockResolvedValue(undefined),
    scrollToLastMessage: vi.fn(),
    composerPendingFiles: ref([]),
    editPendingFiles: ref([]),
    editExistingAttachments: ref([]),
    queueEditPendingFiles: ref([]),
    queueEditExistingAttachments: ref(queueAttachments),
  });

describe('chat step details', () => {
  beforeEach(() => {
    apiMocks.get.mockReset().mockImplementation((url: string) => {
      if (url.endsWith('kind=response')) {
        return Promise.resolve({
          step: {
            raw_response: {
              status_code: 429,
              body: { error: { message: 'Provider returned error' } },
            },
          },
        });
      }

      return Promise.resolve({ step: { raw_request: { model: 'test-model' } } });
    });
  });

  it('loads the raw response for a completed retry while the message is still generating', async () => {
    const inspectors = createInspectors();

    inspectors.openStepDetails({
      messageId: 42,
      messageStatus: 'generating',
      step: {
        id: 7,
        sequence: 2,
        status: 'error',
        response_final: false,
      },
    });
    await flushPromises();

    expect(inspectors.stepDetailsShowResponse.value).toBe(true);
    expect(inspectors.stepDetailsResponsePayload.value).toEqual({
      status_code: 429,
      body: { error: { message: 'Provider returned error' } },
    });
    expect(apiMocks.get).toHaveBeenCalledWith(
      '/api/bff/chat-messages/42/steps/7/raw?kind=response'
    );
  });
});

describe('queued attachment preview', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('uses the queued-content endpoint before canonical delivery', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, text: async () => 'queued file' });
    vi.stubGlobal('fetch', fetchMock);
    const attachment: ExistingChatAttachment = {
      id: 18,
      messageId: 9,
      queuedMessageId: 9,
      name: 'notes.txt',
      size: 11,
      mimeType: 'text/plain',
      isImage: false,
      content: {
        id: 18,
        sequence: 1,
        kind: 'media',
        media: {
          external_id: 'file-1',
          filename: 'notes.txt',
          mime_type: 'text/plain',
          size_bytes: 11,
          sha256: '',
          is_image: false,
        },
      },
    };
    const inspectors = createInspectors([attachment]);

    await inspectors.openExistingAttachmentPreview(attachment);

    expect(inspectors.attachmentPreviewUrl.value).toBe(
      '/api/bff/chat-queued-messages/9/contents/18/file'
    );
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/bff/chat-queued-messages/9/contents/18/file'
    );
    expect(inspectors.attachmentPreviewText.value).toBe('queued file');
  });
});
