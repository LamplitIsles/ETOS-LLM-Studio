import {
  FILE_DOWNLOAD_PATH,
  MAX_FILE_BYTES,
  type FileLimits,
} from "./files.ts";
import { MediaIdSchema } from "./images.ts";
import { validate } from "./validation.ts";

export interface FileOwner {
  ownerId: string;
  sessionId: string;
}
export interface FileBackend {
  /** Return only owner/session-authorized bytes as an exact-size stream. */
  fileStream(
    id: string,
    owner: FileOwner,
  ): Promise<{ body: ReadableStream<Uint8Array>; size: number } | null>;
}
/** Mount before static assets. Resolve authorization and session on each request. */
export async function fileHttp(
  request: Request,
  backend: FileBackend,
  authorize: () => Promise<{
    ownerId: string;
    sessionId: string;
    limits: FileLimits | false;
  } | null>,
): Promise<Response | undefined> {
  const url = new URL(request.url);
  if (!url.pathname.startsWith(FILE_DOWNLOAD_PATH)) return;
  const owner = await authorize();
  if (
    !owner ||
    typeof owner.ownerId !== "string" ||
    !owner.ownerId ||
    typeof owner.sessionId !== "string" ||
    !owner.sessionId
  )
    return new Response("Unauthorized", { status: 401 });
  const headers = {
    "Cache-Control": "private, no-store",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "sandbox; default-src 'none'",
  };
  try {
    if (request.method !== "GET")
      return new Response(null, { status: 405, headers });
    const id = validate(
      MediaIdSchema,
      url.pathname.slice(FILE_DOWNLOAD_PATH.length),
    );
    const file = await backend.fileStream(id, {
      ownerId: owner.ownerId,
      sessionId: owner.sessionId,
    });
    let acquiredReader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    let handedOff = false;
    try {
      const current = await authorize();
      if (
        !current ||
        current.ownerId !== owner.ownerId ||
        current.sessionId !== owner.sessionId
      )
        return new Response(null, { status: 403, headers });
      if (!file) return new Response("Missing file", { status: 404, headers });
      if (
        !Number.isSafeInteger(file.size) ||
        file.size < 0 ||
        file.size > MAX_FILE_BYTES
      )
        throw new Error("Invalid file size");
      const reader = file.body.getReader();
      acquiredReader = reader;
      let count = 0;
      const body = new ReadableStream<Uint8Array>({
        async pull(controller) {
          try {
            const auth = await authorize();
            if (
              !auth ||
              auth.ownerId !== owner.ownerId ||
              auth.sessionId !== owner.sessionId
            )
              throw new Error("Authorization changed");
            const next = await reader.read();
            if (next.done) {
              if (count !== file.size) throw new Error("Wrong file size");
              reader.releaseLock();
              controller.close();
              return;
            }
            count += next.value.byteLength;
            if (count > file.size) throw new Error("Wrong file size");
            controller.enqueue(next.value);
          } catch (error) {
            await reader.cancel().catch(() => {});
            controller.error(error);
          }
        },
        async cancel(reason) {
          await reader.cancel(reason);
        },
      });
      const response = new Response(body, {
        headers: {
          ...headers,
          "Content-Type": "application/octet-stream",
          "Content-Disposition": "attachment",
          "Content-Length": String(file.size),
        },
      });
      handedOff = true;
      return response;
    } finally {
      if (file && !handedOff) {
        if (acquiredReader) await acquiredReader.cancel().catch(() => {});
        else await file.body.cancel().catch(() => {});
      }
    }
  } catch {
    return new Response("File request failed", { status: 400, headers });
  }
}
