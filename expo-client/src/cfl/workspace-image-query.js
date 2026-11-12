/** Accept only the canonical single-query image URL produced by the CFL contract. */
export function isWorkspaceImageGet(value) {
  if (typeof value !== 'string' || !value.startsWith('/api/chat/workspace-image?path=')) return false;
  const encoded = value.slice('/api/chat/workspace-image?path='.length);
  let path;
  try { path = decodeURIComponent(encoded); } catch { return false; }
  if (!path || path !== path.trim() || path.length > 4096 || /[\u0000-\u001f\u007f-\u009f\uFFFD\\]/u.test(path) || path.startsWith('//') || /^[a-z][a-z\d+.-]*:/i.test(path) || path.split('/').includes('..') || !/\.(?:png|jpe?g|webp|gif)$/i.test(path)) return false;
  try { return encoded === encodeURIComponent(path); } catch { return false; }
}
