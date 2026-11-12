import assert from 'node:assert/strict';
import test from 'node:test';
import { runInputAreaProbe } from '../modules/etos-input-area/src/probe-core';
type IosProbeSignature = typeof import('../modules/etos-input-area/src/probe.ios').probeInputAreaTargets;
const typecheckIosSignature: IosProbeSignature | undefined = undefined;
void typecheckIosSignature;

const args = () => ({ hostTag: 1, scrollTag: 2, inputTag: 3, current: () => true });

test('probe validates its explicit targets, native result and old-binary fallback', async () => {
  let calls = 0;
  const native = { probeTargets: async (...tags: number[]) => { calls++; assert.deepEqual(tags, [1, 2, 3]); return { status: 'observed', inputFocused: true, scrollInteracting: false, kcsvAncestor: true }; } };
  assert.deepEqual(await runInputAreaProbe(args(), native), { status: 'observed', inputFocused: true, scrollInteracting: false, kcsvAncestor: true });
  assert.deepEqual(await runInputAreaProbe({ ...args(), scrollTag: 0 }, native), { status: 'invalid_targets' });
  assert.equal(calls, 1);
  assert.deepEqual(await runInputAreaProbe(args(), null), { status: 'unavailable' });
  for (const status of ['host_unavailable', 'input_unsupported', 'scroll_unsupported']) {
    assert.deepEqual(await runInputAreaProbe(args(), { probeTargets: async () => ({ status }) }), { status });
  }
  assert.deepEqual(await runInputAreaProbe(args(), { probeTargets: async () => ({ status: 'observed', inputFocused: true }) }), { status: 'invalid_response' });
  assert.deepEqual(await runInputAreaProbe(args(), { probeTargets: async () => ({ status: 'host_unavailable', unexpected: true }) }), { status: 'invalid_response' });
  assert.deepEqual(await runInputAreaProbe(args(), { probeTargets: async () => { throw Error('sensitive native details'); } }), { status: 'unavailable' });
});

test('a late result or rejection from an invalidated scope is discarded', async () => {
  for (const fail of [false, true]) {
    let valid = true;
    let finish!: (value: unknown) => void;
    let reject!: (error: Error) => void;
    const pending = new Promise<unknown>((resolve, rejectPromise) => { finish = resolve; reject = rejectPromise; });
    const result = runInputAreaProbe({ ...args(), current: () => valid }, { probeTargets: () => pending });
    valid = false;
    if (fail) reject(Error('old')); else finish({ status: 'observed', inputFocused: true, scrollInteracting: false, kcsvAncestor: false });
    assert.deepEqual(await result, { status: 'session_changed' });
  }
  assert.deepEqual(await runInputAreaProbe({ ...args(), current: () => false }, null), { status: 'session_changed' });
});
