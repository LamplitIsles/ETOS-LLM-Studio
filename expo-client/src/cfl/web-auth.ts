import { createAuthClient } from 'better-auth/client';
import { passkeyClient } from '@better-auth/passkey/client';

export type WebAuthState = 'setup' | 'signed_out' | 'signed_in';
/** Only the current document origin can own the browser session. */
type PasskeyClient = { signIn: { passkey(): Promise<{ error?: unknown }> }; passkey: { addPasskey(options: { createSession: true }): Promise<{ error?: unknown }> } };
export class WebAuth {
  constructor(private auth: PasskeyClient = createAuthClient({ plugins: [passkeyClient()] }), private fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init), private available: () => boolean = () => window.isSecureContext && !!window.PublicKeyCredential) {}
  async status(): Promise<WebAuthState> {
    const response = await this.fetcher('/api/auth/status', { credentials: 'same-origin', cache: 'no-store', redirect: 'error' });
    if (!response.ok) throw new Error('unavailable');
    const value = await response.json();
    if (value.mode !== 'passkey' || !['setup', 'signed_out', 'signed_in'].includes(value.state)) throw new Error('invalid_status');
    return value.state;
  }
  async signIn(): Promise<void> {
    if (!this.available()) throw new Error('passkey_unavailable');
    const result = await this.auth.signIn.passkey();
    if (result.error) throw new Error('authentication_failed');
    if (await this.status() !== 'signed_in') throw new Error('authentication_failed');
  }
  async pair(code: string): Promise<void> {
    if (!this.available()) throw new Error('passkey_unavailable');
    const response = await this.fetcher('/api/auth/pairing', { method: 'POST', credentials: 'same-origin', redirect: 'error', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code }) });
    if (!response.ok) throw new Error('pairing_failed');
    const result = await this.auth.passkey.addPasskey({ createSession: true });
    if (result.error || await this.status() !== 'signed_in') throw new Error('authentication_failed');
  }
  async signOut(): Promise<void> {
    const response = await this.fetcher('/api/auth/sign-out', { method: 'POST', credentials: 'same-origin', redirect: 'error', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    if (!response.ok) throw new Error('unavailable');
  }
}
