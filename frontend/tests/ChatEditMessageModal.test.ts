import { mount, type VueWrapper } from '@vue/test-utils';
import { nextTick } from 'vue';

import ChatEditMessageModal from '@/components/chat/ChatEditMessageModal.vue';

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
