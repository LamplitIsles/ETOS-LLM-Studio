import type { ImageData } from './transport';

export type StickerOpacity = 'opaque' | 'transparent' | 'unknown';
export type StaticSticker = { width: number; height: number; contentType: 'image/png' | 'image/jpeg' | 'image/webp' };
type Decoder = (image: ImageData, info: StaticSticker) => Promise<StickerOpacity>;
const MAX_BYTES = 8_000_000;
const MAX_DIMENSION = 4096;
const MAX_PIXELS = 4_000_000;
const MAX_WAITING = 8;
const MAX_WAITING_BYTES = 16_000_000;

const u32be = (b: Uint8Array, i: number) => (b[i] * 0x1000000 + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3]) >>> 0;
const u32le = (b: Uint8Array, i: number) => (b[i] + (b[i + 1] << 8) + (b[i + 2] << 16) + b[i + 3] * 0x1000000) >>> 0;
const u24le = (b: Uint8Array, i: number) => b[i] + (b[i + 1] << 8) + (b[i + 2] << 16);
const tag = (b: Uint8Array, i: number) => String.fromCharCode(...b.subarray(i, i + 4));
function dimensions(width: number, height: number, contentType: StaticSticker['contentType']): StaticSticker | null {
  return width > 0 && height > 0 && width <= MAX_DIMENSION && height <= MAX_DIMENSION && width * height <= MAX_PIXELS ? { width, height, contentType } : null;
}

/** Strictly bound and identify static formats before any platform image decode. */
export function inspectStaticSticker(image: ImageData): StaticSticker | null {
  const b = image.bytes;
  if (!(b instanceof Uint8Array) || !b.length || b.length > MAX_BYTES || (typeof SharedArrayBuffer !== 'undefined' && b.buffer instanceof SharedArrayBuffer)) return null;
  if (image.contentType === 'image/png') {
    if (b.length < 45 || ![137,80,78,71,13,10,26,10].every((v, i) => b[i] === v)) return null;
    let pos = 8, width = 0, height = 0, ihdr = false, data = false;
    while (pos + 12 <= b.length) {
      const size = u32be(b, pos), name = tag(b, pos + 4), end = pos + 12 + size;
      if (end > b.length) return null;
      if (!ihdr) {
        // Canvas and the native RGBA8 buffer may round a 16-bit alpha such as
        // 65534/65535 to 255. Never classify that image as opaque.
        if (name !== 'IHDR' || size !== 13 || b[pos + 16] === 16) return null;
        ihdr = true; width = u32be(b, pos + 8); height = u32be(b, pos + 12);
      }
      else if (name === 'IHDR') return null;
      if (name === 'acTL' || name === 'fcTL' || name === 'fdAT') return null;
      if (name === 'IDAT') data = true;
      if (name === 'IEND') return size === 0 && data && end === b.length ? dimensions(width, height, 'image/png') : null;
      pos = end;
    }
    return null;
  }
  if (image.contentType === 'image/jpeg') {
    if (b.length < 12 || b[0] !== 0xff || b[1] !== 0xd8 || b[b.length - 2] !== 0xff || b[b.length - 1] !== 0xd9) return null;
    let pos = 2, found: StaticSticker | null = null;
    while (pos < b.length - 2) {
      if (b[pos++] !== 0xff) return null;
      while (pos < b.length && b[pos] === 0xff) pos++;
      const marker = b[pos++];
      if (marker === 0xda) return found;
      if (marker === 0x00 || marker === 0xd8 || marker === 0xd9 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7) || pos + 2 > b.length) return null;
      const size = b[pos] * 256 + b[pos + 1];
      if (size < 2 || pos + size > b.length) return null;
      if ((marker >= 0xc0 && marker <= 0xcf) && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
        if (found || size < 8) return null;
        found = dimensions(b[pos + 5] * 256 + b[pos + 6], b[pos + 3] * 256 + b[pos + 4], 'image/jpeg');
        if (!found) return null;
      }
      pos += size;
    }
    return null;
  }
  if (image.contentType === 'image/webp') {
    if (b.length < 20 || tag(b, 0) !== 'RIFF' || tag(b, 8) !== 'WEBP' || u32le(b, 4) + 8 !== b.length) return null;
    let pos = 12, canvas: StaticSticker | null = null, actual: StaticSticker | null = null, extended = false;
    while (pos + 8 <= b.length) {
      const name = tag(b, pos), size = u32le(b, pos + 4), start = pos + 8, end = start + size;
      if (end + (size & 1) > b.length) return null;
      if (name === 'ANIM' || name === 'ANMF') return null;
      if (name === 'VP8X') {
        if (extended || pos !== 12 || size !== 10 || (b[start] & 0xc3) !== 0 || b[start + 1] || b[start + 2] || b[start + 3]) return null;
        extended = true; canvas = dimensions(u24le(b, start + 4) + 1, u24le(b, start + 7) + 1, 'image/webp');
        if (!canvas) return null;
      }
      if (name === 'VP8 ' || name === 'VP8L') {
        if (actual) return null;
        if (name === 'VP8 ') {
          if (size < 10 || b[start + 3] !== 0x9d || b[start + 4] !== 0x01 || b[start + 5] !== 0x2a) return null;
          actual = dimensions((b[start + 6] | b[start + 7] << 8) & 0x3fff, (b[start + 8] | b[start + 9] << 8) & 0x3fff, 'image/webp');
        } else {
          if (size < 5 || b[start] !== 0x2f || (b[start + 4] & 0xe0)) return null;
          const bits = u32le(b, start + 1);
          actual = dimensions((bits & 0x3fff) + 1, ((bits >>> 14) & 0x3fff) + 1, 'image/webp');
        }
        if (!actual) return null;
      }
      pos = end + (size & 1);
    }
    if (pos !== b.length || !actual || (canvas && (canvas.width !== actual.width || canvas.height !== actual.height))) return null;
    return actual;
  }
  // GIF and all other formats are conservative until all frames are supported.
  return null;
}

type Job = { run(): Promise<void>; cancel(): void; bytes: number; signal?: AbortSignal; listener?: () => void };
const waiting: Job[] = [];
let busy = false;
let waitingBytes = 0;
function pump() {
  if (busy) return;
  const job = waiting.shift(); if (!job) return;
  waitingBytes -= job.bytes;
  if (job.listener) job.signal?.removeEventListener('abort', job.listener);
  busy = true;
  void job.run().finally(() => { busy = false; pump(); });
}

/** Consumes no ownership of image bytes. Never starts a network request. */
export function classifyStickerOpacityCore(image: ImageData, current: () => boolean, signal: AbortSignal | undefined, decode: Decoder): Promise<StickerOpacity> {
  const valid = () => { try { return !signal?.aborted && current(); } catch { return false; } };
  if (!valid()) return Promise.resolve('unknown');
  const info = inspectStaticSticker(image);
  if (!info || waiting.length >= MAX_WAITING || (busy && waitingBytes + image.bytes.byteLength > MAX_WAITING_BYTES)) return Promise.resolve('unknown');
  // Freeze the inspected input across queued/native work without retaining caller-owned bytes.
  const snapshot: ImageData = { bytes: new Uint8Array(image.bytes), contentType: image.contentType };
  return new Promise(resolve => {
    const job: Job = { bytes: snapshot.bytes.byteLength, signal, cancel() { const index = waiting.indexOf(job); if (index >= 0) { waiting.splice(index, 1); waitingBytes -= job.bytes; } if (job.listener) signal?.removeEventListener('abort', job.listener); resolve('unknown'); },
      async run() {
        if (!valid()) { resolve('unknown'); return; }
        try { const result = await decode(snapshot, info); resolve(valid() && (result === 'opaque' || result === 'transparent') ? result : 'unknown'); }
        catch { resolve('unknown'); }
      } };
    job.listener = () => job.cancel();
    signal?.addEventListener('abort', job.listener, { once: true });
    waiting.push(job); waitingBytes += job.bytes;
    if (signal?.aborted) job.cancel(); else pump();
  });
}
