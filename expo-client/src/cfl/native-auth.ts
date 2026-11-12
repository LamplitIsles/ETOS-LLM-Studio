/** CFL public-client authorization. All side effects are injected for isolated tests. */
export const CALLBACK = 'etosllmstudio://auth/callback';
export type Grant = { accessToken: string; refreshToken: string; expiresAt: number; pending: boolean };
export interface GrantStore {
  load(origin: string): Promise<Grant | null>;
  save(origin: string, grant: Grant): Promise<void>;
  remove(origin: string): Promise<void>;
}
export interface AuthDependencies {
  store: GrantStore;
  random(): Promise<string>;
  challenge(verifier: string): Promise<string>;
  browser(url: string): Promise<string | null>;
  fetch: typeof fetch;
  now(): number;
}
export class AuthError extends Error {
  constructor(readonly code: 'invalid_origin' | 'invalid_callback' | 'cancelled' | 'authorization_required' | 'unavailable' | 'superseded') { super(code); }
}
export function httpsOrigin(value: string): string {
  let u: URL;
  const raw = value.trim();
  if (!/^https:\/\/[^\s\\/?#]+\/?$/i.test(raw)) throw new AuthError('invalid_origin');
  try { u = new URL(raw); } catch { throw new AuthError('invalid_origin'); }
  if (u.protocol !== 'https:' || u.username || u.password || u.search || u.hash || (u.pathname !== '/' && u.pathname !== '')) throw new AuthError('invalid_origin');
  return u.origin;
}
export class NativeAuth {
  private origin: string | null = null;
  private generation = 0;
  private refresh: Promise<string> | null = null;
  private writes: Promise<void> = Promise.resolve();
  private write(action: () => Promise<void>): Promise<void> {
    const next = this.writes.then(action);
    this.writes = next.catch(() => {});
    return next;
  }
  private save(origin: string, generation: number, value: Grant): Promise<void> {
    return this.write(async () => { this.current(generation, origin); await this.d.store.save(origin, value); });
  }
  constructor(private readonly d: AuthDependencies) {}
  select(origin: string) { this.origin = httpsOrigin(origin); this.generation++; this.refresh = null; }
  private current(generation: number, origin: string) {
    if (generation !== this.generation || origin !== this.origin) throw new AuthError('superseded');
  }
  async signIn(): Promise<void> {
    const origin = this.origin; if (!origin) throw new AuthError('invalid_origin');
    const generation = ++this.generation; this.refresh = null;
    const state = await this.d.random(), verifier = await this.d.random();
    const challenge = await this.d.challenge(verifier); this.current(generation, origin);
    const url = new URL('/api/auth/oauth2/authorize', origin);
    const params = { client_id: 'etos', redirect_uri: CALLBACK, response_type: 'code', scope: 'cfl offline_access', resource: origin, state, code_challenge_method: 'S256', code_challenge: challenge };
    Object.entries(params).forEach(([key, value]) => url.searchParams.set(key, value));
    const callback = await this.d.browser(url.toString()); this.current(generation, origin);
    if (callback === null) throw new AuthError('cancelled');
    let result: URL;
    try { result = new URL(callback); } catch { throw new AuthError('invalid_callback'); }
    const single = (key: string) => { const v = result.searchParams.getAll(key); return v.length === 1 ? v[0] : null; };
    if (result.protocol !== 'etosllmstudio:' || result.hostname !== 'auth' || result.port || result.username || result.password || result.pathname !== '/callback' || result.hash || single('state') !== state || single('iss') !== `${origin}/api/auth` || result.searchParams.has('error') || !single('code')) throw new AuthError('invalid_callback');
    const previous = await this.d.store.load(origin); this.current(generation, origin);
    if (previous) { await this.save(origin, generation, { ...previous, pending: true }); this.current(generation, origin); }
    const grant = await this.exchange(origin, { grant_type: 'authorization_code', client_id: 'etos', redirect_uri: CALLBACK, code: single('code')!, code_verifier: verifier, resource: origin });
    this.current(generation, origin); await this.save(origin, generation, grant); this.current(generation, origin);
  }
  private async exchange(origin: string, fields: Record<string, string>): Promise<Grant> {
    let response: Response;
    try { response = await this.d.fetch(`${origin}/api/auth/oauth2/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Origin: origin }, body: new URLSearchParams(fields).toString(), redirect: 'error' }); }
    catch { throw new AuthError('unavailable'); }
    if ([400, 401, 403].includes(response.status)) throw new AuthError('authorization_required');
    if (!response.ok || response.redirected || response.url !== `${origin}/api/auth/oauth2/token`) throw new AuthError('unavailable');
    const t = await response.json();
    if (typeof t.access_token !== 'string' || !t.access_token || typeof t.refresh_token !== 'string' || !t.refresh_token || typeof t.expires_in !== 'number' || !Number.isFinite(t.expires_in) || t.expires_in <= 0 || typeof t.token_type !== 'string' || t.token_type.toLowerCase() !== 'bearer') throw new AuthError('unavailable');
    return { accessToken: t.access_token, refreshToken: t.refresh_token, expiresAt: this.d.now() + t.expires_in * 1000, pending: false };
  }
  async tokenFor(expectedOrigin: string, forceRefresh = false): Promise<string> {
    if (this.origin !== expectedOrigin) throw new AuthError('superseded');
    const generation = this.generation;
    const value = await this.token(forceRefresh);
    this.current(generation, expectedOrigin);
    return value;
  }
  async token(forceRefresh = false): Promise<string> {
    const origin = this.origin; if (!origin) throw new AuthError('invalid_origin');
    if (this.refresh) return this.refresh;
    const generation = this.generation;
    const task = (async () => {
      const grant = await this.d.store.load(origin); this.current(generation, origin);
      if (!grant || grant.pending) throw new AuthError('authorization_required');
      if (!forceRefresh && grant.expiresAt > this.d.now() + 30000) return grant.accessToken;
      await this.save(origin, generation, { ...grant, pending: true }); this.current(generation, origin);
      const next = await this.exchange(origin, { grant_type: 'refresh_token', client_id: 'etos', refresh_token: grant.refreshToken, resource: origin });
      this.current(generation, origin); await this.save(origin, generation, next); this.current(generation, origin);
      return next.accessToken;
    })();
    this.refresh = task;
    try { return await task; } finally { if (this.refresh === task) this.refresh = null; }
  }
  async signOut(): Promise<void> {
    const origin = this.origin; ++this.generation; this.refresh = null;
    if (origin) await this.write(() => this.d.store.remove(origin));
  }
}
