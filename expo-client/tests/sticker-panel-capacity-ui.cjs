const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { isolatedContext } = require('./ui-test-context.cjs');

const drawing = Buffer.from(fs.readFileSync('tests/fixtures/fixture-attachments.ts', 'utf8').match(/const drawing = '([^']+)'/)[1], 'base64');
const sticker = (prefix, index) => ({
  id: `${prefix}-${index}`,
  version: (index + (prefix === 'pack' ? 1000 : 1)).toString(16).padStart(64, '0'),
  name: `${prefix}${index}`, tags: [], mediaType: 'image/webp', available: true,
});

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  try {
    for (const count of [12, 24]) {
      const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
      const page = await context.newPage();
      const favorites = Array.from({ length: count }, (_, i) => sticker('fav', i));
      const pack = Array.from({ length: count }, (_, i) => sticker('pack', i));
      let gate = false, release, requests = 0;
      const held = new Promise(resolve => { release = resolve; });
      await page.route(url => url.pathname === '/api/stickers/favorites' || url.pathname === '/api/stickers/packs/fixture-pack', async route => {
        const items = new URL(route.request().url()).pathname.endsWith('favorites') ? favorites : pack;
        await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ stickers: items, nextCursor: null }) });
      });
      await page.route('**/api/stickers/media/**/thumbnail', async route => {
        const version = new URL(route.request().url()).pathname.split('/')[4];
        if (gate && favorites.some(item => item.version === version)) { requests++; await held; }
        await route.fulfill({ status: 200, contentType: 'image/webp', body: drawing }).catch(() => {});
      });
      try {
        await page.goto('http://127.0.0.1:8091/');
        await page.getByRole('button', { name: '表情', exact: true }).click({ timeout: 60000 });
        const visibleCount = (prefix, number) => page.waitForFunction(({ prefix, number }) =>
          [...document.querySelectorAll('button')].filter(element => element.textContent.startsWith(`发送表情 ${prefix}`) && element.querySelector('div[style*="background-image"]')).length === number,
        { prefix, number }, { timeout: 15000 });
        await visibleCount('fav', count);
        await page.getByRole('button', { name: '小绿的日常' }).click();
        await visibleCount('pack', count);
        gate = true;
        await page.getByRole('button', { name: '收藏', exact: true }).click();
        await page.getByRole('button', { name: '发送表情 fav0' }).waitFor();
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        const visible = await page.getByRole('button', { name: /^发送表情 fav/ }).locator('div[style*="background-image"]').count();
        console.log(`group_size=${count} returned_visible=${visible}/${count} repeat_thumbnail_requests=${requests}`);
        assert.equal(visible, count);
        assert.equal(requests, 0);
      } finally { release(); await context.close(); }
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
