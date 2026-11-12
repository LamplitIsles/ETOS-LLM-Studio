import { Type, type Static, type TSchema } from "typebox";
import { Value } from "typebox/value";
import { workspaceMediaUrl } from "./workspace-media.ts";

/** The Basic Catalog and the single-message v1.0 Candidate profile used by chat. */
export const A2UI_VERSION = "1.0";
export const A2UI_BASIC_CATALOG_ID =
  "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json";
export const A2UI_MAX_BYTES = 16 * 1024;
export const A2UI_MAX_COMPONENTS = 100;
export const A2UI_MAX_DEPTH = 16;
const Id = Type.String({
  minLength: 1,
  maxLength: 128,
  pattern: "^[A-Za-z0-9_-]+$",
});
const StringValue = Type.String({ maxLength: 4096 });
// Bindings are deliberately limited to one top-level, string-valued model key.
const TextValue = Type.Union([
  StringValue,
  Type.Object(
    { "@path": Type.String({ pattern: "^/[A-Za-z0-9_-]+$", maxLength: 129 }) },
    { additionalProperties: false },
  ),
]);
const Url = Type.String({ minLength: 1, maxLength: 2048 });
const common = {
  id: Id,
  weight: Type.Optional(Type.Number({ minimum: 0, maximum: 100 })),
  accessibility: Type.Optional(
    Type.Object(
      {
        label: Type.Optional(TextValue),
        description: Type.Optional(TextValue),
        live: Type.Optional(
          Type.Union([
            Type.Literal("off"),
            Type.Literal("polite"),
            Type.Literal("assertive"),
          ]),
        ),
      },
      { additionalProperties: false },
    ),
  ),
};
const component = <T extends string, P extends Record<string, TSchema>>(
  name: T,
  properties: P,
) =>
  Type.Object(
    { ...common, component: Type.Literal(name), ...properties },
    { additionalProperties: false },
  );
const optional = <T extends string>(...values: T[]) =>
  Type.Optional(Type.Union(values.map((value) => Type.Literal(value))));
const align = optional("start", "center", "end", "stretch");
const children = Type.Array(Id, { maxItems: A2UI_MAX_COMPONENTS });
export const A2UIComponentSchema = Type.Union([
  component("Text", { text: TextValue, variant: optional("body", "caption") }),
  component("Image", {
    url: Url,
    description: Type.Optional(TextValue),
    fit: optional("contain", "cover", "fill", "none", "scaleDown"),
    variant: optional(
      "icon",
      "avatar",
      "smallFeature",
      "mediumFeature",
      "largeFeature",
      "header",
    ),
  }),
  component("Icon", {
    name: Type.Union(
      [
        "accountCircle",
        "add",
        "arrowBack",
        "arrowForward",
        "attachFile",
        "calendarToday",
        "call",
        "camera",
        "check",
        "close",
        "delete",
        "download",
        "edit",
        "event",
        "error",
        "fastForward",
        "favorite",
        "favoriteOff",
        "folder",
        "help",
        "home",
        "info",
        "locationOn",
        "lock",
        "lockOpen",
        "mail",
        "menu",
        "moreVert",
        "moreHoriz",
        "notificationsOff",
        "notifications",
        "pause",
        "payment",
        "person",
        "phone",
        "photo",
        "play",
        "print",
        "refresh",
        "rewind",
        "search",
        "send",
        "settings",
        "share",
        "shoppingCart",
        "skipNext",
        "skipPrevious",
        "star",
        "starHalf",
        "starOff",
        "stop",
        "upload",
        "visibility",
        "visibilityOff",
        "volumeDown",
        "volumeMute",
        "volumeOff",
        "volumeUp",
        "warning",
      ].map((name) => Type.Literal(name)),
    ),
  }),
  component("Video", { url: Url, posterUrl: Type.Optional(Url) }),
  component("AudioPlayer", { url: Url, description: Type.Optional(TextValue) }),
  component("Row", {
    children,
    align,
    justify: optional(
      "start",
      "center",
      "end",
      "spaceBetween",
      "spaceAround",
      "spaceEvenly",
      "stretch",
    ),
  }),
  component("Column", {
    children,
    align,
    justify: optional(
      "start",
      "center",
      "end",
      "spaceBetween",
      "spaceAround",
      "spaceEvenly",
      "stretch",
    ),
  }),
  component("List", {
    children,
    align,
    direction: optional("vertical", "horizontal"),
  }),
  component("Card", { child: Id }),
  component("Tabs", {
    tabs: Type.Array(
      Type.Object(
        { title: TextValue, child: Id },
        { additionalProperties: false },
      ),
      { minItems: 1, maxItems: A2UI_MAX_COMPONENTS },
    ),
  }),
  component("Modal", { trigger: Id, content: Id }),
  component("Divider", { axis: optional("horizontal", "vertical") }),
  component("Button", {
    child: Id,
    action: Type.Object(
      {
        event: Type.Object(
          { name: Type.Literal("open_modal") },
          { additionalProperties: false },
        ),
      },
      { additionalProperties: false },
    ),
    variant: optional("default", "primary", "borderless"),
  }),
]);
export const A2UISurfaceSchema = Type.Object(
  {
    version: Type.Literal(A2UI_VERSION),
    createSurface: Type.Object(
      {
        surfaceId: Id,
        catalogId: Type.Literal(A2UI_BASIC_CATALOG_ID),
        components: Type.Array(A2UIComponentSchema, {
          minItems: 1,
          maxItems: A2UI_MAX_COMPONENTS,
        }),
        dataModel: Type.Optional(
          Type.Record(
            Type.String({ pattern: "^[A-Za-z0-9_-]+$", maxLength: 128 }),
            StringValue,
            { maxProperties: 100 },
          ),
        ),
      },
      { additionalProperties: false },
    ),
  },
  { additionalProperties: false },
);
export type A2UISurface = Static<typeof A2UISurfaceSchema>;
export type A2UIComponent = Static<typeof A2UIComponentSchema>;

function references(node: A2UIComponent): string[] {
  switch (node.component) {
    case "Row":
    case "Column":
    case "List":
      return node.children;
    case "Card":
    case "Button":
      return [node.child];
    case "Tabs":
      return node.tabs.map((tab) => tab.child);
    case "Modal":
      return [node.trigger, node.content];
    default:
      return [];
  }
}

/** Copy a bounded JSON payload. An invalid payload remains an invalid UI placeholder. */
export function boundA2UIPayload(value: unknown): unknown {
  const seen = new Set<object>();
  let count = 0;
  function json(input: unknown, depth: number): boolean {
    if (++count > A2UI_MAX_BYTES || depth > 32) return false;
    if (input === null || typeof input === "boolean") return true;
    if (typeof input === "string") return input.length <= A2UI_MAX_BYTES;
    if (typeof input === "number") return Number.isFinite(input);
    if (typeof input !== "object" || seen.has(input)) return false;
    if (Array.isArray(input) && input.length > A2UI_MAX_BYTES) return false;
    if (Object.getOwnPropertySymbols(input).length) return false;
    const proto = Object.getPrototypeOf(input);
    if (
      Array.isArray(input)
        ? proto !== Array.prototype
        : proto !== Object.prototype && proto !== null
    )
      return false;
    seen.add(input);
    const descriptors = Object.getOwnPropertyDescriptors(input);
    const keys = Object.keys(descriptors);
    if (
      keys.length > A2UI_MAX_BYTES ||
      keys.some((key) => key.length > A2UI_MAX_BYTES)
    )
      return false;
    const result = keys.every((key) => {
      const descriptor = descriptors[key]!;
      return "value" in descriptor && json(descriptor.value, depth + 1);
    });
    seen.delete(input);
    return result;
  }
  try {
    if (!json(value, 0)) return {};
    const encoded = JSON.stringify(value);
    if (
      typeof encoded !== "string" ||
      new TextEncoder().encode(encoded).byteLength > A2UI_MAX_BYTES
    )
      return {};
    return JSON.parse(encoded);
  } catch {
    return {};
  }
}

/** Work on a projection, never the replicated Chord state. Only ui is bounded. */
export function boundA2UIInMessages(value: unknown): unknown {
  if (
    !value ||
    typeof value !== "object" ||
    !Array.isArray((value as { messages?: unknown }).messages)
  )
    return value;
  const source = value as { messages: unknown[] };
  return {
    ...source,
    messages: source.messages.map((message) => {
      if (
        !message ||
        typeof message !== "object" ||
        !Object.hasOwn(message, "ui")
      )
        return message;
      const record = message as Record<string, unknown>;
      return { ...record, ui: boundA2UIPayload(record.ui) };
    }),
  };
}

/** Absolute media is HTTPS without URL credentials; relative paths are existing CFL media routes. */
function validMediaUrl(
  value: string,
  kind: "image" | "audio" | "video",
): boolean {
  if (
    value.startsWith("workspace:") &&
    workspaceMediaUrl(value, kind) !== null
  )
    return true;
  if (
    kind === "image" &&
    /^\/api\/chat\/media\/[A-Za-z0-9_-]{1,100}\/(?:original|preview|model)$/.test(
      value,
    )
  )
    return true;
  if (kind === "audio" && /^\/api\/audio\/[0-9a-f]{64}\.mp3$/.test(value))
    return true;
  // URL parsers normalize whitespace and backslashes; reject those ambiguous inputs.
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u0020\u007f\\]/.test(value)) return false;
  if (/%(?![A-Fa-f0-9]{2})/.test(value)) return false;
  const authority = /^https:\/\/([^/?#]+)/i.exec(value)?.[1];
  if (!authority || authority.includes("@")) return false;
  try {
    const url = new URL(value);
    return (
      url.protocol === "https:" &&
      !!url.hostname &&
      !url.username &&
      !url.password
    );
  } catch {
    return false;
  }
}

/** Strict semantic validation is required in addition to the exported structural schema. */
export function validateA2UISurface(value: unknown): A2UISurface {
  const bounded = boundA2UIPayload(value);
  if (!Value.Check(A2UISurfaceSchema, bounded))
    throw new Error("Invalid A2UI surface");
  const surface = bounded as A2UISurface;
  // The community reducer stores surfaces and components in ordinary objects.
  // Reject inherited keys before they can shadow or alter those maps.
  const unsafeIds = new Set([
    ...Object.getOwnPropertyNames(Object.prototype),
    "prototype",
  ]);
  if (unsafeIds.has(surface.createSurface.surfaceId))
    throw new Error("Invalid A2UI surface id");
  const nodes = new Map<string, A2UIComponent>();
  for (const node of surface.createSurface.components) {
    if (unsafeIds.has(node.id)) throw new Error("Invalid A2UI component id");
    if (nodes.has(node.id)) throw new Error("Duplicate A2UI component");
    nodes.set(node.id, node);
  }
  const visited = new Set<string>();
  function visit(id: string, depth: number): void {
    const node = nodes.get(id);
    if (!node || visited.has(id) || depth > A2UI_MAX_DEPTH)
      throw new Error("Invalid A2UI component tree");
    visited.add(id);
    for (const child of references(node)) visit(child, depth + 1);
  }
  visit("root", 1);
  if (visited.size !== nodes.size)
    throw new Error("Unreachable A2UI component");
  const triggers = new Set<string>();
  for (const node of nodes.values()) {
    if (node.component !== "Modal") continue;
    if (nodes.get(node.trigger)?.component !== "Button")
      throw new Error("Modal trigger must be a Button");
    triggers.add(node.trigger);
  }
  for (const node of nodes.values()) {
    if (node.component === "Button" && !triggers.has(node.id))
      throw new Error("Button must be a Modal trigger");
  }
  for (const node of nodes.values()) {
    if (node.component === "Image" && !validMediaUrl(node.url, "image"))
      throw new Error("Invalid A2UI image URL");
    if (node.component === "AudioPlayer" && !validMediaUrl(node.url, "audio"))
      throw new Error("Invalid A2UI audio URL");
    if (
      node.component === "Video" &&
      (!validMediaUrl(node.url, "video") ||
        (node.posterUrl !== undefined &&
          !validMediaUrl(node.posterUrl, "image")))
    )
      throw new Error("Invalid A2UI video URL");
  }
  const model = surface.createSurface.dataModel ?? {};
  if (
    Object.keys(model).some((key) =>
      ["__proto__", "constructor", "prototype"].includes(key),
    )
  )
    throw new Error("Invalid A2UI data model key");
  function checkBinding(value: unknown): void {
    if (!value || typeof value !== "object") return;
    if ("@path" in value) {
      const path = value["@path"];
      if (typeof path !== "string" || !Object.hasOwn(model, path.slice(1)))
        throw new Error("Invalid A2UI data binding");
    }
    for (const child of Object.values(value)) checkBinding(child);
  }
  for (const node of nodes.values()) checkBinding(node);
  return surface;
}
