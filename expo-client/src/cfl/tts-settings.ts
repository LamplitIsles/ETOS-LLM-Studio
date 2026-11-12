import type { ChatController } from './chat';
import { readBoundedBody, type ApiTransport } from './transport';

export const TTS_PROVIDERS = ['minimax', 'alibaba', 'bytedance', 'elevenlabs'] as const;
export type TtsProvider = typeof TTS_PROVIDERS[number];
export type TtsKeyProvider = Exclude<TtsProvider, 'minimax'>;
export type TtsSnapshot = { provider: TtsProvider | null; voices: Record<TtsProvider, string>; speeds: Record<'minimax' | 'bytedance', number | null>; configured: Record<TtsKeyProvider, boolean> };
export type TtsSelection = { provider: TtsProvider; voice: string; speed: number | null };
export type TtsVoicePage = { voices: { id: string; name: string }[]; nextCursor: string | null };
export type TtsWriteResult = { state: 'saved'; snapshot: TtsSnapshot } | { state: 'tts_settings_busy' | 'invalid_tts_settings' | 'tts_unsupported' | 'unknown' };
export type TtsKeyResult = { state: 'saved' | 'tts_settings_busy' | 'invalid_tts_key' | 'invalid_tts_settings' | 'tts_unsupported' | 'unknown' };
type Owner = { generation: number; voiceGeneration: number; writing: boolean };
const owners = new WeakMap<ChatController, Owner>();
const settingsPath = '/api/tts/settings', voicePath = '/api/tts/elevenlabs/voices';
const controls = /[\x00-\x1f\x7f]/u;
const validText = (v: unknown, max: number): v is string => typeof v === 'string' && v.length > 0 && v.length <= max && !controls.test(v);
const validVoice = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 512 && v.trim() === v && !controls.test(v);
const validKey = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 512 && v.trim() === v && !/[\x00-\x20\x7f]/u.test(v);
const validCursor = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 2048 && !controls.test(v);
const obj = (value: unknown, keys: string[]): Record<string, unknown> => {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).sort().join(',') !== [...keys].sort().join(',')) throw new Error('invalid_tts_response');
  return value as Record<string, unknown>;
};
function parseSnapshot(raw: unknown): TtsSnapshot {
  const root = obj(raw, ['provider', 'voices', 'speeds', 'configured']);
  const voices = obj(root.voices, [...TTS_PROVIDERS]), speeds = obj(root.speeds, ['minimax', 'bytedance']), configured = obj(root.configured, ['alibaba', 'bytedance', 'elevenlabs']);
  if (root.provider !== null && !TTS_PROVIDERS.includes(root.provider as TtsProvider)) throw new Error('invalid_tts_response');
  if (TTS_PROVIDERS.some(p => voices[p] !== '' && !validVoice(voices[p])) || ['minimax', 'bytedance'].some(p => speeds[p] !== null && (typeof speeds[p] !== 'number' || !Number.isFinite(speeds[p]) || (speeds[p] as number) < 0.5 || (speeds[p] as number) > 2)) || ['alibaba', 'bytedance', 'elevenlabs'].some(p => typeof configured[p] !== 'boolean')) throw new Error('invalid_tts_response');
  return { provider: root.provider as TtsProvider | null, voices: { minimax: voices.minimax as string, alibaba: voices.alibaba as string, bytedance: voices.bytedance as string, elevenlabs: voices.elevenlabs as string }, speeds: { minimax: speeds.minimax as number | null, bytedance: speeds.bytedance as number | null }, configured: { alibaba: configured.alibaba as boolean, bytedance: configured.bytedance as boolean, elevenlabs: configured.elevenlabs as boolean } };
}
function parsePage(raw: unknown): TtsVoicePage {
  const root = obj(raw, ['voices', 'nextCursor']);
  if (!Array.isArray(root.voices) || root.voices.length > 100 || (root.nextCursor !== null && !validCursor(root.nextCursor))) throw new Error('invalid_tts_response');
  const voices = root.voices.map(rawVoice => { const item = obj(rawVoice, ['id', 'name']); if (!validText(item.id, 512) || !validText(item.name, 512)) throw new Error('invalid_tts_response'); return { id: item.id, name: item.name }; });
  return { voices, nextCursor: root.nextCursor as string | null };
}
async function json(response: Response, current: () => boolean, limit: number): Promise<unknown> {
  if (response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('invalid_tts_response');
  const bytes = await readBoundedBody(response, limit, current, 'invalid_tts_response');
  try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; } catch { throw new Error('invalid_tts_response'); }
}
function code(raw: unknown): string | null {
  if (!raw || typeof raw !== 'object' || !('error' in raw)) return null;
  const error = raw.error;
  return error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : null;
}

/** TTS is shared CFL configuration; calls are explicit and never retried. */
export class TtsSettingsClient {
  private owner: Owner;
  private scope: () => boolean;
  private disposed = false;
  constructor(private controller: ChatController, private transport: ApiTransport, private active: () => boolean = () => true) {
    if (controller.origin !== transport.origin && controller.origin !== `synthetic-seed:${transport.origin}`) throw new Error('origin_mismatch');
    this.scope = controller.onlineScope(); if (!this.scope() || !active()) throw new Error('offline');
    let owner = owners.get(controller); if (!owner) { owner = { generation: 0, voiceGeneration: 0, writing: false }; owners.set(controller, owner); }
    this.owner = owner;
  }
  current = () => { if (!this.scope() || !this.active()) this.disposed = true; return !this.disposed; };
  dispose() { this.disposed = true; }
  private check() { if (!this.current()) throw new Error('session_changed'); }
  private async get(path: string, limit: number): Promise<unknown> {
    let response: Response;
    try { response = await this.transport.request(path, { cache: 'no-store' }); } catch { this.check(); throw new Error('tts_unavailable'); }
    this.check();
    if (response.status === 401 || response.status === 403) throw new Error('access_denied');
    if ([404, 405, 501].includes(response.status)) throw new Error('tts_unsupported');
    if (response.status === 400 && path.startsWith(voicePath)) {
      try { if (code(await json(response, this.current, 64 * 1024)) === 'tts_key_required') throw new Error('tts_key_required'); } catch (error) { if (error instanceof Error && error.message === 'tts_key_required') throw error; }
    }
    if (!response.ok || response.redirected) throw new Error('tts_unavailable');
    const value = await json(response, this.current, limit); this.check(); return value;
  }
  async load(): Promise<TtsSnapshot> {
    this.check(); if (this.owner.writing) throw new Error('tts_write_pending');
    const generation = ++this.owner.generation;
    try { const value = parseSnapshot(await this.get(settingsPath, 64 * 1024)); this.check(); if (generation !== this.owner.generation) throw new Error('tts_superseded'); return value; }
    catch (error) { this.check(); if (generation !== this.owner.generation) throw new Error('tts_superseded'); if (error instanceof Error && ['access_denied', 'tts_unsupported', 'tts_unavailable', 'invalid_tts_response'].includes(error.message)) throw error; throw new Error('invalid_tts_response'); }
  }
  /** This fetch contacts the configured ElevenLabs account. Never call it automatically. */
  async listElevenLabsVoices(cursor?: string): Promise<TtsVoicePage> {
    this.check(); if (this.owner.writing) throw new Error('tts_write_pending');
    if (cursor !== undefined && !validCursor(cursor)) throw new Error('invalid_tts_cursor');
    let path = voicePath;
    try { if (cursor !== undefined) path += `?cursor=${encodeURIComponent(cursor)}`; } catch { throw new Error('invalid_tts_cursor'); }
    const generation = ++this.owner.voiceGeneration;
    try { const value = parsePage(await this.get(path, 512 * 1024)); this.check(); if (generation !== this.owner.voiceGeneration) throw new Error('tts_superseded'); return value; }
    catch (error) { this.check(); if (generation !== this.owner.voiceGeneration) throw new Error('tts_superseded'); if (error instanceof Error && ['access_denied', 'tts_unsupported', 'tts_unavailable', 'tts_key_required', 'invalid_tts_response'].includes(error.message)) throw error; throw new Error('invalid_tts_response'); }
  }
  private async write(path: string, body: string, expected: 'selection' | 'key', keyProvider?: TtsKeyProvider): Promise<TtsWriteResult | TtsKeyResult> {
    this.check(); if (this.owner.writing) throw new Error('tts_write_pending');
    this.owner.generation++; this.owner.voiceGeneration++; this.owner.writing = true;
    try {
      let response: Response;
      try { response = await this.transport.request(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body }); } catch { return { state: 'unknown' }; }
      if (!this.current() || response.redirected || response.status === 401 || response.status === 403) return { state: 'unknown' };
      let value: unknown;
      try { value = await json(response, this.current, 64 * 1024); } catch { return { state: 'unknown' }; }
      if (!this.current()) return { state: 'unknown' };
      if (response.ok) {
        try { const snapshot = parseSnapshot(value); return expected === 'key' ? { state: keyProvider && snapshot.configured[keyProvider] ? 'saved' : 'unknown' } : { state: 'saved', snapshot }; }
        catch { return { state: 'unknown' }; }
      }
      const c = code(value);
      if (expected === 'key' && response.status === 404 && c === 'tts_unsupported') return { state: 'tts_unsupported' };
      if (response.status === 405 && c === 'method_not_allowed') return { state: 'tts_unsupported' };
      if (response.status === 409 && c === 'tts_settings_busy') return { state: 'tts_settings_busy' };
      if (response.status === 400 && expected === 'key' && c === 'invalid_tts_key') return { state: 'invalid_tts_key' };
      if (response.status === 400 && c === 'invalid_tts_settings') return { state: 'invalid_tts_settings' };
      return { state: 'unknown' };
    } finally { this.owner.writing = false; }
  }
  async save(selection: TtsSelection): Promise<TtsWriteResult> {
    this.check();
    if (!selection || Object.keys(selection).sort().join(',') !== 'provider,speed,voice' || !TTS_PROVIDERS.includes(selection.provider) || typeof selection.voice !== 'string') throw new Error('invalid_tts_settings');
    const voice = selection.voice.trim(), speed = selection.speed;
    if (!validVoice(voice) || (speed !== null && (typeof speed !== 'number' || !Number.isFinite(speed) || speed < 0.5 || speed > 2)) || ((selection.provider === 'alibaba' || selection.provider === 'elevenlabs') && speed !== null)) throw new Error('invalid_tts_settings');
    const result = await this.write(settingsPath, JSON.stringify({ provider: selection.provider, voice, speed }), 'selection');
    if (result.state === 'saved' && 'snapshot' in result) {
      const value = result.snapshot;
      if (value.provider !== selection.provider || value.voices[selection.provider] !== voice || ((selection.provider === 'minimax' || selection.provider === 'bytedance') && value.speeds[selection.provider] !== speed)) return { state: 'unknown' };
    }
    return result as TtsWriteResult;
  }
  async setKey(provider: TtsKeyProvider, apiKey: string): Promise<TtsKeyResult> {
    this.check();
    if (!['alibaba', 'bytedance', 'elevenlabs'].includes(provider) || !validKey(apiKey)) throw new Error('invalid_tts_key');
    return await this.write(`${settingsPath}/key`, JSON.stringify({ provider, apiKey }), 'key', provider) as TtsKeyResult;
  }
}
