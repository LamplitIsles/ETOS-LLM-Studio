import { isWorkspaceImageGet } from './workspace-image-query.js';

// Exact synthetic-only routes; query keys and mutations remain tightly scoped.
export function isSeedApiRequest(method, value) {
  if (typeof value !== 'string' || !value.startsWith('/') || value.includes('#')) return false;
  const [path, query, ...extra] = value.split('?');
  if (extra.length) return false;
  const id = '[A-Za-z0-9_-]{1,100}', op = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
  if (method === 'GET') {
    if (isWorkspaceImageGet(value)) return true;
    if (query === undefined && (['/api/auth/status', '/api/chat/appearance', '/api/chat/models', '/api/background-settings', '/api/tts/settings', '/api/avatars/companion', '/api/backgrounds/landscape', '/api/backgrounds/portrait'].includes(path) ||
      new RegExp(`^/api/chat/media/${id}/(?:preview|original)$`).test(path) || new RegExp(`^/api/chat/files/${id}$`).test(path) || /^\/api\/stickers\/media\/[a-f0-9]{64}\/(?:thumbnail|original)$/.test(path))) return true;
    if (!/^\/api\/stickers\/(?:packs(?:\/[A-Za-z0-9_-]{1,100})?|favorites|search)$/.test(path) || query === undefined) return false;
    const params = new URLSearchParams(query), keys = [...params.keys()];
    return keys.every((key, i) => ['sessionId', 'limit', 'cursor', 'query'].includes(key) && keys.indexOf(key) === i) && params.has('sessionId') && params.has('limit');
  }
  if (query !== undefined) return false;
  if (method === 'POST') return ['/api/tts/settings', '/api/background-settings/landscape', '/api/background-settings/portrait', '/api/chat/models', '/api/chat/images', '/api/chat/file-operations', '/api/stickers/stage', '/api/stickers/favorites', '/api/stickers/favorites/image'].includes(path) || new RegExp(`^/api/chat/file-operations/${op}/complete$`).test(path);
  return method === 'PUT' && new RegExp(`^/api/chat/file-operations/${op}/files/${id}$`).test(path);
}
export function isSeedMediaGet(path) { return isSeedApiRequest('GET', path) && path !== '/api/auth/status'; }

// ONLY for the isolated fixture proxy; never enable on the fixed 3090 seed.
export function isTestTtsFixtureRequest(method, value) {
  if (method === 'POST') return value === '/api/tts/settings/key';
  if (method !== 'GET' || typeof value !== 'string') return false;
  if (value === '/api/tts/elevenlabs/voices') return true;
  const prefix = '/api/tts/elevenlabs/voices?cursor=';
  if (!value.startsWith(prefix)) return false;
  const encoded = value.slice(prefix.length);
  try { const cursor = decodeURIComponent(encoded); return cursor.length > 0 && cursor.length <= 2048 && !/[\x00-\x1f\x7f]/u.test(cursor) && encodeURIComponent(cursor) === encoded; } catch { return false; }
}
