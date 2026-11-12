const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('button', { name: '搜索聊天记录', exact: true }).click({ timeout: 60000 });
    const dialog = page.getByRole('dialog');
    const input = dialog.getByRole('textbox', { name: '搜索聊天记录' });
    await input.fill('最近总觉得');
    if (process.env.SEARCH_CONTROL === 'button') await dialog.getByRole('button', { name: '搜索', exact: true }).click();
    else await input.press('Enter');
    await dialog.getByRole('button', { name: '还在想，最近总觉得有点忙。' }).waitFor({ timeout: 4000 });
    await dialog.getByTestId('search-highlight').getByText('最近总觉得').waitFor({ timeout: 4000 });
    await dialog.getByRole('button', { name: '关闭聊天搜索' }).click();
    await page.getByRole('textbox', { name: '输入消息…' }).fill('搜索测试 **格式标记**');
    await page.getByRole('button', { name: '发送消息' }).click();
    await page.getByRole('button', { name: '搜索聊天记录', exact: true }).click();
    await dialog.getByRole('textbox', { name: '搜索聊天记录' }).fill('格式标记');
    await dialog.getByRole('textbox', { name: '搜索聊天记录' }).press('Enter');
    await dialog.getByRole('button', { name: '搜索测试 **格式标记**' }).first().click({ timeout: 4000 });
    await dialog.locator('strong').getByText('格式标记').first().waitFor({ timeout: 4000 });
    const user = dialog.getByTestId('search-context-user').last();
    const assistant = dialog.getByTestId('search-context-assistant').first();
    await user.waitFor(); await assistant.waitFor();
    const [userBox, assistantBox] = await Promise.all([user.boundingBox(), assistant.boundingBox()]);
    assert.ok(userBox && assistantBox && userBox.x > assistantBox.x, 'user and assistant context bubbles should align on opposite sides');
    assert.equal(await dialog.getByText('伙伴', { exact: true }).count(), 0);
    assert.equal(await dialog.getByText('你', { exact: true }).count(), 0);
    console.log('PASS: Enter, highlighted results, Markdown, and separate user/assistant context bubbles');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
