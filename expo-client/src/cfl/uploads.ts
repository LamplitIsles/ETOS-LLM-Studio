import { validateUpload, validateUploadResult, validateFileManifest, validateFileUploadResult, sameFileManifest, FILE_OPERATIONS_PATH, fileOperationFileUrl, fileOperationUrl, UPLOAD_PATH, type ImageLimits, type FileLimits, type ImageUpload, type ImageRef, type FileRef } from '../../vendor/contracts/src/index';
import { readBoundedBody, type ApiTransport } from './transport';
import type { AttachmentDraft } from './drafts';

const check = (current: () => boolean) => { if (!current()) throw new Error('session_changed'); };
async function json(response: Response, current: () => boolean): Promise<unknown> {
  check(current); if (response.status === 401 || response.status === 403) throw new Error('access_denied');
  if (!response.ok || response.redirected) throw new Error('upload_failed');
  const data = await readBoundedBody(response, 64 * 1024, current, 'upload_failed');
  try { const value: unknown = JSON.parse(new TextDecoder().decode(data)); check(current); return value; } catch (error) { if (!current()) throw new Error('session_changed'); throw error; }
}
function base64(bytes: Uint8Array) { let binary = ''; for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(binary); }
export async function uploadImages(transport: ApiTransport, sessionId: string, operationId: string, drafts: readonly AttachmentDraft[], limits: ImageLimits, current: () => boolean, jpeg: (draft: AttachmentDraft, edge: number, max: number, current: () => boolean) => Promise<string>, signal?: AbortSignal): Promise<ImageRef[]> {
  if (!drafts.length || drafts.length > limits.maxImagesPerMessage || drafts.some(d => d.kind !== 'image' || !d.size || d.size > limits.maxImageBytes || !limits.mediaTypes.includes(d.mediaType as ImageUpload['images'][number]['mediaType'])) || drafts.reduce((n, d) => n + d.size, 0) > limits.maxMessageImageBytes) throw new Error('invalid_images');
  const images: ImageUpload['images'] = [];
  for (const [order, draft] of drafts.entries()) {
    check(current); const bytes = new Uint8Array(await draft.body.arrayBuffer()); check(current);
    if (bytes.length !== draft.size) throw new Error('invalid_image');
    images.push({ id: draft.id, order, name: draft.name, mediaType: draft.mediaType as ImageUpload['images'][number]['mediaType'], original: base64(bytes), preview: await jpeg(draft, 480, 160_000, current), model: await jpeg(draft, 1200, 320_000, current) });
  }
  const upload = validateUpload({ sessionId, operationId, images }, limits); check(current);
  const response = await transport.request(UPLOAD_PATH, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(upload), signal });
  return validateUploadResult(await json(response, current), upload).images.map(item => item.ref);
}
export async function uploadFiles(transport: ApiTransport, sessionId: string, operationId: string, drafts: readonly AttachmentDraft[], limits: FileLimits, current: () => boolean, signal?: AbortSignal): Promise<FileRef[]> {
  if (drafts.some(d => d.kind !== 'file' || d.body.size !== d.size)) throw new Error('invalid_files');
  const manifest = validateFileManifest({ sessionId, operationId, files: drafts.map(d => ({ id: d.id, name: d.name, mediaType: d.mediaType, size: d.size })) }, limits);
  check(current); const reserve = await transport.request(FILE_OPERATIONS_PATH, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(manifest), signal });
  const status = await json(reserve, current) as { manifest?: unknown; uploaded?: unknown; result?: unknown };
  if (!status || !sameFileManifest(validateFileManifest(status.manifest, limits), manifest) || !Array.isArray(status.uploaded) || status.uploaded.length || status.result !== undefined) throw new Error('invalid_file_reservation');
  for (const draft of drafts) {
    check(current); const response = await transport.request(fileOperationFileUrl(operationId, draft.id), { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, body: draft.body, signal });
    check(current); if (response.status !== 204 || response.redirected) throw new Error('upload_failed');
  }
  check(current); const response = await transport.request(`${fileOperationUrl(operationId)}/complete`, { method: 'POST', signal });
  return validateFileUploadResult(await json(response, current), manifest).files.map(item => item.ref);
}
