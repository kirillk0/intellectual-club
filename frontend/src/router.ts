import { nextTick } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import {
  beginLoadTask,
  setBootstrapLoadStage,
  startupLoadStartedAt,
  type LoadTaskHandle,
} from '@/features/app/loadCoordinator';
import { subscribeRecoveryHeartbeat } from '@/features/app/recoveryHeartbeat';
import { navigateDocumentToRoute } from '@/features/app/routeRecoveryNavigation';
import { ensureAuthInitialized, useSessionAuth } from '@/features/auth/session';
import { rememberPwaRoute, restorePwaRouteOnLaunch } from '@/features/pwa/lastRoute';
import type { PwaServiceWorkerMessage } from '@/features/pwa/serviceWorker';
import { useNavigationStack } from '@/features/stack/navigationStack';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('./views/LoginView.vue'), meta: { title: 'Sign in' } },
    {
      path: '/',
      alias: '/chats',
      name: 'chats',
      component: () => import('./views/ChatsIndexView.vue'),
      meta: { title: 'Chats' },
    },
    {
      path: '/bookmarks',
      name: 'bookmarks',
      component: () => import('./views/BookmarksIndexView.vue'),
      meta: { title: 'Bookmarks' },
    },
    { path: '/settings', name: 'settings', component: () => import('./views/UserSettingsView.vue'), meta: { title: 'Settings' } },
    { path: '/administration', redirect: '/administration/users' },
    {
      path: '/administration/users',
      name: 'admin-users',
      component: () => import('./views/administration/UsersIndexView.vue'),
      meta: { requiresAdmin: true, title: 'Users' },
    },
    {
      path: '/administration/users/:id(\\d+|new)',
      name: 'admin-user',
      component: () => import('./views/administration/UserEditView.vue'),
      meta: { requiresAdmin: true, title: 'User', stackEntityParams: ['id'] },
    },
    {
      path: '/administration/user-groups',
      name: 'admin-user-groups',
      component: () => import('./views/administration/UserGroupsIndexView.vue'),
      meta: { requiresAdmin: true, title: 'User Groups' },
    },
    {
      path: '/administration/user-groups/:id(\\d+|new)',
      name: 'admin-user-group',
      component: () => import('./views/administration/UserGroupEditView.vue'),
      meta: { requiresAdmin: true, title: 'User Group', stackEntityParams: ['id'] },
    },
    {
      path: '/administration/web-push',
      name: 'admin-web-push',
      component: () => import('./views/administration/WebPushSettingsView.vue'),
      meta: { requiresAdmin: true, title: 'Web Push' },
    },
    {
      path: '/outlets/connect',
      name: 'outlet-connect',
      component: () => import('./views/OutletConnectView.vue'),
      meta: { title: 'Outlet Connection' },
    },
    {
      path: '/chats/:id(\\d+)',
      name: 'chat',
      component: () => import('./views/ChatView.vue'),
      meta: { title: 'Chat' },
    },
    { path: '/catalogs', redirect: '/catalogs/bots' },
    {
      path: '/catalogs/knowledge-blocks',
      name: 'knowledge-blocks',
      component: () => import('./views/catalogs/KnowledgeBlocksIndexView.vue'),
      meta: { title: 'Knowledge Blocks' },
    },
    {
      path: '/catalogs/knowledge-blocks/:id(\\d+|new)',
      name: 'knowledge-block',
      component: () => import('./views/catalogs/KnowledgeBlockEditView.vue'),
      meta: { title: 'Knowledge Block', stackEntityParams: ['id'] },
    },
    {
      path: '/catalogs/knowledge-tags',
      redirect: '/catalogs/knowledge-blocks',
    },
    {
      path: '/catalogs/knowledge-tags/:id(\\d+|new)',
      redirect: '/catalogs/knowledge-blocks',
    },
    {
      path: '/catalogs/llm-providers',
      name: 'llm-providers',
      component: () => import('./views/catalogs/LlmProvidersIndexView.vue'),
      meta: { title: 'LLM Providers' },
    },
    {
      path: '/catalogs/llm-providers/:id(\\d+|new)',
      name: 'llm-provider',
      component: () => import('./views/catalogs/LlmProviderEditView.vue'),
      meta: { title: 'LLM Provider', stackEntityParams: ['id'] },
    },
    {
      path: '/catalogs/llm-configurations',
      name: 'llm-configurations',
      component: () => import('./views/catalogs/LlmConfigurationsIndexView.vue'),
      meta: { title: 'LLM Configurations' },
    },
    {
      path: '/catalogs/llm-configurations/usage',
      name: 'llm-configuration-usage',
      component: () => import('./views/catalogs/LlmConfigurationUsageView.vue'),
      meta: { title: 'LLM Usage' },
    },
    {
      path: '/catalogs/llm-configurations/:id(\\d+|new)',
      name: 'llm-configuration',
      component: () => import('./views/catalogs/LlmConfigurationEditView.vue'),
      meta: { title: 'LLM Configuration', stackEntityParams: ['id'] },
    },
    {
      path: '/catalogs/bots',
      name: 'bots',
      component: () => import('./views/catalogs/BotsIndexView.vue'),
      meta: { title: 'Bots' },
    },
    {
      path: '/catalogs/bots/:id(\\d+|new)',
      name: 'bot',
      component: () => import('./views/catalogs/BotEditView.vue'),
      meta: { title: 'Bot', stackEntityParams: ['id'] },
    },
    {
      path: '/catalogs/tools',
      name: 'tools',
      component: () => import('./views/catalogs/ToolInstancesIndexView.vue'),
      meta: { title: 'Tools' },
    },
    {
      path: '/catalogs/tools/:id(\\d+|new)',
      name: 'tool',
      component: () => import('./views/catalogs/ToolInstanceEditView.vue'),
      meta: { title: 'Tool', stackEntityParams: ['id'] },
    },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
});

let routeLoadTask: LoadTaskHandle | null = null;
let routeLoadAttempt = 1;
let routeRecoveryTimer: number | null = null;
let routeRecoveryTimerGeneration = 0;
let routeWatchdogTimer: number | null = null;
let routeRecoveryTarget = '';
let routeNavigationTarget = '';
let routeRetryNavigationTarget = '';
let routeGenerationCounter = 0;
let activeRouteGeneration = 0;
let routeRecoveryFlightGeneration = 0;
let routeRecoveryNeedsDocumentNavigation = false;
let routeRecoveryAllowsDocumentNavigation = false;
const routeGenerations = new WeakMap<object, number>();
const routeReloadGuards = new Map<string, number>();
const ROUTE_NAVIGATION_WATCHDOG_MS = 10_000;
const ROUTE_RECOVERY_ATTEMPT_TIMEOUT_MS = 10_000;
const ROUTE_RELOAD_GUARD_WINDOW_MS = 15_000;

const isDocumentVisible = () => document.visibilityState !== 'hidden';

const waitForReachableServer = async () => {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 5_000);

  try {
    const response = await fetch('/health', {
      cache: 'no-store',
      credentials: 'same-origin',
      headers: { Accept: 'text/plain' },
      signal: controller.signal,
    });
    return response.ok;
  } catch {
    return false;
  } finally {
    window.clearTimeout(timeout);
  }
};

const routeReloadKey = (target: string) =>
  `intellectual-club:route-reload:${__CODE_VERSION__.label}:${target}`;

type RouteReloadGuard = {
  key: string;
  at: number;
};

const validReloadTimestamp = (value: unknown, now: number) => {
  const timestamp = typeof value === 'string' ? Number(value) : value;
  return typeof timestamp === 'number' &&
    Number.isFinite(timestamp) &&
    Math.abs(now - timestamp) < ROUTE_RELOAD_GUARD_WINDOW_MS
    ? timestamp
    : 0;
};

const historyRouteReloadGuard = (now = Date.now()): RouteReloadGuard | null => {
  const state = window.history.state;
  if (!state || typeof state !== 'object') return null;
  const value = (state as Record<string, unknown>).__icRouteReload;
  if (!value || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  const at = validReloadTimestamp(record.at, now);
  return typeof record.key === 'string' && at > 0
    ? { key: record.key, at }
    : null;
};

const reserveRouteReload = (target: string) => {
  const key = routeReloadKey(target);
  const now = Date.now();
  const timestamps = [validReloadTimestamp(routeReloadGuards.get(key), now)];
  const historyGuard = historyRouteReloadGuard(now);
  if (historyGuard?.key === key) timestamps.push(historyGuard.at);

  try {
    timestamps.push(validReloadTimestamp(window.sessionStorage.getItem(key), now));
  } catch {
    // History state and the in-memory timestamp still prevent a reload storm.
  }

  if (timestamps.some((timestamp) => timestamp > 0)) return false;

  routeReloadGuards.set(key, now);
  try {
    window.sessionStorage.setItem(key, String(now));
  } catch {
    // History state and the in-memory timestamp still prevent a reload storm.
  }
  try {
    window.history.replaceState(
      {
        ...(window.history.state || {}),
        __icRouteReload: { key, at: now },
      },
      '',
      window.location.href
    );
  } catch {
    // The in-memory timestamp still protects the current document.
  }
  return true;
};

const clearRouteReloadGuard = (target: string) => {
  const key = routeReloadKey(target);
  routeReloadGuards.delete(key);
  try {
    window.sessionStorage.removeItem(key);
  } catch {
    // Ignore restricted storage; the in-memory guard was cleared above.
  }
  if (historyRouteReloadGuard()?.key === key) {
    try {
      const nextState = { ...(window.history.state || {}) };
      delete nextState.__icRouteReload;
      window.history.replaceState(nextState, '', window.location.href);
    } catch {
      // Ignore restricted history state.
    }
  }
};

const clearRouteWatchdog = () => {
  if (routeWatchdogTimer === null) return;
  window.clearTimeout(routeWatchdogTimer);
  routeWatchdogTimer = null;
};

const clearRouteRecoveryTimer = () => {
  if (routeRecoveryTimer !== null) window.clearTimeout(routeRecoveryTimer);
  routeRecoveryTimer = null;
  routeRecoveryTimerGeneration = 0;
};

const routeGenerationFor = (route: object & { fullPath: string }) =>
  routeGenerations.get(route) ??
  (routeNavigationTarget === route.fullPath ? activeRouteGeneration : 0);

const withRouteRecoveryDeadline = <T>(promise: Promise<T>) =>
  new Promise<T>((resolve, reject) => {
    const timer = window.setTimeout(
      () => reject(new Error('Route recovery timed out.')),
      ROUTE_RECOVERY_ATTEMPT_TIMEOUT_MS
    );
    promise.then(
      (value) => {
        window.clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        window.clearTimeout(timer);
        reject(error);
      }
    );
  });

const scheduleRouteRecovery = (delayMs = 500) => {
  const generation = activeRouteGeneration;
  if (
    routeRecoveryTimer !== null ||
    routeRecoveryFlightGeneration === generation ||
    generation === 0 ||
    !routeRecoveryTarget
  ) {
    return;
  }

  routeLoadTask?.update({
    attempt: routeLoadAttempt,
    retrying: routeLoadAttempt > 1 || Boolean(routeRecoveryTarget),
    waitingForConnection: navigator.onLine === false,
    waitingForVisibility: !isDocumentVisible(),
  });
  routeRecoveryTimerGeneration = generation;
  routeRecoveryTimer = window.setTimeout(async () => {
    if (routeRecoveryTimerGeneration === generation) {
      routeRecoveryTimer = null;
      routeRecoveryTimerGeneration = 0;
    }
    if (generation !== activeRouteGeneration) return;

    routeRecoveryFlightGeneration = generation;
    let nextDelay: number | null = null;
    let documentNavigationTarget = '';
    let retryNavigationTarget = '';

    try {
      if (!(await waitForReachableServer())) {
        if (generation !== activeRouteGeneration) return;
        nextDelay =
          delayMs <= 0 ? 500 : Math.min(10_000, Math.max(500, delayMs * 2));
        return;
      }
      if (
        generation !== activeRouteGeneration ||
        routeRecoveryFlightGeneration !== generation
      ) {
        return;
      }

      const target = routeRecoveryTarget;
      if (!target) return;

      if (routeRecoveryNeedsDocumentNavigation) {
        if (
          routeRecoveryAllowsDocumentNavigation &&
          reserveRouteReload(target)
        ) {
          routeLoadAttempt += 1;
          routeLoadTask?.update({
            attempt: routeLoadAttempt,
            retrying: true,
            waitingForConnection: false,
            waitingForVisibility: false,
          });
          documentNavigationTarget = target;
        }
        nextDelay = 10_000;
        return;
      }

      routeLoadAttempt += 1;
      routeLoadTask?.update({
        attempt: routeLoadAttempt,
        retrying: true,
        waitingForConnection: false,
        waitingForVisibility: false,
      });

      try {
        retryNavigationTarget = target;
        routeRetryNavigationTarget = target;
        await withRouteRecoveryDeadline(router.replace(target));
        if (generation !== activeRouteGeneration) return;
        if (routeRecoveryTarget === target) routeRecoveryTarget = '';
      } catch {
        if (generation !== activeRouteGeneration) return;
        if (
          routeRecoveryAllowsDocumentNavigation &&
          reserveRouteReload(target)
        ) {
          routeLoadAttempt += 1;
          routeLoadTask?.update({
            attempt: routeLoadAttempt,
            retrying: true,
            waitingForConnection: false,
            waitingForVisibility: false,
          });
          documentNavigationTarget = target;
        }
        nextDelay = 10_000;
      }
    } finally {
      if (routeRecoveryFlightGeneration === generation) {
        routeRecoveryFlightGeneration = 0;
      }
      if (routeRetryNavigationTarget === retryNavigationTarget) {
        routeRetryNavigationTarget = '';
      }
      if (
        generation === activeRouteGeneration &&
        nextDelay !== null &&
        routeRecoveryTarget
      ) {
        scheduleRouteRecovery(nextDelay);
      }
      if (
        generation === activeRouteGeneration &&
        documentNavigationTarget
      ) {
        navigateDocumentToRoute(documentNavigationTarget);
      }
    }
  }, delayMs);
};

const resumeRouteRecovery = () => {
  routeLoadTask?.update({
    attempt: routeLoadAttempt,
    retrying: routeLoadAttempt > 1 || Boolean(routeRecoveryTarget),
    waitingForConnection: navigator.onLine === false,
    waitingForVisibility: !isDocumentVisible(),
  });
  if (
    !routeRecoveryTarget ||
    routeRecoveryFlightGeneration === activeRouteGeneration
  ) {
    return;
  }
  clearRouteRecoveryTimer();
  scheduleRouteRecovery(0);
};

subscribeRecoveryHeartbeat(resumeRouteRecovery);

router.beforeEach((to, from) => {
  clearRouteWatchdog();
  const recoveryNavigation =
    routeRetryNavigationTarget === to.fullPath &&
    routeRecoveryFlightGeneration === activeRouteGeneration;
  let generation = activeRouteGeneration;

  if (!recoveryNavigation) {
    generation = ++routeGenerationCounter;
    activeRouteGeneration = generation;
    clearRouteRecoveryTimer();
    routeRecoveryTarget = '';
    routeRecoveryNeedsDocumentNavigation = false;
    routeRecoveryAllowsDocumentNavigation = false;
    routeRetryNavigationTarget = '';
    routeRecoveryFlightGeneration = 0;
    routeLoadAttempt = 1;
  }
  routeGenerations.set(to, generation);

  const initialNavigation = from.matched.length === 0;
  if (!recoveryNavigation) {
    routeRecoveryAllowsDocumentNavigation = initialNavigation;
  }
  routeLoadTask?.finish();
  routeLoadTask = beginLoadTask({
    key: 'route',
    stage: 'route',
    label: String(to.meta.title || ''),
    startedAt: initialNavigation ? startupLoadStartedAt() : Date.now(),
  });
  routeNavigationTarget = to.fullPath;
  routeWatchdogTimer = window.setTimeout(() => {
    routeWatchdogTimer = null;
    if (
      generation !== activeRouteGeneration ||
      !routeLoadTask ||
      routeNavigationTarget !== to.fullPath
    ) {
      return;
    }

    routeRecoveryTarget = to.fullPath;
    routeRecoveryNeedsDocumentNavigation =
      routeRecoveryAllowsDocumentNavigation;
    routeLoadTask.update({
      attempt: routeLoadAttempt,
      retrying: true,
      waitingForConnection: navigator.onLine === false,
      waitingForVisibility: !isDocumentVisible(),
    });
    scheduleRouteRecovery(0);
  }, ROUTE_NAVIGATION_WATCHDOG_MS);
  if (initialNavigation) setBootstrapLoadStage('route');

  ensureAuthInitialized();

  const { currentUser, initialized, isAuthenticated } = useSessionAuth();
  if (!initialized.value) return true;
  const loggedIn = isAuthenticated.value;

  if (to.name === 'login') {
    if (loggedIn) return { path: '/' };
    return true;
  }

  if (!loggedIn) {
    return { name: 'login', query: { next: to.fullPath } };
  }

  if (to.meta.requiresAdmin && !currentUser.value?.is_admin) {
    return { path: '/' };
  }

  const restoredPwaRoute = restorePwaRouteOnLaunch(to);
  if (restoredPwaRoute) return restoredPwaRoute;

  return true;
});

const getHistoryState = () => (router.options.history.state as any) ?? window.history.state;

router.afterEach((to, from, failure) => {
  const generation = routeGenerationFor(to);
  if (generation !== activeRouteGeneration) return;

  clearRouteWatchdog();
  // Vue Router resolves ordinary navigation failures instead of throwing them.
  // Never commit a failed layer transition; its owner clears the tokenized pending push.
  if (failure) {
    if (routeRecoveryTarget === to.fullPath) return;
    routeLoadTask?.finish();
    routeLoadTask = null;
    clearRouteRecoveryTimer();
    routeNavigationTarget = '';
    return;
  }

  clearRouteRecoveryTimer();
  routeLoadTask?.finish();
  routeLoadTask = null;
  routeRecoveryTarget = '';
  routeNavigationTarget = '';
  routeRecoveryNeedsDocumentNavigation = false;
  routeRecoveryAllowsDocumentNavigation = false;
  routeRetryNavigationTarget = '';
  routeRecoveryFlightGeneration = 0;
  clearRouteReloadGuard(to.fullPath);
  setBootstrapLoadStage('ready');

  const { isAuthenticated } = useSessionAuth();
  rememberPwaRoute(to, isAuthenticated.value);

  const stack = useNavigationStack();
  const pending = stack.commitPendingPush(from);
  if (pending) {
    nextTick(() => {
      window.scrollTo({ top: 0, left: 0 });
    });
  }

  if (!stack.active.value) return;

  if (stack.top.value?.route.fullPath === to.fullPath) {
    const entry = stack.pop();
    if (entry) {
      nextTick(() => {
        window.scrollTo({ top: entry.scrollY, left: 0 });
      });
    }
    return;
  }

  if (!getHistoryState()?.stack) {
    stack.reset();
  }
});

router.onError((_error, to) => {
  const generation = routeGenerationFor(to);
  if (generation !== activeRouteGeneration) return;

  clearRouteWatchdog();
  routeRecoveryTarget = to.fullPath;
  routeRecoveryNeedsDocumentNavigation = false;
  routeRecoveryAllowsDocumentNavigation = true;
  routeLoadTask?.update({
    attempt: routeLoadAttempt,
    retrying: true,
    waitingForConnection: navigator.onLine === false,
    waitingForVisibility: !isDocumentVisible(),
  });
  if (routeRecoveryFlightGeneration !== generation) scheduleRouteRecovery();
});

type RouteServiceWorkerMessage = Extract<
  PwaServiceWorkerMessage,
  { type: 'ASSET_RETRY' } | { type: 'VERSION_MISMATCH' }
>;

const isRouteServiceWorkerMessage = (
  value: unknown
): value is RouteServiceWorkerMessage => {
  if (!value || typeof value !== 'object') return false;
  const message = value as Record<string, unknown>;
  return (
    message.context === 'runtime' &&
    typeof message.url === 'string' &&
    (message.type === 'ASSET_RETRY' || message.type === 'VERSION_MISMATCH')
  );
};

const handleRouteServiceWorkerMessage = (event: MessageEvent) => {
  const message = event.data;
  if (
    !routeLoadTask ||
    !isRouteServiceWorkerMessage(message)
  ) {
    return;
  }

  let assetUrl: URL;
  try {
    assetUrl = new URL(message.url, window.location.origin);
  } catch {
    return;
  }
  if (
    assetUrl.origin !== window.location.origin ||
    !assetUrl.pathname.startsWith('/assets/js/chunks/')
  ) {
    return;
  }

  if (message.type === 'ASSET_RETRY') {
    routeLoadAttempt = Math.max(
      routeLoadAttempt,
      typeof message.attempt === 'number' ? message.attempt : routeLoadAttempt
    );
    routeLoadTask.update({
      attempt: routeLoadAttempt,
      retrying: true,
      waitingForConnection: navigator.onLine === false,
      waitingForVisibility: !isDocumentVisible(),
    });
    return;
  }

  if (message.type === 'VERSION_MISMATCH') {
    routeRecoveryTarget = routeNavigationTarget || window.location.pathname;
    routeRecoveryNeedsDocumentNavigation =
      routeRecoveryAllowsDocumentNavigation;
    routeLoadTask.update({
      attempt: routeLoadAttempt,
      retrying: true,
      waitingForConnection: navigator.onLine === false,
      waitingForVisibility: !isDocumentVisible(),
    });
    scheduleRouteRecovery(0);
  }
};

navigator.serviceWorker?.addEventListener('message', handleRouteServiceWorkerMessage);
