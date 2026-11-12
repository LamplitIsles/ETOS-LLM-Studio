export type InputAreaProbeArgs = {
  /** React tags obtained from the current mounted host, FlashList and TextInput. */
  hostTag: number;
  scrollTag: number;
  inputTag: number;
  /** False after session change, unmount or superseding probe. */
  current: () => boolean;
};

export type InputAreaProbeResult =
  | { status: 'observed'; inputFocused: boolean; scrollInteracting: boolean; kcsvAncestor: boolean }
  | { status: 'host_unavailable' | 'input_unsupported' | 'scroll_unsupported' | 'unavailable' | 'invalid_targets' | 'invalid_response' | 'session_changed' };

type NativeProbe = { probeTargets(hostTag: number, scrollTag: number, inputTag: number): Promise<unknown> };

/** Checks only this invocation; it never retains a native view or creates a binding. */
export async function runInputAreaProbe(args: InputAreaProbeArgs, native: NativeProbe | null): Promise<InputAreaProbeResult> {
  if (!args.current()) return { status: 'session_changed' };
  if (![args.hostTag, args.scrollTag, args.inputTag].every(tag => Number.isSafeInteger(tag) && tag > 0)) return { status: 'invalid_targets' };
  if (!native || typeof native.probeTargets !== 'function') return { status: 'unavailable' };
  let value: unknown;
  try { value = await native.probeTargets(args.hostTag, args.scrollTag, args.inputTag); }
  catch { return { status: args.current() ? 'unavailable' : 'session_changed' }; }
  if (!args.current()) return { status: 'session_changed' };
  if (!value || typeof value !== 'object' || Array.isArray(value)) return { status: 'invalid_response' };
  const result = value as Record<string, unknown>;
  if (typeof result.status === 'string' && ['host_unavailable', 'input_unsupported', 'scroll_unsupported'].includes(result.status) && Object.keys(result).length === 1) {
    return { status: result.status as 'host_unavailable' | 'input_unsupported' | 'scroll_unsupported' };
  }
  if (result.status === 'observed' && Object.keys(result).length === 4 &&
      typeof result.inputFocused === 'boolean' && typeof result.scrollInteracting === 'boolean' && typeof result.kcsvAncestor === 'boolean') {
    return { status: 'observed', inputFocused: result.inputFocused, scrollInteracting: result.scrollInteracting, kcsvAncestor: result.kcsvAncestor };
  }
  return { status: 'invalid_response' };
}
