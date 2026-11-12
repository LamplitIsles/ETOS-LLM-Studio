/** Owner-authenticated, same-origin GET. The path query is a literal filesystem path. */
export const WORKSPACE_IMAGE_PATH = "/api/chat/workspace-image";

/** Parse a Markdown image destination once, before encoding it as a query payload. */
export function parseWorkspaceImagePath(source: string): string | null {
  let path: string;
  try {
    path = decodeURIComponent(source);
  } catch {
    return null;
  }
  if (
    !path.trim() ||
    // Paths containing controls or lone surrogates cannot be transported safely.
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\u007f-\u009f\\\uD800-\uDFFF]/u.test(path) ||
    /^[a-z][a-z\d+.-]*:/i.test(path) ||
    path.startsWith("//") ||
    /^\/api(?:\/|$)/i.test(path) ||
    !/\.(?:png|jpe?g|webp|gif)$/i.test(path)
  )
    return null;
  return path;
}

/** Input is the original Markdown destination, not an already decoded query value. */
export function workspaceImageUrl(source: string): string | null {
  const path = parseWorkspaceImagePath(source);
  return path === null
    ? null
    : `${WORKSPACE_IMAGE_PATH}?path=${encodeURIComponent(path)}`;
}
