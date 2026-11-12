import { ChatController } from './chat';
import { pendingStore } from './pending-store';
import { isDevelopmentSeedAllowed } from './seed-guard';
import { syntheticOperationId } from './seed-uuid';
import { isSeedApiRequest, isTestTtsFixtureRequest } from './seed-paths';

/** True only for the explicitly enabled synthetic development proxy. */
export function developmentSeedAvailable(): boolean {
  return isDevelopmentSeedAllowed(__DEV__, process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED, typeof window === 'undefined' ? undefined : window.location.origin, process.env.EXPO_PUBLIC_ETOS_SEED_LAN_HOST);
}

/** Reports only the synthetic host's owner state, never a real CFL authorization. */
export async function developmentSeedStatus(): Promise<'setup' | 'signed_out' | 'signed_in'> {
  if (!developmentSeedAvailable()) throw new Error('synthetic_seed_unavailable');
  const response = await fetch('/api/auth/status', { credentials: 'omit', cache: 'no-store', redirect: 'error' });
  if (!response.ok || response.redirected) throw new Error('unavailable');
  const value: unknown = await response.json();
  if (!value || typeof value !== 'object' || !('mode' in value) || value.mode !== 'passkey' || !('state' in value) || (value.state !== 'setup' && value.state !== 'signed_out' && value.state !== 'signed_in')) throw new Error('unavailable');
  return value.state;
}

/** Never uses real authentication. Synthetic recovery has its own journal namespace. */
export function createDevelopmentSeedChat() {
  if (!developmentSeedAvailable()) throw new Error('synthetic_seed_unavailable');
  const origin = window.location.origin;
  const transport = {
    origin,
    async socket(): Promise<WebSocket> { return new WebSocket(`${origin.replace('http:', 'ws:')}/api/chat/socket`); },
    async checkAuthorization() {
      return await developmentSeedStatus() === 'signed_in';
    },
    async request(path: string, init: RequestInit = {}) {
      // Sensitive TTS routes are still denied by the fixed 3090 proxy; only the
      // test-owned fixture proxy accepts these exact paths without real providers.
      if (!isSeedApiRequest(init.method ?? 'GET', path) && !isTestTtsFixtureRequest(init.method ?? 'GET', path)) throw new Error('invalid_media');
      return fetch(path, { ...init, credentials: 'omit', redirect: 'error' });
    },
    async read(path: string, init?: RequestInit) { return this.request(path, init); },
  };
  return { controller: new ChatController(`synthetic-seed:${origin}`, transport.socket, pendingStore, syntheticOperationId, undefined, transport.checkAuthorization), media: transport };
}
