const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 }, ...(process.env.ETOS_UI_DARK ? { colorScheme: 'dark' } : {}) });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const composer = page.getByRole('textbox', { name: '输入消息…' });
    await composer.waitFor({ timeout: 60000 });
    const query = `布局${Date.now()}`;
    const messages = [`${query}甲：第一条记录`, `${query}乙：第二条记录`];
    for (const text of messages) {
      await composer.fill(text);
      await page.getByRole('button', { name: '发送消息' }).click();
      await page.getByText(text, { exact: true }).waitFor();
    }
    await page.getByRole('button', { name: '搜索聊天记录', exact: true }).click();
    const dialog = page.getByRole('dialog');
    await dialog.getByText('聊天记录', { exact: true }).waitFor();
    const input = dialog.getByRole('textbox', { name: '搜索聊天记录' });
    await input.fill(query);
    await input.press('Enter');
    const first = dialog.getByRole('button', { name: messages[0] });
    const second = dialog.getByRole('button', { name: messages[1] });
    await first.waitFor(); await second.waitFor();
    assert.equal(await first.getByText('你', { exact: true }).count(), 1);
    const firstBox = await first.boundingBox(), secondBox = await second.boundingBox();
    assert.ok(firstBox && secondBox && firstBox.width > 300 && secondBox.y >= firstBox.y + firstBox.height - 1, 'results are full-width separate rows');
    assert.ok(parseFloat(await second.evaluate(node => getComputedStyle(node).borderTopWidth)) > 0, 'adjacent rows have a separator');
    assert.equal(await first.locator('[data-testid="search-highlight"]').count(), 1);
    await first.click();
    await dialog.getByTestId('search-context-user').getByText(messages[0]).waitFor();
    await dialog.getByRole('button', { name: '返回搜索结果' }).click();
    await second.waitFor();
    if (process.env.ETOS_UI_SCREENSHOT) await page.screenshot({ path: process.env.ETOS_UI_SCREENSHOT });
    console.log('PASS: search results have distinct full-width rows and open their contexts');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
