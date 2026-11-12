import { FileRefSchema, fileDownloadUrl, validate, type FileRef } from '../../vendor/contracts/src/index';
import { readBoundedBody, type MediaTransport } from './transport';
/** Explicit file download, bounded by the validated reference and current session. */
export async function loadFile(transport: MediaTransport, input: FileRef, current: () => boolean): Promise<Uint8Array | null> {
  const ref = validate(FileRefSchema, input); if (!current()) throw new Error('session_changed');
  if (ref.availability === 'missing') return null;
  const response = await transport.read(fileDownloadUrl(ref.attachmentId)); if (!current()) throw new Error('session_changed');
  if (response.status === 404) return null;
  if (response.status === 401 || response.status === 403) throw new Error('access_denied');
  if (!response.ok || response.redirected) throw new Error('unavailable');
  if (response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/octet-stream') throw new Error('invalid_file');
  if (ref.size === 0 && !response.body) return new Uint8Array();
  const bytes = await readBoundedBody(response, ref.size, current, 'invalid_file', true);
  if (bytes.length !== ref.size) throw new Error('invalid_file'); return bytes;
}
