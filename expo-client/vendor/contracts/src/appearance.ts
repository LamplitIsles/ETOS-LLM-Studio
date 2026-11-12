import { Type, type Static } from "typebox";
import { validate } from "./validation.ts";

export const APPEARANCE_PATH = "/api/chat/appearance";
// Assets are served by the authenticated deployment, never external URLs.
const AssetUrl = Type.String({ pattern: "^/api/[^?#]+$" });
export const ChatAppearanceSchema = Type.Object(
  {
    companionName: Type.String(),
    userName: Type.String(),
    companionAvatar: Type.Optional(AssetUrl),
    userAvatar: Type.Optional(AssetUrl),
    backgrounds: Type.Optional(
      Type.Object(
        {
          landscape: AssetUrl,
          portrait: AssetUrl,
        },
        { additionalProperties: false },
      ),
    ),
  },
  { additionalProperties: false },
);
export type ChatAppearance = Static<typeof ChatAppearanceSchema>;
export function validateChatAppearance(value: unknown): ChatAppearance {
  return validate(ChatAppearanceSchema, value);
}
