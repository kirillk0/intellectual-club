import type { RouteLocationNormalizedLoaded } from 'vue-router';
import { isStandalonePwa } from '@/pwa';

const STORAGE_KEY = 'intellectual-club:pwa:last-route';
const CHAT_LIST_PATH = '/chats';
const EXCLUDED_ROUTE_NAMES = new Set(['login', 'outlet-connect']);
const LAST_ROUTE_MAX_AGE_MS = 2 * 60 * 60 * 1000;

type StoredPwaRoute = {
  fullPath: string;
  visitedAt: number;
};

let initialRestoreChecked = false;

const storageAvailable = () => {
  try {
    return typeof window.localStorage !== 'undefined';
  } catch {
    return false;
  }
};

const pwaRoutePersistenceEnabled = () => isStandalonePwa() && storageAvailable();

const routeName = (route: RouteLocationNormalizedLoaded) =>
  typeof route.name === 'string' ? route.name : '';

const safeStoredPath = (value: string | null): string | null => {
  if (!value || !value.startsWith('/') || value.startsWith('//')) return null;

  try {
    const url = new URL(value, window.location.origin);
    if (url.origin !== window.location.origin) return null;

    const fullPath = `${url.pathname}${url.search}${url.hash}`;
    if (url.pathname === '/' || url.pathname === '/login' || url.pathname.startsWith('/login/')) return null;
    if (url.pathname === '/outlets/connect') return null;

    return fullPath;
  } catch {
    return null;
  }
};

const chatListStoredPath = (value: string): string | null => {
  if (!value.startsWith('/') || value.startsWith('//')) return null;

  try {
    const url = new URL(value, window.location.origin);
    if (url.origin !== window.location.origin) return null;
    if (url.pathname !== '/' && url.pathname !== CHAT_LIST_PATH) return null;

    return `${CHAT_LIST_PATH}${url.search}${url.hash}`;
  } catch {
    return null;
  }
};

const routeStoredPath = (route: RouteLocationNormalizedLoaded): string | null => {
  if (routeName(route) === 'chats') return chatListStoredPath(route.fullPath);
  return safeStoredPath(route.fullPath);
};

const parseStoredRoute = (raw: string | null): StoredPwaRoute | null => {
  if (!raw) return null;

  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return null;

    const { fullPath, visitedAt } = parsed as Record<string, unknown>;
    if (typeof fullPath !== 'string') return null;
    if (typeof visitedAt !== 'number' || !Number.isFinite(visitedAt)) return null;

    const safeFullPath = safeStoredPath(fullPath);
    if (!safeFullPath) return null;

    return { fullPath: safeFullPath, visitedAt };
  } catch {
    return null;
  }
};

const storedRouteFresh = (visitedAt: number) => {
  const age = Date.now() - visitedAt;
  return age >= 0 && age <= LAST_ROUTE_MAX_AGE_MS;
};

export const restorePwaRouteOnLaunch = (route: RouteLocationNormalizedLoaded): string | null => {
  if (initialRestoreChecked) return null;
  initialRestoreChecked = true;

  if (!pwaRoutePersistenceEnabled()) return null;
  if (route.fullPath !== '/') return null;

  try {
    const storedRoute = parseStoredRoute(window.localStorage.getItem(STORAGE_KEY));
    if (!storedRoute) {
      window.localStorage.removeItem(STORAGE_KEY);
      return null;
    }

    if (!storedRouteFresh(storedRoute.visitedAt)) {
      window.localStorage.removeItem(STORAGE_KEY);
      return null;
    }

    return storedRoute.fullPath;
  } catch {
    return null;
  }
};

export const rememberPwaRoute = (route: RouteLocationNormalizedLoaded, authenticated: boolean) => {
  if (!authenticated || !pwaRoutePersistenceEnabled()) return;
  if (EXCLUDED_ROUTE_NAMES.has(routeName(route))) return;

  const fullPath = routeStoredPath(route);
  if (!fullPath) return;

  try {
    const payload: StoredPwaRoute = { fullPath, visitedAt: Date.now() };
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
  } catch {
    // Ignore private mode storage failures.
  }
};

export const clearStoredPwaRoute = () => {
  if (!storageAvailable()) return;

  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Ignore private mode storage failures.
  }
};
