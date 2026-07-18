/// <reference types="vite/client" />
/// <reference types="vite-svg-loader" />

declare const __CODE_VERSION__: {
  commit_timestamp: string;
  commit_sha: string;
  dirty: boolean;
  label: string;
};

type IcBootstrapStage = 'runtime' | 'route' | 'data' | 'ready';

type IcBootstrapState = {
  buildId: string;
  startAt: number;
  stage: IcBootstrapStage;
  delayed: boolean;
  online: boolean;
  attempt: number;
  update: (patch: {
    stage?: IcBootstrapStage;
    delayed?: boolean;
    online?: boolean;
    attempt?: number;
  }) => void;
};

interface Window {
  __IC_BOOTSTRAP__?: IcBootstrapState;
  __IC_SERVICE_WORKER_REGISTRATION__?: Promise<ServiceWorkerRegistration | null>;
}

declare module '*.vue' {
  import type { DefineComponent } from 'vue';
  const component: DefineComponent<Record<string, unknown>, Record<string, unknown>, unknown>;
  export default component;
}
