import { Type, type Static } from "typebox";
import { validate } from "./validation.ts";
const object = <T extends Record<string, import("typebox").TSchema>>(
  fields: T,
) => Type.Object(fields, { additionalProperties: false });
const id = Type.String({ minLength: 1, maxLength: 300 });
const cursor = Type.Union([id, Type.Null()]);
const epoch = Type.Integer({ minimum: 0, maximum: 8640000000000000 });
const mood = Type.Union([
  Type.Literal("neutral"),
  Type.Literal("serene"),
  Type.Literal("bright"),
  Type.Literal("playful"),
  Type.Literal("tender"),
  Type.Literal("pensive"),
  Type.Literal("tired"),
  Type.Literal("low"),
]);
const note = Type.Optional(Type.String({ maxLength: 40 }));
const reason = Type.Optional(Type.String({ maxLength: 160 }));
export const PANEL_LIMITS = {
  relationship: 20,
  diary: 30,
  album: 30,
  reminders: 100,
  diaryBytes: 128 * 1024,
} as const;
export const PanelReadSchema = object({ sessionId: id, cursor });
export const SessionReadSchema = object({ sessionId: id });
export const DiaryNameSchema = Type.String({
  pattern: "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\\.md$",
});
export const DiaryReadSchema = object({ sessionId: id, name: DiaryNameSchema });
export const RelationshipStateSchema = object({
  mood,
  note,
  affinity: Type.Integer({ minimum: 0, maximum: 100 }),
  signature: Type.String({ maxLength: 80 }),
});
export const RelationshipRecordSchema = object({
  at: Type.String({ minLength: 1, maxLength: 40 }),
  state: RelationshipStateSchema,
  changes: object({
    seed: Type.Optional(Type.Literal(true)),
    mood: Type.Optional(object({ value: mood, note, reason })),
    affinity: Type.Optional(
      object({
        delta: Type.Integer({ minimum: -10, maximum: 10 }),
        value: Type.Integer({ minimum: 0, maximum: 100 }),
        reason,
      }),
    ),
    signature: Type.Optional(
      object({ value: Type.String({ maxLength: 80 }), reason }),
    ),
  }),
});
export const RelationshipSchema = object({
  scope: id,
  current: RelationshipStateSchema,
});
export const RelationshipHistorySchema = object({
  scope: id,
  records: Type.Array(RelationshipRecordSchema, { maxItems: 20 }),
  nextCursor: cursor,
  predecessor: Type.Union([RelationshipRecordSchema, Type.Null()]),
});
export const DiaryPageSchema = object({
  entries: Type.Array(DiaryNameSchema, { maxItems: 30 }),
  nextCursor: cursor,
});
export const DiaryEntrySchema = Type.Union([
  object({
    status: Type.Literal("found"),
    name: DiaryNameSchema,
    text: Type.String({ maxLength: 128 * 1024 }),
  }),
  object({ status: Type.Literal("missing"), name: DiaryNameSchema }),
  object({ status: Type.Literal("too-large"), name: DiaryNameSchema }),
]);
// Relative URLs only. Hosts authorize every request, including save-original requests.
const imageUrl = Type.String({
  minLength: 1,
  maxLength: 2000,
  pattern: "^/api/[^\\\\\\s?#]+(?:\\?[^\\\\\\s#]*)?$",
});
export const AlbumImageSchema = object({
  id,
  filename: Type.String({ minLength: 1, maxLength: 300 }),
  createdAt: epoch,
  origin: Type.Union([
    Type.Literal("human"),
    Type.Literal("agent"),
    Type.Literal("historical"),
    Type.Literal("unknown"),
  ]),
  available: Type.Boolean(),
  previewUrl: Type.Union([imageUrl, Type.Null()]),
  originalUrl: Type.Union([imageUrl, Type.Null()]),
});
export const AlbumPageSchema = object({
  images: Type.Array(AlbumImageSchema, { maxItems: 30 }),
  nextCursor: cursor,
});
const clock = {
  hour: Type.Integer({ minimum: 0, maximum: 23 }),
  minute: Type.Integer({ minimum: 0, maximum: 59 }),
  timeZone: Type.String({ minLength: 1, maxLength: 100 }),
};
export const ReminderSchema = object({
  id,
  title: Type.Optional(Type.String({ maxLength: 300 })),
  message: Type.String({ minLength: 1, maxLength: 16000 }),
  nextAt: epoch,
  schedule: Type.Union([
    object({ kind: Type.Literal("once"), at: epoch }),
    object({
      kind: Type.Literal("interval"),
      everySeconds: Type.Integer({ minimum: 1 }),
      anchor: Type.Optional(
        Type.Integer({ minimum: -8640000000000000, maximum: 8640000000000000 }),
      ),
    }),
    object({ kind: Type.Literal("daily"), ...clock }),
    object({
      kind: Type.Literal("weekly"),
      ...clock,
      weekday: Type.Integer({ minimum: 0, maximum: 6 }),
    }),
  ]),
});
export const RemindersSchema = object({
  reminders: Type.Array(ReminderSchema, { maxItems: 100 }),
});
export const ReminderSourceSchema = object({
  kind: Type.Literal("reminder"),
  reminderId: id,
  occurrenceId: Type.Optional(id),
});
export type PanelRead = Static<typeof PanelReadSchema>;
export type SessionRead = Static<typeof SessionReadSchema>;
export type DiaryRead = Static<typeof DiaryReadSchema>;
export type Relationship = Static<typeof RelationshipSchema>;
export type RelationshipHistory = Static<typeof RelationshipHistorySchema>;
export type DiaryPage = Static<typeof DiaryPageSchema>;
export type DiaryEntry = Static<typeof DiaryEntrySchema>;
export type AlbumPage = Static<typeof AlbumPageSchema>;
export type Reminder = Static<typeof ReminderSchema>;
export type Reminders = Static<typeof RemindersSchema>;
export interface PanelBackend {
  relationship(input: SessionRead): Promise<Relationship>;
  relationshipHistory(input: PanelRead): Promise<RelationshipHistory>;
  diaryList(input: PanelRead): Promise<DiaryPage>;
  diaryRead(input: DiaryRead): Promise<DiaryEntry>;
  album(input: PanelRead): Promise<AlbumPage>;
  reminders(input: SessionRead): Promise<Reminders>;
}
export const panelMethods = {
  relationship: [SessionReadSchema, RelationshipSchema],
  relationshipHistory: [PanelReadSchema, RelationshipHistorySchema],
  diaryList: [PanelReadSchema, DiaryPageSchema],
  diaryRead: [DiaryReadSchema, DiaryEntrySchema],
  album: [PanelReadSchema, AlbumPageSchema],
  reminders: [SessionReadSchema, RemindersSchema],
} as const;
export function validatePanelResult(
  method: keyof typeof panelMethods,
  raw: unknown,
) {
  const value = validate(panelMethods[method][1], raw);
  if (method === "relationshipHistory" && "records" in value) {
    for (const record of [
      ...value.records,
      ...(value.predecessor ? [value.predecessor] : []),
    ])
      if (!Number.isFinite(Date.parse(record.at)))
        throw new Error("Invalid relationship timestamp");
  }
  if (
    method === "diaryRead" &&
    "status" in value &&
    value.status === "found" &&
    new TextEncoder().encode(value.text).byteLength > PANEL_LIMITS.diaryBytes
  )
    throw new Error("Invalid diary size");
  if (method === "album" && "images" in value)
    for (const image of value.images) {
      if (image.available && (!image.previewUrl || !image.originalUrl))
        throw new Error("Missing image URL");
      for (const path of [image.previewUrl, image.originalUrl])
        if (path) {
          const url = new URL(path, "https://fixture.invalid");
          if (
            url.origin !== "https://fixture.invalid" ||
            !url.pathname.startsWith("/api/") ||
            /%2f|%5c|%2e/i.test(path) ||
            path.includes("/../") ||
            path.includes("/./")
          )
            throw new Error("Invalid image URL");
        }
    }
  if (method === "reminders" && "reminders" in value)
    for (const reminder of value.reminders)
      if ("timeZone" in reminder.schedule)
        new Intl.DateTimeFormat("en", { timeZone: reminder.schedule.timeZone });
  return value;
}
