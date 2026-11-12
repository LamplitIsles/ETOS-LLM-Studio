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
    const message = '搜索图片校验!<image name=[Image #1] path="fixture workspace/透明 %.png"></image> 看这里<image name=[Image #2] path="fixture workspace/missing.png"></image>';
    await composer.fill(message);
    await page.getByRole('button', { name: '发送消息' }).click();
    await page.getByRole('button', { name: '搜索聊天记录', exact: true }).click();
    const dialog = page.getByRole('dialog');
    const input = dialog.getByRole('textbox', { name: '搜索聊天记录' });
    await input.fill('搜索图片校验');
    await input.press('Enter');
    await dialog.getByRole('button', { name: message }).first().click({ timeout: 5000 });
    const target = dialog.getByTestId('search-context-user').filter({ hasText: '搜索图片校验' }).last();
    const image = target.getByRole('img', { name: '聊天图片' });
    await image.waitFor();
    await page.waitForFunction(element => element.complete && element.naturalWidth > 0, await image.elementHandle());
    await target.getByText('图片暂时无法显示').waitFor();
    assert.equal(await target.getByRole('img', { name: '聊天图片' }).count(), 1, 'a missing image does not hide a valid one');
    console.log('PASS: search context loads a synthetic archive image through the CFL image route');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
