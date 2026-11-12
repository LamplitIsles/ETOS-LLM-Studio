import type { Static, TSchema } from "typebox";
import { Value } from "typebox/value";
export function validate<T extends TSchema>(
  schema: T,
  value: unknown,
): Static<T> {
  if (!Value.Check(schema, value)) throw new Error("Invalid chat payload");
  return value as Static<T>;
}
