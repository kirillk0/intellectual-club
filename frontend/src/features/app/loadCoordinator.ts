import { computed, readonly, ref } from 'vue';

import { LOADING_NOTICE_DELAY_MS } from '@/features/app/delayedVisibility';
import { subscribeRecoveryHeartbeat } from '@/features/app/recoveryHeartbeat';

export type LoadStage = 'runtime' | 'route' | 'data' | 'ready';

export type LoadTaskSnapshot = {
  key: string;
  stage: Exclude<LoadStage, 'ready'>;
  label: string;
  attempt: number;
  startedAt: number;
  retrying: boolean;
  waitingForConnection: boolean;
  waitingForVisibility: boolean;
};

export type LoadTaskHandle = {
  update: (patch: Partial<Omit<LoadTaskSnapshot, 'key' | 'startedAt'>>) => void;
  finish: () => void;
};

type BeginLoadTaskOptions = {
  key: string;
  stage: Exclude<LoadStage, 'ready'>;
  label?: string;
  startedAt?: number;
};

type BootstrapPatch = {
  stage?: LoadStage;
  delayed?: boolean;
  online?: boolean;
  attempt?: number;
};

const stageOrder: Record<LoadStage, number> = {
  runtime: 0,
  route: 1,
  data: 2,
  ready: 3,
};

const normalizeStartedAt = (value: unknown) => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return Date.now();
  if (value < 1_000_000_000_000) return performance.timeOrigin + value;
  return value;
};

const bootstrap = window.__IC_BOOTSTRAP__;
const startupStartedAt = ref(normalizeStartedAt(bootstrap?.startAt));
const bootstrapStage = ref<LoadStage>(bootstrap?.stage || 'runtime');
const bootstrapDelayed = ref(
  bootstrap?.delayed === true || Date.now() - startupStartedAt.value >= LOADING_NOTICE_DELAY_MS
);
const online = ref(bootstrap?.online ?? navigator.onLine !== false);
const tasks = ref<LoadTaskSnapshot[]>([]);
const delayRevision = ref(0);

let taskGeneration = 0;
let startupHandoffOpen = bootstrapStage.value !== 'ready';
let startupHandoffTimer: number | null = null;

const scheduleDelayedRefresh = (startedAt: number) => {
  const remaining = Math.max(0, startedAt + LOADING_NOTICE_DELAY_MS - Date.now());
  window.setTimeout(() => {
    delayRevision.value += 1;
  }, remaining);
};

scheduleDelayedRefresh(startupStartedAt.value);

const syncBootstrapState = () => {
  const state = window.__IC_BOOTSTRAP__;
  if (!state) return;

  startupStartedAt.value = normalizeStartedAt(state.startAt);
  bootstrapStage.value = state.stage;
  bootstrapDelayed.value =
    state.delayed || Date.now() - startupStartedAt.value >= LOADING_NOTICE_DELAY_MS;
  online.value = state.online;
};

const updateBootstrap = (patch: BootstrapPatch) => {
  const enteringReady = patch.stage === 'ready' && bootstrapStage.value !== 'ready';
  if (patch.stage) bootstrapStage.value = patch.stage;
  if (typeof patch.delayed === 'boolean') bootstrapDelayed.value = patch.delayed;
  if (typeof patch.online === 'boolean') online.value = patch.online;
  const definedPatch = Object.fromEntries(
    Object.entries(patch).filter(([, value]) => value !== undefined)
  ) as BootstrapPatch;
  window.__IC_BOOTSTRAP__?.update(definedPatch);

  if (enteringReady && startupHandoffTimer === null) {
    startupHandoffTimer = window.setTimeout(() => {
      startupHandoffOpen = false;
      startupHandoffTimer = null;
    }, 0);
  }
};

window.addEventListener('ic:bootstrap-state', syncBootstrapState);
subscribeRecoveryHeartbeat((pulse) => {
  updateBootstrap({ online: pulse.onlineHint });
});

export const setBootstrapLoadStage = (stage: LoadStage, patch: Omit<BootstrapPatch, 'stage'> = {}) => {
  updateBootstrap({ ...patch, stage });
};

export const startupLoadStartedAt = () =>
  startupHandoffOpen ? startupStartedAt.value : Date.now();

export const beginLoadTask = ({
  key,
  stage,
  label = '',
  startedAt = Date.now(),
}: BeginLoadTaskOptions): LoadTaskHandle => {
  const generation = ++taskGeneration;
  const taskKey = `${key}:${generation}`;
  const snapshot: LoadTaskSnapshot = {
    key: taskKey,
    stage,
    label,
    attempt: 1,
    startedAt,
    retrying: false,
    waitingForConnection: navigator.onLine === false,
    waitingForVisibility: document.visibilityState === 'hidden',
  };

  tasks.value = [...tasks.value.filter((task) => !task.key.startsWith(`${key}:`)), snapshot];
  scheduleDelayedRefresh(startedAt);

  if (bootstrapStage.value !== 'ready' && stageOrder[stage] >= stageOrder[bootstrapStage.value]) {
    updateBootstrap({
      stage,
      attempt: snapshot.attempt,
      online: !snapshot.waitingForConnection,
    });
  }

  const findTask = () => tasks.value.find((task) => task.key === taskKey);

  return {
    update(patch) {
      const current = findTask();
      if (!current) return;

      tasks.value = tasks.value.map((task) =>
        task.key === taskKey ? { ...task, ...patch } : task
      );

      if (bootstrapStage.value !== 'ready') {
        updateBootstrap({
          stage: patch.stage,
          attempt: patch.attempt,
          online:
            typeof patch.waitingForConnection === 'boolean'
              ? !patch.waitingForConnection
              : undefined,
        });
      }
    },
    finish() {
      tasks.value = tasks.value.filter((task) => task.key !== taskKey);
    },
  };
};

const activeTask = computed(() => {
  delayRevision.value;
  const eligibleTasks =
    bootstrapStage.value === 'ready'
      ? tasks.value.filter((task) => task.stage !== 'data')
      : tasks.value;
  return [...eligibleTasks].sort((left, right) => left.startedAt - right.startedAt)[0] || null;
});

const status = computed<LoadTaskSnapshot | null>(() => {
  const task = activeTask.value;
  if (task) return task;
  if (bootstrapStage.value === 'ready') return null;

  return {
    key: 'bootstrap',
    stage: bootstrapStage.value,
    label: '',
    attempt: Math.max(1, window.__IC_BOOTSTRAP__?.attempt || 1),
    startedAt: startupStartedAt.value,
    retrying: (window.__IC_BOOTSTRAP__?.attempt || 1) > 1,
    waitingForConnection: !online.value,
    waitingForVisibility: false,
  };
});

const visible = computed(() => {
  delayRevision.value;
  const current = status.value;
  if (!current) return false;
  if (current.key === 'bootstrap' && bootstrapDelayed.value) return true;
  return Date.now() - current.startedAt >= LOADING_NOTICE_DELAY_MS;
});

export const useLoadCoordinator = () => ({
  status: readonly(status),
  visible: readonly(visible),
  online: readonly(online),
  startupStartedAt: readonly(startupStartedAt),
  bootstrapStage: readonly(bootstrapStage),
});
