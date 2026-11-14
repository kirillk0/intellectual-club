import {
  canTogglePendingImageOriginal,
  createPendingChatFiles,
  describePendingFileUploadStatus,
  describePendingImage,
  getAttachmentPreviewKind,
  initialPendingImageState,
  pendingFileSizeError,
  pendingFileUploadTarget,
  pendingImageStateAfterConversion,
  pendingImageStateAfterInspection,
  pendingImageStatePatch,
  validateFilesForChatUpload,
  validatePendingFilesForChatUpload,
  type ChatUploadPolicy,
  type PendingChatFile,
  type PendingImageState,
} from '@/features/chat/attachments';

describe('getAttachmentPreviewKind', () => {
  it.each([
    ['page.html', 'text/html', false],
    ['page.txt', 'text/html; charset=utf-8', false],
    ['page.xhtml', 'application/xhtml+xml', false],
    ['PAGE.HTML', 'application/octet-stream', false],
    ['page.htm', '', false],
    ['page.xhtml', 'application/octet-stream', false],
  ])('recognizes %s with MIME %s as HTML', (name, mimeType, isImage) => {
    expect(getAttachmentPreviewKind(name, mimeType, isImage)).toBe('html');
  });

  it.each([
    ['image.html', 'text/html', true, 'image'],
    ['readme.md', 'text/markdown', false, 'markdown'],
    ['readme.markdown', 'application/octet-stream', false, 'markdown'],
    ['notes.txt', 'text/plain', false, 'text'],
    ['data.json', 'application/json', false, 'text'],
    ['clip.mp4', 'video/mp4', false, 'video'],
    ['clip.bin', 'Video/WebM; codecs=vp9', false, 'video'],
    ['sound.mp3', 'audio/mpeg', false, 'audio'],
    ['sound.bin', 'Audio/Ogg; codecs=opus', false, 'audio'],
    ['document.pdf', 'application/pdf', false, 'pdf'],
    ['document.bin', ' APPLICATION/PDF ; version=1.7', false, 'pdf'],
    ['unknown.mp4', 'application/octet-stream', false, 'binary'],
    ['archive.zip', 'application/zip', false, 'binary'],
  ])('keeps %s classified as %s', (name, mimeType, isImage, expected) => {
    expect(getAttachmentPreviewKind(name, mimeType, isImage)).toBe(expected);
  });
});

describe('pending image attachments', () => {
  const original = new File([new Uint8Array(5_300_000)], 'photo.heic', { type: 'image/heic' });
  const compressed = new File([new Uint8Array(625_000)], 'photo.jpg', { type: 'image/jpeg' });

  const pendingImage = (image: Partial<PendingImageState> = {}): PendingChatFile => ({
    ...createPendingChatFiles([original])[0],
    image: { ...initialPendingImageState(original), ...image },
  });

  const readyCompressed: Partial<PendingImageState> = {
    phase: 'ready',
    originalEmbeddable: false,
    original: { width: 4032, height: 3024, size: original.size },
    compressed: { file: compressed, width: 2000, height: 1500 },
  };

  it('tracks the inspection and conversion outcome', () => {
    const inspected = pendingImageStateAfterInspection(initialPendingImageState(original), {
      action: 'convert',
      header: { format: 'heic', width: null, height: null },
      reasons: ['format'],
    });
    expect(inspected).toMatchObject({ phase: 'processing', originalEmbeddable: false });

    expect(
      pendingImageStateAfterConversion(inspected, {
        kind: 'converted',
        file: compressed,
        width: 2000,
        height: 1500,
        sourceWidth: 4032,
        sourceHeight: 3024,
      })
    ).toMatchObject({
      phase: 'ready',
      original: { width: 4032, height: 3024, size: original.size },
      compressed: { file: compressed, width: 2000, height: 1500 },
      failed: false,
    });
    expect(pendingImageStateAfterConversion(inspected, { kind: 'failed', reason: 'decode' })).toMatchObject({
      phase: 'ready',
      compressed: null,
      failed: true,
    });
    expect(pendingImageStateAfterConversion(inspected, { kind: 'unchanged', width: 800, height: 600 })).toMatchObject({
      phase: 'ready',
      originalEmbeddable: true,
      compressed: null,
    });

    const kept = pendingImageStateAfterInspection(initialPendingImageState(original), {
      action: 'keep',
      header: { format: 'jpeg', width: 1200, height: 900 },
    });
    expect(kept).toMatchObject({ phase: 'ready', originalEmbeddable: true, original: { width: 1200, height: 900 } });
  });

  it('waits for the compressed copy unless the original is requested', () => {
    expect(pendingFileUploadTarget(pendingImage({ phase: 'inspecting' }))).toBeNull();
    expect(pendingFileUploadTarget(pendingImage({ phase: 'processing' }))).toBeNull();
    expect(pendingFileUploadTarget(pendingImage({ phase: 'processing', keepOriginal: true }))).toBe(original);
    expect(pendingFileUploadTarget(pendingImage(readyCompressed))).toBe(compressed);
    expect(pendingFileUploadTarget(pendingImage({ ...readyCompressed, keepOriginal: true }))).toBe(original);
    expect(pendingFileUploadTarget(pendingImage({ phase: 'ready', failed: true }))).toBe(original);
    expect(pendingFileUploadTarget({ ...pendingImage(), image: null })).toBe(original);
  });

  it('offers the toggle only while the compressed copy can differ from the original', () => {
    expect(canTogglePendingImageOriginal(pendingImage({ phase: 'processing' }).image!)).toBe(true);
    expect(canTogglePendingImageOriginal(pendingImage(readyCompressed).image!)).toBe(true);
    expect(canTogglePendingImageOriginal(pendingImage({ phase: 'ready', originalEmbeddable: true }).image!)).toBe(false);
    expect(canTogglePendingImageOriginal(pendingImage({ phase: 'ready', failed: true }).image!)).toBe(false);
  });

  it('switches the uploaded variant and drops the previous upload', () => {
    const uploaded: PendingChatFile = {
      ...pendingImage(readyCompressed),
      file: compressed,
      name: compressed.name,
      size: compressed.size,
      mimeType: compressed.type,
      uploadId: 'upload-compressed',
      uploadStatus: 'uploaded',
      uploadedBytes: compressed.size,
      progress: 1,
      variantRevision: 2,
    };

    const { patch, variantChanged } = pendingImageStatePatch(uploaded, { ...uploaded.image!, keepOriginal: true });

    expect(variantChanged).toBe(true);
    expect(patch).toMatchObject({
      file: original,
      name: 'photo.heic',
      size: original.size,
      mimeType: 'image/heic',
      uploadId: null,
      uploadStatus: 'idle',
      uploadedBytes: 0,
      progress: 0,
      variantRevision: 3,
    });
  });

  it('keeps the upload when the uploaded variant stays the same', () => {
    const uploading: PendingChatFile = {
      ...pendingImage({ phase: 'processing', keepOriginal: true }),
      uploadId: 'upload-original',
      uploadStatus: 'uploading',
    };

    const { patch, variantChanged } = pendingImageStatePatch(uploading, {
      ...uploading.image!,
      phase: 'ready',
      compressed: { file: compressed, width: 2000, height: 1500 },
    });

    expect(variantChanged).toBe(false);
    expect(patch).not.toHaveProperty('uploadId');
    expect(patch).toMatchObject({ file: original });
  });

  it('describes what the compression did', () => {
    expect(describePendingImage(pendingImage(readyCompressed).image!)).toEqual({
      originalChecked: false,
      toggleDisabled: false,
      toggleTitle: 'Upload the original file without compression',
      note: '4032×3024, 5.1 MB → 2000×1500, 610.4 KB',
      warning: false,
    });
  });

  it('warns that an oversized original reaches the model as a file link', () => {
    expect(describePendingImage(pendingImage({ ...readyCompressed, keepOriginal: true }).image!)).toMatchObject({
      originalChecked: true,
      toggleDisabled: false,
      note: 'The model gets a link to the file instead of the image',
      warning: true,
    });
    expect(describePendingImage(pendingImage({ phase: 'inspecting', keepOriginal: true }).image!)).toMatchObject({
      note: '',
      warning: false,
    });
  });

  it('explains why the toggle is unavailable', () => {
    expect(describePendingImage(pendingImage({ phase: 'ready', originalEmbeddable: true }).image!)).toMatchObject({
      originalChecked: true,
      toggleDisabled: true,
      note: 'Fits the model limits',
      warning: false,
    });
    expect(describePendingImage(pendingImage({ phase: 'ready', failed: true }).image!)).toMatchObject({
      originalChecked: true,
      toggleDisabled: true,
      note: "The browser couldn't process this image, so the model gets it only as a file.",
      warning: true,
    });
  });

  it('blocks the original when the upload policy would reject it', () => {
    const limited = (image: Partial<PendingImageState>) => ({ ...initialPendingImageState(original, 1024 * 1024), ...image });

    expect(canTogglePendingImageOriginal(limited({ phase: 'inspecting' }))).toBe(false);
    expect(canTogglePendingImageOriginal(limited(readyCompressed))).toBe(false);
    expect(canTogglePendingImageOriginal({ ...limited(readyCompressed), sizeLimitBytes: original.size })).toBe(true);
    expect(describePendingImage(limited(readyCompressed))).toEqual({
      originalChecked: false,
      toggleDisabled: true,
      toggleTitle: 'The original exceeds the maximum file size of 1.0 MB',
      note: '4032×3024, 5.1 MB → 2000×1500, 610.4 KB',
      warning: false,
    });
  });

  it('checks the size limit against the variant that is uploaded', () => {
    const limit = 1024 * 1024;
    const error = 'File "photo.heic" exceeds the maximum size of 1.0 MB.';

    expect(pendingFileSizeError(pendingImage({ phase: 'inspecting' }), limit)).toBe('');
    expect(pendingFileSizeError(pendingImage({ phase: 'processing' }), limit)).toBe('');
    expect(pendingFileSizeError(pendingImage(readyCompressed), limit)).toBe('');
    expect(pendingFileSizeError(pendingImage(readyCompressed), 512 * 1024)).toBe(
      'File "photo.heic" exceeds the maximum size of 512.0 KB.'
    );
    expect(pendingFileSizeError(pendingImage({ phase: 'processing', keepOriginal: true }), limit)).toBe(error);
    expect(pendingFileSizeError(pendingImage({ phase: 'ready', failed: true }), limit)).toBe(error);
    expect(pendingFileSizeError({ ...pendingImage(), image: null }, limit)).toBe(error);
  });

  it('validates added attachments by the variant each one uploads', () => {
    const policy: ChatUploadPolicy = { allowsFiles: true, imagesOnly: true, maxFileSizeBytes: 1024 * 1024, accept: 'image/*' };
    const [note] = createPendingChatFiles([new File(['note'], 'note.txt', { type: 'text/plain' })]);

    expect(validatePendingFilesForChatUpload([pendingImage({ phase: 'processing' }), pendingImage(readyCompressed)], policy)).toEqual([]);
    expect(validatePendingFilesForChatUpload([pendingImage({ phase: 'ready', failed: true }), note], policy)).toEqual([
      'File "photo.heic" exceeds the maximum size of 1.0 MB.',
      'Only image files are allowed. "note.txt" was rejected.',
    ]);
    expect(validatePendingFilesForChatUpload([pendingImage(readyCompressed)], { ...policy, allowsFiles: false })).toEqual([
      'File uploads are disabled for the current bot and configuration.',
    ]);
  });

  it('reports the processing state until the upload starts', () => {
    expect(describePendingFileUploadStatus(pendingImage({ phase: 'processing' }))).toBe('Processing image…');
    expect(describePendingFileUploadStatus(pendingImage({ phase: 'processing', keepOriginal: true }))).toBe(
      '5.1 MB ready to upload'
    );
  });
});

describe('validateFilesForChatUpload', () => {
  const policy: ChatUploadPolicy = { allowsFiles: true, imagesOnly: false, maxFileSizeBytes: 1_000, accept: '' };
  const photo = new File([new Uint8Array(1_001)], 'photo.png', { type: 'image/png' });
  const scan = new File([new Uint8Array(1_001)], 'scan.pdf', { type: 'application/pdf' });
  const small = new File([new Uint8Array(1_000)], 'small.pdf', { type: 'application/pdf' });

  it('rejects files over the size limit', () => {
    expect(validateFilesForChatUpload([photo, scan, small], policy)).toEqual({
      accepted: [small],
      errors: ['File "photo.png" exceeds the maximum size of 1000 B.', 'File "scan.pdf" exceeds the maximum size of 1000 B.'],
    });
  });

  it('leaves the size of images to the check of the uploaded variant when asked to', () => {
    expect(validateFilesForChatUpload([photo, scan, small], policy, { deferImageSizeCheck: true })).toEqual({
      accepted: [photo, small],
      errors: ['File "scan.pdf" exceeds the maximum size of 1000 B.'],
    });
    expect(
      validateFilesForChatUpload([photo], { ...policy, allowsFiles: false }, { deferImageSizeCheck: true }).errors
    ).toEqual(['File uploads are disabled for the current bot and configuration.']);
  });
});
