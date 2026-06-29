import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

import vue from '@vitejs/plugin-vue';
import svgLoader from 'vite-svg-loader';
import { defineConfig, type PluginOption } from 'vite';

type CodeVersion = {
  commit_timestamp: string;
  commit_sha: string;
  dirty: boolean;
  label: string;
};

const emptyCodeVersion: CodeVersion = {
  commit_timestamp: '',
  commit_sha: '',
  dirty: false,
  label: '',
};

const runGit = (args: string[], cwd: string) =>
  execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();

const buildCodeVersion = (repoRoot: string): CodeVersion => {
  try {
    if (runGit(['rev-parse', '--is-inside-work-tree'], repoRoot) !== 'true') return emptyCodeVersion;

    const commitTimestamp = runGit(['log', '-1', '--format=%cI'], repoRoot);
    const commitSha = runGit(['rev-parse', '--short=12', 'HEAD'], repoRoot);
    if (!commitTimestamp || !commitSha) return emptyCodeVersion;

    const dirty = runGit(['status', '--porcelain', '--untracked-files=normal'], repoRoot) !== '';
    const label = `${commitTimestamp} ${commitSha}${dirty ? ' dirty' : ''}`;

    return {
      commit_timestamp: commitTimestamp,
      commit_sha: commitSha,
      dirty,
      label,
    };
  } catch {
    return emptyCodeVersion;
  }
};

const codeVersionPlugin = (codeVersion: CodeVersion): PluginOption => ({
  name: 'code-version',
  generateBundle() {
    this.emitFile({
      type: 'asset',
      fileName: 'code-version.json',
      source: `${JSON.stringify(codeVersion, null, 2)}\n`,
    });
  },
});

export default defineConfig(({ mode }) => {
  const isProd = mode === 'production';
  const repoRoot = path.resolve(__dirname, '..');
  const codeVersion = buildCodeVersion(repoRoot);
  const spaAssetsDir = path.resolve(__dirname, '../server/priv/static/assets');
  const spaGeneratedPaths = [
    path.join(spaAssetsDir, 'assets'),
    path.join(spaAssetsDir, 'code-version.json'),
    path.join(spaAssetsDir, 'css/spa.css'),
    path.join(spaAssetsDir, 'css/spa.css.gz'),
    path.join(spaAssetsDir, 'css/spa.css.map'),
    path.join(spaAssetsDir, 'js/spa.js'),
    path.join(spaAssetsDir, 'js/spa.js.gz'),
    path.join(spaAssetsDir, 'js/spa.js.map'),
    path.join(spaAssetsDir, 'js/chunks'),
    path.join(spaAssetsDir, 'temml.min.js'),
    path.join(spaAssetsDir, 'temml.min.js.gz'),
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
      codeVersionPlugin(codeVersion),
    ],
    resolve: {
      alias: {
        '@': path.resolve(__dirname, 'src'),
      },
    },
    define: {
      'process.env.NODE_ENV': JSON.stringify(isProd ? 'production' : 'development'),
      __CODE_VERSION__: JSON.stringify(codeVersion),
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
