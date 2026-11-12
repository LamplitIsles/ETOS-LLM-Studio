import type { StickerIdentity } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from './drafts';
import type { ChatController } from './chat';
import { outcome } from './send-outcome';
export type { SendOutcome } from './send-outcome';
import type { ApiTransport } from './transport';
import { uploadFiles, uploadImages } from './uploads';
import { validateDrafts } from './intake';
import { jpegVariant } from './image-variants';
import { StickerClient } from './stickers';

import type { SendOutcome } from './send-outcome';
/** Returns after journaling and one dispatch attempt; unknown must never be resent automatically. */
export function sendDrafts(controller: ChatController, transport: ApiTransport, text: string, drafts: readonly AttachmentDraft[]): Promise<SendOutcome> {
  return outcome(controller, controller.sendPrepared(text, async ({ operationId, sessionId, isCurrent, view, signal }) => {
    validateDrafts(view, drafts);
    const images = drafts.filter(d => d.kind === 'image'), files = drafts.filter(d => d.kind === 'file');
    if (images.length && !view.capabilities.images) throw new Error('images_unavailable');
    if (files.length && !view.capabilities.files) throw new Error('files_unavailable');
    return {
      ...(images.length ? { images: await uploadImages(transport, sessionId, operationId, images, view.capabilities.images || (() => { throw new Error('images_unavailable'); })(), isCurrent, jpegVariant, signal) } : {}),
      ...(files.length ? { files: await uploadFiles(transport, sessionId, operationId, files, view.capabilities.files || (() => { throw new Error('files_unavailable'); })(), isCurrent, signal) } : {}),
    };
  }));
}
/** Like the existing App, selecting a sticker starts its explicit send. */
export function sendSticker(controller: ChatController, transport: ApiTransport, sticker: StickerIdentity): Promise<SendOutcome> {
  return outcome(controller, controller.sendPrepared('', async ({ operationId, sessionId, isCurrent, signal }) => ({ images: [await new StickerClient(transport, sessionId, isCurrent, signal).stage(operationId, sticker)] })));
}
