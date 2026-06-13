import fs from 'node:fs';
import path from 'node:path';

import vue from '@vitejs/plugin-vue';
import svgLoader from 'vite-svg-loader';
import { defineConfig } from 'vite';

export default defineConfig(({ mode }) => {
  const isProd = mode === 'production';
  const spaAssetsDir = path.resolve(__dirname, '../server/priv/static/assets');
  const spaGeneratedPaths = [
    path.join(spaAssetsDir, 'assets'),
    path.join(spaAssetsDir, 'css/spa.css'),
    path.join(spaAssetsDir, 'css/spa.css.map'),
    path.join(spaAssetsDir, 'js/spa.js'),
    path.join(spaAssetsDir, 'js/spa.js.map'),
    path.join(spaAssetsDir, 'js/chunks'),
    path.join(spaAssetsDir, 'temml.min.js'),
  ];

  return {
    plugins: [
      {
        name: 'clean-spa-output',
        buildStart() {
          for (const outputPath of spaGeneratedPaths) {
            fs.rmSync(outputPath, { force: true, recursive: true });
          }
        },
      },
      vue(),
      svgLoader({ defaultImport: 'component' }),
    ],
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
            if (assetInfo.name === 'temml.min.js') return '[name][extname]';
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
