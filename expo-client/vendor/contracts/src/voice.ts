import { Type, type Static } from "typebox";
import { Value } from "typebox/value";

/** Existing Lamplit wire semantics; independent of Chord replication. */
export const VOICE_CAPABILITY_PATH = "/api/voice/capability";
export const VOICE_STREAM_PATH = "/api/voice/stream";
export const VOICE_SAMPLE_RATE = 16_000;
export const MAX_VOICE_DURATION_MS = 300_000;
export const MAX_VOICE_PCM_BYTES = 9_600_000;
export const MAX_VOICE_FRAME_BYTES = 16 * 1024;
export const MAX_VOICE_QUEUE_BYTES = 256 * 1024;
export const MAX_VOICE_CONTROL_BYTES = 128;
export const MAX_VOICE_EVENT_BYTES = 128 * 1024;
export const VOICE_TRANSCRIPT_MAX_CHARS = 20_000;
export const VOICE_ERROR_CODES = [
  "voice_disabled",
  "config_unavailable",
  "invalid_key",
  "rate_limited",
  "upstream_error",
  "timeout",
  "cancelled",
  "invalid_audio",
  "transcript_invalid",
] as const;
const strict = { additionalProperties: false };
export const VoiceCapabilitySchema = Type.Object(
  { available: Type.Boolean() },
  strict,
);
export const VoiceControlSchema = Type.Union([
  Type.Object({ type: Type.Literal("finish") }, strict),
  Type.Object({ type: Type.Literal("cancel") }, strict),
]);
export const VoiceServerEventSchema = Type.Union([
  Type.Object({ type: Type.Literal("ready") }, strict),
  Type.Object(
    { type: Type.Literal("result"), text: Type.String({ minLength: 1 }) },
    strict,
  ),
  Type.Object(
    {
      type: Type.Literal("error"),
      code: Type.Enum(VOICE_ERROR_CODES),
    },
    strict,
  ),
]);
export type VoiceCapability = Static<typeof VoiceCapabilitySchema>;
export type VoiceControl = Static<typeof VoiceControlSchema>;
export type VoiceServerEvent = Static<typeof VoiceServerEventSchema>;
export type VoiceErrorCode = (typeof VOICE_ERROR_CODES)[number];

export function validateVoiceCapability(value: unknown): VoiceCapability {
  if (!Value.Check(VoiceCapabilitySchema, value))
    throw new Error("Invalid voice capability");
  return value as VoiceCapability;
}
export function validateVoiceControl(value: unknown): VoiceControl {
  if (!Value.Check(VoiceControlSchema, value))
    throw new Error("Invalid voice control");
  return value as VoiceControl;
}
export function validateVoiceServerEvent(value: unknown): VoiceServerEvent {
  if (!Value.Check(VoiceServerEventSchema, value))
    throw new Error("Invalid voice event");
  const event = value as VoiceServerEvent;
  if (
    event.type === "result" &&
    (!event.text.trim() ||
      Array.from(event.text).length > VOICE_TRANSCRIPT_MAX_CHARS)
  )
    throw new Error("Invalid voice transcript");
  return event;
}
function decode(raw: string, maxBytes: number): unknown {
  if (new TextEncoder().encode(raw).byteLength > maxBytes)
    throw new Error("Voice frame too large");
  return JSON.parse(raw);
}
export function parseVoiceControl(raw: string): VoiceControl {
  return validateVoiceControl(decode(raw, MAX_VOICE_CONTROL_BYTES));
}
export function parseVoiceServerEvent(raw: string): VoiceServerEvent {
  return validateVoiceServerEvent(decode(raw, MAX_VOICE_EVENT_BYTES));
}
/** Returns the new raw PCM total; hosts still enforce ready/finish lifecycle. */
export function validateVoiceFrameBytes(
  bytes: number,
  totalBytes: number,
): number {
  if (
    !Number.isSafeInteger(bytes) ||
    bytes <= 0 ||
    bytes % 2 ||
    bytes > MAX_VOICE_FRAME_BYTES ||
    !Number.isSafeInteger(totalBytes) ||
    totalBytes < 0 ||
    totalBytes % 2 ||
    totalBytes + bytes > MAX_VOICE_PCM_BYTES
  )
    throw new Error("Invalid voice audio");
  return totalBytes + bytes;
}
