import * as ImagePicker from 'expo-image-picker';
import * as DocumentPicker from 'expo-document-picker';
import { File as NativeFile, Paths } from 'expo-file-system';
import { Platform } from 'react-native';
import * as Crypto from 'expo-crypto';
import { syntheticOperationId } from './seed-uuid';
import { captureWithCamera, isCameraCacheUri } from './camera-flow';
export { CameraPermissionError } from './camera-flow';

export type AttachmentDraft = { id: string; kind: 'image' | 'file'; name: string; mediaType: string; size: number; uri: string; width?: number; height?: number; body: Blob; release(): void };
const check = (current: () => boolean) => { if (!current()) throw new Error('session_changed'); };
function releaseAsset(kind: 'image' | 'file', uri: string) {
  if (Platform.OS === 'web') { if (uri.startsWith('blob:')) URL.revokeObjectURL(uri); return; }
  // Only remove the document picker's own cache copy, never a selected original.
  if (kind === 'file') { try { const base = new URL('DocumentPicker/', Paths.cache.uri).href; if (new URL(uri).href.startsWith(base)) new NativeFile(uri).delete(); } catch {} }
}
function releaseCameraAsset(uri: string) {
  // Only delete a camera result in the image picker's own cache directory.
  try { if (isCameraCacheUri(Paths.cache.uri, uri)) new NativeFile(uri).delete(); } catch {}
}
function makeDraft(kind: 'image' | 'file', asset: { uri: string; name?: string | null; mimeType?: string | null; file?: File; width?: number; height?: number }, camera = false): AttachmentDraft {
  const body: Blob = Platform.OS === 'web' ? (asset.file ?? (() => { throw new Error('file_unavailable'); })()) : new NativeFile(asset.uri);
  const mediaType = asset.mimeType ?? body.type ?? '';
  const uri = Platform.OS === 'web' && !asset.uri.startsWith('blob:') ? URL.createObjectURL(body) : asset.uri;
  let released = false;
  return { id: Platform.OS === 'web' ? syntheticOperationId() : Crypto.randomUUID(), kind, name: asset.name || (kind === 'image' ? 'image' : 'file'), mediaType, size: body.size, uri, width: asset.width, height: asset.height, body,
    release() { if (!released) { if (camera) releaseCameraAsset(uri); else releaseAsset(kind, uri); } released = true; } };
}
/** iOS system camera; the caller must combine session and component lifetime in current. */
export async function capturePhoto(current: () => boolean): Promise<AttachmentDraft[] | null> {
  check(current);
  if (Platform.OS !== 'ios') throw new Error('camera_unavailable');
  return captureWithCamera(current, {
    permission: () => ImagePicker.requestCameraPermissionsAsync(),
    launch: () => ImagePicker.launchCameraAsync({ mediaTypes: ['images'], quality: 1, allowsEditing: false }),
    draft: a => {
      const extension = ({ 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif' } as Record<string, string>)[a.mimeType ?? ''];
      return makeDraft('image', { uri: a.uri, name: a.fileName || (extension ? `photo.${extension}` : 'photo'), mimeType: a.mimeType, width: a.width, height: a.height }, true);
    },
    discard: a => releaseCameraAsset(a.uri),
  });
}
/** Call directly from a user gesture; web browsers may not report cancellation. */
export async function pickImages(current: () => boolean): Promise<AttachmentDraft[] | null> {
  check(current);
  const result = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsMultipleSelection: true, selectionLimit: 6, quality: 1, allowsEditing: false, preferredAssetRepresentationMode: ImagePicker.UIImagePickerPreferredAssetRepresentationMode.Compatible });
  if (!current()) { if (!result.canceled) result.assets.forEach(a => releaseAsset('image', a.uri)); throw new Error('session_changed'); }
  if (result.canceled) return null;
  const drafts: AttachmentDraft[] = [];
  try { for (const a of result.assets) drafts.push(makeDraft('image', { uri: a.uri, name: a.fileName, mimeType: a.mimeType, file: a.file, width: a.width, height: a.height })); return drafts; }
  catch (error) { drafts.forEach(d => d.release()); result.assets.forEach(a => releaseAsset('image', a.uri)); throw error; }
}
export async function pickFiles(current: () => boolean): Promise<AttachmentDraft[] | null> {
  check(current);
  const result = await DocumentPicker.getDocumentAsync({ multiple: true, copyToCacheDirectory: true, base64: false });
  if (!current()) { if (!result.canceled) result.assets.forEach(a => releaseAsset('file', a.uri)); throw new Error('session_changed'); }
  if (result.canceled) return null;
  const drafts: AttachmentDraft[] = [];
  try { for (const a of result.assets) drafts.push(makeDraft('file', a)); return drafts; }
  catch (error) { drafts.forEach(d => d.release()); result.assets.forEach(a => releaseAsset('file', a.uri)); throw error; }
}
