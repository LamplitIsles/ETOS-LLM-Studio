import { createHash, randomUUID } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { StickerCacheFiles } from '../../src/cfl/sticker-cache-store';

/** Test-only adapter; directory must be owned by the test. */
export function testCacheFiles(directory: string): StickerCacheFiles {
  const path = (name: string) => join(directory, name);
  return {
    async hash(value) { return createHash('sha256').update(value).digest('hex'); },
    async list() { return readdirSync(directory).map(name => { const stat = statSync(path(name)); return { name, size: stat.size, modified: stat.mtimeMs }; }); },
    size(name) { return existsSync(path(name)) ? statSync(path(name)).size : null; },
    async read(name) { return existsSync(path(name)) ? readFileSync(path(name), 'utf8') : null; },
    async write(name, value) { writeFileSync(path(name), value); },
    remove(name) { rmSync(path(name), { force: true }); },
    commit(from, to) { renameSync(path(from), path(to)); },
    unique: randomUUID,
  };
}
