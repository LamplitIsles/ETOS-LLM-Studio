import { openChat } from '../../vendor/contracts/src/client';
import { validateReceipt, validateSubmission, validate, validateSearchInput, validateSearchResult, validateSearchReadResult, SearchReadInputSchema, type SearchResult, type SearchReadResult, type ChatView, type ChatMessage, type HistoryPage, type Receipt, type ImageRef, type FileRef } from '../../vendor/contracts/src/index';
import { type MediaTransport, type ImageData } from './transport';
import { ImageSessionCache } from './image-session-cache';

/** Opaque timeline row key captured by the caller at the explicit send gesture. */
export type SendAnchor = { after: string | null; predecessor?: string };
export type Pending = { origin: string; sessionId: string; operationId: string; text: string; createdAt: number; state: 'unknown' | 'submitted' | 'failed'; images?: ImageRef[]; files?: FileRef[]; error?: string; messageId?: string; attempt?: number; deliveryVersion?: 2; anchor?: SendAnchor };
function validAnchor(anchor: unknown): anchor is SendAnchor {
  if (!anchor || typeof anchor !== 'object' || Array.isArray(anchor)) return false;
  const x = anchor as Record<string, unknown>;
  return Object.keys(x).every(k => k === 'after' || k === 'predecessor') && (x.after === null || typeof x.after === 'string' && x.after.length > 0 && x.after.length <= 2048) && (x.predecessor === undefined || typeof x.predecessor === 'string' && x.predecessor.length > 0 && x.predecessor.length <= 256);
}
export class AdmissionError extends Error {
  constructor(readonly identity: OperationIdentity, readonly journal: 'unknown' | 'stored', message: string) { super(message); this.name = 'AdmissionError'; }
  readonly dispatched = false;
}
/** Legacy receipts may represent admission rather than final delivery. */
function normalizePending(entry: Pending): Pending {
  if (entry.anchor !== undefined && !validAnchor(entry.anchor)) { const { anchor: _anchor, ...rest } = entry; entry = rest; }
  if (entry.deliveryVersion === 2 && ((entry.state === 'unknown' && entry.attempt === undefined) || (Number.isSafeInteger(entry.attempt) && (entry.attempt ?? 0) > 0))) return entry;
  const { error: _error, messageId: _messageId, attempt: _attempt, ...rest } = entry;
  return { ...rest, state: 'unknown', deliveryVersion: 2 };
}
export interface PendingStore { load(origin: string): Promise<Pending[]>; save(origin: string, entries: Pending[]): Promise<void> }
export type ChatPort = Pick<Awaited<ReturnType<typeof openChat>>, 'history' | 'submit' | 'lookup' | 'close'> & Partial<Pick<Awaited<ReturnType<typeof openChat>>, 'search' | 'searchRead'>>;
export type ChatSnapshot = { connection: 'offline' | 'connecting' | 'online'; failure: 'access_denied' | 'unavailable' | null; view: ChatView | null; history: ChatMessage[]; before: string | null; pending: Pending[] };
export type DeepReadonly<T> = T extends readonly (infer U)[] ? readonly DeepReadonly<U>[] : T extends object ? { readonly [K in keyof T]: DeepReadonly<T[K]> } : T;
/** Separate ranges are ordered by observation, not proof of their relative timeline positions. */
export type DetachedRange = { readonly id: number; readonly messages: readonly DeepReadonly<ChatMessage>[] };
export type ChatControllerSnapshot = ChatSnapshot & { readonly detached: readonly DetachedRange[] };
function freezeJson(value: unknown): void {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freezeJson(child);
    Object.freeze(value);
  }
}
/** The new window may insert records, but must retain the complete old suffix in order. */
function orderedOverlapStart(older: readonly ChatMessage[], next: readonly ChatMessage[]): number {
  const first = older.findIndex(item => item.id === next[0]?.id);
  if (first < 0) return -1;
  const live = new Set(next.map(item => item.id));
  if (older.slice(0, first).some(item => live.has(item.id))) return -1;
  let index = 0;
  for (let i = first; i < older.length; i++) {
    while (index < next.length && next[index].id !== older[i].id) index++;
    if (index === next.length) return -1;
    index++;
  }
  return first;
}
/** Obtain snapshot and its visible row key together, synchronously in the send gesture. */
export type SendPlacement = SendAnchor & { snapshot: ChatSnapshot };
export type OperationIdentity = { origin: string; sessionId: string; operationId: string };
/** References are independent copies of the validated, journaled submission. */
export type SendAdmission = OperationIdentity & { images?: ImageRef[]; files?: FileRef[] };
export type PreparedAdmission = { identity: OperationIdentity; images?: ImageRef[]; files?: FileRef[]; completion: Promise<void> };
export type OperationState = 'unknown' | 'submitted' | 'failed' | 'observed';
export type SocketFactory = () => Promise<WebSocket>;
export type OpenPort = (socket: WebSocket, changed: (view: ChatView) => void, offline: (error: Error) => void, deliveryResult: (receipt: Receipt) => void) => Promise<ChatPort>;

/** One connection per instance; late results are discarded after a session or connection change. */
export class ChatController {
  private imageCache = new ImageSessionCache();
  private epoch = 0;
  private connectionId = 0;
  private searchGeneration = 0;
  private searchReadGeneration = 0;
  private historyLoading = false;
  // Older ranges separated from the live range by an unverified gap. They can
  // rejoin only when a history page proves an ordered overlap.
  private detached: Array<{ range: DetachedRange; messages: ChatMessage[]; before: string | null; bridgeable: boolean }> = [];
  private nextDetachedId = 0;
  private detach(messages: ChatMessage[], before: string | null, bridgeable = true) {
    // Validated protocol messages are JSON; isolate nested attachments and UI
    // payloads so older public snapshots cannot mutate controller state.
    const copy = JSON.parse(JSON.stringify(messages)) as ChatMessage[];
    freezeJson(copy);
    const range: DetachedRange = Object.freeze({ id: ++this.nextDetachedId, messages: copy });
    this.detached.push({ range, messages: copy, before, bridgeable });
  }
  private detachMissing(messages: ChatMessage[], live: Set<string>) {
    let run: ChatMessage[] = [];
    const flush = () => { if (run.length) this.detach(run, null, false); run = []; };
    for (const message of messages) {
      if (live.has(message.id)) flush(); else run.push(message);
    }
    flush();
  }
  private work: Promise<void> = Promise.resolve();
  private serial<T>(action: () => Promise<T>): Promise<T> {
    const task = this.work.then(action);
    this.work = task.then(() => {}, () => {});
    return task;
  }
  private preparations = new Set<AbortController>();
  private cancelPreparations() { for (const item of this.preparations) item.abort(); this.preparations.clear(); }
  private revision = 0;
  private port: ChatPort | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private reconcileTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = true;
  private listeners = new Set<(state: ChatControllerSnapshot) => void>();
  private entries: Pending[] = [];
  private journalUncertain = false;
  private async saveEntries(entries: Pending[]) {
    if (this.journalUncertain) throw new Error('journal_uncertain');
    try { await this.store.save(this.origin, entries); }
    catch (error) { this.journalUncertain = true; throw error; }
  }
  private state: ChatControllerSnapshot = { connection: 'offline', failure: null, view: null, history: [], before: null, pending: [], detached: Object.freeze([]) };
  constructor(readonly origin: string, private socket: SocketFactory, private store: PendingStore, private uuid: () => string, private open: OpenPort = openChat, private checkAuthorization?: () => Promise<boolean>) {}
  snapshot() { return this.state; }
  readImage(media: MediaTransport, id: string, active: () => boolean, variant: 'preview' | 'original' = 'preview', signal?: AbortSignal): Promise<ImageData> {
    const scope = this.scope();
    const sessionId = this.state.view?.sessionId;
    if (this.state.failure === 'access_denied') return Promise.reject(new Error('access_denied'));
    return this.imageCache.read(media, id, variant, () => !!sessionId && scope() && this.state.view?.sessionId === sessionId && this.state.failure !== 'access_denied', active, signal);
  }
  scope(): () => boolean { const epoch = this.epoch, revision = this.revision; return () => !this.stopped && epoch === this.epoch && revision === this.revision; }
  /** Captures both the session epoch and the current live connection. */
  onlineScope(): () => boolean {
    const current = this.scope(), connectionId = this.connectionId, port = this.port, sessionId = this.state.view?.sessionId;
    return () => !!sessionId && !!port && current() && this.state.view?.sessionId === sessionId && this.connectionId === connectionId && this.port === port && this.state.connection === 'online' && this.state.failure !== 'access_denied';
  }
  /** Ignore outstanding search and read completions when the search UI closes. */
  cancelSearch() { this.searchGeneration++; this.searchReadGeneration++; }
  /** Returns archive results; record IDs are opaque and are not timeline message IDs. */
  async search(query: string): Promise<SearchResult> {
    const generation = ++this.searchGeneration; this.searchReadGeneration++;
    const input = validateSearchInput({ query });
    const guard = this.searchGuard(generation, false);
    const port = this.port; if (!port?.search) throw new Error('search_unavailable');
    try { const result = await port.search(input); guard(); return validateSearchResult(result); }
    catch (error) { guard(); throw error; }
  }
  async searchRead(id: string): Promise<SearchReadResult> {
    const generation = ++this.searchReadGeneration;
    const input = validate(SearchReadInputSchema, { id });
    const guard = this.searchGuard(generation, true);
    const port = this.port; if (!port?.searchRead) throw new Error('search_unavailable');
    try { const result = await port.searchRead(input); guard(); return validateSearchReadResult(result, input.id); }
    catch (error) { guard(); throw error; }
  }
  private searchGuard(generation: number, read: boolean): () => void {
    const current = this.scope(), connection = this.connectionId, port = this.port;
    const session = this.state.view?.sessionId;
    if (!session || !port || this.state.connection !== 'online') throw new Error('offline');
    return () => {
      if (!current() || this.state.view?.sessionId !== session) throw new Error('session_changed');
      if (connection !== this.connectionId || port !== this.port || this.state.connection !== 'online') throw new Error('offline');
      if ((read ? this.searchReadGeneration : this.searchGeneration) !== generation) throw new Error('search_superseded');
    };
  }
  subscribe(listener: (state: ChatControllerSnapshot) => void) { this.listeners.add(listener); listener(this.state); return () => this.listeners.delete(listener); }
  /** Missing journal entries and inactive sessions are not evidence of admission. */
  async operationStatus(identity: OperationIdentity): Promise<OperationState> {
    if (identity.origin !== this.origin || this.stopped || this.state.view?.sessionId !== identity.sessionId) return 'unknown';
    const current = this.scope();
    const observed = () => this.state.view?.sessionId === identity.sessionId && [...this.state.history, ...this.state.view.messages].some(m => m.operationId === identity.operationId);
    if (observed()) return 'observed';
    try {
      const entries = await this.store.load(this.origin);
      if (!current()) return 'unknown';
      if (observed()) return 'observed';
      const entry = entries.find(e => e.origin === identity.origin && e.sessionId === identity.sessionId && e.operationId === identity.operationId);
      return entry ? normalizePending(entry).state : 'unknown';
    } catch { return 'unknown'; }
  }
  private publish(patch: Partial<ChatSnapshot>) { this.state = { ...this.state, ...patch, detached: Object.freeze(this.detached.map(item => item.range)) }; for (const listener of this.listeners) listener(this.state); }
  private updateView(view: ChatView) {
    const changed = this.state.view?.sessionId !== view.sessionId;
    if (changed) { this.revision++; this.cancelPreparations(); this.imageCache.clear(); this.detached = []; }
    let history = changed ? [] : this.state.history;
    let before = changed ? view.before : this.state.before;
    const previous = changed ? undefined : this.state.view;
    if (previous) {
      // Keep a displaced prefix when the old suffix remains in order, even if
      // the host inserts new messages between existing ones.
      const first = orderedOverlapStart(previous.messages, view.messages);
      const live = new Set(view.messages.map(item => item.id));
      if (!view.messages.length) {
        const existing = new Set(history.map(item => item.id));
        history = [...history, ...previous.messages.filter(item => !existing.has(item.id))];
      } else if (!previous.messages.length && history.length) {
        const firstHistory = orderedOverlapStart(history, view.messages);
        if (firstHistory >= 0) {
          history = history.slice(0, firstHistory);
        } else if (!history.some(item => live.has(item.id))) {
          this.detach(history, before);
          history = []; before = view.before;
        } else {
          const prefix = Math.max(0, history.findIndex(item => item.id === view.messages[0].id));
          this.detachMissing(history.slice(prefix), live);
          history = history.slice(0, prefix);
        }
      } else if (first >= 0) {
        history = [...history, ...previous.messages.slice(0, first)].filter(item => !live.has(item.id));
      } else if (previous.messages.length && view.messages.length && !previous.messages.some(item => live.has(item.id))) {
        this.detach([...history, ...previous.messages], before);
        history = []; before = view.before;
      } else if (!previous.messages.length && !history.length) {
        before = view.before;
      } else {
        history = history.filter(item => !live.has(item.id));
        this.detachMissing(previous.messages, live);
      }
    }
    // A newer active range can itself contain every item of an older segment.
    // Do not keep a second public copy of a fully represented segment.
    const active = new Set([...history, ...view.messages].map(item => item.id));
    this.detached = this.detached.filter(item => !item.messages.every(message => active.has(message.id)));
    this.publish({ view, history, before, pending: this.entries.filter(e => e.sessionId === view.sessionId) });
    if (this.entries.some(e => e.sessionId === view.sessionId && view.messages.some(m => m.operationId === e.operationId))) {
      void this.serial(async () => {
        const current = this.state.view;
        if (!current || current.sessionId !== view.sessionId) return;
        const next = this.entries.filter(e => e.sessionId !== current.sessionId || !current.messages.some(m => m.operationId === e.operationId));
        await this.saveEntries(next);
        if (this.state.view?.sessionId !== current.sessionId) return;
        this.entries = next; this.publish({ pending: next.filter(e => e.sessionId === current.sessionId) });
      }).catch(() => {});
    }
  }
  async start() {
    this.stop(); this.stopped = false; const epoch = ++this.epoch;
    await this.serial(async () => {
      const entries = await this.store.load(this.origin);
      if (epoch !== this.epoch) return;
      this.entries = entries.filter(e => e.origin === this.origin).map(normalizePending);
      this.journalUncertain = false;
    });
    if (epoch !== this.epoch) return;
    await this.connect(epoch);
  }
  private async connect(epoch: number) {
    if (this.stopped || epoch !== this.epoch) return;
    const connectionId = ++this.connectionId;
    this.publish({ connection: 'connecting', failure: null });
    try {
      const socket = await this.socket();
      if (epoch !== this.epoch || this.stopped) { socket.close(); return; }
      let initialView = false;
      const currentConnection = () => epoch === this.epoch && connectionId === this.connectionId && !this.stopped;
      const delivery = (receipt: Receipt) => {
        if (!currentConnection()) return;
        // Before the initial view there is no session identity to bind to.
        // Reconciliation will look it up once the view is known.
        if (!initialView) return;
        this.acceptDelivery(receipt, epoch, connectionId);
      };
      const port = await this.open(socket, view => {
        if (!currentConnection()) return;
        this.updateView(view); initialView = true;
      }, error => this.disconnected(epoch, connectionId, error), delivery);
      if (epoch !== this.epoch || connectionId !== this.connectionId || this.stopped) { port.close(); return; }
      this.port = port; this.publish({ connection: 'online' });
      void this.reconcile();
    } catch (error) { this.disconnected(epoch, connectionId, error); }
  }
  private disconnected(epoch: number, connectionId: number, error: unknown) {
    if (this.stopped || epoch !== this.epoch || connectionId !== this.connectionId) return;
    this.connectionId++; this.cancelPreparations();
    this.port?.close(); this.port = null;
    const info = error as { retryable?: boolean; code?: string } | null;
    const denied = info?.retryable === false || info?.code === 'authorization_required';
    const disconnectedId = this.connectionId;
    if (denied) this.imageCache.clear(new Error('access_denied'));
    this.publish({ connection: 'offline', failure: denied ? 'access_denied' : 'unavailable' });
    if (denied) return;
    const schedule = () => {
      if (this.stopped || epoch !== this.epoch || disconnectedId !== this.connectionId) return;
      if (!this.timer) this.timer = setTimeout(() => { this.timer = null; void this.connect(epoch); }, 2000);
    };
    if (!this.checkAuthorization) { schedule(); return; }
    void this.checkAuthorization().then(valid => {
      if (this.stopped || epoch !== this.epoch || disconnectedId !== this.connectionId) return;
      if (!valid) { this.imageCache.clear(new Error('access_denied')); this.publish({ failure: 'access_denied' }); } else schedule();
    }, error => {
      if (this.stopped || epoch !== this.epoch || disconnectedId !== this.connectionId) return;
      if ((error as { code?: string })?.code === 'authorization_required') { this.imageCache.clear(new Error('access_denied')); this.publish({ failure: 'access_denied' }); } else schedule();
    });
  }
  stop() {
    this.stopped = true; this.epoch++; this.revision++; this.cancelPreparations(); this.imageCache.clear(); this.detached = [];
    if (this.timer) clearTimeout(this.timer); this.timer = null;
    if (this.reconcileTimer) clearTimeout(this.reconcileTimer); this.reconcileTimer = null;
    this.port?.close(); this.port = null;
    this.publish({ connection: 'offline', failure: null, view: null, history: [], before: null, pending: [] });
  }
  private guard(epoch: number, revision: number, sessionId: string) {
    if (this.epoch !== epoch || this.revision !== revision || this.state.view?.sessionId !== sessionId || this.stopped) throw new Error('session_changed');
  }
  async loadOlder(): Promise<void> {
    const { view, before } = this.state; const port = this.port;
    if (!view || !before || !port || this.historyLoading) return;
    const epoch = this.epoch, revision = this.revision, connectionId = this.connectionId;
    this.historyLoading = true;
    try {
      const page: HistoryPage = await port.history(before); this.guard(epoch, revision, view.sessionId);
      if (connectionId !== this.connectionId || port !== this.port || this.state.before !== before) return;
      const existing = new Set([...this.state.history, ...this.state.view!.messages].map(m => m.id));
      let messages = page.messages.filter(m => !existing.has(m.id));
      let nextBefore = page.before;
      while (messages.length && this.detached.length) {
        const detached = this.detached.at(-1)!;
        if (!detached.bridgeable) {
          const present = new Set([...existing, ...messages.map(item => item.id)]);
          if (!detached.messages.every(item => present.has(item.id))) break;
          this.detached.pop();
          continue;
        }
        const end = messages.findIndex(item => item.id === detached.messages.at(-1)?.id);
        if (end < 0) break;
        let overlap = 0;
        while (overlap <= end && overlap < detached.messages.length &&
          messages[end - overlap].id === detached.messages[detached.messages.length - 1 - overlap].id) overlap++;
        const pageStart = end + 1 - overlap, retainedStart = detached.messages.length - overlap;
        // Both prefixes exist but their relative order is unknown.
        if (pageStart && retainedStart) break;
        if (!pageStart) {
          messages = [...detached.messages.slice(0, retainedStart), ...messages];
          nextBefore = detached.before;
        }
        this.detached.pop();
      }
      this.publish({ history: [...messages, ...this.state.history], before: nextBefore });
    } finally { this.historyLoading = false; }
  }
  send(text: string): Promise<string> { return this.sendPrepared(text, async () => ({})); }
  /** Preparation runs once before durable admission; rejection leaves the caller's draft intact. */
  sendPrepared(text: string, prepare: (context: { operationId: string; sessionId: string; isCurrent: () => boolean; view: ChatView; signal: AbortSignal }) => Promise<{ images?: ImageRef[]; files?: FileRef[] }>): Promise<string> {
    return this.beginPrepared(text, prepare).then(async result => { await result.completion; return result.identity.operationId; });
  }
  /** Captures the visible anchor and scope synchronously, before preparation or queuing. */
  beginPrepared(text: string, prepare: (context: { operationId: string; sessionId: string; isCurrent: () => boolean; view: ChatView; signal: AbortSignal }) => Promise<{ images?: ImageRef[]; files?: FileRef[] }>, placement?: SendPlacement): Promise<PreparedAdmission> {
    if (!this.state.view || !this.port || this.state.connection !== 'online') return Promise.reject(new Error('offline'));
    if (this.journalUncertain) return Promise.reject(new Error('journal_uncertain'));
    if (placement && placement.snapshot !== this.state) return Promise.reject(new Error('session_changed'));
    const anchor = placement ? { after: placement.after, ...(placement.predecessor === undefined ? {} : { predecessor: placement.predecessor }) } : undefined;
    if (anchor && !validAnchor(anchor)) return Promise.reject(new Error('invalid_anchor'));
    if (anchor?.predecessor && !this.state.pending.some(e => e.operationId === anchor.predecessor) && ![...this.state.history, ...this.state.view.messages].some(m => m.operationId === anchor.predecessor)) return Promise.reject(new Error('invalid_anchor'));
    const captured = anchor ? { after: anchor.after, ...(anchor.predecessor ? { predecessor: anchor.predecessor } : {}) } : undefined;
    const current = this.scope();
    return this.serial(() => { if (!current()) throw new Error('session_changed'); return this.sendOnce(text, prepare, captured); });
  }
  private async sendOnce(text: string, prepare: (context: { operationId: string; sessionId: string; isCurrent: () => boolean; view: ChatView; signal: AbortSignal }) => Promise<{ images?: ImageRef[]; files?: FileRef[] }>, anchor?: SendAnchor): Promise<PreparedAdmission> {
    const view = this.state.view, port = this.port;
    if (!view || !port || this.state.connection !== 'online') throw new Error('offline');
    if (this.journalUncertain) throw new Error('journal_uncertain');
    if (text.length > 16000) throw new Error('invalid_text');
    const epoch = this.epoch, revision = this.revision, operationId = this.uuid();
    const abort = new AbortController(); this.preparations.add(abort);
    const isCurrent = () => !abort.signal.aborted && !this.stopped && this.epoch === epoch && this.revision === revision && this.port === port && this.state.connection === 'online' && this.state.view?.sessionId === view.sessionId;
    let prepared: { images?: ImageRef[]; files?: FileRef[] };
    try { prepared = await prepare({ operationId, sessionId: view.sessionId, isCurrent, view, signal: abort.signal }); }
    catch (error) { if (!isCurrent()) throw new Error('session_changed'); throw error; }
    finally { this.preparations.delete(abort); }
    if (!isCurrent()) throw new Error('session_changed');
    if (!text.trim() && !prepared.images?.length && !prepared.files?.length) throw new Error('invalid_text');
    const submission = validateSubmission({ operationId, text, ...(prepared.images ? { images: prepared.images } : {}), ...(prepared.files ? { files: prepared.files } : {}) });
    const last = anchor && !anchor.predecessor ? [...this.entries].reverse().find(e => e.sessionId === view.sessionId) : undefined;
    const preceding = last?.anchor?.after === anchor?.after ? last : undefined;
    const recordedAnchor = anchor ? { ...anchor, ...(preceding ? { predecessor: preceding.operationId } : {}) } : undefined;
    const identity = { origin: this.origin, sessionId: view.sessionId, operationId };
    const entry: Pending = { ...identity, ...submission, createdAt: Date.now(), state: 'unknown', deliveryVersion: 2, ...(recordedAnchor ? { anchor: recordedAnchor } : {}) };
    // Persist before dispatch; a crash must never cause an automatic replay.
    const saved = [...this.entries, entry];
    try { await this.saveEntries(saved); }
    catch { throw new AdmissionError(identity, 'unknown', 'journal_write_unknown'); }
    // Preserve the saved entry even if the visible session changed while saving.
    this.entries = saved;
    if (!isCurrent()) throw new AdmissionError(identity, 'stored', 'session_changed');
    // Snapshot before listeners or the port can mutate shared submission objects.
    const images = entry.images?.map(image => ({ ...image, ...(image.sticker ? { sticker: { ...image.sticker } } : {}) }));
    const files = entry.files?.map(file => ({ ...file }));
    this.publish({ pending: this.entries.filter(e => e.sessionId === view.sessionId) });
    if (!isCurrent()) throw new AdmissionError(identity, 'stored', 'session_changed');
    // Do not hold the journal serial queue while waiting for a network reply:
    // a deliveryResult can settle this operation before the RPC returns.
    const completion = (async () => {
      try {
        const receipt = await port.submit(submission);
        await this.serial(async () => { this.guard(epoch, revision, view.sessionId); await this.applyReceipt(entry, receipt, epoch, revision); });
      } catch { /* dispatched or result lost: reconcile by lookup only */ }
      if (this.entries.some(e => e.operationId === entry.operationId && e.state === 'unknown')) queueMicrotask(() => void this.reconcile());
    })();
    return { identity, ...(images ? { images } : {}), ...(files ? { files } : {}), completion };
  }
  private acceptDelivery(value: Receipt, epoch: number, connectionId: number) {
    let receipt: Receipt;
    try { receipt = validateReceipt(value); } catch { return; }
    const sessionId = this.state.view?.sessionId, revision = this.revision;
    if (!sessionId || this.stopped || epoch !== this.epoch || connectionId !== this.connectionId) return;
    void this.serial(async () => {
      if (this.stopped || epoch !== this.epoch || connectionId !== this.connectionId || revision !== this.revision || this.state.view?.sessionId !== sessionId) return;
      const entry = this.entries.find(e => e.sessionId === sessionId && e.operationId === receipt.operationId);
      if (entry) await this.applyReceipt(entry, receipt, epoch, revision);
    }).catch(() => {});
  }
  private async applyReceipt(entry: Pending, receipt: Receipt, epoch: number, revision: number) {
    this.guard(epoch, revision, entry.sessionId);
    receipt = validateReceipt(receipt);
    if (receipt.operationId !== entry.operationId) throw new Error('invalid_receipt');
    const current = this.entries.find(e => e.sessionId === entry.sessionId && e.operationId === entry.operationId);
    if (!current || current.state === 'submitted' || (current.attempt !== undefined && receipt.attempt < current.attempt)) return;
    // A proven terminal result for an attempt must not be reversed by a late reply.
    if (current.attempt === receipt.attempt && current.state !== 'unknown' && current.state !== receipt.state) return;
    const visible = this.state.view?.messages.some(m => m.operationId === entry.operationId) === true;
    const next: Pending[] = receipt.state === 'submitted' && visible ? this.entries.filter(e => e.sessionId !== entry.sessionId || e.operationId !== entry.operationId) : this.entries.map(e => e.sessionId !== entry.sessionId || e.operationId !== entry.operationId ? e : receipt.state === 'submitted' ? { ...e, state: 'submitted', attempt: receipt.attempt, deliveryVersion: 2, messageId: receipt.messageId ?? undefined, error: undefined } : { ...e, state: 'failed', attempt: receipt.attempt, deliveryVersion: 2, error: receipt.error ?? undefined, messageId: undefined });
    await this.saveEntries(next); this.guard(epoch, revision, entry.sessionId);
    this.entries = next; this.publish({ pending: next.filter(e => e.sessionId === entry.sessionId) });
  }
  reconcile(): Promise<void> { return this.serial(() => this.reconcileOnce()); }
  private async reconcileOnce(): Promise<void> {
    const view = this.state.view, port = this.port; if (!view || !port) return;
    const epoch = this.epoch, revision = this.revision;
    for (const entry of this.entries.filter(e => e.sessionId === view.sessionId && e.state === 'unknown')) {
      try {
        const receipt = await port.lookup(entry.operationId); this.guard(epoch, revision, view.sessionId);
        if (receipt) await this.applyReceipt(entry, receipt, epoch, revision);
      }
      catch { break; }
    }
    if (this.state.connection === 'online' && this.entries.some(e => e.sessionId === view.sessionId && e.state === 'unknown') && !this.reconcileTimer) {
      this.reconcileTimer = setTimeout(() => { this.reconcileTimer = null; void this.reconcile(); }, 5000);
    }
  }
}
