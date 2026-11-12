export type KeyboardPanelRequest = {
  hostTag: number;
  panelTag: number;
  inputTag: number;
  generation: number;
  mode: 'keyboard' | 'panel';
  height: number;
  current: () => boolean;
};

export type KeyboardPanelResult = { status: 'requested' | 'session_changed' | 'invalid_request' | 'unavailable' | 'targets_unavailable' | 'input_unsupported' | 'input_not_focused' | 'input_owned_elsewhere' | 'dismiss_refused' | 'invalid_height' | 'invalid_response' };
export type KeyboardPanelDismiss = Pick<KeyboardPanelRequest, 'hostTag' | 'panelTag' | 'inputTag' | 'generation' | 'current'>;
export type KeyboardPanelNative = {
  requestKeyboardPanel(hostTag: number, panelTag: number, inputTag: number, generation: number, panel: boolean, height: number): Promise<unknown>;
  dismissKeyboardPanel?(hostTag: number, panelTag: number, inputTag: number, generation: number): Promise<unknown>;
};

export async function runKeyboardPanelRequest(args: KeyboardPanelRequest, native: KeyboardPanelNative | null): Promise<KeyboardPanelResult> {
  if (!args.current()) return { status: 'session_changed' };
  if (![args.hostTag, args.panelTag, args.inputTag].every(x => Number.isSafeInteger(x) && x > 0) ||
      !Number.isSafeInteger(args.generation) || args.generation < 0 ||
      (args.mode !== 'panel' && args.mode !== 'keyboard') || !Number.isFinite(args.height) || args.height < 1 || args.height > 1000) return { status: 'invalid_request' };
  if (!native || typeof native.requestKeyboardPanel !== 'function') return { status: 'unavailable' };
  let result: unknown;
  try { result = await native.requestKeyboardPanel(args.hostTag, args.panelTag, args.inputTag, args.generation, args.mode === 'panel', args.height); }
  catch { return { status: args.current() ? 'unavailable' : 'session_changed' }; }
  if (!args.current()) return { status: 'session_changed' };
  const known = ['requested', 'session_changed', 'targets_unavailable', 'input_unsupported', 'input_not_focused', 'input_owned_elsewhere', 'invalid_height'];
  return typeof result === 'string' && known.includes(result) ? { status: result as KeyboardPanelResult['status'] } : { status: 'invalid_response' };
}

export async function runKeyboardPanelDismiss(args: KeyboardPanelDismiss, native: KeyboardPanelNative | null): Promise<KeyboardPanelResult> {
  if (!args.current()) return { status: 'session_changed' };
  if (![args.hostTag, args.panelTag, args.inputTag].every(x => Number.isSafeInteger(x) && x > 0) || !Number.isSafeInteger(args.generation) || args.generation < 0) return { status: 'invalid_request' };
  if (!native || typeof native.dismissKeyboardPanel !== 'function') return { status: 'unavailable' };
  let result: unknown;
  try { result = await native.dismissKeyboardPanel(args.hostTag, args.panelTag, args.inputTag, args.generation); }
  catch { return { status: args.current() ? 'unavailable' : 'session_changed' }; }
  if (!args.current()) return { status: 'session_changed' };
  const known = ['requested', 'session_changed', 'targets_unavailable', 'input_unsupported', 'input_owned_elsewhere', 'dismiss_refused'];
  return typeof result === 'string' && known.includes(result) ? { status: result as KeyboardPanelResult['status'] } : { status: 'invalid_response' };
}
