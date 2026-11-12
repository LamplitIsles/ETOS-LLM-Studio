import type { ChatController } from './chat';
import { readBoundedBody, type ApiTransport } from './transport';

export const MODEL_CHOICES = [
  { id: 'gpt-6.1-sol', name: '6.1 sol' },
  { id: 'gpt-5.6-sol', name: '5.6 sol' },
  { id: 'gpt-6.1-terra', name: '6.1 terra' },
] as const;
export type ModelSettings = { sessionId: string; currentModel: string; fast: boolean; busy: boolean };
export type ModelSelection = { model: typeof MODEL_CHOICES[number]['id']; fast: boolean };
export type ModelChange = { state: 'saved'; snapshot: ModelSettings } | { state: 'stale_model' | 'model_busy'; snapshot: ModelSettings | null } | { state: 'unknown' } | { state: 'access_denied' | 'invalid_request' | 'invalid_model' };

type Owner = { generation: number; writing: boolean; snapshots: WeakMap<ModelSettings, { generation: number; current: () => boolean; transport: ApiTransport }> };
const owners = new WeakMap<ChatController, Owner>();
const path = '/api/chat/models';
const identifier = (value: unknown, max: number): value is string => typeof value === 'string' && value.length > 0 && value.length <= max && value === value.trim() && !/[\r\n\u2028\u2029\x00-\x1f\x7f]/u.test(value);
function parseSnapshot(raw: unknown, sessionId: string): ModelSettings {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('invalid_model_settings');
  const value = raw as Record<string, unknown>;
  if (Object.keys(value).sort().join(',') !== 'busy,currentModel,fast,sessionId' || !identifier(value.sessionId, 300) || !identifier(value.currentModel, 200) || typeof value.fast !== 'boolean' || typeof value.busy !== 'boolean' || value.sessionId !== sessionId) throw new Error('invalid_model_settings');
  return Object.freeze({ sessionId: value.sessionId, currentModel: value.currentModel, fast: value.fast, busy: value.busy });
}
async function json(response: Response, current: () => boolean): Promise<unknown> {
  if (response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('invalid_model_settings');
  const bytes = await readBoundedBody(response, 64 * 1024, current, 'invalid_model_settings');
  try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; } catch { throw new Error('invalid_model_settings'); }
}
function errorCode(value: unknown): string | null {
  if (!value || typeof value !== 'object' || !('error' in value)) return null;
  const error = value.error;
  return error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : null;
}

/** One owner per controller: a successful read is the only basis for an explicit write. */
export class ModelSettingsClient {
  private owner: Owner;
  constructor(private controller: ChatController, private transport: ApiTransport) {
    if (controller.origin !== transport.origin && controller.origin !== `synthetic-seed:${transport.origin}`) throw new Error('origin_mismatch');
    let owner = owners.get(controller);
    if (!owner) { owner = { generation: 0, writing: false, snapshots: new WeakMap() }; owners.set(controller, owner); }
    this.owner = owner;
  }
  private capture() {
    const current = this.controller.onlineScope(), sessionId = this.controller.snapshot().view?.sessionId;
    if (!sessionId || !current()) throw new Error('offline');
    return { current, sessionId };
  }
  private async read(current: () => boolean, sessionId: string, generation: number): Promise<ModelSettings> {
    const response = await this.transport.request(path, { cache: 'no-store' });
    if (!current()) throw new Error('session_changed');
    if (response.status === 401 || response.status === 403) throw new Error('access_denied');
    if ([404, 405, 501].includes(response.status)) throw new Error('model_settings_unsupported');
    if (!response.ok || response.redirected) throw new Error('model_settings_unavailable');
    const raw = await json(response, current);
    if (!current()) throw new Error('session_changed');
    if (this.owner.generation !== generation) throw new Error('model_superseded');
    const snapshot = parseSnapshot(raw, sessionId);
    this.owner.snapshots.set(snapshot, { generation, current, transport: this.transport });
    return snapshot;
  }
  async load(): Promise<ModelSettings> {
    if (this.owner.writing) throw new Error('model_write_pending');
    const { current, sessionId } = this.capture(), generation = ++this.owner.generation;
    try { return await this.read(current, sessionId, generation); }
    catch (error) { if (!current()) throw new Error('session_changed'); if (this.owner.generation !== generation) throw new Error('model_superseded'); throw error; }
  }
  /** Call only after an explicit user choice. Unknown is never dispatched again automatically. */
  async select(snapshot: ModelSettings, choice: ModelSelection): Promise<ModelChange> {
    if (this.owner.writing) throw new Error('model_write_pending');
    const { current, sessionId } = this.capture(), record = this.owner.snapshots.get(snapshot);
    if (!record || record.generation !== this.owner.generation || record.transport !== this.transport || !record.current() || snapshot.sessionId !== sessionId) throw new Error('model_snapshot_stale');
    if (!choice || Object.keys(choice).sort().join(',') !== 'fast,model' || !MODEL_CHOICES.some(item => item.id === choice.model) || typeof choice.fast !== 'boolean') throw new Error('invalid_model_selection');
    const input = { sessionId, expectedModel: snapshot.currentModel, expectedFast: snapshot.fast, model: choice.model, fast: choice.fast };
    const generation = ++this.owner.generation; this.owner.writing = true;
    try {
      let response: Response;
      try { response = await this.transport.request(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) }); }
      catch { return { state: 'unknown' }; }
      if (!current() || response.redirected) return { state: 'unknown' };
      if (response.status === 401 || response.status === 403) return { state: 'access_denied' };
      if (response.ok) {
        try {
          const raw = await json(response, current); if (!current()) return { state: 'unknown' };
          const result = parseSnapshot(raw, sessionId);
          if (result.currentModel !== choice.model || result.fast !== choice.fast) return { state: 'unknown' };
          this.owner.snapshots.set(result, { generation, current, transport: this.transport }); return { state: 'saved', snapshot: result };
        } catch { return { state: 'unknown' }; }
      }
      let code: string | null;
      try { code = errorCode(await json(response, current)); } catch { return { state: 'unknown' }; }
      if (!current()) return { state: 'unknown' };
      if (response.status === 409 && (code === 'stale_model' || code === 'model_busy')) {
        let refreshed: ModelSettings | null = null;
        try { refreshed = await this.read(current, sessionId, generation); } catch { /* preserve the conflict even if refresh fails */ }
        if (!current()) return { state: 'unknown' };
        return { state: code, snapshot: refreshed };
      }
      if (response.status === 400 && (code === 'invalid_request' || code === 'invalid_model')) return { state: code };
      return { state: 'unknown' };
    } finally { this.owner.writing = false; }
  }
}
