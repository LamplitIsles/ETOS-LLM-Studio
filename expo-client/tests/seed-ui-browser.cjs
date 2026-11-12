// Read-only check against the explicitly enabled local synthetic development host.
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByText('在线 · 开发数据').waitFor({ timeout: 60000 });
    await page.getByTestId('companion-avatar').waitFor({ timeout: 15000 });
    await page.getByTestId('chat-background').waitFor({ timeout: 15000 });
    const portrait = await page.getByTestId('chat-background').locator('img').getAttribute('src');
    await page.setViewportSize({ width: 844, height: 390 });
    await page.waitForFunction(previous => document.querySelector('[data-testid="chat-background"] img')?.getAttribute('src') !== previous, portrait);
    await page.waitForFunction(() => [...document.fonts].some(font => font.family.startsWith('MaterialSymbols_') && font.status === 'loaded'));
    assert.equal(await page.getByRole('navigation', { name: '底部导航' }).getByRole('button').count(), 5);
    assert.equal(await page.getByRole('textbox', { name: '输入消息' }).inputValue(), '');
    assert.deepEqual(errors, []);
    console.log('PASS: synthetic seed appearance, system symbols, and chat render (read-only)');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
