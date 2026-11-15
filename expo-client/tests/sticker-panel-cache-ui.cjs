const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');
(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  let blanks = 0, tabs = 0, requests = 0;
  for (let trial = 1; trial <= 3; trial++) {
    const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
    const page = await context.newPage(); let block = false, release;
    const held = new Promise(resolve => { release = resolve; });
    await page.route('**/api/stickers/media/**/thumbnail', async route => { if (block) { requests++; await held; } await route.fallback().catch(() => {}); });
    try {
      await page.goto('http://127.0.0.1:8091/');
      await page.getByRole('button', { name: '表情', exact: true }).click({timeout:60000});
      const sticker = () => page.getByRole('button', { name: '发送表情 小绿' });
      await sticker().locator('div[style*="background-image"]').waitFor({ timeout: 15000 });
      await page.getByRole('button', { name: '小绿的日常' }).click();
      await sticker().locator('div[style*="background-image"]').waitFor({ timeout: 15000 });
      await page.getByRole('button', { name: '收藏', exact: true }).click();
      if (await sticker().locator('div[style*="background-image"]').count()) tabs++;
      await page.getByRole('button', { name: '关闭表情' }).click();
      await page.getByTestId('stickers-panel').waitFor({state:'hidden'});
      block = true;
      await page.getByRole('button', { name: '表情', exact: true }).click();
      await sticker().waitFor({timeout:12000});
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const visible = await sticker().locator('div[style*="background-image"]').count();
      if (!visible) blanks++;
      console.log(`trial ${trial}: reopened_while_thumbnail_held=${visible ? 'visible' : 'blank'}`);
    } finally { release(); await context.close(); }
  }
  await browser.close();
  console.log(`reopen_blank=${blanks}/3 group_switch_cached=${tabs}/3 gated_requests=${requests}`);
  assert.equal(blanks, 0, 'previously viewed sticker should remain visible while reopening');
})().catch(e => { console.error(e.message); process.exitCode = 1; });
