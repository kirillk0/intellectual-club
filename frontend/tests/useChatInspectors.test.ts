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
import type { ExistingChatAttachment, PendingChatFile } from '@/features/chat/attachments';

const createInspectors = (
  queueAttachments: ExistingChatAttachment[] = [],
  composerPendingFiles: PendingChatFile[] = []
) =>
  useChatInspectors({
    compiledPromptText: ref(''),
    loadError: ref(''),
    replaceBranch: vi.fn(),
    branchMessageById: vi.fn().mockReturnValue(null),
    retryConfigurationWarning: vi.fn().mockReturnValue(''),
    startPolling: vi.fn().mockResolvedValue(undefined),
    scrollToLastMessage: vi.fn(),
    composerPendingFiles: ref(composerPendingFiles),
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

describe('attachment preview', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('uses the queued-content endpoint before canonical delivery', async () => {
    const html = '<style>body{color:red}</style><script>document.body.dataset.ready="yes"</script>';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, text: async () => html });
    vi.stubGlobal('fetch', fetchMock);
    const attachment: ExistingChatAttachment = {
      id: 18,
      messageId: 9,
      queuedMessageId: 9,
      name: 'notes.html',
      size: html.length,
      mimeType: 'text/html',
      isImage: false,
      content: {
        id: 18,
        sequence: 1,
        kind: 'media',
        media: {
          external_id: 'file-1',
          filename: 'notes.html',
          mime_type: 'text/html',
          size_bytes: html.length,
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
    expect(inspectors.attachmentPreviewKind.value).toBe('html');
    expect(inspectors.attachmentPreviewText.value).toBe(html);
  });

  it('loads saved HTML and switches to the next previewable attachment', async () => {
    const html = '<h1>Saved HTML</h1>';
    const fetchMock = vi.fn().mockImplementation((url: string) =>
      Promise.resolve({
        ok: true,
        text: async () => (url.endsWith('/18/file') ? html : 'plain text'),
      })
    );
    vi.stubGlobal('fetch', fetchMock);
    const htmlContent = {
      id: 18,
      sequence: 1,
      kind: 'media' as const,
      media: {
        external_id: 'file-html',
        filename: 'preview.html',
        mime_type: 'text/html',
        size_bytes: html.length,
        sha256: '',
        is_image: false,
      },
    };
    const textContent = {
      id: 19,
      sequence: 2,
      kind: 'media' as const,
      media: {
        external_id: 'file-text',
        filename: 'notes.txt',
        mime_type: 'text/plain',
        size_bytes: 10,
        sha256: '',
        is_image: false,
      },
    };
    const inspectors = createInspectors();

    await inspectors.openAttachmentPreview({
      messageId: 7,
      content: htmlContent,
      contents: [htmlContent, textContent],
    });

    expect(inspectors.attachmentPreviewKind.value).toBe('html');
    expect(inspectors.attachmentPreviewText.value).toBe(html);
    expect(inspectors.attachmentPreviewCanNavigate.value).toBe(true);

    await inspectors.showNextAttachmentPreview();

    expect(inspectors.attachmentPreviewKind.value).toBe('text');
    expect(inspectors.attachmentPreviewText.value).toBe('plain text');
  });

  it('loads a pending HTML file without uploading it', async () => {
    const html = '<h1>Pending HTML</h1>';
    const file = new File([html], 'pending.html', { type: 'text/html' });
    Object.defineProperty(file, 'text', { value: vi.fn().mockResolvedValue(html) });
    vi.stubGlobal('URL', {
      createObjectURL: vi.fn().mockReturnValue('blob:pending-html'),
      revokeObjectURL: vi.fn(),
    });
    const pending: PendingChatFile = {
      id: 'pending-html',
      file,
      name: file.name,
      size: file.size,
      mimeType: file.type,
      uploadId: null,
      uploadStatus: 'idle',
      uploadedBytes: 0,
      progress: 0,
      speedBps: 0,
      etaSeconds: null,
      abortHandle: null,
      error: '',
    };
    const inspectors = createInspectors([], [pending]);

    await inspectors.openPendingAttachmentPreview(pending.id);

    expect(inspectors.attachmentPreviewKind.value).toBe('html');
    expect(inspectors.attachmentPreviewUrl.value).toBe('blob:pending-html');
    expect(inspectors.attachmentPreviewText.value).toBe(html);
  });
});
