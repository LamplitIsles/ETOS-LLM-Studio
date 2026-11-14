const { chromium } = require('@playwright/test');
const { isolatedContext } = require('./ui-test-context.cjs');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const input = page.getByRole('textbox', { name: '输入消息…' });
    await input.fill('第一行\n第二行\n第三行', { timeout: 60000 });
    await page.waitForFunction(element => element.getBoundingClientRect().height > 60, await input.elementHandle(), { timeout: 4000 });
    const inputBox = await input.boundingBox();
    const emojiBox = await page.getByRole('button', { name: '表情', exact: true }).boundingBox();
    assert.ok(Math.abs(inputBox.y + inputBox.height - emojiBox.y - emojiBox.height) <= 2, 'emoji aligns with the last line of a multiline input');
    console.log('PASS: emoji aligns with the last line');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
