import { Type, type Static } from "typebox";
import { validate } from "./validation.ts";
const Id = Type.String({ minLength: 1, maxLength: 300 });
const Kind = Type.Union([Type.Literal("message"), Type.Literal("compaction")]);
const Role = Type.Optional(
  Type.Union([Type.Literal("user"), Type.Literal("assistant")]),
);
const metadata = {
  id: Id,
  kind: Kind,
  sessionId: Id,
  sessionName: Type.Optional(Type.String()),
  role: Role,
  phase: Type.Optional(Type.String()),
  createdAt: Type.Optional(Type.String()),
};
export const SearchInputSchema = Type.Object(
  { query: Type.String({ minLength: 1, maxLength: 500 }) },
  { additionalProperties: false },
);
export const SearchReadInputSchema = Type.Object(
  { id: Id },
  { additionalProperties: false },
);
export const SearchCardSchema = Type.Object(
  {
    ...metadata,
    snippet: Type.Object(
      {
        segments: Type.Array(
          Type.Object(
            { text: Type.String(), highlighted: Type.Boolean() },
            { additionalProperties: false },
          ),
        ),
      },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);
export const SearchResultSchema = Type.Object(
  {
    hits: Type.Array(SearchCardSchema, { maxItems: 20 }),
    estimatedTotalHits: Type.Union([
      Type.Integer({ minimum: 0, maximum: Number.MAX_SAFE_INTEGER }),
      Type.Null(),
    ]),
    limited: Type.Boolean(),
  },
  { additionalProperties: false },
);
export const SearchReadResultSchema = Type.Object(
  {
    record: Type.Object(
      { ...metadata, content: Type.String() },
      { additionalProperties: false },
    ),
    context: Type.Object(
      {
        targetSourceRecordIndex: Type.Integer({ minimum: 0 }),
        truncated: Type.Boolean(),
        items: Type.Array(
          Type.Object(
            {
              sourceRecordIndex: Type.Integer({ minimum: 0 }),
              kind: Kind,
              role: Role,
              content: Type.String(),
              truncated: Type.Optional(Type.Boolean()),
            },
            { additionalProperties: false },
          ),
          { maxItems: 17 },
        ),
      },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);
export type SearchInput = Static<typeof SearchInputSchema>;
export type SearchReadInput = Static<typeof SearchReadInputSchema>;
export type SearchCard = Static<typeof SearchCardSchema>;
export type SearchResult = Static<typeof SearchResultSchema>;
export type SearchReadResult = Static<typeof SearchReadResultSchema>;
export interface SearchBackend {
  search(input: SearchInput): Promise<SearchResult>;
  searchRead(input: SearchReadInput): Promise<SearchReadResult>;
}
export function validateSearchInput(input: unknown): SearchInput {
  const value = validate(SearchInputSchema, input);
  if (!value.query.trim()) throw new Error("Empty query");
  return { query: value.query.trim() };
}
export function validateSearchResult(input: unknown): SearchResult {
  const value = validate(SearchResultSchema, input);
  if (new Set(value.hits.map((hit) => hit.id)).size !== value.hits.length)
    throw new Error("Duplicate search identity");
  return value;
}
export function validateSearchReadResult(
  input: unknown,
  id: string,
): SearchReadResult {
  const value = validate(SearchReadResultSchema, input);
  const indexes = value.context.items.map((item) => item.sourceRecordIndex);
  const target = indexes.indexOf(value.context.targetSourceRecordIndex);
  if (
    value.record.id !== id ||
    new Set(indexes).size !== indexes.length ||
    (target < 0
      ? indexes.length > 16
      : target > 8 || indexes.length - target - 1 > 8) ||
    value.context.items.reduce(
      (sum, item) => sum + Array.from(item.content).length,
      0,
    ) > 12000
  )
    throw new Error("Invalid search context");
  return value;
}
