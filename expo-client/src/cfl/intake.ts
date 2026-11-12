import type { ChatView } from '../../vendor/contracts/src/index';
import type { AttachmentDraft } from './drafts';
/** Validate all selected drafts before any upload; selection remains owned by the caller. */
export function validateDrafts(view: ChatView, drafts: readonly AttachmentDraft[]): void {
  const images = drafts.filter(d => d.kind === 'image'), files = drafts.filter(d => d.kind === 'file');
  if (images.length + files.length !== drafts.length || new Set(drafts.map(d => d.id)).size !== drafts.length || drafts.some(d => !/^[A-Za-z0-9_-]{1,100}$/.test(d.id) || !d.name || d.name.length > 200 || d.size !== d.body.size || d.mediaType.length > 255)) throw new Error('invalid_drafts');
  if (images.length) {
    const limits = view.capabilities.images; if (!limits) throw new Error('images_unavailable');
    if (images.length > limits.maxImagesPerMessage || images.some(d => !d.size || d.size > limits.maxImageBytes || !limits.mediaTypes.includes(d.mediaType as typeof limits.mediaTypes[number])) || images.reduce((n, d) => n + d.size, 0) > limits.maxMessageImageBytes) throw new Error('invalid_images');
  }
  if (files.length) {
    const limits = view.capabilities.files; if (!limits) throw new Error('files_unavailable');
    if (files.length > limits.maxFilesPerMessage || files.some(d => d.size > limits.maxFileBytes) || files.reduce((n, d) => n + d.size, 0) > limits.maxMessageFileBytes) throw new Error('invalid_files');
  }
}
