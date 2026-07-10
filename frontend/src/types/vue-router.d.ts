import 'vue-router';
import type { RouteLocationNormalizedLoaded } from 'vue-router';

declare module 'vue-router' {
  interface RouteMeta {
    title?: string | ((route: RouteLocationNormalizedLoaded) => string);
    requiresAdmin?: boolean;
    stackEntityParams?: readonly string[];
  }
}

export {};
