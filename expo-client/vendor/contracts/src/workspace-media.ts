import { WORKSPACE_IMAGE_PATH } from "./workspace-images.ts";

/** Authenticated same-origin endpoint; the server must verify the opened file. */
export const WORKSPACE_MEDIA_PATH = "/api/chat/workspace-media";
export type WorkspaceMediaKind = "image" | "audio" | "video";

/** Parse an A2UI workspace: reference or workspace path, decoding exactly once. */
export function parseWorkspaceMediaPath(
  source: string,
  kind: WorkspaceMediaKind,
): string | null {
  const extension =
    kind === "image"
      ? /\.(?:png|jpe?g|webp|gif)$/i
      : kind === "audio"
        ? /\.(?:wav|mp3)$/i
        : kind === "video"
          ? /\.mp4$/i
          : null;
  if (!extension || typeof source !== "string") return null;
  const explicit = source.startsWith("workspace:");
  let path: string;
  try {
    path = decodeURIComponent(
      explicit ? source.slice("workspace:".length) : source,
    );
  } catch {
    return null;
  }
  if (
    !path ||
    path !== path.trim() ||
    // The query carries this literal path; the server must not decode it again.
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\u007f-\u009f\\\uD800-\uDFFF\uFFFD]/u.test(path) ||
    /^[a-z][a-z\d+.-]*:/i.test(path) ||
    path.includes("//") ||
    /^\/api(?:\/|$)/i.test(path) ||
    path.split("/").includes("..") ||
    !extension.test(path)
  )
    return null;
  return path;
}

/** Build a single-encoded URL; never hand workspace: to a browser media element. */
export function workspaceMediaUrl(
  source: string,
  kind: WorkspaceMediaKind,
): string | null {
  const path = parseWorkspaceMediaPath(source, kind);
  if (path === null) return null;
  const encoded = encodeURIComponent(path);
  return kind === "image"
    ? `${WORKSPACE_IMAGE_PATH}?path=${encoded}`
    : `${WORKSPACE_MEDIA_PATH}?kind=${kind}&path=${encoded}`;
}
