export * from "./a2ui.ts";
export * from "./appearance.ts";
export * from "./search.ts";
import type { SearchBackend } from "./search.ts";
import { ReminderSourceSchema, type PanelBackend } from "./panels.ts";
export * from "./panels.ts";
export * from "./images.ts";
export * from "./files.ts";
import {
  FileRefSchema,
  FileLimitsSchema,
  MAX_FILES_PER_MESSAGE,
  MAX_MESSAGE_FILE_BYTES,
} from "./files.ts";
export * from "./stickers.ts";
export * from "./workspace-images.ts";
export * from "./workspace-media.ts";
export * from "./compact.ts";
import {
  ContextUsageSchema,
  CompactionSchema,
  type CompactInput,
  type CompactResult,
} from "./compact.ts";
import {
  OperationIdSchema,
  ImageRefSchema,
  ImageLimitsSchema,
} from "./images.ts";
import { Type, type Static } from "typebox";
import { Format } from "typebox/format";
import { validate } from "./validation.ts";
export { validate } from "./validation.ts";
import {
  defineService,
  type ReplicatedState,
  type Context,
} from "@earendil-works/chord";

export const PROTOCOL_VERSION = 2;
export const CHAT_PATH = "/api/chat/socket";
export const PAGE_SIZE = 30;
const Id = Type.String({ minLength: 1, maxLength: 300 });
const NullableId = Type.Union([Id, Type.Null()]);
export const SubmissionSchema = Type.Object(
  {
    operationId: OperationIdSchema,
    text: Type.String({ maxLength: 16000 }),
    images: Type.Optional(Type.Array(ImageRefSchema, { maxItems: 6 })),
    files: Type.Optional(
      Type.Array(FileRefSchema, { maxItems: MAX_FILES_PER_MESSAGE }),
    ),
  },
  { additionalProperties: false },
);
export const ReceiptSchema = Type.Object(
  {
    operationId: OperationIdSchema,
    attempt: Type.Integer({ minimum: 1, maximum: Number.MAX_SAFE_INTEGER }),
    state: Type.Union([Type.Literal("submitted"), Type.Literal("failed")]),
    messageId: NullableId,
    turnId: NullableId,
    error: Type.Union([Type.String(), Type.Null()]),
  },
  { additionalProperties: false },
);
export function validateReceipt(value: unknown): Static<typeof ReceiptSchema> {
  return validate(ReceiptSchema, value);
}
export function validateLookup(
  value: unknown,
): Static<typeof ReceiptSchema> | null {
  return value === null ? null : validateReceipt(value);
}
// Native Keet labels are single-line names bounded to 512 Unicode code points.
const KeetLabelSchema = Type.String({
  minLength: 1,
  maxLength: 512,
  pattern: "^(?!.*[\\r\\n\\u2028\\u2029])(?=.*\\S).+$",
});
export const KeetSourceSchema = Type.Object(
  {
    kind: Type.Literal("keet"),
    channel: Type.Union([Type.Literal("dm"), Type.Literal("group")]),
    senderLabel: KeetLabelSchema,
    destination: KeetLabelSchema,
  },
  { additionalProperties: false },
);
// JSON Schema length counts code points; the gateway capacity counts UTF-16 units.
Format.Set("matrix-label", (value) => value.length <= 255);
const MatrixLabelSchema = Type.String({
  maxLength: 255,
  format: "matrix-label",
});
export const MatrixSourceSchema = Type.Object(
  {
    kind: Type.Literal("matrix"),
    senderId: Type.String({ ...MatrixLabelSchema, minLength: 1 }),
    senderDisplayName: MatrixLabelSchema,
    roomId: Type.String({ ...MatrixLabelSchema, minLength: 1 }),
  },
  { additionalProperties: false },
);
export type MatrixSource = Static<typeof MatrixSourceSchema>;
// Post IDs match the canonical producer's 256 UTF-16-unit capacity.
Format.Set("post-native-id", (value) => value.length <= 256);
const PostNativeIdSchema = Type.String({
  minLength: 1,
  maxLength: 256,
  format: "post-native-id",
});
// JSON Schema length counts Unicode code points. Producers normalize names.
const PostDisplayNameSchema = Type.String({
  minLength: 1,
  maxLength: 256,
  pattern: "\\S",
});
export const PostSourceSchema = Type.Object(
  {
    kind: Type.Literal("post"),
    platform: Type.Union([Type.Literal("qq"), Type.Literal("matrix")]),
    conversationType: Type.Union([
      Type.Literal("group"),
      Type.Literal("direct"),
    ]),
    conversationId: PostNativeIdSchema,
    conversationName: Type.Optional(PostDisplayNameSchema),
    senderId: PostNativeIdSchema,
    senderDisplayName: Type.Optional(PostDisplayNameSchema),
  },
  { additionalProperties: false },
);
export type PostSource = Static<typeof PostSourceSchema>;
export const MessageSourceSchema = Type.Union([
  ReminderSourceSchema,
  KeetSourceSchema,
  MatrixSourceSchema,
  PostSourceSchema,
]);
export type KeetSource = Static<typeof KeetSourceSchema>;
export type MessageSource = Static<typeof MessageSourceSchema>;

export const VoiceRefSchema = Type.Object(
  {
    id: Type.String({
      minLength: 64,
      maxLength: 64,
      pattern: "^[0-9a-f]{64}$",
    }),
  },
  { additionalProperties: false },
);
export type VoiceRef = Static<typeof VoiceRefSchema>;

export const MessageSchema = Type.Object(
  {
    images: Type.Optional(Type.Array(ImageRefSchema)),
    files: Type.Optional(
      Type.Array(FileRefSchema, { maxItems: MAX_FILES_PER_MESSAGE }),
    ),
    imageState: Type.Optional(
      Type.Union([
        Type.Literal("preparing"),
        Type.Literal("ready"),
        Type.Literal("failed"),
        Type.Literal("unknown"),
      ]),
    ),
    textState: Type.Optional(
      Type.Union([Type.Literal("streaming"), Type.Literal("complete")]),
    ),
    voice: Type.Optional(VoiceRefSchema),
    /** Untrusted UI is validated per message with validateA2UISurface. */
    ui: Type.Optional(Type.Unknown()),
    source: Type.Optional(MessageSourceSchema),
    id: Id,
    role: Type.Union([
      Type.Literal("user"),
      Type.Literal("agent"),
      Type.Literal("notice"),
    ]),
    text: Type.String(),
    /** Required on delivered ordinary replies; raw backend input may omit these UTF-16 ends. */
    ends: Type.Optional(Type.Array(Type.Integer({ minimum: 1 }))),
    thinking: Type.Optional(Type.String()),
    createdAt: Type.Number(),
    operationId: NullableId,
    turnId: NullableId,
  },
  {
    additionalProperties: false,
    allOf: [
      {
        if: { required: ["ui"] },
        then: {
          properties: { role: { const: "agent" }, text: { const: "" } },
          not: { anyOf: [
            { required: ["source"] }, { required: ["voice"] },
            { required: ["images"] }, { required: ["files"] },
            { required: ["imageState"] }, { required: ["textState"] },
            { required: ["ends"] },
          ] },
        },
      },
      {
        if: { required: ["imageState"] },
        then: {
          properties: { role: { const: "agent" } },
          allOf: [
            {
              if: { properties: { imageState: { const: "ready" } } },
              then: {
                required: ["images"],
                properties: {
                  images: {
                    minItems: 1,
                    maxItems: 1,
                    items: {
                      properties: { availability: { const: "available" } },
                    },
                  },
                },
              },
              else: { not: { required: ["images"] } },
            },
          ],
        },
      },
    ],
  },
);
export const PageSchema = Type.Object(
  {
    messages: Type.Array(MessageSchema, { maxItems: PAGE_SIZE }),
    before: NullableId,
  },
  { additionalProperties: false },
);
/** Transient answer-only preview; the host supplies its UTF-16 segment ends. */
export const StreamingReplySchema = Type.Object(
  { id: Id, turnId: NullableId, createdAt: Type.Number(), text: Type.String(), ends: Type.Optional(Type.Array(Type.Integer({ minimum: 1 }))) },
  { additionalProperties: false },
);
export type StreamingReply = Static<typeof StreamingReplySchema>;
export const ViewSchema = Type.Object(
  {
    version: Type.Literal(PROTOCOL_VERSION),
    sessionId: Id,
    name: Type.String(),
    activeTurnId: NullableId,
    streamingReply: Type.Optional(StreamingReplySchema),
    /** Explicit final-body evidence for the active turn, independent of execution. */
    replyCompletedTurnId: Type.Optional(Id),
    contextUsage: ContextUsageSchema,
    compaction: CompactionSchema,
    messages: Type.Array(MessageSchema, { maxItems: PAGE_SIZE }),
    before: NullableId,
    capabilities: Type.Object(
      {
        text: Type.Literal(true),
        steer: Type.Literal(true),
        stop: Type.Literal(true),
        images: Type.Union([Type.Literal(false), ImageLimitsSchema]),
        files: Type.Optional(
          Type.Union([Type.Literal(false), FileLimitsSchema]),
        ),
        workspaceImages: Type.Optional(Type.Literal(true)),
      },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);
export type Submission = Static<typeof SubmissionSchema>;
export const LookupSchema = Type.Union([ReceiptSchema, Type.Null()]);
export type Receipt = Static<typeof ReceiptSchema>;
export type ChatMessage = Static<typeof MessageSchema>;
export type HistoryPage = Static<typeof PageSchema>;
export type ChatView = Static<typeof ViewSchema>;
type PanelService = {
  [K in keyof PanelBackend]: (
    input: Parameters<PanelBackend[K]>[0],
    context: Context,
  ) => ReturnType<PanelBackend[K]>;
};
type SearchService = {
  [K in keyof SearchBackend]: (
    input: Parameters<SearchBackend[K]>[0],
    context: Context,
  ) => ReturnType<SearchBackend[K]>;
};
export interface ChatService extends PanelService, SearchService {
  view: ReplicatedState<ChatView>;
  compact(input: CompactInput, context: Context): Promise<CompactResult>;
  history(before: string, context: Context): Promise<HistoryPage>;
  submit(input: Submission, context: Context): Promise<Receipt>;
  lookup(operationId: string, context: Context): Promise<Receipt | null>;
  stop(turnId: string, context: Context): Promise<{ stopped: boolean }>;
}
export const Chat = defineService<ChatService>("lamplit.chat.v2");
export function validateId(value: unknown): string {
  return validate(Id, value);
}
export const capabilities: ChatView["capabilities"] = {
  text: true,
  steer: true,
  stop: true,
  images: false,
};

/** Optional attachments are omitted for ordinary text. */
export function validateSubmission(value: unknown): Submission {
  const input = validate(SubmissionSchema, value);
  if (!input.text.trim() && !input.images?.length && !input.files?.length)
    throw new Error("Empty message");
  if (
    input.images &&
    (new Set(input.images.map((r) => r.attachmentId)).size !==
      input.images.length ||
      input.images.some((r) => r.availability !== "available"))
  )
    throw new Error("Invalid submitted images");
  if (
    input.files &&
    (new Set(input.files.map((file) => file.attachmentId)).size !==
      input.files.length ||
      input.files.some((file) => file.availability !== "available") ||
      input.files.reduce((sum, file) => sum + file.size, 0) >
        MAX_MESSAGE_FILE_BYTES)
  )
    throw new Error("Invalid submitted files");
  if (
    input.text === "/compact" &&
    !input.images?.length &&
    !input.files?.length
  )
    throw new Error("Use native compact command");
  return input;
}
