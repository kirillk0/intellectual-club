import { getEffectiveLocale, type SupportedLocale } from '@/i18n';
import type {
  ChatExportAttachment,
  ChatExportChat,
  ChatExportContentItem,
  ChatExportKnowledgeBlock,
  ChatExportMessage,
  ChatExportPayload,
  ChatExportResourceRef,
  ChatExportTool,
  ChatExportWorkingItem,
  ChatExportWorkingStep,
} from '@/types/api';
import { enhanceRenderedChatMessageHtml, renderChatMessageHtml } from '@/utils/chatMarkdown';

type ExportLabels = ReturnType<typeof labelsForLocale>;

const labelsForLocale = (locale: SupportedLocale) =>
  locale === 'ru'
    ? {
        exportTitle: 'Экспорт чата',
        exportedAt: 'Экспортировано',
        chatFamily: 'Связанные чаты',
        context: 'Контекст',
        library: 'Библиотека',
        blocks: 'Блоки знаний',
        tools: 'Инструменты',
        messages: 'Сообщения',
        noResources: 'Нет ресурсов',
        noMessages: 'Нет сообщений в активной ветке.',
        user: 'Пользователь',
        assistant: 'Ассистент',
        working: 'Работа',
        step: 'Шаг',
        status: 'Статус',
        generating: 'Генерация продолжается',
        incomplete: 'Снимок незавершённой генерации',
        attachments: 'Вложения',
        attachmentUnavailable: 'Содержимое вложения не включено в экспорт.',
        parent: 'Родительский чат',
        related: 'Связанный чат',
        relation: 'Связь',
        bot: 'Бот',
        configuration: 'Конфигурация',
        note: 'Заметка',
        created: 'Создано',
        updated: 'Обновлено',
        tags: 'Теги',
        version: 'Версия',
        tokens: 'токенов',
        functions: 'Функции',
        description: 'Описание',
        type: 'Тип',
        alias: 'Алиас',
        arguments: 'Аргументы',
        result: 'Результат инструмента',
        truncated: 'Превью сокращено',
        artifact: 'Артефакт',
        error: 'Ошибка',
        reasoning: 'Рассуждение',
        close: 'Закрыть',
        disabled: 'Отключено',
        source: 'Источник',
        activeBranch: 'Только активная ветка',
      }
    : {
        exportTitle: 'Chat export',
        exportedAt: 'Exported',
        chatFamily: 'Related chats',
        context: 'Context',
        library: 'Library',
        blocks: 'Knowledge blocks',
        tools: 'Tools',
        messages: 'Messages',
        noResources: 'No resources',
        noMessages: 'No messages in the active branch.',
        user: 'User',
        assistant: 'Assistant',
        working: 'Working',
        step: 'Step',
        status: 'Status',
        generating: 'Generation in progress',
        incomplete: 'Snapshot of an incomplete generation',
        attachments: 'Attachments',
        attachmentUnavailable: 'Attachment content is not included in this export.',
        parent: 'Parent chat',
        related: 'Related chat',
        relation: 'Relation',
        bot: 'Bot',
        configuration: 'Configuration',
        note: 'Note',
        created: 'Created',
        updated: 'Updated',
        tags: 'Tags',
        version: 'Version',
        tokens: 'tokens',
        functions: 'Functions',
        description: 'Description',
        type: 'Type',
        alias: 'Alias',
        arguments: 'Arguments',
        result: 'Tool result',
        truncated: 'Preview truncated',
        artifact: 'Artifact',
        error: 'Error',
        reasoning: 'Reasoning',
        close: 'Close',
        disabled: 'Disabled',
        source: 'Source',
        activeBranch: 'Active branch only',
      };

const escapeHtml = (value: unknown) =>
  String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

const nonEmpty = (value: unknown) => (typeof value === 'string' ? value.trim() : '');

const formatDate = (value: string | null | undefined, locale: SupportedLocale) => {
  const timestamp = value ? Date.parse(value) : Number.NaN;
  if (!Number.isFinite(timestamp)) return '';
  return new Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' }).format(timestamp);
};

const formatBytes = (value: number) => {
  const size = Number.isFinite(value) && value > 0 ? value : 0;
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`;
};

const safeJson = (value: unknown) => {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
};

const resourceButton = (kind: 'block' | 'tool', id: number, label: string, suffix = '') =>
  `<button class="resource-link" type="button" data-open-resource="${kind}-${id}">${escapeHtml(label)}${suffix}</button>`;

const renderTags = (tags: string[] | null | undefined) => {
  const values = Array.isArray(tags) ? tags.filter((tag) => nonEmpty(tag)) : [];
  return values.length
    ? `<span class="tag-list">${values.map((tag) => `<span class="tag">${escapeHtml(tag)}</span>`).join('')}</span>`
    : '';
};

const renderMarkdown = (value: unknown) => {
  const wrapper = document.createElement('div');
  const source = typeof value === 'string' ? value : String(value ?? '');
  wrapper.className = 'markdown';
  wrapper.innerHTML = renderChatMessageHtml(source || ' ', { highlightCode: true });
  wrapper
    .querySelectorAll('img, picture, video, audio, iframe, object, embed, svg, source')
    .forEach((node) => {
      const placeholder = document.createElement('span');
      placeholder.className = 'media-placeholder';
      const alt = node instanceof HTMLImageElement ? nonEmpty(node.alt) : '';
      placeholder.textContent = alt ? `[${alt}]` : '[media omitted]';
      node.replaceWith(placeholder);
    });
  return wrapper.outerHTML;
};

const renderAttachment = (attachment: ChatExportAttachment, labels: ExportLabels) => {
  const details = [nonEmpty(attachment.mime_type), formatBytes(attachment.size_bytes)].filter(Boolean).join(' · ');
  return `<li class="attachment${attachment.enabled === false ? ' disabled' : ''}">
    <span aria-hidden="true">▧</span>
    <span><strong>${escapeHtml(attachment.name)}</strong>${details ? `<small>${escapeHtml(details)}</small>` : ''}</span>
    ${attachment.enabled === false ? `<span class="badge">${labels.disabled}</span>` : ''}
    <span class="sr-only">${labels.attachmentUnavailable}</span>
  </li>`;
};

const renderAttachments = (attachments: ChatExportAttachment[] | null | undefined, labels: ExportLabels) => {
  if (!attachments?.length) return '';
  return `<section class="attachments"><strong>${labels.attachments}</strong><ul>${attachments
    .map((attachment) => renderAttachment(attachment, labels))
    .join('')}</ul><p class="muted small">${labels.attachmentUnavailable}</p></section>`;
};

const renderContentItem = (item: ChatExportContentItem, labels: ExportLabels) => {
  const body = item.parts
    .map((part) => {
      const entry = part.handoff_entry;
      const meta = entry
        ? [entry.role, entry.entry_kind, entry.omitted_count ? `+${entry.omitted_count}` : '']
            .filter(Boolean)
            .join(' · ')
        : '';
      return `<div class="content-part">${meta ? `<div class="item-meta">${escapeHtml(meta)}</div>` : ''}${renderMarkdown(part.text)}</div>`;
    })
    .join('');

  if (!body && !item.attachments?.length) return '';
  const label = item.type.startsWith('handoff') ? `<span class="badge">${escapeHtml(item.type)}</span>` : '';
  return `<section class="content-item">${label}${body}${renderAttachments(item.attachments, labels)}</section>`;
};

const metricBadges = (step: ChatExportWorkingStep, labels: ExportLabels) => {
  const values: string[] = [];
  if (typeof step.input_tokens === 'number') values.push(`↓ ${step.input_tokens} ${labels.tokens}`);
  if (typeof step.output_tokens === 'number') values.push(`↑ ${step.output_tokens} ${labels.tokens}`);
  if (typeof step.reasoning_tokens === 'number') values.push(`◌ ${step.reasoning_tokens} ${labels.tokens}`);
  if (typeof step.tokens_per_second === 'number') values.push(`${step.tokens_per_second.toFixed(1)} tok/s`);
  if (typeof step.time_to_first_token_ms === 'number') values.push(`TTFT ${step.time_to_first_token_ms} ms`);
  if (typeof step.cost === 'number') values.push(`$${step.cost.toFixed(6)}`);
  return values.map((value) => `<span class="badge">${escapeHtml(value)}</span>`).join('');
};

const renderWorkingItem = (item: ChatExportWorkingItem, labels: ExportLabels) => {
  if (item.type === 'tool_call') {
    const argumentsText = safeJson(item.arguments);
    return `<div class="working-item"><strong>⚙ ${escapeHtml(item.name || item.type)}</strong>
      ${argumentsText ? `<div class="item-meta">${labels.arguments}</div><pre><code class="language-json">${escapeHtml(argumentsText)}</code></pre>` : ''}
    </div>`;
  }

  if (item.type === 'tool_result') {
    return `<div class="working-item"><strong>↳ ${labels.result}</strong>${item.truncated ? ` <span class="badge">${labels.truncated}</span>` : ''}
      ${item.text ? `<pre><code>${escapeHtml(item.text)}</code></pre>` : ''}
      ${renderAttachments(item.attachments, labels)}
    </div>`;
  }

  if (item.type === 'artifact') {
    return `<div class="working-item"><strong>${labels.artifact}</strong>${renderAttachments(item.attachments, labels)}</div>`;
  }

  const title = item.type === 'reasoning' ? labels.reasoning : item.type === 'error' ? labels.error : item.type;
  return `<div class="working-item"><strong>${escapeHtml(title)}</strong>${renderMarkdown(item.text || '')}</div>`;
};

const renderWorkingStep = (step: ChatExportWorkingStep, labels: ExportLabels) => {
  const status = nonEmpty(step.status);
  const incomplete = status && !['done', 'canceled', 'error'].includes(status);
  return `<details class="step${incomplete ? ' incomplete' : ''}">
    <summary><span>${labels.step} ${step.sequence}</span><span>${status ? `<span class="badge">${escapeHtml(status)}</span>` : ''}${metricBadges(step, labels)}</span></summary>
    <div class="step-body">${step.items.map((item) => renderWorkingItem(item, labels)).join('') || `<p class="muted">—</p>`}</div>
  </details>`;
};

const renderWorking = (message: ChatExportMessage, labels: ExportLabels) => {
  if (message.role !== 'assistant' || !message.working_steps?.length) return '';
  return `<details class="working"><summary>${labels.working} · ${message.working_steps.length}</summary>
    <div class="working-body">${message.working_steps.map((step) => renderWorkingStep(step, labels)).join('')}</div>
  </details>`;
};

const renderMessage = (
  chat: ChatExportChat,
  message: ChatExportMessage,
  childChats: ChatExportChat[],
  labels: ExportLabels,
  locale: SupportedLocale
) => {
  const author = message.role === 'user' ? labels.user : labels.assistant;
  const incomplete = message.status === 'generating';
  const meta = [formatDate(message.created_at, locale), message.llm_configuration?.label].filter(Boolean).join(' · ');
  const children = childChats
    .map(
      (child) =>
        `<a class="relation-link" href="#chat-${child.id}">${labels.related}: ${escapeHtml(child.title)} <span class="badge">${escapeHtml(child.relation?.kind || '')}</span></a>`
    )
    .join('');

  return `<article class="message ${message.role === 'user' ? 'user' : 'assistant'}${incomplete ? ' incomplete' : ''}" id="chat-${chat.id}-message-${message.id}">
    <header><strong>${author}</strong><span>${escapeHtml(meta)}</span>${message.status !== 'done' ? `<span class="badge">${escapeHtml(message.status)}</span>` : ''}</header>
    ${incomplete ? `<p class="notice">${labels.incomplete}</p>` : ''}
    ${renderWorking(message, labels)}
    <div class="message-body">${message.content.map((item) => renderContentItem(item, labels)).join('') || (incomplete ? '<p>…</p>' : '')}</div>
    ${message.error_detail ? `<div class="error"><strong>${labels.error}:</strong> ${escapeHtml(message.error_detail)}</div>` : ''}
    ${children ? `<nav class="relations">${children}</nav>` : ''}
  </article>`;
};

const renderResourceList = (
  refs: ChatExportResourceRef[],
  kind: 'block' | 'tool',
  names: Map<number, string>,
  labels: ExportLabels
) => {
  if (!refs.length) return `<p class="muted small">${labels.noResources}</p>`;
  return `<ul class="resource-list">${refs
    .map((ref) => {
      const id = kind === 'block' ? ref.block_id : ref.tool_instance_id;
      if (!id) return '';
      const name = names.get(id) || `${kind} #${id}`;
      const details = [ref.alias, ref.source].filter(Boolean).join(' · ');
      return `<li>${resourceButton(kind, id, name, ref.enabled === false ? ` <span class="badge">${labels.disabled}</span>` : '')}${
        details ? `<small>${escapeHtml(details)}</small>` : ''
      }</li>`;
    })
    .join('')}</ul>`;
};

const renderPanelDialog = (
  chat: ChatExportChat,
  side: 'context' | 'library',
  blockNames: Map<number, string>,
  toolNames: Map<number, string>,
  labels: ExportLabels
) => {
  const refs = chat[side];
  const title = side === 'context' ? labels.context : labels.library;
  return `<dialog id="chat-${chat.id}-${side}"><div class="dialog-head"><h2>${title}</h2><button type="button" data-close-dialog>${labels.close}</button></div>
    <h3>${labels.blocks}</h3>${renderResourceList(refs.blocks, 'block', blockNames, labels)}
    <h3>${labels.tools}</h3>${renderResourceList(refs.tools, 'tool', toolNames, labels)}
  </dialog>`;
};

const renderRelatedChatsDialog = (chat: ChatExportChat, chats: ChatExportChat[], labels: ExportLabels) =>
  `<dialog id="chat-${chat.id}-related"><div class="dialog-head"><h2>${labels.chatFamily}</h2><button type="button" data-close-dialog>${labels.close}</button></div>
    <ul class="related-chat-list">${chats
      .map(
        (candidate) =>
          `<li><a href="#chat-${candidate.id}" data-chat-link="${candidate.id}">${escapeHtml(candidate.title)}${
            candidate.relation?.kind
              ? ` <span class="badge">${escapeHtml(candidate.relation.kind)}</span>`
              : ''
          }</a></li>`
      )
      .join('')}</ul>
  </dialog>`;

const renderChatSection = (
  chat: ChatExportChat,
  chats: ChatExportChat[],
  labels: ExportLabels,
  locale: SupportedLocale
) => {
  const childByMessage = new Map<number, ChatExportChat[]>();
  const unanchored: ChatExportChat[] = [];
  chats
    .filter((candidate) => candidate.relation?.parent_chat_id === chat.id)
    .forEach((child) => {
      const messageId = child.relation?.parent_message_id;
      if (messageId) childByMessage.set(messageId, [...(childByMessage.get(messageId) || []), child]);
      else unanchored.push(child);
    });

  const details = [
    chat.note ? `${labels.note}: ${chat.note}` : '',
    chat.bot?.name ? `${labels.bot}: ${chat.bot.name}` : '',
    chat.llm_configuration?.label ? `${labels.configuration}: ${chat.llm_configuration.label}` : '',
  ].filter(Boolean);
  const parent = chat.relation
    ? chats.find((candidate) => candidate.id === chat.relation?.parent_chat_id)
    : undefined;

  return `<section class="chat-section" data-chat-section="${chat.id}" aria-labelledby="chat-title-${chat.id}">
    <header class="chat-header"><div><p class="eyebrow">Chat #${chat.id}</p><h1 id="chat-title-${chat.id}">${escapeHtml(chat.title)}</h1></div>
      <div class="chat-header-actions">${chat.active_generation ? `<span class="badge active">${labels.generating}</span>` : ''}
        <button type="button" data-open-panel="chat-${chat.id}-related">${labels.chatFamily}</button>
        <button type="button" data-open-panel="chat-${chat.id}-context">${labels.context}</button>
        <button type="button" data-open-panel="chat-${chat.id}-library">${labels.library}</button>
      </div>
    </header>
    ${details.length ? `<p class="chat-meta">${escapeHtml(details.join(' · '))}</p>` : ''}
    <p class="chat-meta">${labels.created}: ${escapeHtml(formatDate(chat.created_at, locale))} · ${labels.updated}: ${escapeHtml(formatDate(chat.updated_at, locale))}</p>
    ${parent ? `<a class="relation-link" href="#chat-${parent.id}">← ${labels.parent}: ${escapeHtml(parent.title)} <span class="badge">${escapeHtml(chat.relation?.kind || '')}</span></a>` : ''}
    ${unanchored.map((child) => `<a class="relation-link" href="#chat-${child.id}">${labels.related}: ${escapeHtml(child.title)}</a>`).join('')}
    <div class="messages">${chat.messages.length ? chat.messages.map((message) => renderMessage(chat, message, childByMessage.get(message.id) || [], labels, locale)).join('') : `<p class="empty">${labels.noMessages}</p>`}</div>
  </section>`;
};

const renderBlockDialog = (block: ChatExportKnowledgeBlock, labels: ExportLabels, locale: SupportedLocale) => {
  const metadata = [
    block.version != null ? `${labels.version}: ${block.version}` : '',
    typeof block.token_count === 'number' ? `${block.token_count} ${labels.tokens}` : '',
    formatDate(block.updated_at, locale),
  ].filter(Boolean);
  return `<dialog id="resource-block-${block.id}"><div class="dialog-head"><div><p class="eyebrow">${labels.blocks}</p><h2>${escapeHtml(block.name)}</h2></div><button type="button" data-close-dialog>${labels.close}</button></div>
    ${metadata.length ? `<p class="muted">${escapeHtml(metadata.join(' · '))}</p>` : ''}${renderTags(block.tags)}
    ${renderMarkdown(block.content)}${renderAttachments(block.attachments, labels)}
  </dialog>`;
};

const renderToolDialog = (tool: ChatExportTool, labels: ExportLabels) =>
  `<dialog id="resource-tool-${tool.id}"><div class="dialog-head"><div><p class="eyebrow">${labels.tools}</p><h2>${escapeHtml(tool.name)}</h2></div><button type="button" data-close-dialog>${labels.close}</button></div>
    <p class="muted">${labels.alias}: ${escapeHtml(tool.alias)} · ${labels.type}: ${escapeHtml(tool.type_title || tool.type)}</p>
    ${tool.type_description ? renderMarkdown(tool.type_description) : ''}${tool.description ? renderMarkdown(tool.description) : ''}
    <h3>${labels.functions}</h3><ul class="functions">${tool.functions
      .map((fn) => `<li><code>${escapeHtml(fn.name)}</code>${fn.description ? renderMarkdown(fn.description) : ''}</li>`)
      .join('') || `<li class="muted">—</li>`}</ul>
  </dialog>`;

const exportStyles = `
:root{color-scheme:light dark;--bg:#f4f5f7;--panel:#fff;--soft:#eef0f3;--text:#1e232b;--muted:#687180;--line:#d9dde3;--accent:#356ae6;--user:#e7efff;--danger:#a51d2d;--shadow:0 12px 32px rgba(0,0,0,.12)}
@media(prefers-color-scheme:dark){:root{--bg:#17191d;--panel:#22252a;--soft:#2c3037;--text:#eef1f5;--muted:#a8b0bc;--line:#3d424b;--accent:#80a6ff;--user:#243553;--danger:#ff8a9a;--shadow:0 12px 32px rgba(0,0,0,.4)}}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}button,a{font:inherit}.export-head{padding:14px 22px;border-bottom:1px solid var(--line);background:var(--panel);position:sticky;top:0;z-index:4}.export-head strong{display:block}.export-head span,.muted,.chat-meta,.item-meta,small{color:var(--muted)}.relation-link,.resource-link,.related-chat-list a{display:block;width:100%;padding:8px 10px;border:1px solid var(--line);border-radius:9px;color:var(--text);background:var(--panel);text-align:left;text-decoration:none;cursor:pointer}.relation-link:hover,.resource-link:hover,.related-chat-list a:hover{border-color:var(--accent)}.related-chat-list{list-style:none;padding:0;margin:18px 0 0}.related-chat-list li+li{margin-top:7px}.related-chat-list a[aria-current="page"]{border-color:var(--accent);color:var(--accent)}.layout{max-width:1100px;margin:auto;min-height:calc(100vh - 74px)}main{padding:28px;min-width:0}.resource-list,.attachments ul,.functions{list-style:none;padding:0;margin:0}.resource-list li+li{margin-top:7px}.resource-list small{display:block;margin:2px 8px}.resource-link{background:transparent}.chat-section{max-width:920px;margin:auto}.chat-header{display:flex;justify-content:space-between;gap:16px;align-items:flex-start}.chat-header h1,dialog h2{margin:0;line-height:1.2}.chat-header-actions{display:flex;align-items:center;justify-content:flex-end;gap:7px;flex-wrap:wrap}.chat-header-actions button{border:0;background:transparent;color:var(--accent);padding:4px;cursor:pointer;text-decoration:underline;text-underline-offset:3px}.eyebrow{margin:0 0 4px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;font-size:.72rem}.relation-link{margin:12px 0}.messages{display:flex;flex-direction:column;gap:18px;margin-top:24px}.message{max-width:86%;padding:15px 17px;border:1px solid var(--line);border-radius:16px;background:var(--panel);box-shadow:0 2px 8px rgba(0,0,0,.03)}.message.user{align-self:flex-end;background:var(--user)}.message.incomplete{border-style:dashed}.message>header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px}.message>header span{color:var(--muted);font-size:.82rem}.notice,.error{padding:8px 10px;border-radius:8px;background:var(--soft)}.error{color:var(--danger)}.badge,.tag{display:inline-block;border:1px solid var(--line);border-radius:999px;padding:2px 7px;font-size:.75rem;margin:2px}.badge.active{border-color:var(--accent);color:var(--accent)}.tag-list{display:flex;flex-wrap:wrap;margin:8px 0}.content-part+.content-part,.content-item+.content-item{border-top:1px solid var(--line);margin-top:14px;padding-top:14px}.markdown{overflow-wrap:anywhere}.markdown>:first-child{margin-top:0}.markdown>:last-child{margin-bottom:0}.markdown table{border-collapse:collapse;display:block;max-width:100%;overflow:auto}.markdown th,.markdown td{border:1px solid var(--line);padding:6px 9px}.markdown blockquote{border-left:3px solid var(--line);margin-left:0;padding-left:14px;color:var(--muted)}pre{overflow:auto;background:#11151c;color:#e8edf5;border-radius:9px;padding:12px;font-size:.82rem;line-height:1.45;white-space:pre-wrap;word-break:break-word}code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}.markdown :not(pre)>code{background:var(--soft);padding:1px 4px;border-radius:4px}.token.comment,.token.prolog,.token.doctype,.token.cdata{color:#8292a2}.token.punctuation{color:#f8f8f2}.token.property,.token.tag,.token.constant,.token.symbol,.token.deleted{color:#f92672}.token.boolean,.token.number{color:#ae81ff}.token.selector,.token.attr-name,.token.string,.token.char,.token.builtin,.token.inserted{color:#a6e22e}.token.operator,.token.entity,.token.url,.token.variable{color:#f8f8f2}.token.atrule,.token.attr-value,.token.function,.token.class-name{color:#e6db74}.token.keyword{color:#66d9ef}.token.regex,.token.important{color:#fd971f}math.tml-display{display:block;overflow-x:auto;overflow-y:hidden;margin:1em 0}.media-placeholder,.attachment{display:flex;gap:9px;align-items:center;padding:9px;border:1px dashed var(--line);border-radius:8px;background:var(--soft)}.attachment small{display:block}.attachment.disabled{opacity:.65}.attachments{margin-top:12px}.attachments li+li{margin-top:6px}.small{font-size:.82rem}.working{margin:0 0 14px;border-bottom:1px solid var(--line);padding-bottom:10px}.working>summary,.step>summary{cursor:pointer}.working-body,.step-body{padding:10px 0 0 12px}.step{border-left:2px solid var(--line);padding:7px 0 7px 10px}.step.incomplete{border-color:var(--accent)}.step>summary{display:flex;justify-content:space-between;gap:8px}.working-item{margin:10px 0}.working-item .markdown{margin-top:5px}.relations{margin-top:12px}.empty{padding:28px;text-align:center;color:var(--muted)}dialog{width:min(760px,calc(100vw - 28px));max-height:88vh;overflow:auto;border:1px solid var(--line);border-radius:14px;background:var(--panel);color:var(--text);box-shadow:var(--shadow);padding:20px}dialog::backdrop{background:rgba(0,0,0,.55)}dialog h3{font-size:.82rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:22px 0 8px}.dialog-head{display:flex;justify-content:space-between;gap:16px;align-items:flex-start}.dialog-head button{border:1px solid var(--line);border-radius:8px;background:var(--soft);color:var(--text);padding:7px 11px}.functions li{padding:10px 0;border-top:1px solid var(--line)}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
@media(max-width:900px){main{padding:22px 14px}.message{max-width:96%}}
@media(max-width:560px){.message{max-width:100%}.chat-header{display:block}.chat-header-actions{justify-content:flex-start;margin-top:10px}.export-head{position:static}.step>summary{display:block}}
`;

const exportScript = `
(() => {
  const selected = document.body.dataset.selectedChat;
  const route = () => {
    const match = location.hash.match(/^#chat-(\\d+)(?:-message-(\\d+))?$/);
    const requested = match ? match[1] : selected;
    const section = document.querySelector('[data-chat-section="' + requested + '"]');
    const chatId = section ? requested : selected;
    document.querySelectorAll('[data-chat-section]').forEach((node) => { node.hidden = node.dataset.chatSection !== chatId; });
    document.querySelectorAll('[data-chat-link]').forEach((node) => { node.setAttribute('aria-current', node.dataset.chatLink === chatId ? 'page' : 'false'); });
    if (match && match[2]) requestAnimationFrame(() => document.getElementById('chat-' + chatId + '-message-' + match[2])?.scrollIntoView());
    else if (location.hash) window.scrollTo({ top: 0 });
  };
  addEventListener('hashchange', route);
  document.addEventListener('click', (event) => {
    const panel = event.target.closest('[data-open-panel]');
    if (panel) document.getElementById(panel.dataset.openPanel)?.showModal();
    const open = event.target.closest('[data-open-resource]');
    if (open) document.getElementById('resource-' + open.dataset.openResource)?.showModal();
    const close = event.target.closest('[data-close-dialog]');
    if (close) close.closest('dialog')?.close();
    const chatLink = event.target.closest('[data-chat-link]');
    if (chatLink) chatLink.closest('dialog')?.close();
  });
  document.querySelectorAll('dialog').forEach((dialog) => dialog.addEventListener('click', (event) => { if (event.target === dialog) dialog.close(); }));
  route();
})();
`;

const slugify = (value: string) => {
  const slug = value
    .normalize('NFKD')
    .toLocaleLowerCase()
    .replace(/[^\p{Letter}\p{Number}]+/gu, '-')
    .replace(/^-+|-+$/gu, '')
    .slice(0, 80)
    .replace(/-+$/u, '');
  return slug || 'chat';
};

export async function buildChatHtmlExport(
  payload: ChatExportPayload,
  options: { locale?: SupportedLocale } = {}
) {
  const locale = options.locale || getEffectiveLocale();
  const labels = labelsForLocale(locale);
  const selected = payload.chats.find((chat) => chat.id === payload.selected_chat_id) || payload.chats[0];
  if (!selected) throw new Error('The chat export is empty.');

  const blockNames = new Map(payload.resources.knowledge_blocks.map((block) => [block.id, block.name]));
  const toolNames = new Map(payload.resources.tools.map((tool) => [tool.id, tool.name]));
  const content = document.createElement('div');
  content.innerHTML = `<header class="export-head"><strong>${labels.exportTitle}</strong><span>${labels.exportedAt}: ${escapeHtml(formatDate(payload.exported_at, locale))} · ${labels.activeBranch}</span></header>
    <div class="layout"><main>${payload.chats.map((chat) => renderChatSection(chat, payload.chats, labels, locale)).join('')}</main></div>
    ${payload.chats.map((chat) => renderRelatedChatsDialog(chat, payload.chats, labels)).join('')}
    ${payload.chats.map((chat) => renderPanelDialog(chat, 'context', blockNames, toolNames, labels)).join('')}
    ${payload.chats.map((chat) => renderPanelDialog(chat, 'library', blockNames, toolNames, labels)).join('')}
    ${payload.resources.knowledge_blocks.map((block) => renderBlockDialog(block, labels, locale)).join('')}
    ${payload.resources.tools.map((tool) => renderToolDialog(tool, labels)).join('')}`;

  await enhanceRenderedChatMessageHtml(content, { highlightCode: true, highlightedAttr: 'data-export-highlighted' });

  const title = `${selected.title} — ${labels.exportTitle}`;
  const html = `<!doctype html>
<html lang="${locale}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-chat-export-v1'; img-src 'none'; font-src 'none'; connect-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>${escapeHtml(title)}</title><style>${exportStyles}</style></head>
<body data-selected-chat="${selected.id}">${content.innerHTML}<script nonce="chat-export-v1">${exportScript}</script></body></html>`;

  return {
    html,
    blob: new Blob([html], { type: 'text/html;charset=utf-8' }),
    filename: `${slugify(selected.title)}-export.html`,
  };
}
