const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  let releaseOriginal, originalRequested;
  const originalGate = new Promise(resolve => { releaseOriginal = resolve; });
  const originalStarted = new Promise(resolve => { originalRequested = resolve; });
  await page.route('**/api/stickers/media/**/original', async route => {
    originalRequested();
    await originalGate;
    await route.continue().catch(() => {});
  });
  let staged = 0;
  page.on('request', request => { if (new URL(request.url()).pathname === '/api/stickers/stage') staged++; });
  try {
    await page.goto('http://127.0.0.1:8091/');
    await page.getByRole('button', { name: '表情', exact: true }).click({ timeout: 60000 });
    const sticker = page.getByRole('button', { name: '发送表情 小绿' });
    await sticker.waitFor({ timeout: 15000 });
    await sticker.locator('div[style*="background-image"]').first().waitFor({ timeout: 15000 });
    const box = await sticker.boundingBox();
    assert.ok(box);
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    const preview = page.getByTestId('sticker-preview');
    await preview.waitFor({ timeout: 5000 });
    await Promise.race([originalStarted, new Promise((_, reject) => setTimeout(() => reject(new Error('original request did not start')), 5000))]);
    assert.equal(await preview.locator('div[style*="background-image"]').count(), 1, 'preview immediately shows the already loaded thumbnail while original is pending');
    const bubble = await preview.boundingBox();
    assert.ok(bubble && bubble.y + bubble.height <= box.y + 1, 'preview sits above the held sticker');
    assert.ok(bubble.x >= 0 && bubble.x + bubble.width <= 390, 'preview stays inside the viewport');
    await page.mouse.up();
    await preview.waitFor({ state: 'hidden' });
    assert.equal(staged, 0, 'holding and releasing must not send a sticker');
    console.log('preview appears above sticker, stays on screen and closes without sending');
  } finally { releaseOriginal(); await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
