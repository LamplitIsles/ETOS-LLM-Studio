import { Type, type Static } from "typebox";
const MediaIdSchema = Type.String({ pattern: "^[A-Za-z0-9_-]{1,100}$" });
const OperationIdSchema = Type.String({
  pattern:
    "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
});
import { validate } from "./validation.ts";

export const MAX_FILES_PER_MESSAGE = 6;
export const MAX_FILE_BYTES = 100_000_000;
export const MAX_MESSAGE_FILE_BYTES = 200_000_000;
export const FILE_DOWNLOAD_PATH = "/api/chat/files/";
const object = { additionalProperties: false } as const;
export const FileLimitsSchema = Type.Object(
  {
    maxFilesPerMessage: Type.Integer({
      minimum: 1,
      maximum: MAX_FILES_PER_MESSAGE,
    }),
    maxFileBytes: Type.Integer({ minimum: 1, maximum: MAX_FILE_BYTES }),
    maxMessageFileBytes: Type.Integer({
      minimum: 1,
      maximum: MAX_MESSAGE_FILE_BYTES,
    }),
  },
  object,
);
export const FileRefSchema = Type.Object(
  {
    attachmentId: MediaIdSchema,
    name: Type.String({ minLength: 1, maxLength: 200 }),
    mediaType: Type.String({ maxLength: 255 }),
    size: Type.Integer({ minimum: 0, maximum: MAX_FILE_BYTES }),
    availability: Type.Union([
      Type.Literal("available"),
      Type.Literal("missing"),
    ]),
  },
  object,
);
export const FileUploadResultSchema = Type.Object(
  {
    sessionId: Type.String({ minLength: 1, maxLength: 300 }),
    operationId: OperationIdSchema,
    files: Type.Array(
      Type.Object(
        {
          id: MediaIdSchema,
          order: Type.Integer({
            minimum: 0,
            maximum: MAX_FILES_PER_MESSAGE - 1,
          }),
          ref: FileRefSchema,
        },
        object,
      ),
      { minItems: 1, maxItems: MAX_FILES_PER_MESSAGE },
    ),
  },
  object,
);
export type FileLimits = Static<typeof FileLimitsSchema>;
export type FileRef = Static<typeof FileRefSchema>;
export type FileUploadResult = Static<typeof FileUploadResultSchema>;
export function fileDownloadUrl(id: string): string {
  return `${FILE_DOWNLOAD_PATH}${validate(MediaIdSchema, id)}`;
}
export function validateFileUploadResult(
  value: unknown,
  input: FileManifest,
): FileUploadResult {
  const result = validate(FileUploadResultSchema, value);
  if (
    result.sessionId !== input.sessionId ||
    result.operationId !== input.operationId ||
    result.files.length !== input.files.length ||
    new Set(result.files.map((f) => f.ref.attachmentId)).size !==
      result.files.length ||
    result.files.some((file, index) => {
      const source = input.files[index];
      return (
        !source ||
        file.id !== source.id ||
        file.order !== index ||
        file.ref.name !== source.name ||
        file.ref.mediaType !== source.mediaType ||
        file.ref.size !== source.size ||
        file.ref.availability !== "available"
      );
    })
  )
    throw new Error("Invalid file upload result");
  return result;
}

/** The stream protocol uses ordered array positions; no bytes or digest in the manifest. */
export const FILE_OPERATIONS_PATH = "/api/chat/file-operations";
export const MAX_FILE_MANIFEST_BYTES = 32_768;
export const FileManifestSchema = Type.Object(
  {
    sessionId: Type.String({ minLength: 1, maxLength: 300 }),
    operationId: OperationIdSchema,
    files: Type.Array(
      Type.Object(
        {
          id: MediaIdSchema,
          name: Type.String({ minLength: 1, maxLength: 200 }),
          mediaType: Type.String({ maxLength: 255 }),
          size: Type.Integer({ minimum: 0, maximum: MAX_FILE_BYTES }),
        },
        object,
      ),
      { minItems: 1, maxItems: MAX_FILES_PER_MESSAGE },
    ),
  },
  object,
);
export type FileManifest = Static<typeof FileManifestSchema>;
export function validateFileManifest(
  value: unknown,
  limits: FileLimits,
): FileManifest {
  const input = validate(FileManifestSchema, value);
  validate(FileLimitsSchema, limits);
  if (
    input.files.length > limits.maxFilesPerMessage ||
    new Set(input.files.map((f) => f.id)).size !== input.files.length ||
    input.files.some((f) => f.size > limits.maxFileBytes) ||
    input.files.reduce((sum, f) => sum + f.size, 0) > limits.maxMessageFileBytes
  )
    throw new Error("Invalid file manifest limits");
  return input;
}
export function fileOperationUrl(operationId: string): string {
  return `${FILE_OPERATIONS_PATH}/${validate(OperationIdSchema, operationId)}`;
}
export function fileOperationFileUrl(operationId: string, id: string): string {
  return `${fileOperationUrl(operationId)}/files/${validate(MediaIdSchema, id)}`;
}

export function sameFileManifest(a: FileManifest, b: FileManifest): boolean {
  return (
    a.sessionId === b.sessionId &&
    a.operationId === b.operationId &&
    a.files.length === b.files.length &&
    a.files.every((f, i) => {
      const other = b.files[i];
      return (
        !!other &&
        f.id === other.id &&
        f.name === other.name &&
        f.mediaType === other.mediaType &&
        f.size === other.size
      );
    })
  );
}

/** Permanent scoped retirement; a new operation requires an explicit user action. */
export const FILE_OPERATION_RETIRED_CODE = "file_operation_retired";
export const FILE_OPERATION_RETIRED_MESSAGE =
  "File operation retired; start a new attempt explicitly.";
export class FileOperationRetiredError extends Error {
  readonly code = FILE_OPERATION_RETIRED_CODE;
  constructor() {
    super(FILE_OPERATION_RETIRED_MESSAGE);
    this.name = "FileOperationRetiredError";
  }
}

/** Hide missing and other-scope operations on mutation routes. */
export class FileOperationNotFoundError extends Error {
  constructor() {
    super("File operation not found");
    this.name = "FileOperationNotFoundError";
  }
}
