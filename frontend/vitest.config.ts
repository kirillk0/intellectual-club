import path from 'node:path';
import { fileURLToPath } from 'node:url';

import vue from '@vitejs/plugin-vue';
import svgLoader from 'vite-svg-loader';
import { defineConfig } from 'vitest/config';

const frontendRoot = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  plugins: [vue(), svgLoader({ defaultImport: 'component' })],
  resolve: {
    alias: {
      '@': path.resolve(frontendRoot, 'src'),
    },
  },
  define: {
    'process.env.NODE_ENV': JSON.stringify('test'),
    __CODE_VERSION__: JSON.stringify({
      commit_timestamp: '',
      commit_sha: '',
      dirty: false,
      label: 'test',
    }),
    __VUE_OPTIONS_API__: true,
    __VUE_PROD_DEVTOOLS__: false,
  },
  test: {
    environment: 'jsdom',
    globals: true,
    passWithNoTests: true,
    clearMocks: true,
    restoreMocks: true,
  },
});
