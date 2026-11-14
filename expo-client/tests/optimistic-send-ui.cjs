// Run only against a fresh test-owned seed host with ETOS_UI_HOLD_SUBMISSIONS=1.
const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');

(async () => {
  const controlPort = Number(process.env.ETOS_UI_SYNTHETIC_HOST_PORT);
  if (!Number.isInteger(controlPort) || controlPort < 1024 || controlPort > 65535 || [3090, 5173, 8081, 8082, 8091, 8092, 18093].includes(controlPort)) throw new Error('Expected a test-owned fixture control port');
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const input = page.getByRole('textbox', { name: '输入消息…' });
    await input.waitFor({ timeout: 60000 });
    await input.fill('合成发送内容');
    await page.getByRole('button', { name: '发送消息', exact: true }).click();
    const bubble = page.getByTestId('message-user').filter({ hasText: '合成发送内容' });
    await bubble.waitFor({ timeout: 15000 });
    const initialId = await bubble.getAttribute('id');
    assert.ok(initialId, 'pending bubble exposes its timeline identity');
    await page.waitForFunction(() => {
      const input = document.querySelector('textarea[aria-label="输入消息…"]');
      return input && input.value === '' && !input.readOnly && !input.disabled;
    }, null, { timeout: 5000 });
    await input.fill('合成新草稿');
    const released = await fetch(`http://127.0.0.1:${controlPort}/__test/send/release`, { method: 'POST' });
    assert.equal(released.status, 204);
    await page.getByText('我听到了。我们可以慢慢聊，你现在最想从哪儿说起？', { exact: true }).waitFor({ timeout: 15000 });
    assert.equal(await input.inputValue(), '合成新草稿', 'a late receipt does not clear the next draft');
    assert.equal(await bubble.count(), 1, 'admission and the server message share one bubble');
    assert.equal(await bubble.getAttribute('id'), initialId, 'the bubble keeps its identity on confirmation');
    console.log('PASS: local admission unlocks input and a late receipt preserves the new draft and message identity');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
