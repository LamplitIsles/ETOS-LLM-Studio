/** A cache is an expendable local copy, never proof of current authorization. */
export interface StickerCache {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, current: () => boolean): Promise<void>;
  remove?(key: string, current: () => boolean): Promise<void>;
}

type Entry = { name: string; size: number; modified: number };
/** The adapter is confined to one application-owned directory. */
export interface StickerCacheFiles {
  hash(value: string): Promise<string>;
  list(): Promise<Entry[]>;
  size(name: string): number | null;
  read(name: string): Promise<string | null>;
  write(name: string, value: string): Promise<void>;
  remove(name: string): void;
  commit(from: string, to: string): void;
  unique(): string;
}

const MAX_BYTES = 256 * 1024 * 1024;
const MAX_FILES = 4096;
const MAX_RECORD = 1024 * 1024;
const filename = /^[a-f0-9]{64}$/;
const temporary = /^tmp-[a-f0-9-]{36}$/;

/** FIFO by last write, shared across scopes; reads do not refresh the eviction order. */
export class FileStickerCache implements StickerCache {
  private writes: Promise<void> = Promise.resolve();
  constructor(private files: StickerCacheFiles, private maxBytes = MAX_BYTES, private maxFiles = MAX_FILES) {}
  async flush(): Promise<void> { await this.writes; }

  remove(key: string, current: () => boolean): Promise<void> {
    const task = this.writes.then(async () => {
      if (!current()) return;
      const name = await this.files.hash(key);
      if (filename.test(name) && current()) this.files.remove(name);
    }).catch(() => {});
    this.writes = task;
    return task;
  }

  async get(key: string): Promise<string | null> {
    try {
      const name = await this.files.hash(key);
      if (!filename.test(name)) return null;
      const size = this.files.size(name);
      if (size === null || size <= 0 || size > MAX_RECORD) return null;
      const value = await this.files.read(name);
      if (value === null || new TextEncoder().encode(value).length > MAX_RECORD) return null;
      const record = JSON.parse(value) as { value?: unknown; digest?: unknown };
      if (typeof record.value !== 'string' || typeof record.digest !== 'string' || !filename.test(record.digest)) return null;
      return await this.files.hash(record.value) === record.digest ? record.value : null;
    } catch { return null; }
  }

  put(key: string, value: string, current: () => boolean): Promise<void> {
    const task = this.writes.then(async () => {
      if (!current()) return;
      const name = await this.files.hash(key);
      if (!filename.test(name) || !current()) return;
      const digest = await this.files.hash(value);
      if (!filename.test(digest) || !current()) return;
      const contents = JSON.stringify({ value, digest });
      const size = new TextEncoder().encode(contents).length;
      if (!size || size > MAX_RECORD || size > this.maxBytes || this.maxFiles < 1) return;
      const temp = `tmp-${this.files.unique()}`;
      if (!temporary.test(temp)) return;
      const entries = await this.files.list();
      if (!current()) return;
      for (const entry of entries) if (temporary.test(entry.name)) this.files.remove(entry.name);
      const records = entries.filter(entry => filename.test(entry.name)).sort((a, b) => a.modified - b.modified || a.name.localeCompare(b.name));
      let total = records.reduce((sum, entry) => sum + entry.size, 0);
      let count = records.length;
      // The old record and temporary copy coexist until commit, so reserve both.
      for (const entry of records) {
        if (total + size <= this.maxBytes && count + 1 <= this.maxFiles) break;
        this.files.remove(entry.name); total -= entry.size; count--;
      }
      if (total + size > this.maxBytes || count + 1 > this.maxFiles || !current()) return;
      try {
        await this.files.write(temp, contents);
        if (current()) this.files.commit(temp, name);
      } finally {
        try { this.files.remove(temp); } catch { /* moved or already absent */ }
      }
    }).catch(() => { /* Local cache failures never block network. */ });
    this.writes = task;
    return task;
  }
}
