import { Type, type Static } from "typebox";
import { validate } from "./validation.ts";
export const UPLOAD_PATH = "/api/chat/images";
export const MEDIA_PATH = "/api/chat/media/";
const object = { additionalProperties: false } as const;
export const OperationIdSchema = Type.String({
  pattern:
    "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
});
export const MediaIdSchema = Type.String({ pattern: "^[A-Za-z0-9_-]{1,100}$" });
export const ImageTypeSchema = Type.Union([
  Type.Literal("image/png"),
  Type.Literal("image/jpeg"),
  Type.Literal("image/webp"),
  Type.Literal("image/gif"),
]);
export const ImageLimitsSchema = Type.Object(
  {
    mediaTypes: Type.Array(ImageTypeSchema, {
      minItems: 1,
      maxItems: 4,
      uniqueItems: true,
    }),
    maxImagesPerMessage: Type.Integer({ minimum: 1, maximum: 6 }),
    maxImageBytes: Type.Integer({ minimum: 1, maximum: 8_000_000 }),
    maxMessageImageBytes: Type.Integer({ minimum: 1, maximum: 24_000_000 }),
  },
  object,
);
export const StickerIdSchema = Type.String({
  pattern: "^[A-Za-z0-9_-]{1,100}$",
});
export const StickerVersionSchema = Type.String({ pattern: "^[a-f0-9]{64}$" });
/** Immutable sticker identity on a staged or historical image reference. */
export const StickerIdentitySchema = Type.Object(
  {
    id: StickerIdSchema,
    version: StickerVersionSchema,
  },
  object,
);
export type StickerIdentity = Static<typeof StickerIdentitySchema>;
export const ImageRefSchema = Type.Object(
  {
    attachmentId: MediaIdSchema,
    sticker: Type.Optional(StickerIdentitySchema),
    mediaType: ImageTypeSchema,
    name: Type.String({ minLength: 1, maxLength: 200 }),
    availability: Type.Union([
      Type.Literal("available"),
      Type.Literal("missing"),
    ]),
  },
  object,
);
const base64 = (bytes: number) =>
  Type.String({
    minLength: 4,
    maxLength: 4 * Math.ceil(bytes / 3),
    pattern: "^[A-Za-z0-9+/]*={0,2}$",
  });
export const UploadSchema = Type.Object(
  {
    sessionId: Type.String({ minLength: 1, maxLength: 300 }),
    operationId: OperationIdSchema,
    images: Type.Array(
      Type.Object(
        {
          id: MediaIdSchema,
          order: Type.Integer({ minimum: 0, maximum: 5 }),
          name: Type.String({ minLength: 1, maxLength: 200 }),
          mediaType: ImageTypeSchema,
          original: base64(8_000_000),
          preview: base64(160_000),
          model: base64(320_000),
        },
        object,
      ),
      { minItems: 1, maxItems: 6 },
    ),
  },
  object,
);
export const UploadResultSchema = Type.Object(
  {
    sessionId: Type.String({ minLength: 1, maxLength: 300 }),
    operationId: OperationIdSchema,
    images: Type.Array(
      Type.Object(
        {
          id: MediaIdSchema,
          order: Type.Integer({ minimum: 0, maximum: 5 }),
          ref: ImageRefSchema,
        },
        object,
      ),
      { minItems: 1, maxItems: 6 },
    ),
  },
  object,
);
export type ImageLimits = Static<typeof ImageLimitsSchema>;
export type ImageRef = Static<typeof ImageRefSchema>;
export type ImageUpload = Static<typeof UploadSchema>;
export type ImageUploadResult = Static<typeof UploadResultSchema>;
export function validateUploadResult(
  value: unknown,
  input: {
    sessionId: string;
    operationId: string;
    images: readonly Pick<
      ImageUpload["images"][number],
      "id" | "order" | "name" | "mediaType"
    >[];
  },
): ImageUploadResult {
  const result = validate(UploadResultSchema, value);
  if (
    result.sessionId !== input.sessionId ||
    result.operationId !== input.operationId ||
    result.images.length !== input.images.length ||
    new Set(input.images.map((item) => item.id)).size !== input.images.length ||
    input.images.some((item, index) => item.order !== index) ||
    new Set(result.images.map((item) => item.id)).size !==
      result.images.length ||
    new Set(result.images.map((item) => item.ref.attachmentId)).size !==
      result.images.length ||
    result.images.some((item, index) => {
      const draft = input.images[index];
      return (
        !draft ||
        item.id !== draft.id ||
        item.order !== draft.order ||
        item.ref.name !== draft.name ||
        item.ref.mediaType !== draft.mediaType ||
        item.ref.availability !== "available"
      );
    })
  )
    throw new Error("Invalid upload result");
  return result;
}
export const MAX_UPLOAD_BODY_BYTES = 36_000_000;
export function mediaUrl(
  id: string,
  variant: "original" | "preview" | "model" = "original",
) {
  return `${MEDIA_PATH}${validate(MediaIdSchema, id)}/${variant}`;
}
export function validateUpload(
  value: unknown,
  limits: ImageLimits,
): ImageUpload {
  const input = validate(UploadSchema, value);
  validate(ImageLimitsSchema, limits);
  let total = 0;
  const ids = new Set<string>();
  if (input.images.length > limits.maxImagesPerMessage)
    throw new Error("Too many images");
  input.images.forEach((image, order) => {
    const bytes = (data: string) => {
      if (data.length % 4) throw new Error("Invalid base64 length");
      return (
        (data.length / 4) * 3 -
        (data.endsWith("==") ? 2 : data.endsWith("=") ? 1 : 0)
      );
    };
    const size = bytes(image.original);
    total += size;
    if (
      image.order !== order ||
      ids.has(image.id) ||
      !limits.mediaTypes.includes(image.mediaType) ||
      size > limits.maxImageBytes ||
      bytes(image.preview) > 160_000 ||
      bytes(image.model) > 320_000
    )
      throw new Error("Invalid image limits/order");
    const signature = (data: string) =>
      Uint8Array.from(atob(data.slice(0, 32)), (c) => c.charCodeAt(0));
    const jpeg = (data: string) => {
      const b = signature(data);
      return b[0] === 255 && b[1] === 216 && b[2] === 255;
    };
    const original = signature(image.original);
    const validOriginal =
      image.mediaType === "image/jpeg"
        ? jpeg(image.original)
        : image.mediaType === "image/png"
          ? [137, 80, 78, 71, 13, 10, 26, 10].every((b, i) => original[i] === b)
          : image.mediaType === "image/gif"
            ? new TextDecoder()
                .decode(original.slice(0, 6))
                .match(/^GIF8[79]a$/)
            : new TextDecoder().decode(original.slice(0, 4)) === "RIFF" &&
              new TextDecoder().decode(original.slice(8, 12)) === "WEBP";
    if (!validOriginal || !jpeg(image.preview) || !jpeg(image.model))
      throw new Error("Invalid image bytes");
    ids.add(image.id);
  });
  if (
    total > limits.maxMessageImageBytes ||
    new TextEncoder().encode(JSON.stringify(input)).length >
      MAX_UPLOAD_BODY_BYTES
  )
    throw new Error("Images too large");
  return input;
}
