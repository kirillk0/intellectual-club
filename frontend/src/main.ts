import { createApp } from 'vue';
import { VueQueryPlugin } from '@tanstack/vue-query';

import App from './App.vue';
import { i18n } from './i18n';
import { installDomTranslations } from './i18n/dom';
import { setupPwa } from './pwa';
import { router } from './router';
import { serverStateQueryClient } from './features/serverState/queryClient';
import { setupScrollableTabs } from './utils/scrollableTabs';
import './spa.css';

const root = document.getElementById('spa-root');

if (root) {
  createApp(App)
    .use(i18n)
    .use(router)
    .use(VueQueryPlugin, { queryClient: serverStateQueryClient })
    .mount(root);
  installDomTranslations(document.body);
  setupScrollableTabs(root);
  setupPwa();
}
