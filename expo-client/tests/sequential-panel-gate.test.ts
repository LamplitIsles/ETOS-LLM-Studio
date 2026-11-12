import assert from 'node:assert/strict';
import test from 'node:test';
import { SequentialPanelGate } from '../src/ui/sequentialPanelGate';

const identity = { panel: 7, generation: 2, operation: 1 };
const shown = { generation: 2, operation: 1, status: 'shown' } as const;
const gatePromise = () => { let resolve!: (value: { status: string }) => void; const promise = new Promise<{ status: string }>(r => { resolve = r; }); return { promise, resolve }; };

test('a real shown event completes even while the native acknowledgement is pending', async () => {
  const gate = new SequentialPanelGate(), native = gatePromise();
  const result = gate.run(identity, 'panel', () => true, () => native.promise);
  await Promise.resolve();
  assert.equal(gate.receive(shown), 'panel');
  assert.deepEqual(await result, { status: 'requested' });
  native.resolve({ status: 'unknown' });
  await Promise.resolve();
  assert.equal(gate.receive({ ...shown, status: 'owner_lost' }), 'owner_lost');
});

test('unknown acknowledgement retains the exact operation for explicit abandonment', async () => {
  const gate = new SequentialPanelGate();
  assert.deepEqual(await gate.run(identity, 'panel', () => true, async () => ({ status: 'unknown' })), { status: 'unavailable' });
  assert.equal(gate.receive(shown), null);
  assert.deepEqual(gate.abandon(), identity);
  assert.equal(gate.abandon(), null);
});

test('cancellation waits for drain and ignores stale events', async () => {
  const gate = new SequentialPanelGate();
  const result = gate.run(identity, 'keyboard', () => true, async () => ({ status: 'requested' }));
  await Promise.resolve();
  assert.equal(gate.receive({ ...shown, generation: 3 }), null);
  assert.equal(gate.receive({ ...shown, status: 'cancelled' }), null);
  assert.equal(gate.receive(shown), null);
  assert.equal(gate.receive({ ...shown, status: 'drained' }), null);
  assert.deepEqual(await result, { status: 'targets_unavailable' });
});

test('abandon before dispatch never starts a stale operation', async () => {
  const gate = new SequentialPanelGate(); let calls = 0;
  const result = gate.run(identity, 'panel', () => true, async () => { calls++; return { status: 'requested' }; });
  assert.deepEqual(gate.abandon(2), identity);
  assert.deepEqual(await result, { status: 'session_changed' });
  await Promise.resolve();
  assert.equal(calls, 0);
});

test('a refused new operation does not erase the last confirmed panel owner', async () => {
  const gate = new SequentialPanelGate();
  const open = gate.run(identity, 'panel', () => true, async () => ({ status: 'requested' }));
  await Promise.resolve();
  assert.equal(gate.receive(shown), 'panel');
  await open;
  assert.deepEqual(await gate.run({ ...identity, operation: 2 }, 'keyboard', () => true, async () => ({ status: 'keyboard_state_unknown' })), { status: 'targets_unavailable' });
  assert.equal(gate.receive({ ...shown, status: 'owner_lost' }), 'owner_lost');
});

test('a late native focus failure retains operation ownership until abandonment', async () => {
  const gate = new SequentialPanelGate();
  const result = gate.run(identity, 'panel', () => true, async () => ({ status: 'requested' }));
  await Promise.resolve();
  assert.equal(gate.receive({ ...shown, status: 'focus_unknown' }), null);
  assert.deepEqual(await result, { status: 'unavailable' });
  assert.equal(gate.receive(shown), null);
  assert.deepEqual(gate.abandon(), identity);
});

test('owner loss is observed while the next operation is waiting for dispatch', async () => {
  const gate = new SequentialPanelGate();
  const open = gate.run(identity, 'panel', () => true, async () => ({ status: 'requested' }));
  await Promise.resolve(); gate.receive(shown); await open;
  const next = gate.run({ ...identity, operation: 2 }, 'keyboard', () => true, async () => ({ status: 'keyboard_state_unknown' }));
  assert.equal(gate.receive({ ...shown, status: 'owner_lost' }), 'owner_lost');
  assert.deepEqual(await next, { status: 'targets_unavailable' });
  assert.equal(gate.receive({ ...shown, status: 'owner_lost' }), null);
});

test('draining a cancelled keyboard handoff clears the previous panel owner', async () => {
  const gate = new SequentialPanelGate();
  const open = gate.run(identity, 'panel', () => true, async () => ({ status: 'requested' }));
  await Promise.resolve(); gate.receive(shown); await open;
  const next = gate.run({ ...identity, operation: 2 }, 'keyboard', () => true, async () => ({ status: 'requested' }));
  await Promise.resolve();
  gate.receive({ generation: 2, operation: 2, status: 'cancelled' });
  assert.equal(gate.receive({ generation: 2, operation: 2, status: 'drained' }), 'owner_lost');
  assert.deepEqual(await next, { status: 'targets_unavailable' });
  assert.equal(gate.receive({ ...shown, status: 'owner_lost' }), null);
});
