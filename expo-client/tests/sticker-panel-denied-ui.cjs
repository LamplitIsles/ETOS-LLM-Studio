const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  let deny = false;
  await page.route(url => url.pathname === '/api/stickers/favorites', async route => {
    if (deny) await route.fulfill({ status: 403 }); else await route.fallback();
  });
  try {
    await page.goto('http://127.0.0.1:8091/');
    await page.getByRole('button', { name: '表情', exact: true }).click({ timeout: 60000 });
    const sticker = page.getByRole('button', { name: '发送表情 小绿' });
    await sticker.locator('div[style*="background-image"]').waitFor({ timeout: 15000 });
    await page.getByRole('button', { name: '关闭表情' }).click();
    await page.getByTestId('stickers-panel').waitFor({ state: 'hidden' });
    deny = true;
    await page.getByRole('button', { name: '表情', exact: true }).click();
    await page.getByText('登录已失效，重新登录').waitFor({ timeout: 15000 });
    assert.equal(await sticker.count(), 0, 'known denial must remove cached sticker controls');
    console.log('access denial removes cached sticker controls');
  } finally {
    await context.close();
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
