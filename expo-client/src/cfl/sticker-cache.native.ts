import * as Crypto from 'expo-crypto';
import { Directory, File, Paths } from 'expo-file-system';
import { FileStickerCache, type StickerCache, type StickerCacheFiles } from './sticker-cache-store';

let instance: StickerCache | undefined;

/** Reuse one queue and budget for all scopes in this JS runtime. */
export function createStickerCache(): StickerCache | undefined {
  if (instance) return instance;
  let directory: Directory;
  try { directory = new Directory(Paths.cache, 'etos-sticker-cache-v1'); } catch { return undefined; }
  const ensure = () => { directory.create({ idempotent: true, intermediates: true }); };
  const file = (name: string) => new File(directory, name);
  const files: StickerCacheFiles = {
    hash: value => Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, value),
    async list() {
      ensure();
      return directory.list().filter((entry): entry is File => entry instanceof File).map(entry => ({ name: entry.name, size: entry.size, modified: entry.modificationTime ?? 0 }));
    },
    size(name) { const item = file(name); return item.exists ? item.size : null; },
    async read(name) { const item = file(name); return item.exists ? item.text() : null; },
    async write(name, value) { ensure(); await file(name).write(value); },
    remove(name) { const item = file(name); if (item.exists) item.delete(); },
    commit(from, to) { file(from).moveSync(file(to), { overwrite: true }); },
    unique: () => Crypto.randomUUID(),
  };
  instance = new FileStickerCache(files);
  return instance;
}
