import * as ImageManipulator from 'expo-image-manipulator';
import { Platform } from 'react-native';
import { File as NativeFile, Paths } from 'expo-file-system';
import type { AttachmentDraft } from './drafts';

const check = (current: () => boolean) => { if (!current()) throw new Error('session_changed'); };
export async function jpegVariant(draft: AttachmentDraft, edge: number, max: number, current: () => boolean): Promise<string> {
  if (!draft.width || !draft.height) throw new Error('invalid_image');
  for (let i = 0; i < 5; i++) {
    check(current); const scale = Math.min(1, edge / Math.max(draft.width, draft.height));
    const result = await ImageManipulator.manipulateAsync(draft.uri, [{ resize: { width: Math.max(1, Math.round(draft.width * scale)), height: Math.max(1, Math.round(draft.height * scale)) } }], { format: ImageManipulator.SaveFormat.JPEG, compress: 0.76, base64: true });
    if (Platform.OS !== 'web' && result.uri !== draft.uri) { try { const base = new URL('ImageManipulator/', Paths.cache.uri).href; if (new URL(result.uri).href.startsWith(base)) new NativeFile(result.uri).delete(); } catch {} }
    check(current); const value = result.base64;
    if (value && (value.length / 4 * 3 - (value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0)) <= max) return value;
    edge = Math.round(edge * 0.7);
  }
  throw new Error('image_too_large');
}
