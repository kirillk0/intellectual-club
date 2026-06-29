<template>
  <div class="app-shell">
    <header ref="appHeader" class="app-header compact" v-show="!isLoginRoute">
      <button class="menu-toggle" type="button" @click="toggleMenu" aria-label="Open menu">☰</button>
      <RouterLink to="/chats" custom v-slot="{ href, navigate, route: targetRoute }">
        <a
          class="app-logo"
          :href="href"
          aria-label="Go to home"
          title="Go to home"
          @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
        >
          <img class="app-logo__mark" :src="appLogoUrl" alt="" aria-hidden="true" />
          <span class="app-logo__text" data-i18n-ignore>Intellectual Club</span>
        </a>
      </RouterLink>
      <nav class="app-nav" :class="{ open: mobileMenuOpen }">
        <RouterLink to="/chats" custom v-slot="{ href, isActive, isExactActive, navigate, route: targetRoute }">
          <a
            :href="href"
            :class="{
              'router-link-active': isActive,
              'router-link-exact-active': isExactActive,
            }"
            @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
          >
            <SvgIcon class="app-nav__icon" name="chat" />
            Chats
          </a>
        </RouterLink>
        <RouterLink to="/catalogs/bots" custom v-slot="{ href, isActive, isExactActive, navigate, route: targetRoute }">
          <a
            :href="href"
            :class="{
              'router-link-active': isActive,
              'router-link-exact-active': isExactActive,
            }"
            @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
          >
            <SvgIcon class="app-nav__icon" name="bot" />
            Bots
          </a>
        </RouterLink>
        <RouterLink
          to="/catalogs/knowledge-blocks"
          custom
          v-slot="{ href, isActive, isExactActive, navigate, route: targetRoute }"
        >
          <a
            :href="href"
            :class="{
              'router-link-active': isActive,
              'router-link-exact-active': isExactActive,
            }"
            @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
          >
            <SvgIcon class="app-nav__icon" name="document" />
            Knowledge Blocks
          </a>
        </RouterLink>
        <RouterLink to="/catalogs/tools" custom v-slot="{ href, isActive, isExactActive, navigate, route: targetRoute }">
          <a
            :href="href"
            :class="{
              'router-link-active': isActive,
              'router-link-exact-active': isExactActive,
            }"
            @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
          >
            <SvgIcon class="app-nav__icon" name="wrench" />
            Tools
          </a>
        </RouterLink>
        <RouterLink to="/catalogs/llm-configurations" custom v-slot="{ href, navigate, route: targetRoute }">
          <a
            :href="href"
            :class="{ 'router-link-active': isLlmConfigurationRoute }"
            @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
          >
            <SvgIcon class="app-nav__icon" name="sliders" />
            LLM Configuration
          </a>
        </RouterLink>
        <RouterLink
          v-if="currentUser?.is_admin"
          to="/administration/users"
          custom
          v-slot="{ href, isActive, isExactActive, navigate, route: targetRoute }"
        >
          <a
            :href="href"
            :class="{
              'router-link-active': isActive,
              'router-link-exact-active': isExactActive,
            }"
            @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
          >
            <SvgIcon class="app-nav__icon" name="shield" />
            Administration
          </a>
        </RouterLink>
        <div class="user-slot" v-if="currentUser">
          <RouterLink to="/settings" custom v-slot="{ href, isActive, isExactActive, navigate, route: targetRoute }">
            <a
              class="user-link"
              :href="href"
              :class="{
                'router-link-active': isActive,
                'router-link-exact-active': isExactActive,
              }"
              @click="handleMenuNavigation($event, navigate, targetRoute.fullPath)"
            >
              <SvgIcon class="app-nav__icon" name="user" />
              {{ currentUser.username }}
            </a>
          </RouterLink>
          <button
            type="button"
            class="link"
            :disabled="signingOut"
            @click="handleSignOut"
          >
            {{ signingOut ? 'Signing out...' : 'Sign out' }}
          </button>
        </div>
      </nav>
      <div id="toolbar-host" class="toolbar-host"></div>
    </header>

    <section
      v-if="backendStatusBanner"
      class="backend-status-banner"
      role="alert"
      aria-live="polite"
    >
      <div class="backend-status-copy">
        <strong>{{ backendStatusBanner.title }}</strong>
        <span>{{ backendStatusBanner.message }}</span>
      </div>
      <button type="button" @click="dismissBackendStatusBanner">Dismiss</button>
    </section>

    <main class="app-main" :class="{ 'app-main--chat': isChatRoute, 'app-main--login': isLoginRoute }">
      <StackRouterView :reopen-key="routeReopenKey" />
    </main>

    <footer v-if="showCodeVersionFooter" class="app-footer">
      <span>{{ translate('Build date') }}:</span>
      <code data-i18n-ignore>{{ codeVersionLabel }}</code>
    </footer>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter, type RouteLocationNormalizedLoaded } from 'vue-router';
import {
  ensureAuthInitialized,
  refreshSessionUser,
  signOut,
  useSessionAuth,
} from '@/features/auth/session';
import { useBackendStatusBanner } from '@/features/app/backendStatusBanner';
import { pageTitleOverride, useDocumentTitle } from '@/features/app/documentTitle';
import { syncExistingWebPushSubscription } from '@/features/push/webPush';
import { effectiveLocale, translate } from '@/i18n';
import appLogoUrl from '@/assets/icon_full_size.png';
import SvgIcon from '@/components/icons/SvgIcon.vue';
import StackRouterView from '@/components/StackRouterView.vue';

const router = useRouter();
const route = useRoute();

ensureAuthInitialized();

const { currentUser } = useSessionAuth();
const { banner: backendStatusBanner, dismissBackendStatusBanner } = useBackendStatusBanner();
const signingOut = ref(false);

const isLoginRoute = computed(() => route.name === 'login');
const isChatRoute = computed(() => route.name === 'chat');
const isLlmConfigurationRoute = computed(() => String(route.name || '').startsWith('llm-'));
const codeVersionLabel = computed(() => __CODE_VERSION__.label.trim());
const showCodeVersionFooter = computed(() => Boolean(codeVersionLabel.value) && !isLoginRoute.value && !isChatRoute.value);
type RouteTitle = string | ((route: RouteLocationNormalizedLoaded) => string);

const resolveRouteTitle = (targetRoute: RouteLocationNormalizedLoaded) => {
  if (targetRoute.name === 'chat' && pageTitleOverride.value) return pageTitleOverride.value;

  effectiveLocale.value;
  const routeTitle = targetRoute.meta.title as RouteTitle | undefined;
  if (typeof routeTitle === 'function') return translate(routeTitle(targetRoute).trim());
  if (typeof routeTitle === 'string') return translate(routeTitle.trim());
  return '';
};

useDocumentTitle(computed(() => resolveRouteTitle(route)));

const mobileMenuOpen = ref(false);
const routeReopenKey = ref(0);

const toggleMenu = () => {
  mobileMenuOpen.value = !mobileMenuOpen.value;
};

const closeMenu = () => {
  mobileMenuOpen.value = false;
};

const shouldLetBrowserHandleNavigation = (event: MouseEvent) =>
  event.defaultPrevented || event.button !== 0 || event.metaKey || event.altKey || event.ctrlKey || event.shiftKey;

const handleMenuNavigation = (
  event: MouseEvent,
  navigate: (event?: MouseEvent) => unknown,
  targetFullPath: string
) => {
  if (shouldLetBrowserHandleNavigation(event)) return;

  if (router.currentRoute.value.fullPath === targetFullPath) {
    event.preventDefault();
    closeMenu();
    routeReopenKey.value += 1;
    return;
  }

  void navigate(event);
};

watch(
  () => router.currentRoute.value.fullPath,
  () => {
    closeMenu();
  }
);

watch(isLoginRoute, () => {
  scheduleCssVarUpdate();
});

const handleClickOutside = (event: MouseEvent) => {
  const target = event.target as HTMLElement | null;
  const nav = document.querySelector('.app-nav');
  const toggle = document.querySelector('.menu-toggle');
  if (!nav || !toggle || !target) return;
  if (!nav.contains(target) && !toggle.contains(target)) {
    closeMenu();
  }
};

const appHeader = ref<HTMLElement | null>(null);
let headerObserver: ResizeObserver | null = null;
let updateRafId: number | null = null;
let lastHeaderHeight = '';
let lastViewportUnit = '';
let lastWebPushSyncUserId: number | null = null;

const setRootVar = (name: string, nextValue: string) => {
  if (name === '--app-header-height') {
    if (lastHeaderHeight === nextValue) return;
    lastHeaderHeight = nextValue;
  } else if (name === '--app-vh') {
    if (lastViewportUnit === nextValue) return;
    lastViewportUnit = nextValue;
  }

  document.documentElement.style.setProperty(name, nextValue);
};

const updateCssVars = () => {
  if (appHeader.value) {
    const height = Math.round(appHeader.value.getBoundingClientRect().height);
    setRootVar('--app-header-height', `${height}px`);
  } else {
    setRootVar('--app-header-height', '0px');
  }
  setRootVar('--app-vh', `${window.innerHeight * 0.01}px`);
};

const scheduleCssVarUpdate = () => {
  if (updateRafId !== null) return;
  updateRafId = window.requestAnimationFrame(() => {
    updateRafId = null;
    updateCssVars();
  });
};

const syncWebPushForCurrentUser = () => {
  const userId = currentUser.value?.id ?? null;
  if (!userId || lastWebPushSyncUserId === userId) return;
  lastWebPushSyncUserId = userId;

  void syncExistingWebPushSubscription().catch((error) => {
    console.warn('Failed to sync Web Push subscription.', error);
  });
};

const routeFromServiceWorkerUrl = (rawUrl: unknown) => {
  if (typeof rawUrl !== 'string' || rawUrl.trim() === '') return;

  let url: URL;

  try {
    url = new URL(rawUrl, window.location.origin);
  } catch {
    return;
  }

  if (url.origin !== window.location.origin) return;

  const target = `${url.pathname}${url.search}${url.hash}`;
  closeMenu();

  if (router.currentRoute.value.fullPath === target) return;

  void router.push(target).catch((error) => {
    console.warn('Failed to route from Web Push notification click.', error);
  });
};

const handleServiceWorkerMessage = (event: MessageEvent) => {
  const data = event.data;
  if (!data || typeof data !== 'object') return;
  if ((data as { type?: unknown }).type !== 'web_push_notification_click') return;

  routeFromServiceWorkerUrl((data as { url?: unknown }).url);
};

onMounted(() => {
  document.addEventListener('click', handleClickOutside);
  navigator.serviceWorker?.addEventListener('message', handleServiceWorkerMessage);

  if (currentUser.value) {
    void refreshSessionUser().catch((error) => {
      console.error('Failed to refresh session user.', error);
    });
  }

  syncWebPushForCurrentUser();

  scheduleCssVarUpdate();
  window.addEventListener('resize', scheduleCssVarUpdate);
  window.addEventListener('orientationchange', scheduleCssVarUpdate);

  if (appHeader.value && typeof ResizeObserver !== 'undefined') {
    headerObserver = new ResizeObserver(scheduleCssVarUpdate);
    headerObserver.observe(appHeader.value);
  }
});

watch(
  () => currentUser.value?.id,
  () => {
    syncWebPushForCurrentUser();
  }
);

onBeforeUnmount(() => {
  document.removeEventListener('click', handleClickOutside);
  navigator.serviceWorker?.removeEventListener('message', handleServiceWorkerMessage);
  window.removeEventListener('resize', scheduleCssVarUpdate);
  window.removeEventListener('orientationchange', scheduleCssVarUpdate);
  if (updateRafId !== null) {
    window.cancelAnimationFrame(updateRafId);
    updateRafId = null;
  }
  if (headerObserver) {
    headerObserver.disconnect();
    headerObserver = null;
  }
});

const handleSignOut = async () => {
  if (signingOut.value) return;
  signingOut.value = true;

  try {
    await signOut();
  } finally {
    signingOut.value = false;
    window.location.assign('/login');
  }
};
</script>
