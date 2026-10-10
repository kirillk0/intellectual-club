import { flushPromises } from '@vue/test-utils';
import { ref } from 'vue';

const apiMocks = vi.hoisted(() => ({
  get: vi.fn(),
}));

vi.mock('@/api/client', () => ({
  api: apiMocks,
  getApiErrorMessage: (_error: unknown, fallback: string) => fallback,
  isHttpError: (error: unknown) => Boolean(error && typeof error === 'object' && 'bodyJson' in error),
}));

import { useChatInspectors } from '@/features/chat/model/useChatInspectors';
import type { ExistingChatAttachment, PendingChatFile } from '@/features/chat/attachments';
import * as download from '@/utils/download';

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

  it('reports an unreconstructable stored request without showing an empty payload', async () => {
    apiMocks.get.mockRejectedValue({ bodyJson: { code: 'request_unavailable' }, status: 422 });
    const inspectors = createInspectors();
    inspectors.openStepDetails({
      messageId: 42,
      messageStatus: 'generating',
      step: { id: 7, sequence: 2, status: 'waiting_provider', response_final: false },
    });
    await flushPromises();
    expect(inspectors.stepDetailsRequestError.value).toBe('Stored request could not be reconstructed');
    expect(inspectors.stepDetailsRequestPayload.value).toBeNull();
    expect(inspectors.stepDetailsRequestLoading.value).toBe(false);
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
      '/api/bff/chat-messages/42/steps/7/raw?kind=response',
      { showErrorBanner: false }
    );
  });
});

describe('attachment preview', () => {
  beforeEach(() => {
    apiMocks.get.mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it.each([
    ['text', 'notes.txt', 'text/plain', false],
    ['html', 'page.html', 'text/html', false],
    ['markdown', 'notes.md', 'text/markdown', false],
    ['image', 'photo.png', 'image/png', true],
    ['pdf', 'document.pdf', 'application/pdf', false],
    ['video', 'clip.mp4', 'video/mp4', false],
    ['audio', 'sound.mp3', 'audio/mpeg', false],
  ] as const)('previews a linked %s attachment from another message', async (kind, filename, mimeType, isImage) => {
    const fileId = 'c6012361-90b8-4f6b-afb0-35729ae584c6';
    const content = {
      id: 18, sequence: 1, kind: 'media',
      media: { external_id: 'content-uuid', file_external_id: fileId, filename, mime_type: mimeType, size_bytes: 10, sha256: '', is_image: isImage },
    };
    apiMocks.get.mockResolvedValue({ message_id: 7, content });
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, text: async () => 'file contents' });
    vi.stubGlobal('fetch', fetchMock);
    const inspectors = createInspectors();

    await inspectors.openAttachmentPreview({ messageId: 99, fileId, contents: [] });

    expect(apiMocks.get).toHaveBeenCalledWith(`/api/bff/chat-files/${fileId}/attachment`, { showErrorBanner: false });
    expect(inspectors.attachmentPreviewOpen.value).toBe(true);
    expect(inspectors.attachmentPreviewKind.value).toBe(kind);
    expect(inspectors.attachmentPreviewTitle.value).toBe(filename);
    expect(inspectors.attachmentPreviewUrl.value).toBe('/api/bff/chat-messages/7/contents/18/file');
    if (['text', 'html', 'markdown'].includes(kind)) {
      expect(inspectors.attachmentPreviewText.value).toBe('file contents');
    } else {
      expect(fetchMock).not.toHaveBeenCalled();
    }
  });

  it('downloads a linked attachment whose type cannot be previewed', async () => {
    const save = vi.spyOn(download, 'saveUrlAsFile').mockResolvedValue(undefined);
    const content = {
      id: 18, sequence: 1, kind: 'media',
      media: { external_id: 'file-zip', filename: 'archive.zip', mime_type: 'application/zip', size_bytes: 10, sha256: '', is_image: false },
    };
    apiMocks.get.mockResolvedValue({ message_id: 7, content });
    const inspectors = createInspectors();

    await inspectors.openAttachmentPreview({ messageId: 99, fileId: 'file-zip' });

    expect(inspectors.attachmentPreviewOpen.value).toBe(false);
    expect(save).toHaveBeenCalledWith('/api/bff/chat-messages/7/contents/18/file', 'archive.zip', 'application/zip');
  });

  it('keeps a newer preview when an older linked attachment lookup completes', async () => {
    let resolveLookup!: (value: unknown) => void;
    apiMocks.get.mockReturnValue(new Promise((resolve) => { resolveLookup = resolve; }));
    const content = {
      id: 18, sequence: 1, kind: 'media',
      media: { external_id: 'file-image', filename: 'photo.png', mime_type: 'image/png', size_bytes: 10, sha256: '', is_image: true },
    };
    const inspectors = createInspectors();
    const older = inspectors.openAttachmentPreview({ messageId: 99, fileId: 'old-file' });
    await inspectors.openAttachmentPreview({ messageId: 7, content });
    resolveLookup({ message_id: 99, content: { ...content, id: 19 } });
    await older;

    expect(inspectors.attachmentPreviewUrl.value).toBe('/api/bff/chat-messages/7/contents/18/file');
  });

  it('reports a failed linked attachment lookup without opening an empty preview', async () => {
    const alert = vi.spyOn(window, 'alert').mockImplementation(() => {});
    apiMocks.get.mockRejectedValue({ status: 404 });
    const inspectors = createInspectors();

    await inspectors.openAttachmentPreview({ messageId: 99, fileId: 'missing-file' });

    expect(inspectors.attachmentPreviewOpen.value).toBe(false);
    expect(alert).toHaveBeenCalledOnce();
  });

  it.each([
    ['video', 'video/mp4'],
    ['audio', 'audio/mpeg'],
    ['pdf', 'application/pdf'],
  ] as const)('passes saved, queued and pending %s files directly to the browser', async (kind, mimeType) => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const attachment: ExistingChatAttachment = {
      id: 18, messageId: 9, name: 'attachment', size: 3, mimeType, isImage: false,
      content: {
        id: 18, sequence: 1, kind: 'media',
        media: { external_id: 'file-1', filename: 'attachment', mime_type: mimeType, size_bytes: 3, sha256: '', is_image: false },
      },
    };
    const file = new File(['123'], 'attachment', { type: mimeType });
    const readText = vi.fn();
    Object.defineProperty(file, 'text', { value: readText });
    const revokeObjectURL = vi.fn();
    vi.stubGlobal('URL', { createObjectURL: vi.fn().mockReturnValue('blob:attachment'), revokeObjectURL });
    const pending: PendingChatFile = {
      id: 'pending', file, name: file.name, size: file.size, mimeType,
      uploadId: null, uploadStatus: 'idle', uploadedBytes: 0, progress: 0, speedBps: 0,
      etaSeconds: null, abortHandle: null, error: '',
    };
    const queued = { ...attachment, queuedMessageId: 9 };
    const inspectors = createInspectors([queued], [pending]);

    await inspectors.openAttachmentPreview({ messageId: 9, content: attachment.content });
    expect(inspectors.attachmentPreviewUrl.value).toBe('/api/bff/chat-messages/9/contents/18/file');
    expect(inspectors.attachmentPreviewKind.value).toBe(kind);
    expect(inspectors.attachmentPreviewLoading.value).toBe(false);

    await inspectors.openExistingAttachmentPreview(queued);
    expect(inspectors.attachmentPreviewUrl.value).toBe('/api/bff/chat-queued-messages/9/contents/18/file');
    expect(inspectors.attachmentPreviewLoading.value).toBe(false);

    await inspectors.openPendingAttachmentPreview('pending');
    expect(inspectors.attachmentPreviewUrl.value).toBe('blob:attachment');
    expect(inspectors.attachmentPreviewLoading.value).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(readText).not.toHaveBeenCalled();

    inspectors.closeAttachmentPreview();
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:attachment');
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

  it.each(['attachment', 'link'])('loads saved HTML through a %s and switches to the next previewable attachment', async (source) => {
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
        file_external_id: 'file-html-uuid',
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
      ...(source === 'link' ? { fileId: 'FILE-HTML-UUID' } : { content: htmlContent }),
      contents: [htmlContent, textContent],
    });

    expect(inspectors.attachmentPreviewKind.value).toBe('html');
    expect(inspectors.attachmentPreviewText.value).toBe(html);
    expect(inspectors.attachmentPreviewCanNavigate.value).toBe(true);
    expect(apiMocks.get).not.toHaveBeenCalled();

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
