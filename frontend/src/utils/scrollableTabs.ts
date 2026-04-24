const TAB_LIST_SELECTOR = '.tabs';
const ACTIVE_TAB_SELECTOR = '.tab.active';

const centerActiveTab = (tabs: HTMLElement, behavior: ScrollBehavior = 'auto') => {
  const activeTab = tabs.querySelector<HTMLElement>(ACTIVE_TAB_SELECTOR);
  if (!activeTab) return;

  const tabsRect = tabs.getBoundingClientRect();
  const activeRect = activeTab.getBoundingClientRect();
  const targetLeft =
    tabs.scrollLeft + activeRect.left - tabsRect.left - (tabs.clientWidth - activeRect.width) / 2;

  tabs.scrollTo({
    left: Math.max(0, targetLeft),
    behavior,
  });
};

const centerAllActiveTabs = (root: HTMLElement) => {
  root.querySelectorAll<HTMLElement>(TAB_LIST_SELECTOR).forEach((tabs) => centerActiveTab(tabs));
};

export function setupScrollableTabs(root: HTMLElement) {
  const centerInteractiveTab = (target: EventTarget | null) => {
    if (!(target instanceof Element)) return;

    const tabs = target.closest<HTMLElement>(TAB_LIST_SELECTOR);
    if (!tabs || !root.contains(tabs)) return;

    window.setTimeout(() => centerActiveTab(tabs, 'smooth'), 0);
  };

  centerAllActiveTabs(root);

  root.addEventListener('click', (event) => centerInteractiveTab(event.target));
  root.addEventListener('focusin', (event) => centerInteractiveTab(event.target));

  const observer = new MutationObserver((mutations) => {
    const tabLists = new Set<HTMLElement>();

    mutations.forEach((mutation) => {
      if (mutation.type === 'attributes' && mutation.target instanceof Element) {
        const tabs = mutation.target.closest<HTMLElement>(TAB_LIST_SELECTOR);
        if (tabs) tabLists.add(tabs);
        return;
      }

      mutation.addedNodes.forEach((node) => {
        if (!(node instanceof Element)) return;

        if (node.matches(TAB_LIST_SELECTOR)) {
          tabLists.add(node as HTMLElement);
        }

        node.querySelectorAll<HTMLElement>(TAB_LIST_SELECTOR).forEach((tabs) => tabLists.add(tabs));
      });
    });

    if (!tabLists.size) return;

    window.requestAnimationFrame(() => {
      tabLists.forEach((tabs) => centerActiveTab(tabs));
    });
  });

  observer.observe(root, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['class'],
  });
}
