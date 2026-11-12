import {
  UPLOAD_PATH,
  MEDIA_PATH,
  MediaIdSchema,
  MAX_UPLOAD_BODY_BYTES,
  validateUploadResult,
  validateUpload,
  type ImageLimits,
  type ImageUpload,
} from "./images.ts";
import { validate } from "./validation.ts";
import { matchesEtag } from "./http-etag.ts";
// Existing native-generated originals may exceed new-input intake limits.
const MAX_ORIGINAL_MEDIA_BYTES = 32 * 1024 * 1024;
const noStore = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

export interface ImageBackend {
  /** Authenticated owner/session adapter; stores immutable operation+ordered upload payload. */
  upload(input: ImageUpload): Promise<unknown>;
  media(
    id: string,
    variant: "original" | "preview" | "model",
  ): Promise<{ bytes: Uint8Array; mediaType: string } | null>;
}
/** Mount before static assets. Authorization must resolve the current owner and session on every request. */
export async function imageHttp(
  request: Request,
  backend: ImageBackend,
  authorize: () => Promise<{
    sessionId: string;
    limits: ImageLimits | false;
  } | null>,
): Promise<Response | undefined> {
  const url = new URL(request.url);
  if (url.pathname !== UPLOAD_PATH && !url.pathname.startsWith(MEDIA_PATH))
    return;
  const owner = await authorize();
  if (!owner)
    return new Response("Unauthorized", { status: 401, headers: noStore });
  const headers = noStore;
  try {
    if (url.pathname === UPLOAD_PATH) {
      if (request.method !== "POST")
        return new Response(null, { status: 405, headers });
      if (request.headers.get("origin") !== url.origin)
        return new Response(null, { status: 403, headers });
      if (!owner.limits)
        return new Response("Images unavailable", { status: 503, headers });
      if (request.headers.get("content-type") !== "application/json")
        return new Response(null, { status: 415, headers });
      if (Number(request.headers.get("content-length")) > MAX_UPLOAD_BODY_BYTES)
        return new Response(null, { status: 413, headers });
      const reader = request.body?.getReader();
      if (!reader) throw new Error("Missing body");
      const chunks: Uint8Array[] = [];
      let length = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          length += value.byteLength;
          if (length > MAX_UPLOAD_BODY_BYTES) {
            await reader.cancel();
            return new Response(null, { status: 413, headers });
          }
          chunks.push(value);
        }
      } finally {
        reader.releaseLock();
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.length;
      }
      const input = validateUpload(
        JSON.parse(new TextDecoder().decode(bytes)),
        owner.limits,
      );
      if (input.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      const current = await authorize();
      if (!current || current.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      if (!current.limits) return new Response(null, { status: 503, headers });
      validateUpload(input, current.limits);
      const result = validateUploadResult(await backend.upload(input), input);
      const final = await authorize();
      if (!final || final.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      return Response.json(result, { headers });
    }
    if (request.method !== "GET")
      return new Response(null, { status: 405, headers });
    const parts = url.pathname.slice(MEDIA_PATH.length).split("/");
    const id = validate(MediaIdSchema, parts[0]);
    const variant = parts[1];
    if (
      parts.length !== 2 ||
      !["original", "preview", "model"].includes(variant!)
    )
      throw new Error("Invalid media path");
    const media = await backend.media(
      id,
      variant as "original" | "preview" | "model",
    );
    const mediaType = media?.mediaType;
    if (
      media &&
      (!mediaType ||
        media.bytes.length >
          (variant === "original"
            ? MAX_ORIGINAL_MEDIA_BYTES
            : variant === "preview"
              ? 160_000
              : 320_000) ||
        !["image/png", "image/jpeg", "image/webp", "image/gif"].includes(
          mediaType,
        ) ||
        (variant !== "original" && mediaType !== "image/jpeg"))
    )
      throw new Error("Invalid media result");
    // Snapshot exactly the bytes that will be returned before hashing them.
    const bytes = media ? Uint8Array.from(media.bytes) : null;
    const digest = bytes
      ? new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
      : null;
    const current = await authorize();
    if (!current || current.sessionId !== owner.sessionId)
      return new Response(null, { status: 403, headers });
    if (!media || !mediaType || !bytes || !digest)
      return new Response("Missing image", { status: 404, headers });
    const hash = Array.from(digest, (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
    const etag = `"${hash}-${variant}-${mediaType.slice(6)}"`;
    const mediaHeaders = {
      ...headers,
      "Cache-Control": "private, max-age=2592000",
      "Content-Type": mediaType,
      ETag: etag,
    };
    if (matchesEtag(request.headers.get("if-none-match"), etag))
      return new Response(null, { status: 304, headers: mediaHeaders });
    return new Response(bytes as BodyInit, { headers: mediaHeaders });
  } catch {
    return new Response("Image request failed", { status: 400, headers });
  }
}
