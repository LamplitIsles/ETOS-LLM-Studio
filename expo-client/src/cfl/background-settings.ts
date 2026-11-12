import type { ChatController } from './chat';
import { readBoundedBody, type ApiTransport } from './transport';

export const MAX_BACKGROUND_BYTES = 20 * 1024 * 1024;
export type BackgroundKind = 'landscape' | 'portrait';
export type BackgroundAsset = { body: Blob; mediaType: string; size: number };
export type BackgroundSnapshot = { landscape: boolean; portrait: boolean };
export type BackgroundSave = { state: 'saved'; snapshot: BackgroundSnapshot } | { state: 'unknown' | 'background_settings_busy' | 'invalid_background' | 'invalid_background_type' | 'background_too_large' };

type Owner = { generation: number; writing: boolean };
const owners = new WeakMap<ChatController, Owner>();
const allowed = ['image/png', 'image/jpeg', 'image/webp', 'image/gif'];
const path = '/api/background-settings';
function signature(type: string, bytes: Uint8Array) {
  const prefix = (...wanted: number[]) => wanted.every((value, i) => bytes[i] === value);
  if (type === 'image/png') return prefix(137,80,78,71,13,10,26,10);
  if (type === 'image/jpeg') return prefix(255,216,255);
  if (type === 'image/gif') return prefix(71,73,70,56,55,97) || prefix(71,73,70,56,57,97);
  if (type === 'image/webp') return prefix(82,73,70,70) && bytes.length >= 12 && bytes[8] === 87 && bytes[9] === 69 && bytes[10] === 66 && bytes[11] === 80;
  return false;
}
async function parse(response: Response, current: () => boolean): Promise<unknown> {
  if (response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('invalid_background_settings');
  const bytes = await readBoundedBody(response, 64 * 1024, current, 'invalid_background_settings');
  try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; } catch { throw new Error('invalid_background_settings'); }
}
function snapshot(value: unknown): BackgroundSnapshot {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('invalid_background_settings');
  const v = value as Record<string, unknown>;
  if (Object.keys(v).sort().join(',') !== 'landscape,portrait' || typeof v.landscape !== 'boolean' || typeof v.portrait !== 'boolean') throw new Error('invalid_background_settings');
  return { landscape: v.landscape, portrait: v.portrait };
}
function errorCode(value: unknown): string | null {
  if (!value || typeof value !== 'object' || !('error' in value)) return null;
  const error = value.error;
  return error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : null;
}

/** Construct while online; the instance and the selected asset remain bound to that scope. */
export class BackgroundSettingsClient {
  private owner: Owner;
  private scope: () => boolean;
  private disposed = false;
  constructor(private controller: ChatController, private transport: ApiTransport, private active: () => boolean = () => true) {
    if (controller.origin !== transport.origin && controller.origin !== `synthetic-seed:${transport.origin}`) throw new Error('origin_mismatch');
    this.scope = controller.onlineScope(); if (!this.scope() || !active()) throw new Error('offline');
    let owner = owners.get(controller); if (!owner) { owner = { generation: 0, writing: false }; owners.set(controller, owner); }
    this.owner = owner;
  }
  current = () => {
    if (!this.scope() || !this.active()) this.disposed = true;
    return !this.disposed;
  };
  dispose() { this.disposed = true; }
  private check() { if (!this.current()) throw new Error('session_changed'); }
  async load(): Promise<BackgroundSnapshot> {
    this.check(); if (this.owner.writing) throw new Error('background_write_pending');
    const generation = ++this.owner.generation;
    try {
      const response = await this.transport.request(path, { cache: 'no-store' }); this.check();
      if (response.status === 401 || response.status === 403) throw new Error('access_denied');
      if ([404, 405, 501].includes(response.status)) throw new Error('background_settings_unsupported');
      if (!response.ok || response.redirected) throw new Error('background_settings_unavailable');
      const result = snapshot(await parse(response, this.current)); this.check();
      if (generation !== this.owner.generation) throw new Error('background_superseded');
      return result;
    } catch (error) { this.check(); if (generation !== this.owner.generation) throw new Error('background_superseded'); throw error; }
  }
  /** The caller retains and releases asset on every outcome, including failure and cancellation. */
  async save(kind: BackgroundKind, asset: BackgroundAsset): Promise<BackgroundSave> {
    this.check(); if (this.owner.writing) throw new Error('background_write_pending');
    if (kind !== 'landscape' && kind !== 'portrait') throw new Error('invalid_background_kind');
    if (!asset || !allowed.includes(asset.mediaType)) throw new Error('invalid_background_type');
    if (!asset.body || typeof asset.body.arrayBuffer !== 'function' || !Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.size !== asset.body.size) throw new Error('invalid_background');
    if (asset.size > MAX_BACKGROUND_BYTES) throw new Error('background_too_large');
    ++this.owner.generation; this.owner.writing = true;
    try {
      let buffer: ArrayBuffer;
      try { buffer = await asset.body.arrayBuffer(); } catch { this.check(); throw new Error('background_read_failed'); }
      this.check();
      const bytes = new Uint8Array(buffer);
      if (bytes.byteLength !== asset.size || !signature(asset.mediaType, bytes)) throw new Error('invalid_background');
      let response: Response;
      try { response = await this.transport.request(`${path}/${kind}`, { method: 'POST', headers: { 'Content-Type': asset.mediaType }, body: buffer }); }
      catch { return { state: 'unknown' }; }
      if (!this.current() || response.redirected) return { state: 'unknown' };
      if (response.ok) {
        try { const value = snapshot(await parse(response, this.current)); if (!this.current() || !value[kind]) return { state: 'unknown' }; return { state: 'saved', snapshot: value }; }
        catch { return { state: 'unknown' }; }
      }
      // Authorization can expire after the server has committed but before it replies.
      if (response.status === 401 || response.status === 403) return { state: 'unknown' };
      let code: string | null;
      try { code = errorCode(await parse(response, this.current)); } catch { return { state: 'unknown' }; }
      if (!this.current()) return { state: 'unknown' };
      if (response.status === 409 && code === 'background_settings_busy') return { state: code };
      if (response.status === 400 && code === 'invalid_background') return { state: code };
      if (response.status === 413 && code === 'background_too_large') return { state: code };
      if (response.status === 415 && code === 'invalid_background_type') return { state: code };
      return { state: 'unknown' };
    } finally { this.owner.writing = false; }
  }
}
