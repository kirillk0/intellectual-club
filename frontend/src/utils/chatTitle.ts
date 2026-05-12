type ChatTitleParams = {
  botName?: string | null;
  note?: string | null;
};

export const formatChatBaseTitle = ({ botName, note }: ChatTitleParams): string => {
  const bot = String(botName || '').trim() || 'No bot';
  const chatNote = String(note || '').trim();
  return chatNote ? `${bot} (${chatNote})` : bot;
};

export const formatChatFullTitle = ({ botName, note }: ChatTitleParams): string => {
  return formatChatBaseTitle({ botName, note });
};
