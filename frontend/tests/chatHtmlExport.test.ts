import { buildChatHtmlExport } from '@/features/chat/chatHtmlExport';
import type { ChatExportPayload } from '@/types/api';
import temml from 'temml';

beforeAll(() => {
  (window as Window & { temml?: typeof temml }).temml = temml;
});

afterAll(() => {
  delete (window as Window & { temml?: typeof temml }).temml;
});

const payload = (): ChatExportPayload => ({
  schema_version: 1,
  exported_at: '2026-09-04T10:00:00Z',
  selected_chat_id: 2,
  root_chat_id: 1,
  chats: [
    {
      id: 1,
      title: 'Root <script>alert(1)</script>',
      note: '',
      subagent: false,
      created_at: '2026-09-04T09:00:00Z',
      updated_at: '2026-09-04T09:10:00Z',
      relation: null,
      bot: { name: 'Assistant', tags: [] },
      llm_configuration: { label: 'Model', tags: [] },
      active_generation: false,
      context: {
        blocks: [{ block_id: 10, source: 'bot', sequence: 0, order: 0, enabled: true }],
        tools: [],
      },
      library: { blocks: [], tools: [] },
      messages: [
        {
          id: 100,
          parent_id: null,
          role: 'user',
          status: 'done',
          created_at: '2026-09-04T09:01:00Z',
          content: [
            {
              type: 'input',
              step_sequence: 1,
              item_sequence: 1,
              parts: [{ text: '**Hello** <script>window.evil = true</script> ![remote](https://example.com/x.png)' }],
              attachments: [
                {
                  name: 'notes.txt',
                  mime_type: 'text/plain',
                  size_bytes: 12,
                  kind: 'file',
                  enabled: true,
                },
              ],
            },
          ],
          working_steps: [
            {
              id: 299,
              sequence: 1,
              status: 'done',
              items: [{ type: 'reasoning', sequence: 1, text: 'USER_WORKING_SHOULD_NOT_RENDER' }],
            },
          ],
        },
      ],
    },
    {
      id: 2,
      title: 'Child / export',
      note: 'Running child',
      subagent: true,
      created_at: '2026-09-04T09:05:00Z',
      updated_at: '2026-09-04T10:00:00Z',
      relation: { parent_chat_id: 1, parent_message_id: 100, kind: 'spawn' },
      bot: null,
      llm_configuration: null,
      active_generation: true,
      context: { blocks: [], tools: [{ tool_instance_id: 20, alias: 'safe', source: 'chat', sequence: 0, enabled: true }] },
      library: { blocks: [{ block_id: 10, sequence: 0, enabled: false }], tools: [] },
      messages: [
        {
          id: 200,
          parent_id: null,
          role: 'assistant',
          status: 'generating',
          error_detail: null,
          created_at: '2026-09-04T09:06:00Z',
          content: [
            {
              type: 'answer',
              step_sequence: 1,
              item_sequence: 2,
              parts: [
                { text: 'Formula: $x^2$\n\n```javascript\nconst answer = 42;\n```' },
                { text: 'Second multipart section' },
              ],
              attachments: [],
            },
          ],
          working_steps: [
            {
              id: 300,
              sequence: 1,
              status: 'streaming',
              response_final: false,
              input_tokens: 14,
              output_tokens: 7,
              items: [
                { type: 'reasoning', sequence: 1, text: 'Thinking **safely**' },
                { type: 'tool_call', sequence: 2, name: 'lookup', arguments: { q: '<query>' } },
                { type: 'tool_result', sequence: 3, text: 'line 1\nline 2', truncated: true },
              ],
            },
          ],
        },
      ],
    },
  ],
  resources: {
    knowledge_blocks: [
      {
        id: 10,
        name: 'Knowledge block',
        version: 3,
        content: '# Full text',
        token_count: 2,
        tags: ['guide'],
        attachments: [],
      },
    ],
    tools: [
      {
        id: 20,
        name: 'Safe tool',
        alias: 'safe',
        type: 'native',
        type_title: 'Native',
        description: 'Public description',
        functions: [{ name: 'lookup', description: 'Looks things up.' }],
      },
    ],
  },
});

describe('buildChatHtmlExport', () => {
  it('creates a self-contained sanitized document with navigation and dialogs', async () => {
    const exported = await buildChatHtmlExport(payload(), { locale: 'en' });

    expect(exported.filename).toBe('child-export-export.html');
    expect(exported.blob.type).toBe('text/html;charset=utf-8');
    expect(exported.html).toMatch(/^<!doctype html>/u);
    expect(exported.html).toContain("default-src 'none'");
    expect(exported.html).toContain("connect-src 'none'");
    expect(exported.html).toContain('<style>');
    expect(exported.html).toContain("script-src 'nonce-chat-export-v1'");
    expect(exported.html).toContain('<script nonce="chat-export-v1">');
    expect(exported.html).not.toMatch(/<script[^>]+src=/u);
    expect(exported.html).not.toMatch(/<link[^>]+stylesheet/u);
    expect(exported.html).not.toContain('<img');
    expect(exported.html).not.toContain('window.evil');
    expect(exported.html).not.toContain('https://example.com/x.png');
    expect(exported.html).toContain('<strong>Hello</strong>');
    expect(exported.html).toContain('<math');
    expect(exported.html).toContain('class="token');
    expect(exported.html).toContain('href="#chat-1"');
    expect(exported.html).toContain('href="#chat-2"');
    expect(exported.html).not.toContain('class="sidebar');
    expect(exported.html).toContain('id="chat-2-related"');
    expect(exported.html).toContain('id="chat-2-context"');
    expect(exported.html).toContain('id="chat-2-library"');
    expect(exported.html).toContain('data-open-panel="chat-2-related"');
    expect(exported.html).toContain('data-open-panel="chat-2-context"');
    expect(exported.html).toContain('id="resource-block-10"');
    expect(exported.html).toContain('id="resource-tool-20"');
    expect(exported.html).toContain('data-open-resource="block-10"');
    expect(exported.html).toContain('data-open-resource="tool-20"');
    expect(exported.html).toContain('notes.txt');
    expect(exported.html).toContain('Attachment content is not included');
    expect(exported.html).toContain('Snapshot of an incomplete generation');
    expect(exported.html).toContain('Preview truncated');
    expect(exported.html).toContain('Second multipart section');
    expect(exported.html).toContain(
      '.content-part+.content-part,.content-item+.content-item{border-top:1px solid var(--line)'
    );
    expect(exported.html).toContain('font-size:.82rem');
    expect(exported.html).not.toContain('USER_WORKING_SHOULD_NOT_RENDER');

    const assistantMessage = new DOMParser()
      .parseFromString(exported.html, 'text/html')
      .querySelector('#chat-2-message-200');
    expect(assistantMessage?.querySelector('.working')?.nextElementSibling?.classList.contains('message-body')).toBe(
      true
    );
    const parsedDocument = new DOMParser().parseFromString(exported.html, 'text/html');
    expect(parsedDocument.querySelector('.export-head [data-chat-link]')).toBeNull();
    expect(parsedDocument.querySelectorAll('#chat-2-related [data-chat-link]')).toHaveLength(2);
  });

  it('uses localized service labels without changing exported content', async () => {
    const exported = await buildChatHtmlExport(payload(), { locale: 'ru' });

    expect(exported.html).toContain('<html lang="ru">');
    expect(exported.html).toContain('Экспорт чата');
    expect(exported.html).toContain('Связанные чаты');
    expect(exported.html).toContain('Снимок незавершённой генерации');
  });

  it('navigates by hash and opens embedded resource dialogs', async () => {
    const exported = await buildChatHtmlExport(payload(), { locale: 'en' });
    const frame = document.createElement('iframe');
    document.body.appendChild(frame);
    const frameWindow = frame.contentWindow;
    const frameDocument = frame.contentDocument;
    expect(frameWindow).toBeTruthy();
    expect(frameDocument).toBeTruthy();
    if (!frameWindow || !frameDocument) return;
    const frameGlobal = frameWindow as Window & typeof globalThis;

    frameDocument.open();
    frameDocument.write(exported.html);
    frameDocument.close();
    frameGlobal.HTMLDialogElement.prototype.showModal = function showModal() {
      this.setAttribute('open', '');
    };
    frameGlobal.HTMLDialogElement.prototype.close = function close() {
      this.removeAttribute('open');
    };

    const script = frameDocument.querySelector('script')?.textContent;
    expect(script).toBeTruthy();
    frameWindow.location.hash = '#chat-2';
    frameGlobal.eval(script ?? '');

    expect(frameDocument.querySelector<HTMLElement>('[data-chat-section="1"]')?.hidden).toBe(true);
    expect(frameDocument.querySelector<HTMLElement>('[data-chat-section="2"]')?.hidden).toBe(false);

    frameWindow.location.hash = '#chat-1';
    frameWindow.dispatchEvent(new frameGlobal.HashChangeEvent('hashchange'));
    expect(frameDocument.querySelector<HTMLElement>('[data-chat-section="1"]')?.hidden).toBe(false);
    expect(frameDocument.querySelector('[data-chat-link="1"]')?.getAttribute('aria-current')).toBe('page');

    frameDocument.querySelector<HTMLButtonElement>('[data-open-panel="chat-1-related"]')?.click();
    const relatedDialog = frameDocument.querySelector<HTMLDialogElement>('#chat-1-related');
    expect(relatedDialog?.open).toBe(true);
    relatedDialog?.querySelector<HTMLAnchorElement>('[data-chat-link="2"]')?.click();
    expect(relatedDialog?.open).toBe(false);

    frameDocument.querySelector<HTMLButtonElement>('[data-open-panel="chat-1-context"]')?.click();
    expect(frameDocument.querySelector<HTMLDialogElement>('#chat-1-context')?.open).toBe(true);
    frameDocument.querySelector<HTMLButtonElement>('[data-open-resource="block-10"]')?.click();
    expect(frameDocument.querySelector<HTMLDialogElement>('#resource-block-10')?.open).toBe(true);
    frameDocument
      .querySelector<HTMLDialogElement>('#resource-block-10')
      ?.querySelector<HTMLButtonElement>('[data-close-dialog]')
      ?.click();
    expect(frameDocument.querySelector<HTMLDialogElement>('#resource-block-10')?.open).toBe(false);

    frame.remove();
  });
});
