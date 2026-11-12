import { Type, type Static } from "typebox";
const Id = Type.String({ minLength: 1, maxLength: 300 });
const Count = Type.Number({ minimum: 0, maximum: Number.MAX_SAFE_INTEGER });
/** Active native context, never accumulated billing. Null remains null on wire. */
export const ContextUsageSchema = Type.Object(
  {
    tokens: Type.Union([Count, Type.Null()]),
    capacity: Type.Union([
      Type.Number({ exclusiveMinimum: 0, maximum: Number.MAX_SAFE_INTEGER }),
      Type.Null(),
    ]),
  },
  { additionalProperties: false },
);
/** Native lifecycle facts only; identity may be absent in an engine. */
export const CompactionSchema = Type.Union([
  Type.Null(),
  Type.Object(
    {
      id: Type.Union([Id, Type.Null()]),
      status: Type.Union([
        Type.Literal("running"),
        Type.Literal("complete"),
        Type.Literal("failed"),
      ]),
    },
    { additionalProperties: false },
  ),
]);
export const CompactInputSchema = Type.Object(
  { sessionId: Id },
  { additionalProperties: false },
);
export const CompactResultSchema = Type.Object(
  { sessionId: Id, accepted: Type.Boolean() },
  { additionalProperties: false },
);
export type ContextUsage = Static<typeof ContextUsageSchema>;
export type Compaction = Static<typeof CompactionSchema>;
export type CompactInput = Static<typeof CompactInputSchema>;
export type CompactResult = Static<typeof CompactResultSchema>;
