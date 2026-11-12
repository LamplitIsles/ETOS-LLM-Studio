import { validate } from "./validation.ts";
import { matchesEtag } from "./http-etag.ts";
import { ImageTypeSchema } from "./images.ts";
import {
  StickerPageRequestSchema,
  StickerPackRequestSchema,
  StickerPackPageSchema,
  StickerPageSchema,
  StickerFavoriteSchema,
  StickerFavoriteImageSchema,
  StickerFavoriteResultSchema,
  StickerUploadSchema,
  StickerImportResultSchema,
  StickerStageSchema,
  StickerVersionSchema,
  validateStickerStageResult,
  STICKER_ZIP_MAX_BYTES,
  STICKER_UPLOAD_MAX_BYTES,
  type StickerBackend,
} from "./stickers.ts";

const ROOT = "/api/stickers";
const jsonLimit = Math.ceil(STICKER_UPLOAD_MAX_BYTES / 3) * 4 + 16384;
const headers = {
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};
async function body(request: Request, max: number): Promise<Uint8Array> {
  if (Number(request.headers.get("content-length")) > max || !request.body)
    throw new Error("Invalid body");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > max) {
        await reader.cancel();
        throw new Error("Body too large");
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
  return bytes;
}
/** The host provides per-request owner/session authorization and commits only while it remains valid. */
export async function stickerHttp(
  request: Request,
  backend: StickerBackend,
  authorize: () => Promise<{ sessionId: string } | null>,
): Promise<Response | undefined> {
  const url = new URL(request.url);
  if (url.pathname !== ROOT && !url.pathname.startsWith(`${ROOT}/`)) return;
  const owner = await authorize();
  if (!owner) return new Response("Unauthorized", { status: 401, headers });
  const allowed = async () =>
    (await authorize())?.sessionId === owner.sessionId;
  const reply = async (value: unknown) => {
    if (!(await allowed()))
      return new Response("Unauthorized", { status: 403, headers });
    return Response.json(value, { headers });
  };
  try {
    const path = url.pathname.slice(ROOT.length);
    if (request.method === "GET") {
      const match = /^\/media\/([a-f0-9]{64})\/(original|thumbnail)$/.exec(
        path,
      );
      if (match) {
        const version = validate(StickerVersionSchema, match[1]);
        const variant = match[2] as "original" | "thumbnail";
        const value = await backend.media(version, variant);
        if (!(await allowed()))
          return new Response("Unauthorized", { status: 403, headers });
        if (!value)
          return new Response("Missing image", { status: 404, headers });
        validate(ImageTypeSchema, value.mediaType);
        if (
          !value.bytes.length ||
          value.bytes.length >
            (variant === "original" ? STICKER_UPLOAD_MAX_BYTES : 160_000) ||
          (variant === "thumbnail" && value.mediaType !== "image/webp")
        )
          throw new Error("Invalid media");
        // Hash and return the same snapshot even if the backend reuses its buffer.
        const bytes = Uint8Array.from(value.bytes);
        const mediaType = value.mediaType;
        // The ETag represents the returned bytes, including a separately
        // generated thumbnail, not just the original's content version.
        const digest = new Uint8Array(
          await crypto.subtle.digest("SHA-256", bytes),
        );
        const hash = Array.from(digest, (byte) =>
          byte.toString(16).padStart(2, "0"),
        ).join("");
        const etag = `"${hash}-${variant}-${mediaType.slice(6)}"`;
        const mediaHeaders = {
          "Content-Type": mediaType,
          "Cache-Control": "private, max-age=2592000",
          ETag: etag,
          "X-Content-Type-Options": "nosniff",
        };
        // Requests that reach the server revalidate authorization after hashing.
        if (!(await allowed()))
          return new Response("Unauthorized", { status: 403, headers });
        if (matchesEtag(request.headers.get("if-none-match"), etag))
          return new Response(null, { status: 304, headers: mediaHeaders });
        return new Response(bytes as BodyInit, { headers: mediaHeaders });
      }
      if (path.startsWith("/media/"))
        return new Response("Not found", { status: 404, headers });
      const keys = [...url.searchParams.keys()];
      if (
        keys.some((key, index) => keys.indexOf(key) !== index) ||
        keys.some(
          (key) => !["sessionId", "cursor", "limit", "query"].includes(key),
        )
      )
        throw new Error("Invalid query");
      const input = validate(StickerPageRequestSchema, {
        sessionId: url.searchParams.get("sessionId"),
        cursor: url.searchParams.get("cursor"),
        limit: Number(url.searchParams.get("limit") ?? 30),
        ...(url.searchParams.has("query")
          ? { query: url.searchParams.get("query") }
          : {}),
      });
      if (input.sessionId !== owner.sessionId)
        return new Response("Wrong session", { status: 403, headers });
      if (path === "/packs") {
        const page = validate(
          StickerPackPageSchema,
          await backend.packs(input),
        );
        if (page.packs.length > input.limit)
          throw new Error("Invalid page size");
        return reply(page);
      }
      if (path === "/search" || path === "/favorites") {
        const page = validate(
          StickerPageSchema,
          await (path === "/search"
            ? backend.search(input)
            : backend.favorites(input)),
        );
        if (page.stickers.length > input.limit)
          throw new Error("Invalid page size");
        return reply(page);
      }
      const pack = /^\/packs\/([A-Za-z0-9_-]{1,100})$/.exec(path);
      if (pack) {
        if (input.query !== undefined) throw new Error("Invalid query");
        const value = validate(StickerPackRequestSchema, {
          sessionId: input.sessionId,
          cursor: input.cursor,
          limit: input.limit,
          packId: pack[1],
        });
        const page = validate(StickerPageSchema, await backend.pack(value));
        if (page.stickers.length > input.limit)
          throw new Error("Invalid page size");
        return reply(page);
      }
      return new Response("Not found", { status: 404, headers });
    }
    if (request.method !== "POST")
      return new Response(null, { status: 405, headers });
    if (request.headers.get("origin") !== url.origin)
      return new Response(null, { status: 403, headers });
    if (path === "/imports") {
      if (
        request.headers.get("content-type") !== "application/zip" ||
        url.searchParams.size !== 1 ||
        url.searchParams.get("sessionId") !== owner.sessionId
      )
        throw new Error("Invalid import");
      const bytes = await body(request, STICKER_ZIP_MAX_BYTES);
      return reply(
        validate(
          StickerImportResultSchema,
          await backend.importZip(owner.sessionId, bytes, allowed),
        ),
      );
    }
    if (
      url.search ||
      request.headers.get("content-type") !== "application/json"
    )
      throw new Error("Invalid request");
    const value: unknown = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(
        await body(request, jsonLimit),
      ),
    );
    if (path === "/favorites") {
      const input = validate(StickerFavoriteSchema, value);
      if (input.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      const result = validate(
        StickerFavoriteResultSchema,
        await backend.favorite(input, allowed),
      );
      if (
        result.sticker.id !== input.stickerId ||
        result.favorite !== input.favorite
      )
        throw new Error("Invalid favorite result");
      return reply(result);
    }
    if (path === "/favorites/image") {
      const input = validate(StickerFavoriteImageSchema, value);
      if (input.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      const result = validate(
        StickerFavoriteResultSchema,
        await backend.favoriteImage(input, allowed),
      );
      if (!result.favorite) throw new Error("Invalid favorite result");
      return reply(result);
    }
    if (path === "/favorites/upload") {
      const input = validate(StickerUploadSchema, value);
      if (input.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      const decoded = atob(input.data);
      if (
        !decoded.length ||
        decoded.length > STICKER_UPLOAD_MAX_BYTES ||
        btoa(decoded) !== input.data
      )
        throw new Error("Invalid image encoding");
      const result = validate(
        StickerFavoriteResultSchema,
        await backend.upload(input, allowed),
      );
      if (!result.favorite) throw new Error("Invalid favorite result");
      return reply(result);
    }
    if (path === "/stage") {
      const input = validate(StickerStageSchema, value);
      if (input.sessionId !== owner.sessionId)
        return new Response(null, { status: 403, headers });
      return reply(
        validateStickerStageResult(await backend.stage(input, allowed), input),
      );
    }
    return new Response("Not found", { status: 404, headers });
  } catch {
    if (!(await allowed()))
      return new Response("Unauthorized", { status: 403, headers });
    return new Response("Sticker request failed", { status: 400, headers });
  }
}
