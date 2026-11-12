import { fixtureImageBase64 } from './fixture-art';
import type { ApiTransport } from '../../src/cfl/transport';
import { createHash } from 'node:crypto';
import { StickerFavoriteSchema, StickerFavoriteImageSchema, validate, type Sticker, type StickerFavorite, type StickerFavoriteImage } from '../../vendor/contracts/src/index';

// Original synthetic 40px WebP drawing made for this fixture.
const drawing = 'UklGRgwDAABXRUJQVlA4WAoAAAAgAAAAJwAAJwAASUNDUMgBAAAAAAHIAAAAAAQwAABtbnRyUkdCIFhZWiAH4AABAAEAAAAAAABhY3NwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAA9tYAAQAAAADTLQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAlkZXNjAAAA8AAAACRyWFlaAAABFAAAABRnWFlaAAABKAAAABRiWFlaAAABPAAAABR3dHB0AAABUAAAABRyVFJDAAABZAAAAChnVFJDAAABZAAAAChiVFJDAAABZAAAAChjcHJ0AAABjAAAADxtbHVjAAAAAAAAAAEAAAAMZW5VUwAAAAgAAAAcAHMAUgBHAEJYWVogAAAAAAAAb6IAADj1AAADkFhZWiAAAAAAAABimQAAt4UAABjaWFlaIAAAAAAAACSgAAAPhAAAts9YWVogAAAAAAAA9tYAAQAAAADTLXBhcmEAAAAAAAQAAAACZmYAAPKnAAANWQAAE9AAAApbAAAAAAAAAABtbHVjAAAAAAAAAAEAAAAMZW5VUwAAACAAAAAcAEcAbwBvAGcAbABlACAASQBuAGMALgAgADIAMAAxADZWUDggHgEAAHAHAJ0BKigAKAA+XSaNRaOiIR48BAA4BcSygGbhlgnO/QA6MAyEHKFGxkWyabmgDc9AeaLRnee52rdy2pZqFambWg0AAP78d1OEeI9lGlUSmRn+pCpFbaSEgkN60h9n69aW5vcgENOAwM5gm4XnXFqT72mpgJ5IWgcjEr4hQPFGc9roQF49f/4Rvpssy+d3/la/S3KcFtMXvk/N0RdBwqifd0Y0KE22CTOLe8x3X6pzi6hltGjXuS5BQ7BXtTemvZn3WXvGq37Zm7s+RejvD/1QPznhKGiLLGNb7lyG2gc48d7JACE/CNRR6lYs2i8cpTJjWUkESQ2QLAhE3vbssymbZ6RkRmVvvrk8Ahj+8AoXNz8Pd9VcAOSoRMogAAA=';
// Generate bytes locally; fixture never makes network requests.
const bytes = (data: string) => Uint8Array.from(atob(data), c => c.charCodeAt(0));
const version = '0'.repeat(64);
// A 16x16 synthetic RGBA pink circle with fully transparent corners.
export const transparentStickerBase64 = 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAPElEQVR4nGNgGNTgf0DTfxAmWyM6pkgzUYYQ0kzQEIoMIFYzTkMoNmDgw4BYQ/BqJmQIUZqxGUSyRroCAIrMDhCz6+93AAAAAElFTkSuQmCC';
export const fixtureWorkspaceImagePath = 'fixture workspace/透明 %.png';
const sticker: Sticker = { id: 'fixture-sticker', version, name: '小绿', tags: ['微笑'], mediaType: 'image/webp', available: true };
const pack = { id: 'fixture-pack', name: '小绿的日常', description: '合成表情', cover: sticker };
export function createFixtureMedia(): ApiTransport {
  const images = new Map<string, { data: Uint8Array; type: string }>();
  const files = new Map<string, { manifest: any; bodies: Map<string, Blob> }>();
  const downloads = new Map<string, Blob>();
  const stickers = new Map<string, Sticker>([[sticker.id, sticker]]);
  const favorites = new Set([sticker.id]);
  const savedImages = new Map<string, { data: Uint8Array; type: string }>();
  const backgrounds = new Map<string, { data: Uint8Array; type: string }>();
  const backgroundSnapshot = () => ({ landscape: backgrounds.has('landscape'), portrait: backgrounds.has('portrait') });
  let model = 'gpt-6.1-sol', fast = true;
  const tts = { provider: 'minimax' as 'minimax' | 'alibaba' | 'bytedance' | 'elevenlabs', voices: { minimax: 'fixture-voice', alibaba: '', bytedance: '', elevenlabs: '' }, speeds: { minimax: null as number | null, bytedance: null as number | null }, configured: { alibaba: false, bytedance: false, elevenlabs: false } };
  const read = async (path: string): Promise<Response> => {
    if (path === '/api/chat/appearance') return Response.json({ companionName: 'Mica', userName: '', ...(backgrounds.size ? { backgrounds: { landscape: '/api/backgrounds/landscape', portrait: '/api/backgrounds/portrait' } } : {}) });
    if (path === '/api/background-settings') return Response.json(backgroundSnapshot());
    if (path === '/api/backgrounds/landscape' || path === '/api/backgrounds/portrait') {
      const kind = path.endsWith('landscape') ? 'landscape' : 'portrait';
      const image = backgrounds.get(kind) ?? backgrounds.get(kind === 'landscape' ? 'portrait' : 'landscape');
      return image ? new Response(image.data as Uint8Array<ArrayBuffer>, { headers: { 'Content-Type': image.type, 'Cache-Control': 'no-store' } }) : new Response(null, { status: 404 });
    }
    if (path === `/api/chat/workspace-image?path=${encodeURIComponent(fixtureWorkspaceImagePath)}`) return new Response(bytes(fixtureImageBase64), { headers: { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' } });
    if (path === '/api/chat/media/fixture-agent-sticker/original') return new Response(bytes(transparentStickerBase64), { headers: { 'Content-Type': 'image/png' } });
    if (path === '/api/chat/media/fixture-agent-sticker/preview') return new Response(bytes(fixtureImageBase64), { headers: { 'Content-Type': 'image/png' } });
    if (path === '/api/chat/media/fixture-image/preview' || path === '/api/chat/media/fixture-image/original') return new Response(bytes(fixtureImageBase64), { headers: { 'Content-Type': 'image/png' } });
    const image = /^\/api\/chat\/media\/([A-Za-z0-9_-]+)\/(preview|original)$/.exec(path);
    if (image && images.has(image[1])) { const data = images.get(image[1])!; return new Response(data.data as Uint8Array<ArrayBuffer>, { headers: { 'Content-Type': data.type } }); }
    const file = /^\/api\/chat\/files\/([A-Za-z0-9_-]+)$/.exec(path);
    if (file && downloads.has(file[1])) return new Response(downloads.get(file[1])!, { headers: { 'Content-Type': 'application/octet-stream' } });
    if (path === `/api/stickers/media/${version}/thumbnail` || path === `/api/stickers/media/${version}/original`) return new Response(bytes(drawing), { headers: { 'Content-Type': 'image/webp' } });
    const saved = /^\/api\/stickers\/media\/([a-f0-9]{64})\/(thumbnail|original)$/.exec(path);
    if (saved && savedImages.has(saved[1])) {
      const image = savedImages.get(saved[1])!;
      return new Response((saved[2] === 'thumbnail' ? bytes(drawing) : image.data) as Uint8Array<ArrayBuffer>, { headers: { 'Content-Type': saved[2] === 'thumbnail' ? 'image/webp' : image.type } });
    }
    return new Response(null, { status: 404 });
  };
  return { origin: 'fixture://local', read, async request(path, init = {}) {
    const method = init.method ?? 'GET';
    if (path === '/api/tts/settings' && method === 'GET') return Response.json(tts);
    if (path === '/api/tts/settings' && method === 'POST') {
      let input: any; try { input = JSON.parse(String(init.body)); } catch { return Response.json({ error: { code: 'invalid_tts_settings' } }, { status: 400 }); }
      if (!input || Object.keys(input).sort().join(',') !== 'provider,speed,voice' || !['minimax', 'alibaba', 'bytedance', 'elevenlabs'].includes(input.provider) || typeof input.voice !== 'string' || !input.voice.trim() || input.voice.trim().length > 512 || /[\x00-\x1f\x7f]/u.test(input.voice.trim()) || (input.speed !== null && (typeof input.speed !== 'number' || !Number.isFinite(input.speed) || input.speed < 0.5 || input.speed > 2)) || (['alibaba', 'elevenlabs'].includes(input.provider) && input.speed !== null)) return Response.json({ error: { code: 'invalid_tts_settings' } }, { status: 400 });
      tts.provider = input.provider; tts.voices[tts.provider] = input.voice.trim();
      if (tts.provider === 'minimax' || tts.provider === 'bytedance') tts.speeds[tts.provider] = input.speed;
      return Response.json(tts);
    }
    if (path === '/api/tts/settings/key' && method === 'POST') {
      let input: any; try { input = JSON.parse(String(init.body)); } catch { return Response.json({ error: { code: 'invalid_tts_key' } }, { status: 400 }); }
      if (!input || Object.keys(input).sort().join(',') !== 'apiKey,provider' || !['alibaba', 'bytedance', 'elevenlabs'].includes(input.provider) || typeof input.apiKey !== 'string' || !/^fixture-[A-Za-z0-9_-]{1,120}$/.test(input.apiKey)) return Response.json({ error: { code: 'invalid_tts_key' } }, { status: 400 });
      // This fixture keeps only a boolean, never the supplied test key.
      tts.configured[input.provider as keyof typeof tts.configured] = true; return Response.json(tts);
    }
    if (method === 'GET' && (path === '/api/tts/elevenlabs/voices' || path.startsWith('/api/tts/elevenlabs/voices?cursor='))) {
      if (!tts.configured.elevenlabs) return Response.json({ error: { code: 'tts_key_required' } }, { status: 400 });
      return path.includes('?') ? Response.json({ voices: [{ id: 'fixture-voice-2', name: '合成声音二' }], nextCursor: null }) : Response.json({ voices: [{ id: 'fixture-voice-1', name: '合成声音一' }], nextCursor: 'fixture-next' });
    }
    if (method === 'POST' && (path === '/api/background-settings/landscape' || path === '/api/background-settings/portrait')) {
      const type = new Headers(init.headers).get('content-type') ?? '';
      if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(type)) return Response.json({ error: { code: 'invalid_background_type' } }, { status: 415 });
      const data = new Uint8Array(await new Response(init.body).arrayBuffer());
      if (!data.length || data.length > 20 * 1024 * 1024) return Response.json({ error: { code: 'invalid_background' } }, { status: 400 });
      backgrounds.set(path.endsWith('landscape') ? 'landscape' : 'portrait', { data, type });
      return Response.json(backgroundSnapshot());
    }
    if (path === '/api/chat/models' && method === 'GET') return Response.json({ sessionId: 'fixture-session', currentModel: model, fast, busy: false });
    if (path === '/api/chat/models' && method === 'POST') {
      let input: any; try { input = JSON.parse(String(init.body)); } catch { return Response.json({ error: { code: 'invalid_request' } }, { status: 400 }); }
      if (!input || Object.keys(input).sort().join(',') !== 'expectedFast,expectedModel,fast,model,sessionId' || typeof input.fast !== 'boolean' || typeof input.expectedFast !== 'boolean' || typeof input.model !== 'string' || typeof input.expectedModel !== 'string' || typeof input.sessionId !== 'string') return Response.json({ error: { code: 'invalid_request' } }, { status: 400 });
      if (!['gpt-6.1-sol', 'gpt-5.6-sol', 'gpt-6.1-terra'].includes(input.model)) return Response.json({ error: { code: 'invalid_model' } }, { status: 400 });
      if (input.sessionId !== 'fixture-session' || input.expectedModel !== model || input.expectedFast !== fast) return Response.json({ error: { code: 'stale_model' } }, { status: 409 });
      model = input.model; fast = input.fast;
      return Response.json({ sessionId: 'fixture-session', currentModel: model, fast, busy: false });
    }
    if (method === 'GET' && path.startsWith('/api/stickers/') && path.includes('?')) {
      const url = new URL(path, 'https://fixture.invalid'); if (url.searchParams.get('sessionId') !== 'fixture-session') return new Response(null, { status: 403 });
      const limit = Number(url.searchParams.get('limit'));
      const encodedCursor = url.searchParams.get('cursor');
      const decodedCursor = encodedCursor ? Buffer.from(encodedCursor, 'base64url').toString('utf8') : '0';
      const offset = Number(decodedCursor);
      if (!Number.isInteger(limit) || limit < 1 || limit > 30 || !/^\d+$/.test(decodedCursor) || !Number.isSafeInteger(offset)) return new Response(null, { status: 400 });
      const pagination = <T>(items: T[]) => ({ items: items.slice(offset, offset + limit), nextCursor: offset + limit < items.length ? Buffer.from(String(offset + limit)).toString('base64url') : null });
      if (url.pathname === '/api/stickers/packs') { const page = pagination([pack]); return Response.json({ packs: page.items, nextCursor: page.nextCursor }); }
      if (['/api/stickers/packs/fixture-pack', '/api/stickers/favorites', '/api/stickers/search'].includes(url.pathname)) {
        const items = url.pathname === '/api/stickers/favorites' ? [...favorites].map(id => stickers.get(id)!) : url.pathname === '/api/stickers/search' ? [...stickers.values()] : [sticker];
        const page = pagination(items.filter(item => !url.searchParams.get('query') || item.name.includes(url.searchParams.get('query')!)));
        return Response.json({ stickers: page.items, nextCursor: page.nextCursor });
      }
    }
    if (method === 'GET') return read(path);
    if (method === 'POST' && path === '/api/stickers/favorites') {
      let input: StickerFavorite;
      try { input = validate(StickerFavoriteSchema, JSON.parse(String(init.body))); } catch { return new Response(null, { status: 400 }); }
      if (input.sessionId !== 'fixture-session') return new Response(null, { status: 403 });
      const item = stickers.get(input.stickerId); if (!item) return new Response(null, { status: 404 });
      if (input.favorite) favorites.add(item.id); else favorites.delete(item.id);
      return Response.json({ sticker: item, favorite: input.favorite });
    }
    if (method === 'POST' && path === '/api/stickers/favorites/image') {
      let input: StickerFavoriteImage;
      try { input = validate(StickerFavoriteImageSchema, JSON.parse(String(init.body))); } catch { return new Response(null, { status: 400 }); }
      if (input.sessionId !== 'fixture-session') return new Response(null, { status: 403 });
      const source = input.imageId === 'fixture-image' ? { data: bytes(fixtureImageBase64), type: 'image/png' } : images.get(input.imageId);
      if (!source) return new Response(null, { status: 404 });
      const hash = createHash('sha256').update(input.imageId).digest('hex');
      const item: Sticker = { id: `image-${hash}`, version: hash, name: input.name, tags: input.tags, mediaType: source.type as Sticker['mediaType'], available: true };
      stickers.set(item.id, item); favorites.add(item.id); savedImages.set(hash, source);
      return Response.json({ sticker: item, favorite: true });
    }
    if (method === 'POST' && path === '/api/stickers/stage') {
      const input = JSON.parse(String(init.body)); if (input.sessionId !== 'fixture-session' || input.sticker.id !== sticker.id || input.sticker.version !== version) return new Response(null, { status: 400 });
      const attachmentId = `sticker-${input.operationId}`; images.set(attachmentId, { data: bytes(drawing), type: sticker.mediaType });
      return Response.json({ sessionId: input.sessionId, operationId: input.operationId, image: { attachmentId, name: sticker.name, mediaType: sticker.mediaType, availability: 'available', sticker: { id: sticker.id, version } } });
    }
    if (method === 'POST' && path === '/api/chat/images') {
      const input = JSON.parse(String(init.body)); if (input.sessionId !== 'fixture-session') return new Response(null, { status: 403 });
      return Response.json({ sessionId: input.sessionId, operationId: input.operationId, images: input.images.map((image: any) => {
        const attachmentId = `image-${image.id}`; images.set(attachmentId, { data: bytes(image.original), type: image.mediaType });
        return { id: image.id, order: image.order, ref: { attachmentId, mediaType: image.mediaType, name: image.name, availability: 'available' } };
      }) });
    }
    if (method === 'POST' && path === '/api/chat/file-operations') {
      const manifest = JSON.parse(String(init.body)); if (manifest.sessionId !== 'fixture-session' || files.has(manifest.operationId)) return new Response(null, { status: 409 });
      files.set(manifest.operationId, { manifest, bodies: new Map() }); return Response.json({ manifest, uploaded: [] });
    }
    const file = /^\/api\/chat\/file-operations\/([0-9a-fA-F-]{36})\/files\/([A-Za-z0-9_-]+)$/.exec(path);
    if (method === 'PUT' && file && files.has(file[1])) { files.get(file[1])!.bodies.set(file[2], init.body as Blob); return new Response(null, { status: 204 }); }
    const complete = /^\/api\/chat\/file-operations\/([0-9a-fA-F-]{36})\/complete$/.exec(path);
    if (method === 'POST' && complete && files.has(complete[1])) {
      const entry = files.get(complete[1])!; if (entry.manifest.files.some((f: any) => entry.bodies.get(f.id)?.size !== f.size)) return new Response(null, { status: 400 });
      for (const item of entry.manifest.files) downloads.set(`file-${item.id}`, entry.bodies.get(item.id)!);
      return Response.json({ sessionId: entry.manifest.sessionId, operationId: entry.manifest.operationId, files: entry.manifest.files.map((f: any, order: number) => ({ id: f.id, order, ref: { attachmentId: `file-${f.id}`, name: f.name, mediaType: f.mediaType, size: f.size, availability: 'available' } })) });
    }
    return new Response(null, { status: 404 });
  } };
}
