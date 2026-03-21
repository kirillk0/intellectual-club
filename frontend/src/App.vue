<template>
  <div class="app-shell">
    <header ref="appHeader" class="app-header compact" v-show="!isLoginRoute">
      <button class="menu-toggle" type="button" @click="toggleMenu" aria-label="Open menu">☰</button>
      <nav class="app-nav" :class="{ open: mobileMenuOpen }">
        <RouterLink to="/" custom v-slot="{ href, isActive, isExactActive, navigate }">
          <a
            :href="href"
            :class="{
              'router-link-active': isActive,
              'router-link-exact-active': isExactActive,
            }"
            @click="handleChatsNavigation($event, navigate)"
          >
            Chats
          </a>
        </RouterLink>
        <RouterLink to="/catalogs/bots">Bots</RouterLink>
        <RouterLink to="/catalogs/tools">Tools</RouterLink>
        <RouterLink to="/catalogs/knowledge-blocks">Knowledge Blocks</RouterLink>
        <RouterLink to="/catalogs/llm-providers">LLM Providers</RouterLink>
        <RouterLink to="/catalogs/llm-configurations">LLM Configurations</RouterLink>
        <RouterLink v-if="currentUser?.is_admin" to="/administration/users">Administration</RouterLink>
        <div class="user-slot" v-if="currentUser">
          <RouterLink class="user-link" to="/settings">{{ currentUser.username }}</RouterLink>
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

    <main class="app-main" :class="{ 'app-main--chat': isChatRoute, 'app-main--login': isLoginRoute }">
      <StackRouterView />
    </main>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';
import {
  ensureAuthInitialized,
  refreshSessionUser,
  signOut,
  useSessionAuth,
} from '@/features/auth/session';
import StackRouterView from '@/components/StackRouterView.vue';

const CHAT_LIST_RESET_EVENT = 'chat-list:reset-to-first-page';

const router = useRouter();
const route = useRoute();

ensureAuthInitialized();

const { currentUser } = useSessionAuth();
const signingOut = ref(false);

const isLoginRoute = computed(() => route.name === 'login');
const isChatRoute = computed(() => route.name === 'chat');

const mobileMenuOpen = ref(false);

const toggleMenu = () => {
  mobileMenuOpen.value = !mobileMenuOpen.value;
};

const closeMenu = () => {
  mobileMenuOpen.value = false;
};

const handleChatsNavigation = (event: MouseEvent, navigate: (event?: MouseEvent) => unknown) => {
  if (route.name === 'chats') {
    event.preventDefault();
    closeMenu();
    window.dispatchEvent(new CustomEvent(CHAT_LIST_RESET_EVENT));
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

onMounted(() => {
  document.addEventListener('click', handleClickOutside);

  if (currentUser.value) {
    void refreshSessionUser().catch((error) => {
      console.error('Failed to refresh session user.', error);
    });
  }

  scheduleCssVarUpdate();
  window.addEventListener('resize', scheduleCssVarUpdate);
  window.addEventListener('orientationchange', scheduleCssVarUpdate);

  if (appHeader.value && typeof ResizeObserver !== 'undefined') {
    headerObserver = new ResizeObserver(scheduleCssVarUpdate);
    headerObserver.observe(appHeader.value);
  }
});

onBeforeUnmount(() => {
  document.removeEventListener('click', handleClickOutside);
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
