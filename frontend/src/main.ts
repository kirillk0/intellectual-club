import { createApp } from 'vue';
import 'temml/dist/Temml-Local.css';

import App from './App.vue';
import { setupPwa } from './pwa';
import { router } from './router';
import { setupScrollableTabs } from './utils/scrollableTabs';
import './spa.css';

const root = document.getElementById('spa-root');

if (root) {
  createApp(App).use(router).mount(root);
  setupScrollableTabs(root);
  setupPwa();
}
