import { computed, ref } from 'vue';
import type { LeftPanelTab } from '@/features/chat/types';

export function useChatUiChrome() {
  const leftOpen = ref(true);
  const rightOpen = ref(true);
  const leftTab = ref<LeftPanelTab>('messages');
  const isMobile = ref(false);

  const menuOpen = ref(false);
  const deleting = ref(false);
  const exporting = ref(false);
  const duplicating = ref(false);

  const menuRef = ref<HTMLElement | null>(null);
  const menuAnchorRef = ref<HTMLElement | null>(null);
  const menuButtonRef = ref<HTMLElement | null>(null);
  const menuStyle = ref<Record<string, string>>({});

  const PANEL_STORAGE_VERSION = 2;
  const PANEL_STORAGE_KEY = 'chat_panels_state_v2';
  const LEGACY_PANEL_STORAGE_KEY = 'chat_panels_state';

  const gridColumns = computed(() => {
    if (isMobile.value) return '1fr';
    const cols: string[] = [];
    if (leftOpen.value) cols.push('260px');
    cols.push('1fr');
    if (rightOpen.value) cols.push('260px');
    return cols.join(' ');
  });

  const toggleMenu = () => {
    menuOpen.value = !menuOpen.value;
    if (menuOpen.value) updateMenuPosition();
  };

  const closeMenu = () => {
    menuOpen.value = false;
  };

  const closeOverlays = () => {
    leftOpen.value = false;
    rightOpen.value = false;
  };

  const handleResize = () => {
    isMobile.value = window.matchMedia('(max-width: 900px)').matches;
    if (isMobile.value) {
      leftOpen.value = false;
      rightOpen.value = false;
    }
  };

  const handleClickOutside = (event: MouseEvent) => {
    const target = event.target as Node | null;
    if (!menuRef.value || !target) return;
    if (menuRef.value.contains(target)) return;
    if (menuButtonRef.value && menuButtonRef.value.contains(target)) return;
    menuOpen.value = false;
  };

  const updateMenuPosition = () => {
    if (!menuOpen.value) return;
    const btn = menuButtonRef.value;
    if (!btn) return;
    const rect = btn.getBoundingClientRect();
    const viewportPadding = 8;
    const preferredWidth = 320;
    const maxWidth = Math.max(220, window.innerWidth - viewportPadding * 2);
    const width = Math.min(preferredWidth, maxWidth);
    const clampedLeft = Math.min(
      Math.max(viewportPadding, rect.right - width),
      Math.max(viewportPadding, window.innerWidth - width - viewportPadding)
    );
    menuStyle.value = {
      position: 'fixed',
      top: `${rect.bottom + 6}px`,
      left: `${clampedLeft}px`,
      right: 'auto',
      width: `${width}px`,
      maxWidth: `${maxWidth}px`,
      zIndex: '2000',
    };
  };

  const restorePanelState = () => {
    try {
      const saved = localStorage.getItem(PANEL_STORAGE_KEY);
      if (saved) {
        const parsed = JSON.parse(saved);
        if (parsed?.version === PANEL_STORAGE_VERSION) {
          if (typeof parsed.left === 'boolean') leftOpen.value = parsed.left;
          if (typeof parsed.right === 'boolean') rightOpen.value = parsed.right;
          if (parsed.leftTab === 'messages' || parsed.leftTab === 'prompt') {
            leftTab.value = parsed.leftTab;
          }
          return;
        }
      }

      const legacySaved = localStorage.getItem(LEGACY_PANEL_STORAGE_KEY);
      if (!legacySaved) return;
      const legacyParsed = JSON.parse(legacySaved);
      if (legacyParsed.leftTab === 'messages' || legacyParsed.leftTab === 'prompt') {
        leftTab.value = legacyParsed.leftTab;
      } else if (legacyParsed.rightTab === 'context') {
        leftTab.value = 'prompt';
      } else if (legacyParsed.rightTab === 'chat') {
        leftTab.value = 'messages';
      }
    } catch (error) {
      console.warn('Failed to restore panel state', error);
    }
  };

  const persistPanelState = () => {
    try {
      localStorage.setItem(
        PANEL_STORAGE_KEY,
        JSON.stringify({
          version: PANEL_STORAGE_VERSION,
          left: leftOpen.value,
          right: rightOpen.value,
          leftTab: leftTab.value,
        })
      );
    } catch (error) {
      console.warn('Failed to persist panel state', error);
    }
  };

  let keydownHandler: ((event: KeyboardEvent) => void) | null = null;

  const mountListeners = (handleKeyNavigation: (event: KeyboardEvent) => void) => {
    keydownHandler = handleKeyNavigation;
    document.addEventListener('click', handleClickOutside);
    window.addEventListener('resize', handleResize);
    window.addEventListener('resize', updateMenuPosition);
    window.addEventListener('scroll', updateMenuPosition, true);
    window.addEventListener('keydown', handleKeyNavigation, { passive: false });
    handleResize();
  };

  const unmountListeners = () => {
    document.removeEventListener('click', handleClickOutside);
    window.removeEventListener('resize', handleResize);
    window.removeEventListener('resize', updateMenuPosition);
    window.removeEventListener('scroll', updateMenuPosition, true);
    if (keydownHandler) {
      window.removeEventListener('keydown', keydownHandler);
      keydownHandler = null;
    }
  };

  return {
    leftOpen,
    rightOpen,
    leftTab,
    isMobile,
    menuOpen,
    deleting,
    exporting,
    duplicating,
    menuRef,
    menuAnchorRef,
    menuButtonRef,
    menuStyle,
    gridColumns,
    toggleMenu,
    closeMenu,
    closeOverlays,
    handleResize,
    handleClickOutside,
    updateMenuPosition,
    restorePanelState,
    persistPanelState,
    mountListeners,
    unmountListeners,
  };
}

