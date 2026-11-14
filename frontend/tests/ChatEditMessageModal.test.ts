import { mount, type VueWrapper } from '@vue/test-utils';
import { nextTick } from 'vue';

import ChatEditMessageModal from '@/components/chat/ChatEditMessageModal.vue';
import {
  createPendingChatFiles,
  initialPendingImageState,
  type PendingChatFile,
  type PendingImageState,
} from '@/features/chat/attachments';

describe('ChatEditMessageModal document scroll lock', () => {
  let wrapper: VueWrapper | null = null;
  let coarsePointer = false;
  let visualViewport: EventTarget & { height: number };

  beforeEach(() => {
    coarsePointer = false;
    visualViewport = Object.assign(new EventTarget(), { height: 720 });
    document.documentElement.style.cssText = '';
    document.body.style.cssText = '';
    vi.stubGlobal(
      'matchMedia',
      vi.fn((query: string) => ({
        matches:
          coarsePointer && (query.includes('(pointer: coarse)') || query.includes('(hover: none)')),
        media: query,
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn(),
      }))
    );
    vi.stubGlobal('requestAnimationFrame', vi.fn(() => 1));
    vi.stubGlobal('visualViewport', visualViewport);
    Object.defineProperty(window, 'scrollX', { configurable: true, value: 18 });
    Object.defineProperty(window, 'scrollY', { configurable: true, value: 240 });
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    document.documentElement.style.cssText = '';
    document.body.style.cssText = '';
  });

  function mountModal() {
    wrapper = mount(ChatEditMessageModal, {
      props: {
        open: true,
        mode: 'branch',
        modelValue: ['Message'],
      },
    });
    return wrapper;
  }

  function setInitialDocumentStyles() {
    document.documentElement.style.overflow = 'scroll';
    document.body.style.position = 'relative';
    document.body.style.overflow = 'auto';
  }

  function expectInitialDocumentStyles() {
    expect(document.documentElement.style.overflow).toBe('scroll');
    expect(document.body.style.position).toBe('relative');
    expect(document.body.style.overflow).toBe('auto');
  }

  it('uses the shared modal lock and restores the original document styles after closing', async () => {
    setInitialDocumentStyles();
    const mounted = mountModal();

    expect(document.documentElement.style.overflow).toBe('hidden');
    expect(document.body.style.position).toBe('fixed');
    expect(document.body.style.overflow).toBe('hidden');

    await mounted.setProps({ open: false });

    expectInitialDocumentStyles();
    expect(window.scrollTo).toHaveBeenCalledOnce();
    expect(window.scrollTo).toHaveBeenCalledWith(18, 240);
  });

  it('keeps the shared lock while switching to the mobile layout', async () => {
    setInitialDocumentStyles();
    const mounted = mountModal();

    coarsePointer = true;
    visualViewport.dispatchEvent(new Event('resize'));
    await nextTick();

    expect(document.querySelector('.edit-message-modal--mobile-layer')).not.toBeNull();
    expect(document.documentElement.style.overflow).toBe('hidden');
    expect(document.body.style.position).toBe('fixed');
    expect(document.body.style.overflow).toBe('hidden');

    await mounted.setProps({ open: false });

    expectInitialDocumentStyles();
    expect(window.scrollTo).toHaveBeenCalledOnce();
  });

  it('releases the shared lock when unmounted while open', () => {
    setInitialDocumentStyles();
    const mounted = mountModal();

    mounted.unmount();
    wrapper = null;

    expectInitialDocumentStyles();
    expect(window.scrollTo).toHaveBeenCalledOnce();
    expect(window.scrollTo).toHaveBeenCalledWith(18, 240);
  });
});

describe('ChatEditMessageModal pending images', () => {
  let wrapper: VueWrapper | null = null;

  beforeEach(() => {
    vi.stubGlobal(
      'matchMedia',
      vi.fn((query: string) => ({
        matches: false,
        media: query,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
      }))
    );
    vi.stubGlobal('requestAnimationFrame', vi.fn(() => 1));
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  });

  afterEach(() => {
    wrapper?.unmount();
    wrapper = null;
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  const original = new File([new Uint8Array(5_300_000)], 'photo.heic', { type: 'image/heic' });
  const compressed = new File([new Uint8Array(625_000)], 'photo.jpg', { type: 'image/jpeg' });
  const pendingImage = (image: Partial<PendingImageState>): PendingChatFile => ({
    ...createPendingChatFiles([original])[0],
    id: 'pending-image',
    file: compressed,
    name: compressed.name,
    size: compressed.size,
    mimeType: compressed.type,
    image: {
      ...initialPendingImageState(original),
      phase: 'ready',
      originalEmbeddable: false,
      original: { width: 4032, height: 3024, size: original.size },
      compressed: { file: compressed, width: 2000, height: 1500 },
      ...image,
    },
  });

  const mountModal = (pendingFiles: PendingChatFile[], saving = false) => {
    wrapper = mount(ChatEditMessageModal, {
      attachTo: document.body,
      props: { open: true, mode: 'edit', modelValue: ['Message'], pendingFiles, saving },
    });
    return wrapper;
  };

  const toggle = () => document.body.querySelector<HTMLInputElement>('.pending-image-options input[type="checkbox"]');

  it('shows the compression result and switches to the original without opening the preview', async () => {
    const mounted = mountModal([pendingImage({})]);

    expect(document.body.querySelector('.pending-image-options__note')?.textContent).toBe(
      '4032×3024, 5.1 MB → 2000×1500, 610.4 KB'
    );
    expect(toggle()?.checked).toBe(false);

    toggle()!.click();
    await nextTick();

    expect(mounted.emitted('set-pending-file-original')).toEqual([['pending-image', true]]);
    expect(mounted.emitted('preview-pending-file')).toBeUndefined();
  });

  it('warns about an oversized original and locks the toggle while saving', () => {
    mountModal([pendingImage({ keepOriginal: true })], true);

    expect(toggle()?.checked).toBe(true);
    expect(toggle()?.disabled).toBe(true);
    expect(document.body.querySelector('.pending-image-options__note--warning')?.textContent).toBe(
      'The model gets a link to the file instead of the image'
    );
  });

  it('shows no image controls for other files', () => {
    mountModal([createPendingChatFiles([new File(['note'], 'note.txt', { type: 'text/plain' })])[0]]);

    expect(document.body.querySelector('.attachment-row')).not.toBeNull();
    expect(document.body.querySelector('.pending-image-options')).toBeNull();
  });
});
