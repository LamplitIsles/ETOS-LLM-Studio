import { boundA2UIInMessages } from "./a2ui.ts";
import {
  validateSearchInput,
  validateSearchResult,
  validateSearchReadResult,
  SearchReadInputSchema,
  type SearchBackend,
} from "./search.ts";
import {
  panelMethods,
  validatePanelResult,
  type PanelBackend,
} from "./panels.ts";
import {
  RemoteServiceProvider,
  replicatedState,
  createServiceStateEncoder,
  decodeServiceControlCall,
  type ServiceSubscription,
  type JsonValue,
} from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import {
  Chat,
  ViewSchema,
  PageSchema,
  validateSubmission,
  validateReceipt,
  validateLookup,
  validate,
  validateId,
  type ChatView,
  type ChatMessage,
  type StreamingReply,
  type HistoryPage,
  type Receipt,
  type Submission,
  OperationIdSchema,
} from "./index.ts";
import {
  CompactInputSchema,
  CompactResultSchema,
  type CompactInput,
  type CompactResult,
} from "./compact.ts";
import { decodeFrame, readCall, type WireSocket } from "./wire.ts";
import { createReplyProjection } from "./reply-projection.ts";
import { isReplySource } from "./reply-ranges.ts";

/** A provider-defined, process-local session lifetime; never serialized. */
export type ChatScope = symbol;
/** Changes contain committed absolute facts in provider observation order.
 * afterId is a visible source ID (null means first), never a native slot guess.
 * Use a window when the existing visible order cannot be expressed by changes. */
export type ChatChange =
  | { type: "session"; scope: ChatScope; nextScope: ChatScope; view: ChatView }
  /** A proven current-attempt result; transport may deliver it after a retry. */
  | { type: "deliveryResult"; scope: ChatScope; receipt: Receipt }
  | { type: "update"; scope: ChatScope;
      messages?: Array<{ type: "upsert"; message: ChatMessage; afterId?: string | null } | { type: "remove"; id: string }>;
      window?: { messages: ChatMessage[]; before: string | null };
      state?: Partial<Pick<ChatView, "activeTurnId" | "name" | "before" | "capabilities" | "contextUsage" | "compaction">> & {
        streamingReply?: StreamingReply | null;
        replyCompletedTurnId?: string | null;
      };
    }
  | { type: "error"; error: unknown };

/** Engine adapters own durable admission and execution. Socket disposal never cancels them. */
export interface ChatBackend extends PanelBackend, SearchBackend {
  read(signal?: AbortSignal): Promise<ChatView>;
  compact(input: CompactInput): Promise<CompactResult>;
  history(before: string): Promise<HistoryPage>;
  /** Attempts start at 1 and advance only on an explicit retry after failure.
   * Durable source identities preserve attempt numbering across restart. */
  submit(input: Submission): Promise<Receipt>;
  lookup(operationId: string): Promise<Receipt | null>;
  stop(turnId: string): Promise<{ stopped: boolean }>;
  /** Install before read(); changes use absolute source values and delivery order.
   * Startup changes are applied to the initial read in order: the provider must
   * prevent them from regressing facts included in that read and eventually
   * deliver subsequent facts the read did not include. This does not require a
   * global atomic snapshot across independent sources.
   * Use a fresh scope on each session lifetime, including a return to the same ID.
   * Emit deliveryResult for proven current-attempt changes even if view is unchanged.
   * Filter obsolete asynchronous results before delivery; close stops delivery. */
  subscribe(changed: (change: ChatChange) => void): { scope: ChatScope; close(): void };
}
/** Bounded identity only; never contains state, calls, or codec dictionaries. */
export interface ChatSubscription {
  version: 1;
  subscriptionId: string;
  serviceId: "lamplit.chat.v2";
  mode: "singleton";
}
export interface ChatConnectionOptions {
  /** Persist before acknowledging subscribe/unsubscribe. Throwing closes the channel. */
  onSubscriptionChange?(
    subscription: ChatSubscription | null,
  ): void | Promise<void>;
}
function readSubscription(value: unknown): ChatSubscription | null {
  if (value === null) return null;
  if (
    typeof value !== "object" ||
    !value ||
    Array.isArray(value) ||
    Object.keys(value).sort().join(",") !==
      "mode,serviceId,subscriptionId,version"
  )
    throw new Error("Invalid subscription");
  const record = value as ChatSubscription;
  if (
    record.version !== 1 ||
    record.serviceId !== Chat.id ||
    record.mode !== "singleton" ||
    typeof record.subscriptionId !== "string" ||
    !record.subscriptionId.length ||
    record.subscriptionId.length > 100
  )
    throw new Error("Invalid subscription");
  return {
    version: 1,
    subscriptionId: record.subscriptionId,
    serviceId: "lamplit.chat.v2",
    mode: "singleton",
  };
}
export async function createChatHost(
  backend: ChatBackend,
  onError: (error: unknown) => void = console.error,
  options: { signal?: AbortSignal } = {},
) {
  let replyProjection = createReplyProjection();
  const provider = new RemoteServiceProvider([Chat]);
  let closed = false, sessionEpoch = 0, scope: ChatScope;
  let view!: ReturnType<typeof replicatedState<ChatView>>;
  const pending: ChatChange[] = [];
  let starting = true;
  let failStartup!: (error: unknown) => void;
  const startupFailure = new Promise<never>((_, reject) => { failStartup = reject; });
  void startupFailure.catch(() => {});
  const report = (error: unknown) => { try { onError(error); } catch {} };
  const publish = (source: ChatView, reset = false) => {
    const checked = validate(ViewSchema, boundA2UIInMessages(source));
    const projection = reset ? createReplyProjection() : replyProjection;
    const next = projection.view(checked, reset ? undefined : view?.value);
    if (reset) replyProjection = projection;
    if (!view) { view = replicatedState(next); return; }
    if (JSON.stringify(next) === JSON.stringify(view.value)) return;
    view.change(BACKGROUND_CONTEXT, draft => {
      draft.messages = next.messages;
      if (next.streamingReply) draft.streamingReply = next.streamingReply;
      else delete draft.streamingReply;
      if (next.replyCompletedTurnId !== undefined) draft.replyCompletedTurnId = next.replyCompletedTurnId;
      else delete draft.replyCompletedTurnId;
      draft.before = next.before;
      draft.activeTurnId = next.activeTurnId;
      draft.name = next.name;
      draft.sessionId = next.sessionId;
      draft.capabilities = next.capabilities;
      draft.contextUsage = next.contextUsage;
      draft.compaction = next.compaction;
    });
  };
  const apply = (base: ChatView, change: ChatChange, bootstrap: boolean): ChatView => {
    if (change.type === "error") throw change.error;
    if (change.scope !== scope) return base;
    if (change.type === "session") {
      if (change.nextScope === scope) throw new Error("Session scope must change");
      scope = change.nextScope;
      sessionEpoch++;
      return change.view;
    }
    if (change.type === "deliveryResult") return base;
    if (change.window && change.messages?.length) throw new Error("Conflicting message updates");
    const preserveCompleted = (existing: ChatMessage | undefined, message: ChatMessage) => {
      if (!bootstrap || !existing || !isReplySource(existing) || !isReplySource(message) || existing.textState === "streaming") return message;
      if (message.textState !== "streaming") {
        if (existing.text !== message.text) throw new Error("Reply source conflict: completed source changed");
        return message;
      }
      const preserved = { ...message, text: existing.text };
      if (existing.textState === undefined) delete preserved.textState;
      else preserved.textState = existing.textState;
      return preserved;
    };
    const next: ChatView = { ...base, ...change.state, messages: change.window
      ? change.window.messages.map(message => preserveCompleted(base.messages.find(item => item.id === message.id), message))
      : base.messages.slice() } as ChatView;
    if (change.window) next.before = change.window.before;
    if (change.state?.streamingReply === null) delete next.streamingReply;
    if (change.state?.replyCompletedTurnId === null) delete next.replyCompletedTurnId;
    for (const operation of change.messages ?? []) {
      const index = next.messages.findIndex(item => item.id === (operation.type === "remove" ? operation.id : operation.message.id));
      if (operation.type === "remove") {
        if (index < 0 && !bootstrap) throw new Error("Unknown message to remove");
        if (index >= 0) next.messages.splice(index, 1);
        continue;
      }
      const message = preserveCompleted(next.messages[index], operation.message);
      if (index >= 0) next.messages.splice(index, 1);
      if (operation.afterId === undefined) {
        if (index < 0) throw new Error("New message requires an ordering anchor");
        next.messages.splice(index, 0, message);
      } else {
        const after = operation.afterId === null ? -1 : next.messages.findIndex(item => item.id === operation.afterId);
        if (operation.afterId !== null && after < 0) throw new Error("Unknown message ordering anchor");
        next.messages.splice(after + 1, 0, message);
      }
    }
    return next;
  };
  const changed = (change: ChatChange) => {
    if (closed) return;
    if (starting) {
      if (change.type === "error") { failStartup(change.error); return; }
      // Coalesce repeated absolute text updates while an initial read is held.
      const last = pending.at(-1);
      if (last?.type === "update" && change.type === "update" && last.scope === change.scope &&
          !last.window && !change.window && !last.state && !change.state &&
          last.messages?.length === 1 && change.messages?.length === 1 &&
          last.messages[0]?.type === "upsert" && change.messages[0]?.type === "upsert" &&
          last.messages[0].message.id === change.messages[0].message.id && change.messages[0].afterId === undefined) {
        pending[pending.length - 1] = { ...change, messages: [{ ...change.messages[0], afterId: last.messages[0].afterId }] };
      } else pending.push(change);
      return;
    }
    if (change.type === "error") {
      closeHost();
      report(change.error);
      return;
    }
    if (change.type === "deliveryResult") {
      if (change.scope !== scope) return;
      try {
        const receipt = validateReceipt(change.receipt);
        for (const connection of connections) connection.deliveryResult(receipt, sessionEpoch);
      } catch (error) { report(error); }
      return;
    }
    const oldScope = scope, oldEpoch = sessionEpoch;
    try {
      const next = apply(view.value, change, false);
      publish(next, scope !== oldScope);
    } catch (error) { scope = oldScope; sessionEpoch = oldEpoch; report(error); }
  };
  let subscription: ReturnType<ChatBackend["subscribe"]> | undefined;
  const signal = options.signal;
  const initialRead = new AbortController();
  let abort: (() => void) | undefined;
  try {
    if (signal?.aborted) throw new Error("Chat host initialization cancelled");
    subscription = backend.subscribe(changed);
    scope = subscription.scope;
    const read = backend.read(initialRead.signal);
    const cancelled = new Promise<never>((_, reject) => {
      abort = () => { initialRead.abort(); reject(new Error("Chat host initialization cancelled")); };
      signal?.addEventListener("abort", abort, { once: true });
    });
    if (signal?.aborted) abort?.();
    let initial = await Promise.race(signal ? [read, startupFailure, cancelled] : [read, startupFailure]);
    for (const change of pending) initial = apply(initial, change, true);
    publish(initial);
    starting = false;
    pending.length = 0;
  } catch (error) {
    closed = true;
    initialRead.abort();
    pending.length = 0;
    subscription?.close();
    provider.dispose();
    throw error;
  } finally {
    if (abort) signal?.removeEventListener("abort", abort);
  }
  const panels = Object.fromEntries(
    Object.entries(panelMethods).map(([method, schemas]) => [
      method,
      async (input: unknown) => {
        const read = validate(schemas[0], input);
        if (read.sessionId !== view.value.sessionId)
          throw new Error("Wrong session");
        const result = await (
          backend[method as keyof PanelBackend] as (
            input: unknown,
          ) => Promise<unknown>
        )(read);
        return validatePanelResult(method as keyof PanelBackend, result);
      },
    ]),
  ) as unknown as PanelBackend;
  provider.provide(Chat, {
    ...panels,
    view,
    async search(input) {
      return validateSearchResult(
        await backend.search(validateSearchInput(input)),
      );
    },
    async searchRead(input) {
      const value = validate(SearchReadInputSchema, input);
      return validateSearchReadResult(
        await backend.searchRead(value),
        value.id,
      );
    },
    async compact(input: CompactInput) {
      const value = validate(CompactInputSchema, input);
      if (value.sessionId !== view.value.sessionId)
        throw new Error("Wrong session");
      const epoch = sessionEpoch;
      if (
        view.value.activeTurnId ||
        view.value.compaction?.status === "running"
      )
        return { sessionId: value.sessionId, accepted: false };
      const result = validate(
        CompactResultSchema,
        await backend.compact(value),
      );
      if (sessionEpoch !== epoch || result.sessionId !== value.sessionId)
        throw new Error("Wrong compact session");
      return result;
    },
    async history(before: string) {
      // Retain only the request's starting view; pages without an overlapping
      // source cannot be ordered from the backend's existing contract.
      const initialView = view.value;
      const epoch = sessionEpoch;
      const page = validate(
        PageSchema,
        boundA2UIInMessages(await backend.history(validateId(before))),
      );
      if (closed || sessionEpoch !== epoch || view.value.sessionId !== initialView.sessionId)
        throw new Error("History session changed");
      return replyProjection.history(page, view.value, initialView);
    },
    async submit(input: Submission) {
      const value = validateSubmission(input);
      const sessionId = view.value.sessionId;
      const epoch = sessionEpoch;
      const receipt = validateReceipt(await backend.submit(value));
      if (receipt.operationId !== value.operationId)
        throw new Error("Wrong operation receipt");
      if (closed || sessionEpoch !== epoch || view.value.sessionId !== sessionId)
        throw new Error("Wrong receipt session");
      return receipt;
    },
    async lookup(id: string) {
      const value = validate(OperationIdSchema, id);
      const sessionId = view.value.sessionId;
      const epoch = sessionEpoch;
      const receipt = validateLookup(await backend.lookup(value));
      if (receipt && receipt.operationId !== value)
        throw new Error("Wrong operation receipt");
      if (
        closed || sessionEpoch !== epoch || view.value.sessionId !== sessionId
      )
        throw new Error("Wrong receipt session");
      return receipt;
    },
    async stop(id: string) {
      const result = await backend.stop(validateId(id));
      return result;
    },
  });
  const connections = new Set<ReturnType<typeof connect>>();
  function closeHost() {
    if (closed) return;
    closed = true;
    replyProjection.clear();
    subscription?.close();
    for (const c of connections) c.disconnect();
    provider.dispose();
  }
  function connect(
    socket: WireSocket,
    authorize: () => Promise<boolean>,
    options: ChatConnectionOptions = {},
  ) {
    if (closed) throw new Error("Chat host closed");
    let disposed = false;
    const subscriptions = new Map<string, ServiceSubscription>();
    let subscription: ChatSubscription | null = null;
    let incoming: Promise<void> = Promise.resolve();
    let activeReads = 0;
    const enqueue = (work: () => Promise<void>) => {
      const next = incoming.then(work);
      incoming = next.catch(() => {});
      return next;
    };
    const fail = () => {
      socket.close(1011, "Connection failed");
      dispose();
    };
    async function persist(next: ChatSubscription | null) {
      try {
        await options.onSubscriptionChange?.(next && { ...next });
        if (!disposed) subscription = next;
      } catch (error) {
        fail();
        throw error;
      }
    }
    function subscribe(record: ChatSubscription) {
      const encoder = createServiceStateEncoder();
      const sub = provider.subscribe(record.serviceId, record.mode, (update) =>
        deliver({
          type: "update",
          subscriptionId: record.subscriptionId,
          update: encoder.encodeUpdate(update),
        }),
      );
      subscriptions.set(record.subscriptionId, sub);
      return { encoder, sub };
    }
    let outgoing: Promise<void> = Promise.resolve();
    let queuedBytes = 0;
    const deliver = (frame: unknown, current: () => boolean = () => true) => {
      if (disposed) return;
      const raw = JSON.stringify(frame);
      const bytes = new TextEncoder().encode(raw).byteLength;
      if (
        bytes > 2 * 1024 * 1024 ||
        queuedBytes + bytes + (socket.bufferedAmount ?? 0) > 4 * 1024 * 1024
      ) {
        socket.close(1013, "Reconnect");
        dispose();
        return;
      }
      queuedBytes += bytes;
      outgoing = outgoing
        .then(async () => {
          try {
            if (disposed) return;
            if (!(await authorize())) {
              socket.close(1008, "Session expired");
              dispose();
              return;
            }
            if (!disposed && current()) socket.send(raw);
          } finally {
            queuedBytes -= bytes;
          }
        })
        .catch((error) => {
          onError(error);
          socket.close(1011, "Connection failed");
          dispose();
        });
    };
    function dispose() {
      if (disposed) return;
      disposed = true;
      for (const sub of subscriptions.values()) sub.close();
      subscriptions.clear();
      subscription = null;
      connections.delete(connection);
    }
    async function process(raw: string, readOverloaded = false) {
      if (disposed) return;
      if (!(await authorize())) {
        socket.close(1008, "Session expired");
        dispose();
        return;
      }
      if (disposed) return;
      let id: string | undefined;
      try {
        const frame = decodeFrame(raw);
        if (
          frame.type !== "call" ||
          frame.version !== 1 ||
          typeof frame.id !== "string" ||
          frame.id.length > 100
        )
          throw new Error("Invalid request");
        id = frame.id;
        const call = readCall(frame.call);
        const control = decodeServiceControlCall(call);
        let result: unknown;
        if (control?.type === "subscribe") {
          if (subscriptions.size || subscriptions.has(control.subscriptionId))
            throw new Error("Already subscribed");
          const record = readSubscription({
            version: 1,
            subscriptionId: control.subscriptionId,
            serviceId: control.serviceId,
            mode: control.mode,
          })!;
          const { encoder, sub } = subscribe(record);
          result = encoder.encodeSnapshot(sub.snapshot);
          await persist(record);
          if (disposed) return;
          deliver({ type: "result", id, result });
          sub.activate();
          return;
        } else if (control?.type === "unsubscribe") {
          subscriptions.get(control.subscriptionId)?.close();
          subscriptions.delete(control.subscriptionId);
          await persist(subscriptions.size ? subscription : null);
          if (disposed) return;
          result = null;
        } else if (control?.type === "catalogue") result = provider.catalogue;
        else {
          if (
            call.serviceId !== Chat.id ||
            call.instance ||
            ![
              "history",
              "submit",
              "lookup",
              "stop",
              "compact",
              "search",
              "searchRead",
              ...Object.keys(panelMethods),
            ].includes(call.member) ||
            call.args.length !== 1
          )
            throw new Error("Invalid method");
          if (readOverloaded) throw new Error("Too many concurrent reads");
          result = (await provider.invoke(
            call,
            BACKGROUND_CONTEXT,
          )) as JsonValue;
        }
        const reply = { type: "result", id, result: result ?? null };
        // Method results fail in isolation before the transport would disconnect.
        if (
          new TextEncoder().encode(JSON.stringify(reply)).byteLength >
          2 * 1024 * 1024
        )
          throw new Error("Method result exceeds frame limit");
        deliver(reply);
      } catch (error) {
        if (!id) {
          socket.close(1002, "Invalid frame");
          dispose();
        } else
          deliver({
            type: "error",
            id,
            error: "Request could not be completed",
          });
        onError(error);
      }
    }
    const connection = {
      deliveryResult(receipt: Receipt, epoch: number) {
        const record = subscription;
        if (!record || !subscriptions.has(record.subscriptionId)) return;
        deliver({ type: "deliveryResult", subscriptionId: record.subscriptionId, receipt },
          () => sessionEpoch === epoch && subscription === record && subscriptions.has(record.subscriptionId));
      },
      receive(raw: string) {
        return enqueue(async () => {
          let read = false;
          try {
            const frame = decodeFrame(raw);
            const call = readCall(frame.call);
            read =
              frame.type === "call" &&
              frame.version === 1 &&
              typeof frame.id === "string" &&
              frame.id.length <= 100 &&
              call.serviceId === Chat.id &&
              !call.instance &&
              (call.member === "history" || call.member === "lookup") &&
              call.args.length === 1;
          } catch {
            /* Invalid frames follow the ordinary validation path. */
          }
          if (!read) return process(raw);
          const accepted = activeReads < 8;
          if (accepted) activeReads++;
          void process(raw, !accepted)
            .catch(onError)
            .finally(() => {
              if (accepted) activeReads--;
            });
        }).catch(onError);
      },
      getSubscription(): ChatSubscription | null {
        return subscription && { ...subscription };
      },
      restoreSubscription(value: unknown): Promise<void> {
        return enqueue(async () => {
          if (disposed) throw new Error("Connection closed");
          try {
            const record = readSubscription(value);
            if (subscriptions.size) throw new Error("Already subscribed");
            if (!(await authorize())) {
              socket.close(1008, "Session expired");
              dispose();
              throw new Error("Unauthorized subscription");
            }
            if (disposed || !record) return;
            const { encoder, sub } = subscribe(record);
            subscription = record;
            deliver({
              type: "update",
              subscriptionId: record.subscriptionId,
              update: encoder.encodeUpdate({
                type: "reset",
                snapshot: sub.snapshot,
              }),
            });
            sub.activate();
            await outgoing;
          } catch (error) {
            if (!disposed) fail();
            throw error;
          }
        });
      },
      close: dispose,
      disconnect() {
        socket.close(1012, "Reconnect");
        dispose();
      },
    };
    connections.add(connection);
    return connection;
  }
  return {
    connect,
    close: closeHost,
  };
}

export { imageHttp, type ImageBackend } from "./image-http.ts";
export { stickerHttp } from "./sticker-http.ts";

export { fileHttp, type FileBackend, type FileOwner } from "./file-http.ts";

export { fileStreamHttp, type FileStreamBackend, type FileStreamStatus } from "./file-stream-http.ts";

export { FileOperationRetiredError, FileOperationNotFoundError } from "./files.ts";
