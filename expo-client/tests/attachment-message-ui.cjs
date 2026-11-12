const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  try {
    const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('button', { name: '附件', exact: true }).waitFor({ timeout: 60000 });
    await page.getByRole('button', { name: '附件', exact: true }).click();
    const chooser = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: '选择照片' }).click();
    const encoded = fs.readFileSync('tests/fixtures/fixture-art.ts', 'utf8').match(/'([A-Za-z0-9+/=]+)'/)[1];
    const png = Buffer.from(encoded, 'base64');
    const large = Buffer.alloc(8_000_001); png.copy(large);
    await (await chooser).setFiles({ name: 'synthetic.png', mimeType: 'image/png', buffer: large });
    const alert = page.getByRole('alert').filter({ hasText: '图片大小约为 8.0 MB，超过当前服务单张上限（约 8.0 MB）。' });
    await alert.waitFor({ timeout: 15000 });
    assert.equal(await alert.evaluate(node => getComputedStyle(node.parentElement).backgroundColor), 'rgb(255, 255, 255)');
    assert.equal(await page.getByRole('button', { name: '移除附件 synthetic.png' }).count(), 0);
    assert.deepEqual(errors, []);
    console.log('PASS: oversized image explains service limit before preview');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
