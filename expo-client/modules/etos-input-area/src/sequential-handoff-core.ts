// Isolated candidate: event + request coordination without React or network.
export type SequentialArgs = { hostTag: number; panelTag: number; inputTag: number; generation: number; operation: number; mode: 'panel' | 'keyboard' | 'dismiss'; height: number; current: () => boolean };
export type SequentialEvent = { generation: number; operation: number; status: 'will_hide' | 'did_hide' | 'will_show' | 'did_show' | 'target_focused' | 'shown' | 'hidden' | 'cancelled' | 'drained' | 'owner_lost' | 'focus_unknown' | 'focus_refused' | 'resign_refused' };
export type SequentialNative = {
  supportsSequentialHandoff?: () => boolean;
  enableSequentialHandoff?: (panel: number, generation: number) => Promise<unknown>;
  disableSequentialHandoff?: (panel: number, generation: number) => Promise<unknown>;
  snapshotSequentialHandoff?: (host: number, panel: number, input: number, generation: number) => Promise<unknown>;
  beginSequentialHandoff?: (host: number, panel: number, input: number, generation: number, operation: number, destination: number, height: number) => Promise<unknown>;
  cancelSequentialHandoff?: (panel: number, generation: number, operation: number) => Promise<unknown>;
  inspectSequentialHandoff?: (panel: number, generation: number, operation: number) => Promise<unknown>;
};
export function sequentialAvailable(native: SequentialNative | null): boolean {
  try { return !!native && native.supportsSequentialHandoff?.() === true && typeof native.enableSequentialHandoff === 'function' && typeof native.disableSequentialHandoff === 'function' && typeof native.snapshotSequentialHandoff === 'function' && typeof native.beginSequentialHandoff === 'function' && typeof native.cancelSequentialHandoff === 'function' && typeof native.inspectSequentialHandoff === 'function'; } catch { return false; }
}
const knownBegin = new Set(['requested', 'session_changed','invalid_operation','busy','targets_unavailable','invalid_height','input_unsupported','composition_active','keyboard_state_unknown','input_owned_elsewhere','focus_unknown','focus_refused','resign_refused']);
const events = new Set(['will_hide','did_hide','will_show','did_show','target_focused','shown','hidden','cancelled','drained','owner_lost','focus_unknown','focus_refused','resign_refused']);
const int = (value: number, allowZero = false) => Number.isSafeInteger(value) && (allowZero ? value >= 0 : value > 0);
export async function enableSequential(panel: number, generation: number, native: SequentialNative | null): Promise<{status:string}> {
  if (!int(panel) || !int(generation,true)) return {status:'invalid_request'};
  if (!sequentialAvailable(native)) return {status:'unavailable'};
  try { const result = await native!.enableSequentialHandoff!(panel,generation); return {status:typeof result === 'string' && ['enabled','session_changed','targets_unavailable','input_owned_elsewhere'].includes(result) ? result : 'unknown'}; } catch { return {status:'unknown'}; }
}
export async function disableSequential(panel: number, generation: number, native: SequentialNative | null): Promise<{status:string}> {
  if (!int(panel) || !int(generation,true)) return {status:'invalid_request'};
  if (!sequentialAvailable(native)) return {status:'unavailable'};
  try { const result = await native!.disableSequentialHandoff!(panel,generation); return {status:typeof result === 'string' && ['disabled','session_changed','targets_unavailable','draining','panel_visible','focus_refused'].includes(result) ? result : 'unknown'}; } catch { return {status:'unknown'}; }
}
export async function snapshotSequential(host:number, panel:number, input:number, generation:number, current:()=>boolean, native:SequentialNative|null):Promise<Record<string,string>> {
  if (!current()) return {status:'session_changed'};
  if (![host,panel,input].every(x=>int(x)) || !int(generation,true)) return {status:'invalid_request'};
  if (!sequentialAvailable(native)) return {status:'unavailable'};
  let raw:unknown; try { raw=await native!.snapshotSequentialHandoff!(host,panel,input,generation); } catch { return {status:'unknown'}; }
  if (!current()) return {status:'session_changed'};
  if (!raw || typeof raw !== 'object') return {status:'unknown'};
  const v=raw as Record<string,unknown>;
  if (v.status === 'unavailable') return {status:'unavailable'};
  if (v.status !== 'observed' || typeof v.focus !== 'string' || !['composer','panel','fence','window','other','unknown'].includes(v.focus) || typeof v.visibility !== 'string' || !['unknown','changing','visible','hidden'].includes(v.visibility) || typeof v.geometry !== 'string' || !['overlap_possible','no_overlap_observed'].includes(v.geometry)) return {status:'unknown'};
  return {status:'observed',focus:v.focus,visibility:v.visibility,geometry:v.geometry};
}
export async function beginSequential(args: SequentialArgs, native: SequentialNative | null): Promise<{status:string}> {
  if (!args.current()) return {status:'session_changed'};
  if (![args.hostTag,args.panelTag,args.inputTag,args.operation].every(x => int(x)) || !int(args.generation,true) || !['panel','keyboard','dismiss'].includes(args.mode) || !Number.isFinite(args.height) || args.height < 1 || args.height > 1000) return {status:'invalid_request'};
  if (!sequentialAvailable(native)) return {status:'unavailable'};
  let result: unknown;
  try { result = await native!.beginSequentialHandoff!(args.hostTag,args.panelTag,args.inputTag,args.generation,args.operation,args.mode === 'panel' ? 0 : args.mode === 'keyboard' ? 1 : 2,args.height); }
  catch { return {status:args.current() ? 'unknown' : 'session_changed'}; }
  if (!args.current()) return {status:'session_changed'};
  return {status:typeof result === 'string' && knownBegin.has(result) ? result : 'unknown'};
}
export function sanitizeSequentialEvent(value: unknown, generation: number, operation: number, current: () => boolean): SequentialEvent | null {
  if (!current() || !value || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  if (record.generation !== generation || record.operation !== operation || typeof record.status !== 'string' || !events.has(record.status)) return null;
  return {generation, operation, status:record.status as SequentialEvent['status']};
}
export async function cancelSequential(panel: number, generation: number, operation: number, native: SequentialNative | null): Promise<{status:string}> {
  if (!int(panel) || !int(generation,true) || !int(operation)) return {status:'invalid_request'};
  if (!sequentialAvailable(native)) return {status:'unavailable'};
  try { const result = await native!.cancelSequentialHandoff!(panel,generation,operation); return {status:typeof result === 'string' && ['not_pending','draining','cancelled'].includes(result) ? result : 'unknown'}; } catch { return {status:'unknown'}; }
}
export async function inspectSequential(panel: number, generation: number, operation: number, native: SequentialNative | null): Promise<{status:string}> {
  if (!int(panel) || !int(generation,true) || !int(operation)) return {status:'invalid_request'};
  if (!sequentialAvailable(native)) return {status:'unavailable'};
  try { const result = await native!.inspectSequentialHandoff!(panel,generation,operation); return {status:typeof result === 'string' && ['not_pending','draining','pending_unconfirmed'].includes(result) ? result : 'unknown'}; } catch { return {status:'unknown'}; }
}
