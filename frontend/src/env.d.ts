/// <reference types="vite/client" />
/// <reference types="vite-svg-loader" />

declare const __CODE_VERSION__: {
  commit_timestamp: string;
  commit_sha: string;
  dirty: boolean;
  label: string;
};

declare module '*.vue' {
  import type { DefineComponent } from 'vue';
  const component: DefineComponent<Record<string, unknown>, Record<string, unknown>, unknown>;
  export default component;
}
