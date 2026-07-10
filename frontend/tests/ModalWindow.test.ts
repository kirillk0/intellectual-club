import { mount, type VueWrapper } from '@vue/test-utils';

import ModalWindow from '@/components/ModalWindow.vue';

describe('ModalWindow document scroll lock', () => {
  let wrappers: VueWrapper[] = [];

  beforeEach(() => {
    wrappers = [];
    document.documentElement.style.cssText = '';
    document.body.style.cssText = '';
    Object.defineProperty(window, 'scrollX', { configurable: true, value: 12 });
    Object.defineProperty(window, 'scrollY', { configurable: true, value: 345 });
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined);
  });

  afterEach(() => {
    for (const wrapper of wrappers) wrapper.unmount();
    vi.restoreAllMocks();
    document.documentElement.style.cssText = '';
    document.body.style.cssText = '';
  });

  function mountModal() {
    const wrapper = mount(ModalWindow, {
      props: { open: true },
      slots: { default: '<p>Modal content</p>' },
    });
    wrappers.push(wrapper);
    return wrapper;
  }

  it('freezes the document and restores its scroll position after closing', async () => {
    document.documentElement.style.overflow = 'scroll';
    document.body.style.position = 'relative';

    const wrapper = mountModal();

    expect(document.documentElement.style.overflow).toBe('hidden');
    expect(document.documentElement.style.overscrollBehavior).toBe('none');
    expect(document.body.style.position).toBe('fixed');
    expect(document.body.style.top).toBe('-345px');
    expect(document.body.style.left).toBe('-12px');
    expect(document.body.style.overflow).toBe('hidden');

    await wrapper.setProps({ open: false });

    expect(document.documentElement.style.overflow).toBe('scroll');
    expect(document.documentElement.style.overscrollBehavior).toBe('');
    expect(document.body.style.position).toBe('relative');
    expect(document.body.style.top).toBe('');
    expect(document.body.style.left).toBe('');
    expect(document.body.style.overflow).toBe('');
    expect(window.scrollTo).toHaveBeenCalledWith(12, 345);
  });

  it('keeps the document frozen until the last stacked modal closes', async () => {
    const first = mountModal();
    const second = mountModal();

    await first.setProps({ open: false });

    expect(document.body.style.position).toBe('fixed');
    expect(window.scrollTo).not.toHaveBeenCalled();

    await second.setProps({ open: false });

    expect(document.body.style.position).toBe('');
    expect(window.scrollTo).toHaveBeenCalledOnce();
    expect(window.scrollTo).toHaveBeenCalledWith(12, 345);
  });
});
