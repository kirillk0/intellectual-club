import path from 'node:path';

import vue from '@vitejs/plugin-vue';
import { defineConfig } from 'vite';

export default defineConfig(({ mode }) => {
  const isProd = mode === 'production';

  return {
    plugins: [vue()],
    resolve: {
      alias: {
        '@': path.resolve(__dirname, 'src'),
      },
    },
    define: {
      'process.env.NODE_ENV': JSON.stringify(isProd ? 'production' : 'development'),
      __VUE_OPTIONS_API__: true,
      __VUE_PROD_DEVTOOLS__: false,
    },
    build: {
      outDir: path.resolve(__dirname, '../server/priv/static/assets'),
      emptyOutDir: false,
      sourcemap: !isProd,
      cssCodeSplit: false,
      lib: {
        entry: path.resolve(__dirname, 'src/main.ts'),
        formats: ['es'],
        fileName: () => 'js/spa.js',
      },
      rollupOptions: {
        output: {
          chunkFileNames: 'js/chunks/[name]-[hash].js',
          assetFileNames: (assetInfo) => {
            if (assetInfo.name?.endsWith('.css')) return 'css/spa.css';
            return 'assets/[name][extname]';
          },
        },
      },
    },
    esbuild: {
      target: 'es2022',
    },
  };
});
