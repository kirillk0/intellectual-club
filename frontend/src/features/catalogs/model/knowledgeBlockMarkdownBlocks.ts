export const COMMENT_PREFIX = '//// ';

export type KnowledgeBlockMarkdownBlock = {
  kind: 'markdown' | 'comment' | 'blank';
  source: string;
  start: number;
  end: number;
  key: string;
};

type SourceLine = {
  source: string;
  text: string;
  start: number;
  end: number;
};

type FenceInfo = {
  char: '`' | '~';
  length: number;
};

export function stripKnowledgeBlockComments(content: string) {
  return String(content || '')
    .split('\n')
    .filter((line) => !line.startsWith(COMMENT_PREFIX))
    .join('\n');
}

export function replaceKnowledgeBlockRange(content: string, start: number, end: number, nextSource: string) {
  const source = String(content || '');
  const safeStart = Math.max(0, Math.min(source.length, start));
  const safeEnd = Math.max(safeStart, Math.min(source.length, end));
  return `${source.slice(0, safeStart)}${nextSource}${source.slice(safeEnd)}`;
}

export function commentBodyFromSource(source: string) {
  const raw = String(source || '');
  const lines = raw.split('\n');
  if (raw.endsWith('\n')) lines.pop();

  return lines
    .map((line) => {
      const normalized = line.endsWith('\r') ? line.slice(0, -1) : line;
      return normalized.startsWith(COMMENT_PREFIX)
        ? normalized.slice(COMMENT_PREFIX.length)
        : normalized;
    })
    .join('\n');
}

export function commentSourceFromBody(body: string) {
  const raw = String(body ?? '').replace(/\r\n/gu, '\n').replace(/\r/gu, '\n');
  if (raw.trim() === '') return '';
  return raw.split('\n').map((line) => `${COMMENT_PREFIX}${line}`).join('\n');
}

export function parseKnowledgeBlockMarkdownBlocks(content: string): KnowledgeBlockMarkdownBlock[] {
  const lines = splitSourceLines(String(content || ''));
  const blocks: KnowledgeBlockMarkdownBlock[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];

    if (isBlankLine(line)) {
      index = pushBlock(blocks, lines, index, (candidate) => isBlankLine(candidate), 'blank');
      continue;
    }

    if (line.text.startsWith(COMMENT_PREFIX)) {
      index = pushBlock(
        blocks,
        lines,
        index,
        (candidate) => candidate.text.startsWith(COMMENT_PREFIX),
        'comment'
      );
      continue;
    }

    const fence = fenceInfo(line.text);
    if (fence) {
      index = pushFenceBlock(blocks, lines, index, fence);
      continue;
    }

    index = pushMarkdownBlock(blocks, lines, index);
  }

  return blocks;
}

function splitSourceLines(source: string): SourceLine[] {
  const lines: SourceLine[] = [];
  let cursor = 0;

  while (cursor < source.length) {
    let lineEnd = cursor;

    while (lineEnd < source.length && source[lineEnd] !== '\n' && source[lineEnd] !== '\r') {
      lineEnd += 1;
    }

    let end = lineEnd;
    if (lineEnd < source.length) {
      end = source[lineEnd] === '\r' && source[lineEnd + 1] === '\n'
        ? lineEnd + 2
        : lineEnd + 1;
    }

    lines.push({
      source: source.slice(cursor, end),
      text: source.slice(cursor, lineEnd),
      start: cursor,
      end,
    });

    cursor = end;
  }

  return lines;
}

function isBlankLine(line: SourceLine) {
  return line.text.trim() === '';
}

function pushBlock(
  blocks: KnowledgeBlockMarkdownBlock[],
  lines: SourceLine[],
  startIndex: number,
  keepGoing: (line: SourceLine) => boolean,
  kind: KnowledgeBlockMarkdownBlock['kind']
) {
  let endIndex = startIndex + 1;
  while (endIndex < lines.length && keepGoing(lines[endIndex])) endIndex += 1;
  appendBlock(blocks, lines, startIndex, endIndex, kind);
  return endIndex;
}

function pushFenceBlock(
  blocks: KnowledgeBlockMarkdownBlock[],
  lines: SourceLine[],
  startIndex: number,
  fence: FenceInfo
) {
  let endIndex = startIndex + 1;

  while (endIndex < lines.length) {
    if (fenceCloses(lines[endIndex].text, fence)) {
      endIndex += 1;
      break;
    }

    endIndex += 1;
  }

  appendBlock(blocks, lines, startIndex, endIndex, 'markdown');
  return endIndex;
}

function pushMarkdownBlock(
  blocks: KnowledgeBlockMarkdownBlock[],
  lines: SourceLine[],
  startIndex: number
) {
  let endIndex = startIndex + 1;

  while (endIndex < lines.length) {
    const line = lines[endIndex];
    if (isBlankLine(line)) break;
    if (line.text.startsWith(COMMENT_PREFIX)) break;
    if (fenceInfo(line.text)) break;
    endIndex += 1;
  }

  appendBlock(blocks, lines, startIndex, endIndex, 'markdown');
  return endIndex;
}

function appendBlock(
  blocks: KnowledgeBlockMarkdownBlock[],
  lines: SourceLine[],
  startIndex: number,
  endIndex: number,
  kind: KnowledgeBlockMarkdownBlock['kind']
) {
  const first = lines[startIndex];
  const last = lines[endIndex - 1];
  const start = first.start;
  const end = last.end;

  blocks.push({
    kind,
    source: lines.slice(startIndex, endIndex).map((line) => line.source).join(''),
    start,
    end,
    key: `${kind}:${start}:${end}`,
  });
}

function fenceInfo(line: string): FenceInfo | null {
  const match = /^ {0,3}([`~]{3,})/u.exec(line);
  const marker = match?.[1];
  if (!marker) return null;

  const char = marker[0] as '`' | '~';
  if (!Array.from(marker).every((item) => item === char)) return null;
  return { char, length: marker.length };
}

function fenceCloses(line: string, fence: FenceInfo) {
  const info = fenceInfo(line);
  return Boolean(info && info.char === fence.char && info.length >= fence.length);
}
