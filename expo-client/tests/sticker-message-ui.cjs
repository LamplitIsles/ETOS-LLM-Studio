const { chromium } = require('@playwright/test');
const { isolatedContext } = require('./ui-test-context.cjs');
const assert = require('node:assert/strict');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('button', { name: '表情', exact: true }).click({ timeout: 60000 });
    await page.getByRole('button', { name: '发送表情 小绿' }).click();
    await page.waitForFunction(() => [...document.querySelectorAll('img[alt="表情图片"]')].some(img => img.src.startsWith('data:image/webp') && getComputedStyle(img.parentElement).borderRadius === '12px'), null, { timeout: 10000 });
    const radii = await page.locator('img[alt="表情图片"]').evaluateAll(images => images.map(img => ({ type: img.src.slice(0, 15), radius: getComputedStyle(img.parentElement).borderRadius })));
    assert.ok(radii.some(image => image.type === 'data:image/webp' && image.radius === '12px'), 'opaque sticker is rounded');
    assert.ok(radii.some(image => image.type === 'data:image/png;' && image.radius === '0px'), 'transparent sticker retains its outline');
    console.log('PASS: opaque stickers are rounded and transparent stickers retain their outline');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
