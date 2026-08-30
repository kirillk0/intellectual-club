export type KnowledgeBlockTab = 'code' | 'tags' | 'files' | 'secrets' | 'details';

export type KnowledgeBlockCodeEditorExpose = {
  resetScroll: () => void;
  focus: () => void;
};
