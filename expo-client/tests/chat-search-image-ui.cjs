const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const composer = page.getByRole('textbox', { name: '输入消息…' });
    await composer.waitFor({ timeout: 60000 });
    const query = `图片校验${Date.now()}`;
    const message = `${query} **加粗**!<image name=[Image #1] path="fixture workspace/透明 %.png"></image> 看这里`;
    await composer.fill(message);
    await page.getByRole('button', { name: '发送消息' }).click();
    await page.getByRole('button', { name: '搜索聊天记录', exact: true }).click();
    const dialog = page.getByRole('dialog');
    const input = dialog.getByRole('textbox', { name: '搜索聊天记录' });
    await input.fill(query);
    await input.press('Enter');
    await dialog.getByRole('button', { name: message }).first().click({ timeout: 5000 });
    const target = dialog.getByTestId('search-context-user').filter({ hasText: query }).last();
    const image = target.getByRole('img', { name: '聊天图片' });
    await image.waitFor();
    await page.waitForFunction(element => element.complete && element.naturalWidth > 0, await image.elementHandle());
    assert.equal(await target.getByText(/<image name=/).count(), 0, 'image marker is replaced in the rendered message');
    assert.equal(await target.getByText('看这里').count(), 1, 'surrounding text is preserved');
    assert.equal(await target.locator('strong').getByText('加粗').count(), 1, 'Markdown formatting is preserved');
    const html = await target.innerHTML();
    assert.ok(html.indexOf('<img') < html.indexOf('看这里'), 'the image remains at the marker position');
    console.log('PASS: search context replaces a synthetic image marker through the CFL image route');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
