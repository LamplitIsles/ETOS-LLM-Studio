/** Platform-independent lifecycle for a single, explicitly requested camera photo. */
export class CameraPermissionError extends Error {
  readonly code = 'camera_permission_denied';
  constructor(readonly canAskAgain: boolean) { super('camera_permission_denied'); }
}
type CameraResult<A> = { canceled: true; assets: null } | { canceled: false; assets: A[] };
type Releasable = { release(): void };
type CameraPort<A, D extends Releasable> = {
  permission(): Promise<{ granted: boolean; canAskAgain: boolean }>;
  launch(): Promise<CameraResult<A>>;
  draft(asset: A): D;
  discard(asset: A): void;
};
const check = (current: () => boolean) => { if (!current()) throw new Error('session_changed'); };
/** Restrict deletion to an ImagePicker-generated UUID filename in its cache. */
export function isCameraCacheUri(cacheUri: string, uri: string): boolean {
  try {
    const root = new URL(cacheUri.endsWith('/') ? cacheUri : `${cacheUri}/`);
    const base = new URL('ImagePicker/', root);
    const file = new URL(uri);
    if (root.protocol !== 'file:' || file.protocol !== 'file:' || file.host || file.search || file.hash || !file.href.startsWith(base.href)) return false;
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]+$/i.test(file.href.slice(base.href.length));
  } catch { return false; }
}
export async function captureWithCamera<A, D extends Releasable>(current: () => boolean, camera: CameraPort<A, D>): Promise<D[] | null> {
  check(current);
  let permission: { granted: boolean; canAskAgain: boolean };
  try { permission = await camera.permission(); } catch (error) { check(current); throw error; }
  check(current);
  if (!permission.granted) throw new CameraPermissionError(permission.canAskAgain);
  let result: CameraResult<A>;
  try { result = await camera.launch(); } catch (error) { check(current); throw error; }
  if (!current()) { if (!result.canceled) result.assets.forEach(camera.discard); throw new Error('session_changed'); }
  if (result.canceled) return null;
  if (result.assets.length !== 1) { result.assets.forEach(camera.discard); throw new Error('invalid_photo'); }
  let draft: D | undefined;
  try { draft = camera.draft(result.assets[0]); check(current); return [draft]; }
  catch (error) { if (draft) draft.release(); else camera.discard(result.assets[0]); throw error; }
}
