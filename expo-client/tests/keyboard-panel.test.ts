import assert from 'node:assert/strict';
import test from 'node:test';
import { runKeyboardPanelDismiss, runKeyboardPanelRequest } from '../modules/etos-input-area/src/keyboard-panel-core';
type IosSignature = typeof import('../modules/etos-input-area/src/keyboard-panel.ios').requestKeyboardPanel;
const iosTypecheck: IosSignature | undefined = undefined;
void iosTypecheck;

const args = () => ({ hostTag: 1, panelTag: 2, inputTag: 3, generation: 4, mode: 'panel' as const, height: 300, current: () => true });
test('request passes the exact scoped targets once and handles unavailability', async () => {
  let calls = 0;
  const native = { requestKeyboardPanel: async (...values: unknown[]) => { calls++; assert.deepEqual(values, [1, 2, 3, 4, true, 300]); return 'requested'; } };
  assert.deepEqual(await runKeyboardPanelRequest(args(), native), { status: 'requested' });
  assert.deepEqual(await runKeyboardPanelRequest({ ...args(), panelTag: 0 }, native), { status: 'invalid_request' });
  assert.deepEqual(await runKeyboardPanelRequest({ ...args(), height: Infinity }, native), { status: 'invalid_request' });
  assert.deepEqual(await runKeyboardPanelRequest(args(), null), { status: 'unavailable' });
  assert.equal(calls, 1);
  assert.deepEqual(await runKeyboardPanelRequest({ ...args(), current: () => false }, native), { status: 'session_changed' });
  assert.equal(calls, 1);
  const keyboard = { requestKeyboardPanel: async (...values: unknown[]) => { assert.equal(values[4], false); return 'requested'; } };
  assert.deepEqual(await runKeyboardPanelRequest({ ...args(), mode: 'keyboard' }, keyboard), { status: 'requested' });
  assert.deepEqual(await runKeyboardPanelRequest(args(), { requestKeyboardPanel: async () => 'input_not_focused' }), { status: 'input_not_focused' });
  assert.deepEqual(await runKeyboardPanelRequest(args(), { requestKeyboardPanel: async () => 'unexpected private details' }), { status: 'invalid_response' });
});
test('a late response is not treated as completion in a new scope', async () => {
  let active = true;
  let resolve!: (result: string) => void;
  const pending = new Promise<string>(done => { resolve = done; });
  const result = runKeyboardPanelRequest({ ...args(), current: () => active }, { requestKeyboardPanel: () => pending });
  active = false; resolve('requested');
  assert.deepEqual(await result, { status: 'session_changed' });
});

test('dismiss targets only the owning input and never retries unknown results', async () => {
  let calls = 0;
  const native = { requestKeyboardPanel: async () => 'requested', dismissKeyboardPanel: async (...values: unknown[]) => { calls++; assert.deepEqual(values, [1, 2, 3, 4]); return 'requested'; } };
  assert.deepEqual(await runKeyboardPanelDismiss(args(), native), { status: 'requested' });
  assert.deepEqual(await runKeyboardPanelDismiss({ ...args(), current: () => false }, native), { status: 'session_changed' });
  assert.deepEqual(await runKeyboardPanelDismiss(args(), { requestKeyboardPanel: native.requestKeyboardPanel }), { status: 'unavailable' });
  assert.equal(calls, 1);
  let failures = 0;
  assert.deepEqual(await runKeyboardPanelDismiss(args(), { ...native, dismissKeyboardPanel: async () => { failures++; throw Error('private'); } }), { status: 'unavailable' });
  assert.equal(failures, 1);
  let reject!: (error: Error) => void;
  let active = true;
  const pending = new Promise<string>((_resolve, fail) => { reject = fail; });
  const result = runKeyboardPanelDismiss({ ...args(), current: () => active }, { ...native, dismissKeyboardPanel: () => pending });
  active = false; reject(Error('private'));
  assert.deepEqual(await result, { status: 'session_changed' });
});
