const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const port = Number(process.env.ETOS_UI_SYNTHETIC_HOST_PORT);
  if (!Number.isInteger(port) || port < 1024 || [3090, 5173, 8081, 8082, 8091, 8092].includes(port)) throw new Error('Expected test-only host port');
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 480 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('button', { name: '搜索聊天记录' }).waitFor({ timeout: 60000 });
    for (let i = 0; i < 9; i++) {
      const response = await fetch(`http://127.0.0.1:${port}/__test/append`, { method: 'POST' });
      if (!response.ok) throw new Error(`fixture append: ${response.status}`);
    }
    await page.getByRole('button', { name: '搜索聊天记录' }).click();
    const dialog = page.getByRole('dialog');
    const input = dialog.getByRole('textbox', { name: '搜索聊天记录' });
    await input.fill('合成实时消息 5'); await input.press('Enter');
    await dialog.getByRole('button', { name: '合成实时消息 5', exact: true }).click({ timeout: 5000 });
    const selected = dialog.getByTestId('search-context-user').filter({ hasText: '合成实时消息 5' });
    await selected.waitFor();
    await assertEventually(async () => {
      const [message, viewport] = await Promise.all([selected.boundingBox(), dialog.getByTestId('search-context-scroll').boundingBox()]);
      assert.ok(message && viewport && message.y >= viewport.y - 1 && message.y + Math.min(message.height, 20) <= viewport.y + viewport.height + 1, 'matched message should be visible in the search viewport');
    });
    const scroll = dialog.getByTestId('search-context-scroll');
    const before = await scroll.evaluate(element => element.scrollTop);
    await scroll.hover(); await page.mouse.wheel(0, -400);
    await assertEventually(async () => assert.ok(await scroll.evaluate(element => element.scrollTop) < before - 20, 'manual scrolling should move away from the target'));
    const after = await scroll.evaluate(element => element.scrollTop);
    await page.addStyleTag({ content: '[data-testid="search-context-user"] { padding-bottom: 20px; }' });
    await page.waitForTimeout(500);
    assert.ok(await scroll.evaluate(element => element.scrollTop) < before - 20, `content relayout should not take over manual scrolling (previous ${after})`);
    await dialog.getByRole('button', { name: '返回搜索结果' }).click();
    await input.fill('上次你说'); await input.press('Enter');
    await dialog.getByRole('button', { name: '上次你说周末想出去走走，后来选好地方了吗？', exact: true }).click();
    const firstScroll = dialog.getByTestId('search-context-scroll');
    await assertEventually(async () => assert.equal(await firstScroll.evaluate(element => element.scrollTop), 0));
    await dialog.getByRole('button', { name: '返回搜索结果' }).click();
    await input.fill('我听到了'); await input.press('Enter');
    await dialog.getByRole('button', { name: '我听到了。我们可以慢慢聊，你现在最想从哪儿说起？', exact: true }).last().click();
    const lastScroll = dialog.getByTestId('search-context-scroll');
    await assertEventually(async () => assert.ok(await lastScroll.evaluate(element => Math.abs(element.scrollHeight - element.clientHeight - element.scrollTop) < 2), 'last result should align to the end'));
    console.log('PASS: first, middle and last search targets; manual scrolling survives relayout');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });

async function assertEventually(check) {
  let last;
  for (let i = 0; i < 20; i++) {
    try { await check(); return; } catch (error) { last = error; await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  throw last;
}
