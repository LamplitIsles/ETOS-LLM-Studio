import type { ChatController } from './chat';
import { readBoundedBody, type ApiTransport } from './transport';

export type BarkSnapshot = { configured: boolean; enabled: boolean };
export type BarkAction = { action: 'set'; key: string } | { action: 'enable' | 'disable' | 'remove' };
export type BarkResult = { state: 'saved'; snapshot: BarkSnapshot } | { state: 'unsupported' | 'invalid' | 'busy' | 'access_denied' | 'unknown' };
/** Accepted means the Bark server returned HTTP 2xx, not that a device displayed it. */
export type BarkTestResult = { state: 'accepted' | 'bark_not_configured' | 'bark_disabled' | 'bark_upstream_rejected' | 'unsupported' | 'busy' | 'unknown' };

type Owner = { generation: number; writing: boolean };
const owners = new WeakMap<ChatController, Owner>();
const path = '/api/bark/settings';
const testPath = '/api/bark/test';
const unsupported = (status: number) => [404, 405, 501].includes(status);

function snapshot(raw: unknown): BarkSnapshot {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('invalid_bark_response');
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).sort().join(',') !== 'configured,enabled' || typeof value.configured !== 'boolean' || typeof value.enabled !== 'boolean' || (value.enabled && !value.configured)) throw new Error('invalid_bark_response');
  return { configured: value.configured, enabled: value.enabled };
}
function validAction(raw: unknown): raw is BarkAction {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return false;
  const value = raw as Record<string, unknown>;
  if (value.action === 'set') return Object.keys(value).sort().join(',') === 'action,key' && typeof value.key === 'string' && value.key.length > 0 && value.key.length <= 512 && !/[\x00-\x20\x7f]/u.test(value.key) && value.key.trim() === value.key;
  return Object.keys(value).join(',') === 'action' && (value.action === 'enable' || value.action === 'disable' || value.action === 'remove');
}
async function json(response: Response, current: () => boolean): Promise<unknown> {
  if (response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('invalid_bark_response');
  const bytes = await readBoundedBody(response, 64 * 1024, current, 'invalid_bark_response');
  try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; } catch { throw new Error('invalid_bark_response'); }
}
function testErrorCode(raw: unknown): string | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).join(',') !== 'error') return null;
  const error = (raw as Record<string, unknown>).error;
  if (!error || typeof error !== 'object' || Array.isArray(error) || Object.keys(error).sort().join(',') !== 'code,message') return null;
  const value = error as Record<string, unknown>;
  return typeof value.code === 'string' && typeof value.message === 'string' ? value.code : null;
}

/** Bound to the controller's current online scope. Explicit writes are never retried. */
export class BarkSettingsClient {
  private owner: Owner;
  private scope: () => boolean;
  private disposed = false;
  constructor(controller: ChatController, private transport: ApiTransport, private active: () => boolean = () => true) {
    if (controller.origin !== transport.origin && controller.origin !== `synthetic-seed:${transport.origin}`) throw new Error('origin_mismatch');
    this.scope = controller.onlineScope();
    if (!this.scope() || !active()) throw new Error('offline');
    let owner = owners.get(controller);
    if (!owner) { owner = { generation: 0, writing: false }; owners.set(controller, owner); }
    this.owner = owner;
  }
  current = () => {
    if (!this.scope() || !this.active()) this.disposed = true;
    return !this.disposed;
  };
  dispose() { this.disposed = true; }
  private check() { if (!this.current()) throw new Error('session_changed'); }

  async load(): Promise<BarkSnapshot> {
    this.check();
    if (this.owner.writing) throw new Error('bark_write_pending');
    const generation = ++this.owner.generation;
    try {
      let response: Response;
      try { response = await this.transport.request(path, { cache: 'no-store' }); } catch { throw new Error('bark_unavailable'); }
      this.check();
      if (response.redirected) throw new Error('bark_unavailable');
      if (response.status === 401 || response.status === 403) throw new Error('access_denied');
      if (unsupported(response.status)) throw new Error('unsupported');
      if (!response.ok) throw new Error('bark_unavailable');
      const result = snapshot(await json(response, this.current));
      this.check();
      if (generation !== this.owner.generation) throw new Error('bark_superseded');
      return result;
    } catch (error) {
      this.check();
      if (generation !== this.owner.generation) throw new Error('bark_superseded');
      if (error instanceof Error && ['access_denied', 'unsupported', 'bark_unavailable', 'invalid_bark_response'].includes(error.message)) throw error;
      throw new Error('invalid_bark_response');
    }
  }

  async update(action: BarkAction): Promise<BarkResult> {
    this.check();
    if (!validAction(action)) return { state: 'invalid' };
    if (this.owner.writing) return { state: 'busy' };
    const input: BarkAction = action.action === 'set' ? { action: 'set', key: action.key } : { action: action.action };
    ++this.owner.generation; this.owner.writing = true;
    try {
      let response: Response;
      try { response = await this.transport.request(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) }); }
      catch { return { state: 'unknown' }; }
      if (!this.current() || response.redirected) return { state: 'unknown' };
      // Authorization may be revoked after the server commits but before it replies.
      if (response.status === 401 || response.status === 403) return { state: 'unknown' };
      if (unsupported(response.status)) return { state: 'unsupported' };
      if (response.status === 400) return { state: 'invalid' };
      if (response.status === 409) return { state: 'busy' };
      if (!response.ok) return { state: 'unknown' };
      try {
        const result = snapshot(await json(response, this.current));
        if (!this.current()) return { state: 'unknown' };
        if ((input.action === 'set' && !result.configured) || (input.action === 'enable' && !result.enabled) || (input.action === 'disable' && result.enabled) || (input.action === 'remove' && result.configured)) return { state: 'unknown' };
        return { state: 'saved', snapshot: result };
      } catch { return { state: 'unknown' }; }
    } finally { this.owner.writing = false; }
  }

  /** Explicit user action only; an unconfirmed attempt must not be replayed automatically. */
  async testNotification(): Promise<BarkTestResult> {
    if (!this.current()) return { state: 'unknown' };
    if (this.owner.writing) return { state: 'busy' };
    ++this.owner.generation; this.owner.writing = true;
    try {
      let response: Response;
      try { response = await this.transport.request(testPath, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }); }
      catch { return { state: 'unknown' }; }
      if (!this.current() || response.redirected) return { state: 'unknown' };
      if (unsupported(response.status)) return { state: 'unsupported' };
      if (response.status !== 200 && response.status !== 409 && response.status !== 502) return { state: 'unknown' };
      try {
        const value = await json(response, this.current);
        if (!this.current()) return { state: 'unknown' };
        if (response.status === 200 && value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).join(',') === 'status' && (value as Record<string, unknown>).status === 'accepted') return { state: 'accepted' };
        const code = testErrorCode(value);
        if (response.status === 409 && (code === 'bark_not_configured' || code === 'bark_disabled')) return { state: code };
        if (response.status === 502 && code === 'bark_upstream_rejected') return { state: code };
        return { state: 'unknown' };
      } catch { return { state: 'unknown' }; }
    } finally { this.owner.writing = false; }
  }
}
