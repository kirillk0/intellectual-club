import { computed, ref } from 'vue';
import { api, isHttpError } from '@/api/client';
import { startupLoadStartedAt } from '@/features/app/loadCoordinator';
import { normalizePreferredTheme, setPreferredTheme } from '@/features/app/theme';
import {
  createRecoverableRead,
  type RecoverableReadController,
} from '@/features/app/useRecoverableRead';
import { cleanupWebPushForLogout } from '@/features/push/webPush';
import { clearStoredPwaRoute } from '@/features/pwa/lastRoute';
import { navigateToLoginWithReturn } from '@/features/auth/loginNavigation';
import { normalizePreferredLocale, setPreferredLocale } from '@/i18n';
import type { SessionUser } from '@/types/api';

const currentUser = ref<SessionUser | null>(null);
const initialized = ref(false);
let refreshPromise: Promise<SessionUser | null> | null = null;
let refreshController: RecoverableReadController<SessionUser> | null = null;

const isAuthenticated = computed(() => Boolean(currentUser.value));

const parseInitialUserFromDom = (): SessionUser | null => {
  const host = document.getElementById('spa-root') as HTMLElement | null;
  if (!host) return null;

  const id = Number(host.dataset.currentUserId || '');
  const username = String(host.dataset.currentUserUsername || '').trim();
  const isAdminRaw = String(host.dataset.currentUserIsAdmin || '').trim();
  const isAdmin = isAdminRaw === 'true';
  const preferredLocale = normalizePreferredLocale(host.dataset.currentUserPreferredLocale || null);
  const preferredTheme = normalizePreferredTheme(host.dataset.currentUserPreferredTheme || null);

  if (!Number.isFinite(id) || id <= 0 || username === '') return null;

  return { id, username, is_admin: isAdmin, preferred_locale: preferredLocale, preferred_theme: preferredTheme };
};

export const applySessionUser = (user: SessionUser | null) => {
  currentUser.value = user;
  setPreferredLocale(user?.preferred_locale ?? null);
  setPreferredTheme(user?.preferred_theme ?? 'system');
};

export const ensureAuthInitialized = () => {
  if (initialized.value) return;
  applySessionUser(parseInitialUserFromDom());
  initialized.value = true;
};

export const useSessionAuth = () => ({
  currentUser,
  initialized,
  isAuthenticated,
});

export const signIn = async (username: string, password: string): Promise<SessionUser> => {
  const payload = await api.post<{ user: SessionUser }>(
    '/api/bff/auth/login',
    { username, password },
    { redirectOnUnauthorized: false }
  );

  applySessionUser(payload.user);
  initialized.value = true;
  return payload.user;
};

export const fetchCurrentUser = async (): Promise<SessionUser> => {
  const payload = await api.get<{ user: SessionUser }>('/api/bff/auth/me', {
    redirectOnUnauthorized: false,
  });

  applySessionUser(payload.user);
  initialized.value = true;
  return payload.user;
};

export const refreshSessionUser = async (): Promise<SessionUser | null> => {
  if (refreshPromise) return refreshPromise;

  const controller = createRecoverableRead<SessionUser>({
    key: 'session:refresh',
    stage: 'data',
    startedAt: startupLoadStartedAt,
  });
  refreshController = controller;

  refreshPromise = (async () => {
    try {
      return await controller.run(async ({ signal }) => {
          const payload = await api.get<{ user: SessionUser }>('/api/bff/auth/me', {
            redirectOnUnauthorized: false,
            retry: false,
            showErrorBanner: false,
            signal,
          });

          applySessionUser(payload.user);
          initialized.value = true;
          return payload.user;
        });
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return null;

      if (isHttpError(error) && error.status === 401) {
        applySessionUser(null);
        initialized.value = true;
        navigateToLoginWithReturn();
        return null;
      }

      throw error;
    } finally {
      controller.dispose();
      if (refreshController === controller) refreshController = null;
      refreshPromise = null;
    }
  })();

  return refreshPromise;
};

export const signOut = async (): Promise<void> => {
  refreshController?.dispose();
  refreshController = null;

  await cleanupWebPushForLogout().catch((error) => {
    console.warn('Failed to clean up Web Push subscription before sign out.', error);
  });
  await api.post('/api/bff/auth/logout', {});
  clearStoredPwaRoute();
  applySessionUser(null);
  initialized.value = true;
};
