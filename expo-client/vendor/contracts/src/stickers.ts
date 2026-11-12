import { Type, type Static } from "typebox";
import {
  ImageRefSchema,
  ImageTypeSchema,
  OperationIdSchema,
  StickerIdentitySchema,
  StickerIdSchema,
  StickerVersionSchema,
} from "./images.ts";
import { validate } from "./validation.ts";
export { StickerIdSchema, StickerVersionSchema } from "./images.ts";

const object = <T extends Record<string, import("typebox").TSchema>>(
  fields: T,
) => Type.Object(fields, { additionalProperties: false });
export const STICKER_PAGE_LIMIT = 30;
export const STICKER_ZIP_MAX_BYTES = 32 * 1024 * 1024;
export const STICKER_UPLOAD_MAX_BYTES = 5 * 1024 * 1024;
const session = Type.String({ minLength: 1, maxLength: 300 });
const cursor = Type.Union([
  Type.String({ minLength: 1, maxLength: 300, pattern: "^[A-Za-z0-9_-]+$" }),
  Type.Null(),
]);
const query = Type.String({ maxLength: 100 });
const label = Type.String({ minLength: 1, maxLength: 160, pattern: "\\S" });
const tag = Type.String({ minLength: 1, maxLength: 80, pattern: "\\S" });
const tags = Type.Array(tag, { maxItems: 32, uniqueItems: true });
export const StickerPageRequestSchema = object({
  sessionId: session,
  cursor,
  limit: Type.Integer({ minimum: 1, maximum: STICKER_PAGE_LIMIT }),
  query: Type.Optional(query),
});
export const StickerPackRequestSchema = object({
  sessionId: session,
  packId: StickerIdSchema,
  cursor,
  limit: Type.Integer({ minimum: 1, maximum: STICKER_PAGE_LIMIT }),
});
export const StickerSchema = object({
  id: StickerIdSchema,
  version: StickerVersionSchema,
  name: label,
  tags,
  mediaType: ImageTypeSchema,
  available: Type.Boolean(),
});
export const StickerPackSchema = object({
  id: StickerIdSchema,
  name: label,
  description: Type.String({ maxLength: 2000 }),
  cover: StickerSchema,
});
export const StickerPackPageSchema = object({
  packs: Type.Array(StickerPackSchema, { maxItems: STICKER_PAGE_LIMIT }),
  nextCursor: cursor,
});
export const StickerPageSchema = object({
  stickers: Type.Array(StickerSchema, { maxItems: STICKER_PAGE_LIMIT }),
  nextCursor: cursor,
});
export const StickerFavoriteSchema = object({
  sessionId: session,
  stickerId: StickerIdSchema,
  favorite: Type.Boolean(),
});
export const StickerFavoriteResultSchema = object({
  sticker: StickerSchema,
  favorite: Type.Boolean(),
});
export const StickerFavoriteImageSchema = object({
  sessionId: session,
  imageId: StickerIdSchema,
  name: label,
  tags,
});
export const StickerUploadSchema = object({
  sessionId: session,
  name: label,
  tags,
  mediaType: ImageTypeSchema,
  data: Type.String({
    minLength: 4,
    maxLength: 4 * Math.ceil(STICKER_UPLOAD_MAX_BYTES / 3),
    pattern: "^[A-Za-z0-9+/]*={0,2}$",
  }),
});
export const StickerImportResultSchema = object({
  pack: StickerPackSchema,
  count: Type.Integer({ minimum: 1, maximum: 500 }),
});
export const StickerStageSchema = object({
  sessionId: session,
  operationId: OperationIdSchema,
  sticker: StickerIdentitySchema,
});
export const StickerStageResultSchema = object({
  sessionId: session,
  operationId: OperationIdSchema,
  image: ImageRefSchema,
});
export type Sticker = Static<typeof StickerSchema>;
export type StickerPack = Static<typeof StickerPackSchema>;
export type StickerPage = Static<typeof StickerPageSchema>;
export type StickerPackPage = Static<typeof StickerPackPageSchema>;
export type StickerStage = Static<typeof StickerStageSchema>;
export type StickerStageResult = Static<typeof StickerStageResultSchema>;

/** Only versioned, same-origin media endpoints are exposed; paths never come from the host filesystem. */
export function stickerMediaUrl(
  version: string,
  variant: "original" | "thumbnail",
): string {
  const hash = validate(StickerVersionSchema, version);
  if (variant !== "original" && variant !== "thumbnail")
    throw new Error("Invalid sticker variant");
  return `/api/stickers/media/${hash}/${variant}`;
}

/** A stage response must refer to exactly the requested immutable sticker version. */
export function validateStickerStageResult(
  raw: unknown,
  request: StickerStage,
): StickerStageResult {
  const input = validate(StickerStageSchema, request);
  const result = validate(StickerStageResultSchema, raw);
  if (
    result.sessionId !== input.sessionId ||
    result.operationId !== input.operationId ||
    result.image.availability !== "available" ||
    result.image.sticker?.id !== input.sticker.id ||
    result.image.sticker.version !== input.sticker.version
  )
    throw new Error("Invalid sticker stage result");
  return result;
}

export type StickerPageRequest = Static<typeof StickerPageRequestSchema>;
export type StickerPackRequest = Static<typeof StickerPackRequestSchema>;
export type StickerFavorite = Static<typeof StickerFavoriteSchema>;
export type StickerFavoriteImage = Static<typeof StickerFavoriteImageSchema>;
export type StickerUpload = Static<typeof StickerUploadSchema>;
export type StickerImportResult = Static<typeof StickerImportResultSchema>;
export type StickerFavoriteResult = Static<typeof StickerFavoriteResultSchema>;
/** All mutations must recheck the supplied authorization guard at their commit point. */
export interface StickerBackend {
  packs(input: StickerPageRequest): Promise<StickerPackPage>;
  pack(input: StickerPackRequest): Promise<StickerPage>;
  search(input: StickerPageRequest): Promise<StickerPage>;
  favorites(input: StickerPageRequest): Promise<StickerPage>;
  favorite(
    input: StickerFavorite,
    authorizeCommit: () => Promise<boolean>,
  ): Promise<StickerFavoriteResult>;
  favoriteImage(
    input: StickerFavoriteImage,
    authorizeCommit: () => Promise<boolean>,
  ): Promise<StickerFavoriteResult>;
  upload(
    input: StickerUpload,
    authorizeCommit: () => Promise<boolean>,
  ): Promise<StickerFavoriteResult>;
  importZip(
    sessionId: string,
    bytes: Uint8Array,
    authorizeCommit: () => Promise<boolean>,
  ): Promise<StickerImportResult>;
  stage(
    input: StickerStage,
    authorizeCommit: () => Promise<boolean>,
  ): Promise<StickerStageResult>;
  media(
    version: string,
    variant: "original" | "thumbnail",
  ): Promise<{ bytes: Uint8Array; mediaType: string } | null>;
}
