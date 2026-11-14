import { computed, ref, watch, type ComputedRef, type Ref } from 'vue';
import { api, getApiErrorMessage } from '@/api/client';
import {
  canTogglePendingImageOriginal, createPendingChatFiles, initialPendingImageState, isImageMimeType,
  pendingImageStateAfterInspection, pendingImageStateAfterConversion, pendingImageStatePatch,
  validateFilesForChatUpload, type ChatUploadPolicy, type DraftAttachmentSnapshot,
  type PendingChatFile, type PendingImageState,
} from '@/features/chat/attachments';
import { convertImageFile, enqueueImageConversion, inspectImageFile, MODEL_IMAGE_LIMITS } from '@/features/chat/imageNormalization';
import { abortChatUploadSession, type ChatUploadSessionOptions } from '@/features/chat/upload';
import { publishChatChange } from '@/features/chat/chatEvents';
import { translate } from '@/i18n';

type Target = { chatId: number; userId: number };
type Session = {
  target: Target; policy: ChatUploadPolicy; files: Ref<PendingChatFile[]>; pending: Map<string, Promise<void>>;
  removed: Set<string>; workers: Map<string, Ref<PendingChatFile[]>[]>;
  refreshSequence: number; mutations: number; desired: Map<string, boolean>;
};
type AttachmentResponse = { attachment: DraftAttachmentSnapshot };
const requestOptions = { showErrorBanner: false, invalidateServerState: false, retry: false as const };
const endpoint = (s: Session, id?: string) =>
  `/api/bff/chat-drafts/${s.target.chatId}/attachments${id ? `/${id}` : ''}`;

/** Durable file state is independent of text revisions and never enters text recovery storage. */
export function useChatDraftAttachments(options: {
  target: ComputedRef<Target | null>;
  files: Ref<PendingChatFile[]>;
  policy: ComputedRef<ChatUploadPolicy>;
  error: Ref<string>;
  upload: (files: Ref<PendingChatFile[]>, id: string, chatId: number, options: ChatUploadSessionOptions) => Promise<string | null>;
}) {
  const sessions = new Map<string, Session>();
  let current: Session | null = null;
  let displaying = false;
  let disposed = false;
  const enabled = computed(() => options.target.value !== null);
  const display = (s: Session) => {
    if (current !== s || disposed) return;
    displaying = true;
    options.files.value = s.files.value;
    displaying = false;
  };
  const find = (s: Session, id: string) => s.files.value.find((item) => item.id === id);
  const patch = (s: Session, id: string, attrs: Partial<PendingChatFile>) => {
    s.files.value = s.files.value.map((item) => item.id === id ? { ...item, ...attrs } : item);
    display(s);
  };
  const changed = (s: Session) => publishChatChange({ operation: 'touch', id: s.target.chatId, meta: { reason: 'draft-changed' } });
  const remoteFile = (snapshot: DraftAttachmentSnapshot, policy: ChatUploadPolicy): PendingChatFile => {
    const metadata = snapshot.metadata;
    const original = snapshot.original ?? {
      name: String(metadata.filename || 'Attachment'), size: Number(metadata.size_bytes || 0),
      type: String(metadata.mime_type || 'application/octet-stream'), url: '',
    };
    const selected = snapshot.keep_original ? original : snapshot.compressed ?? original;
    const image: PendingImageState | null = snapshot.status === 'ready' && isImageMimeType(original.type) && ('original_embeddable' in metadata || metadata.failed === true) ? {
      phase: 'ready', keepOriginal: snapshot.keep_original,
      originalEmbeddable: metadata.original_embeddable === true,
      original: { width: Number(metadata.width) || null, height: Number(metadata.height) || null, size: original.size },
      compressed: snapshot.compressed ? { file: snapshot.compressed,
        width: Number(metadata.compressed_width) || 0, height: Number(metadata.compressed_height) || 0 } : null,
      failed: metadata.failed === true, sizeLimitBytes: policy.maxFileSizeBytes,
    } : null;
    return {
      id: snapshot.id, file: selected, sourceFile: original, name: selected.name, size: selected.size,
      mimeType: selected.type, uploadTotalBytes: selected.size, image, draftAttachment: snapshot, uploadId: null,
      uploadStatus: snapshot.status === 'ready' ? 'uploaded' : 'error',
      uploadedBytes: snapshot.status === 'ready' ? selected.size : 0,
      progress: snapshot.status === 'ready' ? 1 : 0, speedBps: 0, etaSeconds: null, abortHandle: null,
      error: snapshot.status === 'ready' ? '' : translate('Upload is unfinished. Finish it on the original device or remove and attach the file again.'),
    };
  };
  const adopt = (s: Session, snapshot: DraftAttachmentSnapshot) => {
    if (s.removed.has(snapshot.id)) return;
    if (snapshot.status === 'deleted') {
      s.files.value = s.files.value.filter((item) => item.id !== snapshot.id);
      s.removed.add(snapshot.id);
    } else {
      const existing = find(s, snapshot.id);
      if ((existing?.draftAttachment?.revision ?? -1) > snapshot.revision) return;
      const restored = remoteFile(snapshot, s.policy);
      if (existing) patch(s, snapshot.id, restored);
      else s.files.value = [...s.files.value, restored];
    }
    display(s);
  };
  const refresh = async (s = current) => {
    if (!s || disposed) return;
    const sequence = ++s.refreshSequence;
    const mutations = s.mutations;
    try {
      const payload = await api.get<{ attachments: DraftAttachmentSnapshot[] }>(endpoint(s), requestOptions);
      if (!payload?.attachments || sequence !== s.refreshSequence || mutations !== s.mutations) return;
      const ids = new Set(payload.attachments.map((item) => item.id));
      s.files.value = s.files.value.filter((item) => s.pending.has(item.id) ||
        !item.draftAttachment || ids.has(item.id));
      for (const snapshot of payload.attachments) {
        if (s.pending.has(snapshot.id)) continue;
        const local = find(s, snapshot.id);
        if (snapshot.status === 'pending' && local?.file instanceof File) {
          patch(s, snapshot.id, { draftAttachment: snapshot });
        } else adopt(s, snapshot);
      }
      display(s);
    } catch (error) {
      if (current === s) options.error.value = getApiErrorMessage(error, translate('Failed to load draft attachments.'));
    }
  };
  const mutate = async (s: Session, id: string, body: Record<string, unknown>) => {
    s.mutations++;
    return (await api.put<AttachmentResponse>(endpoint(s, id), body, requestOptions)).attachment;
  };
  const applyImage = (s: Session, id: string, image: PendingImageState | null) => {
    const item = find(s, id);
    if (item) patch(s, id, { ...pendingImageStatePatch(item, image).patch,
      uploadStatus: item.draftAttachment?.status === 'ready' ? 'uploaded' : 'uploading',
      ...(item.draftAttachment?.status === 'ready' ? { progress: 1, uploadTotalBytes: (image?.keepOriginal ? item.sourceFile : image?.compressed?.file)?.size ?? item.size, uploadedBytes: (image?.keepOriginal ? item.sourceFile : image?.compressed?.file)?.size ?? item.size } : {}) });
  };
  const prepare = async (s: Session, id: string, source: File) => {
    if (!isImageMimeType(source.type)) return;
    try {
      const plan = await inspectImageFile(source);
      let image = find(s, id)?.image;
      if (!image) return;
      if (!plan) { applyImage(s, id, null); return; }
      applyImage(s, id, pendingImageStateAfterInspection(image, plan));
      if (plan.action !== 'convert') return;
      const converted = await enqueueImageConversion(() => convertImageFile(source, plan,
        { limits: { ...MODEL_IMAGE_LIMITS, maxBytes: Math.min(MODEL_IMAGE_LIMITS.maxBytes, s.policy.maxFileSizeBytes) } }));
      image = find(s, id)?.image;
      if (image) applyImage(s, id, pendingImageStateAfterConversion(image, converted));
    } catch {
      const image = find(s, id)?.image;
      if (image) applyImage(s, id, { ...image, phase: 'ready', failed: true });
    }
  };
  const save = (s: Session, id: string): Promise<void> => {
    const existing = s.pending.get(id);
    if (existing) return existing;
    const work = (async () => {
      const item = find(s, id);
      if (!item || s.removed.has(id)) return;
      const source = item.sourceFile ?? item.file;
      if (!(source instanceof File)) throw new Error(translate('Upload is unfinished. Finish it on the original device or remove and attach the file again.'));
      patch(s, id, { uploadStatus: 'uploading', error: '' });
      const started = await mutate(s, id, { operation: 'start', filename: source.name, mime_type: source.type, size_bytes: source.size });
      if (started.status === 'deleted') { adopt(s, started); return; }
      if (started.status === 'ready') { adopt(s, await synchronizeSelection(s, started)); s.workers.delete(id); return; }
      patch(s, id, { draftAttachment: started });
      await prepare(s, id, source);
      if (s.removed.has(id) || !find(s, id)) return;
      const compressed = find(s, id)?.image?.compressed?.file;
      let workers = s.workers.get(id);
      if (!workers) {
        workers = [ref(createPendingChatFiles([source]))];
        if (compressed instanceof File) workers.push(ref(createPendingChatFiles([compressed])));
        s.workers.set(id, workers);
      }
      const total = workers.reduce((sum, worker) => sum + worker.value[0]!.size, 0);
      const stop = watch(workers, () => {
        const bytes = workers!.reduce((sum, worker) => sum + (worker.value[0]?.uploadedBytes ?? 0), 0);
        patch(s, id, { uploadedBytes: bytes, uploadTotalBytes: total, progress: total ? bytes / total : 0 });
      }, { deep: true });
      try {
        const ids: string[] = [];
        for (const worker of workers) {
          if (s.removed.has(id)) return;
          const uploaded = await options.upload(worker, worker.value[0]!.id, s.target.chatId, { purpose: 'draft' });
          if (!uploaded) throw new Error('Failed to upload attachment.');
          ids.push(uploaded);
        }
        if (s.removed.has(id)) return;
        const image = find(s, id)?.image;
        const snapshot = await mutate(s, id, {
          operation: 'finish', original_upload_id: ids[0], compressed_upload_id: ids[1],
          keep_original: image?.keepOriginal ?? false,
          image: image ? { width: image.original.width, height: image.original.height,
            compressed_width: image.compressed?.width, compressed_height: image.compressed?.height,
            original_embeddable: image.originalEmbeddable, failed: image.failed } : {},
        });
        const selected = await synchronizeSelection(s, snapshot);
        adopt(s, selected);
        s.workers.delete(id);
        changed(s);
      } finally { stop(); }
    })().catch((error) => {
      if (!s.removed.has(id)) patch(s, id, { uploadStatus: 'error', error: getApiErrorMessage(error, translate('Failed to save draft attachment.')) });
      throw error;
    }).finally(() => { s.pending.delete(id); if (disposed && ![...sessions.values()].some((session) => session.pending.size)) window.removeEventListener('beforeunload', beforeUnload); });
    s.pending.set(id, work);
    return work;
  };
  const add = (files: File[]) => {
    const s = current;
    if (!s) return;
    s.policy = options.policy.value;
    const { accepted, errors } = validateFilesForChatUpload(files, options.policy.value, { deferImageSizeCheck: true });
    options.error.value = errors[0] || '';
    const items = createPendingChatFiles(accepted).map((item) => ({ ...item,
      image: isImageMimeType(item.mimeType) ? initialPendingImageState(item.file, options.policy.value.maxFileSizeBytes) : null }));
    s.files.value = [...s.files.value, ...items];
    display(s);
    for (const item of items) void save(s, item.id).catch(() => {});
  };
  const remove = async (id: string) => {
    const s = current;
    if (!s) return;
    s.removed.add(id); s.mutations++;
    for (const worker of s.workers.get(id) ?? []) worker.value[0]?.abortHandle?.();
    try {
      await api.del(endpoint(s, id), requestOptions);
      s.files.value = s.files.value.filter((item) => item.id !== id);
      display(s); changed(s);
      for (const worker of s.workers.get(id) ?? []) {
        const uploadId = worker.value[0]?.uploadId;
        if (uploadId) void abortChatUploadSession(s.target.chatId, uploadId).catch(() => {});
      }
      s.workers.delete(id);
    } catch (error) {
      s.removed.delete(id);
      patch(s, id, { uploadStatus: 'error', error: getApiErrorMessage(error, translate('Failed to remove draft attachment.')) });
    }
  };
  const synchronizeSelection = async (s: Session, initial: DraftAttachmentSnapshot) => {
    let snapshot = initial;
    while (!s.removed.has(snapshot.id) && snapshot.status === 'ready' &&
      s.desired.has(snapshot.id) && s.desired.get(snapshot.id) !== snapshot.keep_original) {
      const desired = s.desired.get(snapshot.id)!;
      const previousRevision = snapshot.revision;
      snapshot = await mutate(s, snapshot.id, { operation: 'select', expected_revision: previousRevision, keep_original: desired });
      if (snapshot.revision !== previousRevision + 1 || snapshot.keep_original !== desired) {
        // Another device won the compare-and-swap; do not overwrite its newer choice.
        s.desired.delete(snapshot.id);
        break;
      }
    }
    s.desired.delete(snapshot.id);
    return snapshot;
  };
  const select = async (id: string, keepOriginal: boolean) => {
    const s = current;
    const item = s && find(s, id);
    if (!s || !item?.image || !canTogglePendingImageOriginal(item.image)) return;
    s.desired.set(id, keepOriginal);
    applyImage(s, id, { ...item.image, keepOriginal });
    if (s.pending.has(id) || item.draftAttachment?.status !== 'ready') return;
    const work = (async () => {
      const snapshot = await synchronizeSelection(s, item.draftAttachment!);
      adopt(s, snapshot); changed(s);
    })().catch((error) => {
      adopt(s, item.draftAttachment!);
      if (current === s) options.error.value = getApiErrorMessage(error, translate('Failed to save draft attachment.'));
      throw error;
    }).finally(() => s.pending.delete(id));
    s.pending.set(id, work);
    await work;
  };
  const ensureSaved = async (ids: ReadonlySet<string>) => {
    const s = current;
    if (!s) return [];
    for (const id of ids) {
      if (s.pending.has(id)) await s.pending.get(id);
      const item = find(s, id);
      if (!item || s.removed.has(id)) throw new Error(translate('Draft attachment was removed.'));
      if (item.draftAttachment?.status !== 'ready') await save(s, id);
    }
    return [...ids].map((id) => {
      const snapshot = find(s, id)?.draftAttachment;
      if (!snapshot || snapshot.status !== 'ready') throw new Error(translate('Draft attachment is not ready.'));
      return { id, revision: snapshot.revision };
    });
  };
  const acknowledge = (ids: ReadonlySet<string>, chatId: number) => {
    const s = [...sessions.values()].find((session) => session.target.chatId === chatId);
    if (!s) return;
    s.mutations++;
    for (const id of ids) s.removed.add(id);
    s.files.value = s.files.value.filter((item) => !ids.has(item.id));
    display(s);
  };
  const stopFiles = watch(options.files, (files) => {
    if (!displaying && current) current.files.value = files;
  }, { flush: 'sync' });
  const stopTarget = watch(options.target, (target) => {
    if (target && current?.target.chatId === target.chatId && current.target.userId === target.userId) return;
    const previous = current;
    current = null;
    if (previous) { displaying = true; options.files.value = []; displaying = false; }
    if (!target) return;
    const key = `${target.userId}:${target.chatId}`;
    let session = sessions.get(key);
    if (!session) {
      session = { target, policy: options.policy.value, files: ref([]), pending: new Map(), removed: new Set(), workers: new Map(), refreshSequence: 0, mutations: 0, desired: new Map() };
      sessions.set(key, session);
    }
    current = session; display(session); void refresh(session);
  }, { immediate: true, flush: 'sync' });
  const wake = () => {
    void refresh();
    if (navigator.onLine === false) return;
    for (const s of sessions.values()) {
      if (s.target.userId !== options.target.value?.userId) continue;
      for (const item of s.files.value) {
        if (item.uploadStatus === 'error' && item.file instanceof File) void save(s, item.id).catch(() => {});
      }
    }
  };
  const retry = (id: string) => { if (current) void save(current, id).catch(() => {}); };
  const beforeUnload = (event: BeforeUnloadEvent) => {
    if (![...sessions.values()].some((s) => s.pending.size > 0 || s.files.value.some((item) => item.file instanceof File))) return;
    event.preventDefault(); event.returnValue = '';
  };
  window.addEventListener('focus', wake); window.addEventListener('online', wake);
  window.addEventListener('beforeunload', beforeUnload);
  const dispose = () => {
    disposed = true; stopFiles(); stopTarget();
    window.removeEventListener('focus', wake); window.removeEventListener('online', wake);
    if (![...sessions.values()].some((s) => s.pending.size)) window.removeEventListener('beforeunload', beforeUnload);
    // In-flight uploads retain their captured chat/session and can finish after navigation.
  };
  return { enabled, add, remove, select, retry, ensureSaved, acknowledge, refresh, dispose };
}
