import * as ImageManipulator from 'expo-image-manipulator';
import { File as NativeFile, Paths } from 'expo-file-system';
import type { ChatView } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from './drafts';
import { isCameraWebpCacheUri, prepareCameraPhotoCore } from './camera-photo-core';
export { CameraPhotoError } from './camera-photo-core';

/** Consumes photo; existing drafts remain owned by the caller. */
export function prepareCameraPhoto(view: ChatView, existing: readonly AttachmentDraft[], photo: AttachmentDraft, current: () => boolean): Promise<AttachmentDraft> {
  return prepareCameraPhotoCore(view, existing, photo, current, async source => {
    const context = ImageManipulator.ImageManipulator.manipulate(source.uri);
    let image: Awaited<ReturnType<typeof context.renderAsync>> | undefined;
    let output: string | undefined;
    const canRemove = (uri: string) => uri !== source.uri && !existing.some(item => item.uri === uri) && isCameraWebpCacheUri(Paths.cache.uri, uri);
    const remove = (uri: string) => { if (canRemove(uri)) { try { new NativeFile(uri).delete(); } catch {} } };
    try {
      image = await context.renderAsync();
      if (!current()) throw new Error('session_changed');
      const result = await image.saveAsync({ format: ImageManipulator.SaveFormat.WEBP, compress: 0.8 });
      output = result.uri;
      if (!canRemove(output)) throw new Error('invalid_output');
      const body = new NativeFile(output);
      const uri = output;
      return { uri, body, width: result.width, height: result.height, release() { remove(uri); } };
    } catch (error) {
      if (output) remove(output);
      throw error;
    } finally {
      try { image?.release(); } catch {}
      try { context.release(); } catch {}
    }
  });
}
