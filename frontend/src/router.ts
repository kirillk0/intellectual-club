import { nextTick } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import { ensureAuthInitialized, useSessionAuth } from '@/features/auth/session';
import { useNavigationStack } from '@/features/stack/navigationStack';

import BotEditView from './views/catalogs/BotEditView.vue';
import BotsIndexView from './views/catalogs/BotsIndexView.vue';
import KnowledgeBlockEditView from './views/catalogs/KnowledgeBlockEditView.vue';
import KnowledgeBlocksIndexView from './views/catalogs/KnowledgeBlocksIndexView.vue';
import LlmConfigurationEditView from './views/catalogs/LlmConfigurationEditView.vue';
import LlmConfigurationsIndexView from './views/catalogs/LlmConfigurationsIndexView.vue';
import LlmProviderEditView from './views/catalogs/LlmProviderEditView.vue';
import LlmProvidersIndexView from './views/catalogs/LlmProvidersIndexView.vue';
import ToolInstanceEditView from './views/catalogs/ToolInstanceEditView.vue';
import ToolInstancesIndexView from './views/catalogs/ToolInstancesIndexView.vue';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('./views/LoginView.vue') },
    { path: '/', name: 'chats', component: () => import('./views/ChatsIndexView.vue') },
    { path: '/bookmarks', name: 'bookmarks', component: () => import('./views/BookmarksIndexView.vue') },
    { path: '/settings', name: 'settings', component: () => import('./views/UserSettingsView.vue') },
    { path: '/administration', redirect: '/administration/users' },
    {
      path: '/administration/users',
      name: 'admin-users',
      component: () => import('./views/administration/UsersIndexView.vue'),
      meta: { requiresAdmin: true },
    },
    {
      path: '/administration/users/:id(\\d+|new)',
      name: 'admin-user',
      component: () => import('./views/administration/UserEditView.vue'),
      meta: { requiresAdmin: true },
    },
    {
      path: '/administration/user-groups',
      name: 'admin-user-groups',
      component: () => import('./views/administration/UserGroupsIndexView.vue'),
      meta: { requiresAdmin: true },
    },
    {
      path: '/administration/user-groups/:id(\\d+|new)',
      name: 'admin-user-group',
      component: () => import('./views/administration/UserGroupEditView.vue'),
      meta: { requiresAdmin: true },
    },
    { path: '/outlets/connect', name: 'outlet-connect', component: () => import('./views/OutletConnectView.vue') },
    {
      path: '/chats/:id(\\d+)',
      name: 'chat',
      component: () => import('./views/ChatView.vue'),
    },
    { path: '/catalogs', redirect: '/catalogs/bots' },
    {
      path: '/catalogs/knowledge-blocks',
      name: 'knowledge-blocks',
      component: KnowledgeBlocksIndexView,
    },
    {
      path: '/catalogs/knowledge-blocks/:id(\\d+|new)',
      name: 'knowledge-block',
      component: KnowledgeBlockEditView,
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
      component: LlmProvidersIndexView,
    },
    {
      path: '/catalogs/llm-providers/:id(\\d+|new)',
      name: 'llm-provider',
      component: LlmProviderEditView,
    },
    {
      path: '/catalogs/llm-configurations',
      name: 'llm-configurations',
      component: LlmConfigurationsIndexView,
    },
    {
      path: '/catalogs/llm-configurations/:id(\\d+|new)',
      name: 'llm-configuration',
      component: LlmConfigurationEditView,
    },
    { path: '/catalogs/bots', name: 'bots', component: BotsIndexView },
    {
      path: '/catalogs/bots/:id(\\d+|new)',
      name: 'bot',
      component: BotEditView,
    },
    { path: '/catalogs/tools', name: 'tools', component: ToolInstancesIndexView },
    {
      path: '/catalogs/tools/:id(\\d+|new)',
      name: 'tool',
      component: ToolInstanceEditView,
    },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
});

router.beforeEach((to) => {
  ensureAuthInitialized();

  const { currentUser, isAuthenticated } = useSessionAuth();
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

  return true;
});

const getHistoryState = () => (router.options.history.state as any) ?? window.history.state;

router.afterEach((to, from) => {
  const stack = useNavigationStack();

  if (stack.pendingPush.value !== null) {
    const scrollY = stack.pendingPush.value;
    stack.push(from, scrollY);
    stack.clearPendingPush();
    if (scrollY) {
      nextTick(() => {
        window.scrollTo({ top: scrollY, left: 0 });
      });
    }
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
