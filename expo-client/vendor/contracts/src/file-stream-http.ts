import {
  FILE_OPERATIONS_PATH,
  FILE_OPERATION_RETIRED_CODE,
  FILE_OPERATION_RETIRED_MESSAGE,
  FileOperationRetiredError,
  FileOperationNotFoundError,
  MAX_FILE_MANIFEST_BYTES,
  MAX_FILES_PER_MESSAGE,
  MAX_FILE_BYTES,
  MAX_MESSAGE_FILE_BYTES,
  FileManifestSchema,
  fileOperationUrl,
  sameFileManifest,
  validateFileManifest,
  validateFileUploadResult,
  type FileLimits,
  type FileManifest,
  type FileUploadResult,
} from "./files.ts";
import { validate } from "./validation.ts";
import type { FileOwner } from "./file-http.ts";

export interface FileStreamStatus {
  manifest: FileManifest;
  uploaded: string[];
  result?: FileUploadResult;
}
/** Host owns durable atomic reservation, incremental digest, temporary storage and cleanup.
 * Every mutation must call check() immediately before its atomic publication.
 * Throw FileOperationRetiredError only for a permanently fenced operation belonging
 * to this owner/session, including retirement races. Use null from status, or
 * FileOperationNotFoundError from mutations, for missing or other-scope IDs. */
export interface FileStreamBackend {
  reserve(
    manifest: FileManifest,
    owner: FileOwner,
    check: () => Promise<void>,
  ): Promise<FileStreamStatus>;
  status(
    operationId: string,
    owner: FileOwner,
  ): Promise<FileStreamStatus | null>;
  receive(
    manifest: FileManifest,
    id: string,
    bytes: AsyncIterable<Uint8Array>,
    owner: FileOwner,
    check: () => Promise<void>,
  ): Promise<void>;
  complete(
    manifest: FileManifest,
    owner: FileOwner,
    check: () => Promise<void>,
  ): Promise<FileUploadResult>;
}
const headers = {
  "Cache-Control": "private, no-store",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "sandbox; default-src 'none'",
};
const protocolLimits: FileLimits = {
  maxFilesPerMessage: MAX_FILES_PER_MESSAGE,
  maxFileBytes: MAX_FILE_BYTES,
  maxMessageFileBytes: MAX_MESSAGE_FILE_BYTES,
};
class FileScopeChangedError extends Error {}
function checkedStatus(
  value: FileStreamStatus,
  operationId: string,
  owner: FileOwner,
): FileStreamStatus {
  const manifest = validateFileManifest(value.manifest, protocolLimits);
  if (
    manifest.operationId !== operationId ||
    manifest.sessionId !== owner.sessionId ||
    !Array.isArray(value.uploaded) ||
    new Set(value.uploaded).size !== value.uploaded.length ||
    value.uploaded.some((id) => !manifest.files.some((f) => f.id === id))
  )
    throw new Error("Invalid status");
  if (value.result) {
    if (value.uploaded.length !== manifest.files.length)
      throw new Error("Incomplete status");
    validateFileUploadResult(value.result, manifest);
  }
  return value;
}
async function readManifest(request: Request): Promise<unknown> {
  if (Number(request.headers.get("content-length")) > MAX_FILE_MANIFEST_BYTES)
    throw new Error("Manifest too large");
  const reader = request.body?.getReader();
  if (!reader) throw new Error("Missing manifest");
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_FILE_MANIFEST_BYTES) {
        await reader.cancel();
        throw new Error("Manifest too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}
/** Mount before fileHttp/static assets. No upload payload buffering occurs here. */
export async function fileStreamHttp(
  request: Request,
  backend: FileStreamBackend,
  authorize: () => Promise<(FileOwner & { limits: FileLimits | false }) | null>,
): Promise<Response | undefined> {
  const url = new URL(request.url);
  if (
    url.pathname !== FILE_OPERATIONS_PATH &&
    !url.pathname.startsWith(FILE_OPERATIONS_PATH + "/")
  )
    return;
  const isStatusLookup =
    request.method === "GET" &&
    url.pathname.startsWith(FILE_OPERATIONS_PATH + "/") &&
    !url.pathname.slice(FILE_OPERATIONS_PATH.length + 1).includes("/");
  const initial = await authorize();
  if (
    !initial ||
    typeof initial.ownerId !== "string" ||
    !initial.ownerId ||
    typeof initial.sessionId !== "string" ||
    !initial.sessionId
  )
    return new Response(null, { status: 401, headers });
  if (!initial.limits && !isStatusLookup)
    return new Response(null, { status: 503, headers });
  const owner = { ownerId: initial.ownerId, sessionId: initial.sessionId };
  let manifest: FileManifest | undefined;
  const checkScope = async () => {
    let now;
    try {
      now = await authorize();
    } catch {
      throw new FileScopeChangedError();
    }
    if (
      !now ||
      now.ownerId !== owner.ownerId ||
      now.sessionId !== owner.sessionId
    )
      throw new FileScopeChangedError();
    if (request.signal.aborted) throw new Error("Aborted");
    return now;
  };
  const check = async () => {
    const now = await checkScope();
    if (!now.limits) throw new Error("Files unavailable");
    if (manifest) validateFileManifest(manifest, now.limits);
  };
  try {
    if (
      request.method !== "GET" &&
      request.headers.get("origin") !== url.origin
    )
      return new Response(null, { status: 403, headers });
    if (url.pathname === FILE_OPERATIONS_PATH) {
      if (request.method !== "POST")
        return new Response(null, { status: 405, headers });
      if (request.headers.get("content-type") !== "application/json")
        return new Response(null, { status: 415, headers });
      if (!initial.limits) return new Response(null, { status: 503, headers });
      manifest = validateFileManifest(
        await readManifest(request),
        initial.limits,
      );
      if (manifest.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      await check();
      const status = checkedStatus(
        await backend.reserve(manifest, owner, check),
        manifest.operationId,
        owner,
      );
      if (!sameFileManifest(status.manifest, manifest))
        throw new Error("Manifest conflict");
      await check();
      return Response.json(status, { headers });
    }
    const parts = url.pathname
      .slice(FILE_OPERATIONS_PATH.length + 1)
      .split("/");
    const operationId = parts[0]!;
    if (
      fileOperationUrl(operationId) !== `${FILE_OPERATIONS_PATH}/${operationId}`
    )
      throw new Error("Invalid operation");
    const status = await backend.status(operationId, owner);
    await checkScope();
    if (!status) return new Response(null, { status: 404, headers });
    checkedStatus(status, operationId, owner);
    manifest = validate(FileManifestSchema, status.manifest);
    if (isStatusLookup) return Response.json(status, { headers });
    await check();
    if (
      parts.length === 2 &&
      parts[1] === "complete" &&
      request.method === "POST"
    ) {
      if (status.uploaded.length !== manifest.files.length)
        throw new Error("Incomplete upload");
      const result = validateFileUploadResult(
        await backend.complete(manifest, owner, check),
        manifest,
      );
      await check();
      return Response.json(result, { headers });
    }
    if (
      parts.length === 3 &&
      parts[1] === "files" &&
      request.method === "PUT"
    ) {
      if (request.headers.get("content-type") !== "application/octet-stream")
        return new Response(null, { status: 415, headers });
      const file = manifest.files.find((f) => f.id === parts[2]);
      if (!file) throw new Error("Unknown file");
      const lengthHeader = request.headers.get("content-length");
      if (
        lengthHeader !== null &&
        (!/^\d+$/.test(lengthHeader) || Number(lengthHeader) !== file.size)
      )
        throw new Error("Wrong length");
      const reader = request.body?.getReader();
      let count = 0,
        finished = false;
      async function* bounded() {
        if (reader) {
          try {
            for (;;) {
              if (request.signal.aborted) throw new Error("Aborted");
              const { done, value } = await reader.read();
              if (done) break;
              count += value.byteLength;
              if (count > file!.size) throw new Error("Too many bytes");
              yield value;
            }
          } finally {
            if (!finished) await reader.cancel().catch(() => {});
            reader.releaseLock();
          }
        }
        if (count !== file!.size) throw new Error("Wrong size");
        finished = true;
      }
      const commitCheck = async () => {
        if (!finished) throw new Error("Body not consumed");
        await check();
      };
      try {
        await backend.receive(manifest, file.id, bounded(), owner, commitCheck);
        await commitCheck();
      } finally {
        if (!finished && reader) await reader.cancel().catch(() => {});
      }
      return new Response(null, { status: 204, headers });
    }
    return new Response(null, { status: 405, headers });
  } catch (error) {
    if (error instanceof FileScopeChangedError)
      return new Response(null, { status: 403, headers });
    if (
      error instanceof FileOperationRetiredError ||
      error instanceof FileOperationNotFoundError
    ) {
      try {
        const current = await authorize();
        if (
          !current ||
          current.ownerId !== owner.ownerId ||
          current.sessionId !== owner.sessionId
        )
          return new Response(null, { status: 403, headers });
        if (!current.limits && !isStatusLookup)
          return new Response(null, { status: 503, headers });
        if (error instanceof FileOperationNotFoundError)
          return new Response(null, { status: 404, headers });
        return Response.json(
          {
            error: {
              code: FILE_OPERATION_RETIRED_CODE,
              message: FILE_OPERATION_RETIRED_MESSAGE,
            },
          },
          { status: 410, headers },
        );
      } catch {
        return new Response(null, { status: 403, headers });
      }
    }
    return new Response("File operation failed", { status: 400, headers });
  }
}
