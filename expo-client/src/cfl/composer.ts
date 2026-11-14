import type { StickerIdentity } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from './drafts';
import type { ChatController, SendPlacement, OperationIdentity } from './chat';
import { outcome } from './send-outcome';
export type { SendOutcome } from './send-outcome';
import type { ApiTransport } from './transport';
import { uploadFiles, uploadImages } from './uploads';
import { validateDrafts } from './intake';
import { StickerClient } from './stickers';

import type { SendOutcome } from './send-outcome';
function prepareDrafts(transport: ApiTransport, drafts: readonly AttachmentDraft[]): Parameters<ChatController['sendPrepared']>[1] {
  drafts = [...drafts];
  return async ({ operationId, sessionId, isCurrent, view, signal }) => {
    validateDrafts(view, drafts);
    const images = drafts.filter(d => d.kind === 'image'), files = drafts.filter(d => d.kind === 'file');
    if (images.length && !view.capabilities.images) throw new Error('images_unavailable');
    if (files.length && !view.capabilities.files) throw new Error('files_unavailable');
    return {
      ...(images.length ? { images: await uploadImages(transport, sessionId, operationId, images, view.capabilities.images || (() => { throw new Error('images_unavailable'); })(), isCurrent, async (...args) => (await import('./image-variants')).jpegVariant(...args), signal) } : {}),
      ...(files.length ? { files: await uploadFiles(transport, sessionId, operationId, files, view.capabilities.files || (() => { throw new Error('files_unavailable'); })(), isCurrent, signal) } : {}),
    };
  };
}
/** Resolves after the pending entry is saved and published; receipt handling continues independently. */
export async function beginSendDrafts(controller: ChatController, transport: ApiTransport, text: string, drafts: readonly AttachmentDraft[], anchor: SendPlacement): Promise<OperationIdentity> {
  const result = await controller.beginPrepared(text, prepareDrafts(transport, drafts), anchor);
  return result.identity;
}
/** Returns after journaling and one dispatch attempt; unknown must never be resent automatically. */
export function sendDrafts(controller: ChatController, transport: ApiTransport, text: string, drafts: readonly AttachmentDraft[]): Promise<SendOutcome> {
  return outcome(controller, controller.sendPrepared(text, prepareDrafts(transport, drafts)));
}
/** Like the existing App, selecting a sticker starts its explicit send. */
export function sendSticker(controller: ChatController, transport: ApiTransport, sticker: StickerIdentity): Promise<SendOutcome> {
  return outcome(controller, controller.sendPrepared('', prepareSticker(transport, sticker)));
}
function prepareSticker(transport: ApiTransport, sticker: StickerIdentity): Parameters<ChatController['sendPrepared']>[1] {
  const identity = { id: sticker.id, version: sticker.version };
  return async ({ operationId, sessionId, isCurrent, signal }) => ({ images: [await new StickerClient(transport, sessionId, isCurrent, signal).stage(operationId, identity)] });
}
/** Stage only from the explicit action; after admission inspect this operation instead of resending it. */
export async function beginSendSticker(controller: ChatController, transport: ApiTransport, sticker: StickerIdentity, anchor: SendPlacement): Promise<OperationIdentity> {
  const result = await controller.beginPrepared('', prepareSticker(transport, sticker), anchor);
  return result.identity;
}
