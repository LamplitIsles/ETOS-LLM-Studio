import { loadImage, type ImageData, type MediaTransport } from './transport';

const MAX_ENTRIES = 48;
const MAX_BYTES = 16_000_000;
const MAX_PENDING = 16;
const MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;
type Waiter = { active: () => boolean; signal?: AbortSignal; resolve(value: ImageData): void; reject(error: Error): void; abort(): void };
type Pending = { key: string; media: MediaTransport; id: string; variant: 'preview' | 'original'; running: boolean; abort: AbortController; scope: () => boolean; waiters: Set<Waiter> };
type Cached = { image: ImageData; expires: number };
const aborted = () => Object.assign(new Error('aborted'), { name: 'AbortError' });
const copy = (image: ImageData): ImageData => ({ contentType: image.contentType, bytes: image.bytes.slice() });

/** Owned by one ChatController. A transport object and its origin are part of the key. */
export class ImageSessionCache {
  private transports = new WeakMap<MediaTransport, number>();
  private nextTransport = 0;
  private cache = new Map<string, Cached>();
  private pending = new Map<string, Pending>();
  private bytes = 0;
  private running = 0;
  private generation = 0;
  private key(media: MediaTransport, id: string, variant: string) {
    let transportId = this.transports.get(media);
    if (transportId === undefined) { transportId = ++this.nextTransport; this.transports.set(media, transportId); }
    return JSON.stringify([transportId, media.origin, id, variant]);
  }
  private forget(key: string) { const item = this.cache.get(key); if (item) { this.bytes -= item.image.bytes.byteLength; this.cache.delete(key); } }
  private removeWaiter(pending: Pending, waiter: Waiter) {
    pending.waiters.delete(waiter); waiter.signal?.removeEventListener('abort', waiter.abort);
    if (!pending.waiters.size && this.pending.get(pending.key) === pending) { this.pending.delete(pending.key); pending.abort.abort(); this.pump(); }
  }
  clear(error = new Error('session_changed'), except?: Pending) {
    this.generation++; this.cache.clear(); this.bytes = 0;
    for (const pending of [...this.pending.values()]) {
      if (pending === except) continue;
      this.pending.delete(pending.key); pending.abort.abort();
      for (const waiter of [...pending.waiters]) { this.removeWaiter(pending, waiter); waiter.reject(error); }
    }
  }
  private pump() {
    for (const pending of this.pending.values()) {
      if (this.running >= MAX_PENDING) break;
      if (pending.running || !pending.waiters.size) continue;
      for (const waiter of [...pending.waiters]) {
        if (!pending.scope() || !waiter.active() || waiter.signal?.aborted) {
          pending.waiters.delete(waiter); waiter.signal?.removeEventListener('abort', waiter.abort);
          waiter.reject(waiter.signal?.aborted ? aborted() : new Error('session_changed'));
        }
      }
      if (!pending.waiters.size) { this.pending.delete(pending.key); continue; }
      pending.running = true; this.running++;
      void loadImage(pending.media, pending.id, () => pending.scope() && !pending.abort.signal.aborted, pending.variant, pending.abort.signal).then(image => {
        if (this.pending.get(pending.key) !== pending) return;
        this.pending.delete(pending.key);
        const interested = [...pending.waiters].filter(waiter => waiter.active() && !waiter.signal?.aborted && pending.scope());
        if (interested.length && image.bytes.byteLength <= MAX_BYTES) {
          this.cache.set(pending.key, { image: copy(image), expires: Date.now() + MAX_AGE_MS }); this.bytes += image.bytes.byteLength;
          while (this.cache.size > MAX_ENTRIES || this.bytes > MAX_BYTES) this.forget(this.cache.keys().next().value!);
        }
        for (const waiter of [...pending.waiters]) {
          this.removeWaiter(pending, waiter);
          if (waiter.signal?.aborted) waiter.reject(aborted());
          else if (!pending.scope() || !waiter.active()) waiter.reject(new Error('session_changed'));
          else waiter.resolve(copy(image));
        }
      }, error => {
        if (this.pending.get(pending.key) !== pending) return;
        this.pending.delete(pending.key);
        if (error instanceof Error && error.message === 'access_denied') this.clear(new Error('access_denied'), pending);
        for (const waiter of [...pending.waiters]) {
          this.removeWaiter(pending, waiter);
          waiter.reject(!pending.scope() || !waiter.active() ? new Error('session_changed') : error);
        }
      }).finally(() => { this.running--; this.pump(); });
    }
  }
  read(media: MediaTransport, id: string, variant: 'preview' | 'original', scope: () => boolean, active: () => boolean, signal?: AbortSignal): Promise<ImageData> {
    if (!scope() || !active()) return Promise.reject(new Error('session_changed'));
    if (signal?.aborted) return Promise.reject(aborted());
    if (!/^[A-Za-z0-9_-]{1,100}$/.test(id) || (variant !== 'preview' && variant !== 'original')) return Promise.reject(new Error('invalid_media'));
    const key = this.key(media, id, variant), item = this.cache.get(key);
    if (item && item.expires <= Date.now()) this.forget(key);
    else if (item) {
      const generation = this.generation;
      this.cache.delete(key); this.cache.set(key, item);
      return Promise.resolve().then(() => { if (signal?.aborted) throw aborted(); if (generation !== this.generation || !scope() || !active()) throw new Error('session_changed'); return copy(item.image); });
    }
    let pending = this.pending.get(key);
    if (!pending) {
      pending = { key, media, id, variant, running: false, abort: new AbortController(), scope, waiters: new Set() };
      this.pending.set(key, pending);
    }
    const task = pending;
    return new Promise((resolve, reject) => {
      const waiter: Waiter = { active, signal, resolve, reject, abort: () => { this.removeWaiter(task, waiter); reject(aborted()); } };
      task.waiters.add(waiter); signal?.addEventListener('abort', waiter.abort, { once: true });
      if (signal?.aborted) waiter.abort(); else this.pump();
    });
  }
}
