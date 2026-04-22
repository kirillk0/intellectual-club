type ChatTitleParams = {
  botName?: string | null;
  note?: string | null;
  configLabel?: string | null;
};

export const formatChatBaseTitle = ({ botName, note }: ChatTitleParams): string => {
  const bot = String(botName || '').trim() || 'No bot';
  const chatNote = String(note || '').trim();
  return chatNote ? `${bot} (${chatNote})` : bot;
};

export const formatChatFullTitle = ({ botName, note, configLabel }: ChatTitleParams): string => {
  const baseTitle = formatChatBaseTitle({ botName, note });
  const config = String(configLabel || '').trim();
  return config ? `${baseTitle} (${config})` : baseTitle;
};
