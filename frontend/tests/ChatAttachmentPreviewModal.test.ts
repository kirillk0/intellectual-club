import { mount, type VueWrapper } from '@vue/test-utils';

import ChatAttachmentPreviewModal from '@/components/chat/ChatAttachmentPreviewModal.vue';
import type { AttachmentPreviewKind } from '@/features/chat/attachments';

const ModalWindowStub = {
  props: ['modalClass', 'backdropClass', 'closeOnBackdrop'],
  emits: ['cancel'],
  template:
    '<div class="modal-window-stub" :class="[modalClass, backdropClass]" :data-close-on-backdrop="closeOnBackdrop"><slot /></div>',
};

function mountPreview(kind: AttachmentPreviewKind, text = '', url = '/attachment') {
  return mount(ChatAttachmentPreviewModal, {
    props: {
      open: true,
      title: 'preview.html',
      kind,
      text,
      url,
    },
    global: {
      stubs: {
        ModalWindow: ModalWindowStub,
        SvgIcon: true,
      },
    },
  });
}

describe('ChatAttachmentPreviewModal', () => {
  let wrappers: VueWrapper[] = [];

  afterEach(() => {
    for (const wrapper of wrappers) wrapper.unmount();
    wrappers = [];
  });

  it('renders HTML as an isolated script-enabled srcdoc document', () => {
    const html = '<!doctype html><style>body{color:red}</style><script>document.body.dataset.ready="yes"</script>';
    const wrapper = mountPreview('html', html);
    wrappers.push(wrapper);

    const iframe = wrapper.get('iframe').element as HTMLIFrameElement;

    expect(iframe.srcdoc).toBe(html);
    expect(iframe.getAttribute('sandbox')).toBe('allow-scripts');
    expect(iframe.getAttribute('sandbox')).not.toContain('allow-same-origin');
    expect(iframe.getAttribute('allow')).toBe(
      "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'"
    );
    expect(iframe.getAttribute('referrerpolicy')).toBe('no-referrer');
    expect(iframe.title).toBe('preview.html');
  });

  it('recreates the iframe when switching attachments', async () => {
    const wrapper = mountPreview('html', '<script>window.previewRuns = 1</script>', '/first');
    wrappers.push(wrapper);
    const firstIframe = wrapper.get('iframe').element;

    await wrapper.setProps({ url: '/second' });

    expect(wrapper.get('iframe').element).not.toBe(firstIframe);
  });

  it.each(['image', 'html', 'markdown', 'text', 'binary'] as const)(
    'opens the %s preview full-screen with only the collapse action remaining',
    async (kind) => {
      const wrapper = mountPreview(kind, '<p>content</p>');
      wrappers.push(wrapper);
      const iframe = kind === 'html' ? wrapper.get('iframe').element : null;

      await wrapper.get('button[aria-label="Open full-screen preview"]').trigger('click');

      expect(wrapper.classes()).toContain('attachment-preview-modal--fullscreen');
      expect(wrapper.classes()).toContain('attachment-preview-backdrop--fullscreen');
      expect(wrapper.attributes('data-close-on-backdrop')).toBe('false');
      expect(wrapper.find('.attachment-preview-title-wrap').exists()).toBe(false);
      expect(wrapper.findAll('.attachment-preview-action')).toHaveLength(1);
      expect(wrapper.get('.attachment-preview-action').attributes('aria-label')).toBe(
        'Exit full-screen preview'
      );
      expect(wrapper.get('.attachment-preview-content').classes()).toContain(
        'attachment-preview-content--fullscreen'
      );
      if (iframe) expect(wrapper.get('iframe').element).toBe(iframe);
    }
  );

  it('returns to the regular modal instead of closing from full-screen mode', async () => {
    const wrapper = mountPreview('text', 'content');
    wrappers.push(wrapper);

    await wrapper.get('button[aria-label="Open full-screen preview"]').trigger('click');
    await wrapper.get('button[aria-label="Exit full-screen preview"]').trigger('click');

    expect(wrapper.emitted('close')).toBeUndefined();
    expect(wrapper.classes()).not.toContain('attachment-preview-modal--fullscreen');
    expect(wrapper.find('button[aria-label="Close preview"]').exists()).toBe(true);
  });

  it('collapses on the first cancel and closes on the second', async () => {
    const wrapper = mountPreview('text', 'content');
    wrappers.push(wrapper);
    const modal = wrapper.getComponent(ModalWindowStub);

    await wrapper.get('button[aria-label="Open full-screen preview"]').trigger('click');
    modal.vm.$emit('cancel');
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('close')).toBeUndefined();
    expect(wrapper.classes()).not.toContain('attachment-preview-modal--fullscreen');

    modal.vm.$emit('cancel');
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('close')).toHaveLength(1);
  });

  it.each([
    ['image', '.attachment-preview-image'],
    ['markdown', '.attachment-preview-markdown'],
    ['text', '.attachment-preview-text'],
    ['binary', '.attachment-preview-state'],
  ] as const)('keeps the existing %s renderer', (kind, selector) => {
    const wrapper = mountPreview(kind, 'content');
    wrappers.push(wrapper);

    expect(wrapper.find('iframe').exists()).toBe(false);
    expect(wrapper.find(selector).exists()).toBe(true);
  });
});
