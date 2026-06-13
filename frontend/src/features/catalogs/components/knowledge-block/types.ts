export type KnowledgeBlockTab = 'code' | 'tags' | 'files' | 'details';

export type KnowledgeBlockCodeEditorExpose = {
  resetScroll: () => void;
  focus: () => void;
};
