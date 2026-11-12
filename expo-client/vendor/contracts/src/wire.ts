import {
  isJsonValue,
  parseServiceCall,
  type ServiceCall,
} from "@earendil-works/chord";
export const MAX_FRAME_BYTES = 2 * 1024 * 1024;
export interface WireSocket {
  readonly bufferedAmount?: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}
export function decodeFrame(raw: string): Record<string, unknown> {
  if (new TextEncoder().encode(raw).byteLength > MAX_FRAME_BYTES)
    throw new Error("Frame too large");
  const value: unknown = JSON.parse(raw);
  if (
    !isJsonValue(value) ||
    !value ||
    typeof value !== "object" ||
    Array.isArray(value)
  )
    throw new Error("Invalid frame");
  return value;
}
export function readCall(value: unknown): ServiceCall {
  return parseServiceCall(value);
}
export function sendFrame(socket: WireSocket, frame: unknown): void {
  const raw = JSON.stringify(frame);
  if (new TextEncoder().encode(raw).byteLength > MAX_FRAME_BYTES)
    throw new Error("Frame too large");
  socket.send(raw);
}
