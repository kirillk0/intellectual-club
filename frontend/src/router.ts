import { nextTick } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import { ensureAuthInitialized, useSessionAuth } from '@/features/auth/session';
import { rememberPwaRoute, restorePwaRouteOnLaunch } from '@/features/pwa/lastRoute';
import { useNavigationStack } from '@/features/stack/navigationStack';

import BotEditView from './views/catalogs/BotEditView.vue';
import BotsIndexView from './views/catalogs/BotsIndexView.vue';
import KnowledgeBlocksIndexView from './views/catalogs/KnowledgeBlocksIndexView.vue';
import LlmConfigurationEditView from './views/catalogs/LlmConfigurationEditView.vue';
import LlmConfigurationsIndexView from './views/catalogs/LlmConfigurationsIndexView.vue';
import LlmConfigurationUsageView from './views/catalogs/LlmConfigurationUsageView.vue';
import LlmProviderEditView from './views/catalogs/LlmProviderEditView.vue';
import LlmProvidersIndexView from './views/catalogs/LlmProvidersIndexView.vue';
import ToolInstanceEditView from './views/catalogs/ToolInstanceEditView.vue';
import ToolInstancesIndexView from './views/catalogs/ToolInstancesIndexView.vue';

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
      meta: { requiresAdmin: true, title: 'User' },
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
      meta: { requiresAdmin: true, title: 'User Group' },
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
      component: KnowledgeBlocksIndexView,
      meta: { title: 'Knowledge Blocks' },
    },
    {
      path: '/catalogs/knowledge-blocks/:id(\\d+|new)',
      name: 'knowledge-block',
      component: () => import('./views/catalogs/KnowledgeBlockEditView.vue'),
      meta: { title: 'Knowledge Block' },
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
      meta: { title: 'LLM Providers' },
    },
    {
      path: '/catalogs/llm-providers/:id(\\d+|new)',
      name: 'llm-provider',
      component: LlmProviderEditView,
      meta: { title: 'LLM Provider' },
    },
    {
      path: '/catalogs/llm-configurations',
      name: 'llm-configurations',
      component: LlmConfigurationsIndexView,
      meta: { title: 'LLM Configurations' },
    },
    {
      path: '/catalogs/llm-configurations/usage',
      name: 'llm-configuration-usage',
      component: LlmConfigurationUsageView,
      meta: { title: 'LLM Usage' },
    },
    {
      path: '/catalogs/llm-configurations/:id(\\d+|new)',
      name: 'llm-configuration',
      component: LlmConfigurationEditView,
      meta: { title: 'LLM Configuration' },
    },
    { path: '/catalogs/bots', name: 'bots', component: BotsIndexView, meta: { title: 'Bots' } },
    {
      path: '/catalogs/bots/:id(\\d+|new)',
      name: 'bot',
      component: BotEditView,
      meta: { title: 'Bot' },
    },
    { path: '/catalogs/tools', name: 'tools', component: ToolInstancesIndexView, meta: { title: 'Tools' } },
    {
      path: '/catalogs/tools/:id(\\d+|new)',
      name: 'tool',
      component: ToolInstanceEditView,
      meta: { title: 'Tool' },
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

  const restoredPwaRoute = restorePwaRouteOnLaunch(to);
  if (restoredPwaRoute) return restoredPwaRoute;

  return true;
});

const getHistoryState = () => (router.options.history.state as any) ?? window.history.state;

router.afterEach((to, from) => {
  const { isAuthenticated } = useSessionAuth();
  rememberPwaRoute(to, isAuthenticated.value);

  const stack = useNavigationStack();

  if (stack.pendingPush.value !== null) {
    const scrollY = stack.pendingPush.value;
    stack.push(from, scrollY);
    stack.clearPendingPush();
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
