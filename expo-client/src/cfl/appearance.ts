import { APPEARANCE_PATH, validateChatAppearance } from '../../vendor/contracts/src/appearance';
import { readBoundedBody, type ImageData, type MediaTransport } from './transport';

export type Appearance = { companionName: string; userName: string; companionAvatar: boolean; backgrounds: boolean };
export type AppearanceImage = 'companionAvatar' | 'landscape' | 'portrait';
const paths: Record<AppearanceImage, string> = {
  companionAvatar: '/api/avatars/companion',
  landscape: '/api/backgrounds/landscape',
  portrait: '/api/backgrounds/portrait',
};

async function request(transport: MediaTransport, path: string, isCurrent: () => boolean): Promise<Response | null> {
  if (!isCurrent()) throw new Error('session_changed');
  let response: Response;
  try { response = await transport.read(path); }
  catch (error) { if (!isCurrent()) throw new Error('session_changed'); throw error; }
  if (!isCurrent()) { await response.body?.cancel().catch(() => {}); throw new Error('session_changed'); }
  if (response.redirected) throw new Error('unavailable');
  if (response.status === 404) return null;
  if (response.status === 401 || response.status === 403) throw new Error('access_denied');
  if (!response.ok) throw new Error('unavailable');
  return response;
}

/** Call with a fresh controller.scope() after the chat session is established. */
export async function loadAppearance(transport: MediaTransport, isCurrent: () => boolean): Promise<Appearance | null> {
  const response = await request(transport, APPEARANCE_PATH, isCurrent);
  if (!response) return null;
  if (response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('invalid_appearance');
  const bytes = await readBoundedBody(response, 64 * 1024, isCurrent, 'invalid_appearance');
  let value: ReturnType<typeof validateChatAppearance>;
  try { value = validateChatAppearance(JSON.parse(new TextDecoder().decode(bytes))); }
  catch { throw new Error('invalid_appearance'); }
  if (!isCurrent()) throw new Error('session_changed');
  if ((value.companionAvatar !== undefined && value.companionAvatar !== paths.companionAvatar) ||
      (value.backgrounds !== undefined && (value.backgrounds.landscape !== paths.landscape || value.backgrounds.portrait !== paths.portrait))) throw new Error('invalid_appearance');
  return { companionName: value.companionName, userName: value.userName, companionAvatar: value.companionAvatar !== undefined, backgrounds: value.backgrounds !== undefined };
}

/** Missing assets return null so the caller can keep its existing fallback. */
export async function loadAppearanceImage(transport: MediaTransport, kind: AppearanceImage, isCurrent: () => boolean): Promise<ImageData | null> {
  if (!Object.hasOwn(paths, kind)) throw new Error('invalid_media');
  const response = await request(transport, paths[kind], isCurrent);
  if (!response) return null;
  const contentType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() ?? '';
  if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(contentType)) throw new Error('invalid_media');
  const limit = kind === 'companionAvatar' ? 5 * 1024 * 1024 : 20 * 1024 * 1024;
  return { bytes: await readBoundedBody(response, limit, isCurrent, 'invalid_media'), contentType };
}
