import { createApp } from 'vue';
import { VueQueryPlugin } from '@tanstack/vue-query';

import App from './App.vue';
import { i18n } from './i18n';
import { installDomTranslations } from './i18n/dom';
import { setBootstrapLoadStage } from './features/app/loadCoordinator';
import { requestRecoveryNow } from './features/app/recoveryHeartbeat';
import { setupPwa } from './pwa';
import { router } from './router';
import { serverStateQueryClient } from './features/serverState/queryClient';
import { setupInitialQueryLoadBridge } from './features/serverState/queryLoadBridge';
import { setupScrollableTabs } from './utils/scrollableTabs';
import './spa.css';

const root = document.getElementById('spa-root');

setupPwa();

if (root) {
  setBootstrapLoadStage('route');
  setupInitialQueryLoadBridge(serverStateQueryClient);
  requestRecoveryNow();

  const app = createApp(App)
    .use(i18n)
    .use(router)
    .use(VueQueryPlugin, { queryClient: serverStateQueryClient });

  app.mount(root);
  installDomTranslations(document.body);
  setupScrollableTabs(root);
}
