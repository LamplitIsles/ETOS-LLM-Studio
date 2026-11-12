// Requires test:ui:host with ETOS_UI_REPLY_FIXTURE=1 and a test-only Metro.
const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');

(async () => {
  const port = Number(process.env.ETOS_UI_SYNTHETIC_HOST_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535 || [3090, 5173, 8081, 8082, 8091, 8092].includes(port)) throw new Error('Set the test-only fixture control port');
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  try {
    const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('textbox', { name: '输入消息…' }).waitFor({ timeout: 60000 });
    const row = text => page.getByTestId('message-agent').filter({ hasText: text });
    const update = async stage => assert.equal((await fetch(`http://127.0.0.1:${port}/__test/reply/${stage}`, { method: 'POST' })).status, 204);
    await update(1);
    await row('第一句😀').waitFor();
    assert.equal(await row('未完成').count(), 0);
    const firstId = await row('第一句😀').getAttribute('id');
    await update(2);
    await row('第二句').waitFor();
    assert.equal(await row('第一句😀').count(), 1);
    assert.equal(await row('未完成').count(), 0);
    assert.notEqual(await row('第二句').getAttribute('id'), firstId);
    const secondId = await row('第二句').getAttribute('id');
    await update(3);
    await row('未完成').waitFor();
    assert.equal(await row('第一句😀').count(), 1);
    assert.equal(await row('第一句😀').getAttribute('id'), firstId);
    assert.equal(await row('第二句').getAttribute('id'), secondId);
    assert.deepEqual(errors, []);
    console.log('PASS: host reply ranges and preview-to-final bubble identity');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
