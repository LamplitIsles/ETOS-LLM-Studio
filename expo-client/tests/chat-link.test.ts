import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isChatLink, listenForChatLink } from '../src/ui/chatLink';

test('only the fixed chat intent is accepted, never authentication or parameters', () => {
  assert.equal(isChatLink('etosllmstudio://open/chat'), true);
  for (const value of [null, undefined, 'etosllmstudio://auth/callback', 'etosllmstudio://open/chat?origin=https://example.test',
    'etosllmstudio://open/chat#fragment', 'etosllmstudio://open/chat/', 'etosllmstudio://evil/chat',
    'etosllmstudio://user@open/chat', 'https://open/chat', 'etosllmstudio://open/%63hat']) {
    assert.equal(isChatLink(value), false, String(value));
  }
});

test('launch and foreground links share a listener, deduplicate startup and ignore cleanup', async () => {
  let resolve!: (value: string | null) => void;
  let listener!: (event: { url: string }) => void;
  let removed = false, opened = 0;
  const linking = {
    getInitialURL: () => new Promise<string | null>(done => { resolve = done; }),
    addEventListener: (_type: 'url', fn: (event: { url: string }) => void) => { listener = fn; return { remove: () => { removed = true; } }; },
  };
  const stop = listenForChatLink(linking, () => { opened++; });
  listener({ url: 'etosllmstudio://auth/callback' });
  listener({ url: 'etosllmstudio://open/chat' });
  resolve('etosllmstudio://open/chat');
  await Promise.resolve();
  assert.equal(opened, 1);
  listener({ url: 'etosllmstudio://open/chat' });
  assert.equal(opened, 2);
  stop(); listener({ url: 'etosllmstudio://open/chat' });
  assert.equal(removed, true); assert.equal(opened, 2);
});

test('a launch link is delivered unless the subscription was disposed', async () => {
  let resolve!: (value: string | null) => void;
  let opened = 0;
  const start = () => listenForChatLink({
    getInitialURL: () => new Promise<string | null>(done => { resolve = done; }),
    addEventListener: () => ({ remove() {} }),
  }, () => { opened++; });
  const stop = start(); resolve('etosllmstudio://open/chat'); await Promise.resolve();
  assert.equal(opened, 1); stop();
  const cancel = start(); cancel(); resolve('etosllmstudio://open/chat'); await Promise.resolve();
  assert.equal(opened, 1);
});
