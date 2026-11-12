// Requires test:ui:host started with ETOS_UI_SYNTHETIC_EXTRA_MESSAGES=173.
const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');

(async () => {
  const controlPort = Number(process.env.ETOS_UI_SYNTHETIC_HOST_PORT);
  if (!Number.isInteger(controlPort) || controlPort < 1 || controlPort > 65535 || [3090, 5173, 8081, 8082, 8091, 8092].includes(controlPort)) throw new Error('Set ETOS_UI_SYNTHETIC_HOST_PORT to the test-only fixture control port');
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  try {
    const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const mask = page.getByTestId('timeline-mask');
    await page.getByRole('textbox', { name: '输入消息…' }).waitFor({ timeout: 60000 });
    await page.waitForFunction(() => {
      const mask = document.querySelector('[data-testid="timeline-mask"]');
      return [...(mask?.querySelectorAll('div') ?? [])].some(e => /auto|scroll/.test(getComputedStyle(e).overflowY) && e.clientHeight > 0);
    });
    const anchors = ['还在想，最近总觉得有点忙。', '合成消息 143', '合成消息 113', '合成消息 083', '合成消息 053', '合成消息 023'];
    for (const label of anchors) {
      await page.mouse.move(180, 400);
      await page.mouse.wheel(0, -100000);
      await page.waitForFunction(() => {
        const mask = document.querySelector('[data-testid="timeline-mask"]');
        const scroll = [...(mask?.querySelectorAll('div') ?? [])].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY));
        return scroll && scroll.scrollTop <= 1;
      }, null, { timeout: 15000 });
      const oldHeight = await mask.evaluate(element => {
        const scroll = [...element.querySelectorAll('div')].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY));
        return scroll.scrollHeight;
      });
      const older = page.getByRole('button', { name: '加载更早消息' });
      await older.waitFor({ timeout: 15000 });
      const anchor = page.getByText(label, { exact: false }).first();
      await anchor.waitFor({ timeout: 15000 });
      const before = await anchor.boundingBox();
      const rowAnchor = await anchor.evaluate(node => {
        const row = node.closest('[id^="timeline-"]');
        return { id: row.id, top: row.getBoundingClientRect().top };
      });
      await older.click();
      await page.waitForFunction(height => {
        const mask = document.querySelector('[data-testid="timeline-mask"]');
        const scroll = [...(mask?.querySelectorAll('div') ?? [])].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY));
        return scroll && scroll.scrollHeight > height;
      }, oldHeight, { timeout: 15000 });
      await page.waitForFunction(({ id, top }) => {
        const node = document.getElementById(id);
        return node && Math.abs(node.getBoundingClientRect().top - top) <= 4;
      }, rowAnchor, { timeout: 3000 });
      await page.waitForTimeout(150);
      const after = await anchor.boundingBox();
      assert.ok(before && after && Math.abs(after.y - before.y) <= 4, `history insertion preserves ${label}: ${JSON.stringify({ before, after })}`);
    }
    // A test-owned host publishes an incoming message while the user reads history.
    await page.mouse.move(180, 400); await page.mouse.wheel(0, 1);
    const reading = page.getByText('合成消息 023', { exact: false }).first();
    const readingBefore = await reading.boundingBox();
    const beforeAppend = await mask.evaluate(element => [...element.querySelectorAll('div')].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY)).scrollHeight);
    assert.equal((await fetch(`http://127.0.0.1:${controlPort}/__test/append`, { method: 'POST' })).status, 204);
    await page.waitForFunction(height => {
      const element = document.querySelector('[data-testid="timeline-mask"]');
      const scroll = [...(element?.querySelectorAll('div') ?? [])].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY));
      return scroll && scroll.scrollHeight > height;
    }, beforeAppend, { timeout: 15000 });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const readingAfter = await reading.boundingBox();
    assert.ok(readingBefore && readingAfter && Math.abs(readingAfter.y - readingBefore.y) <= 4, `incoming messages do not interrupt reading: ${JSON.stringify({ readingBefore, readingAfter })}`);
    const down = page.getByRole('button', { name: '回到底部' });
    await down.click();
    await page.waitForFunction(() => {
      const mask = document.querySelector('[data-testid="timeline-mask"]');
      const scroll = [...(mask?.querySelectorAll('div') ?? [])].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY));
      return scroll && scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 5;
    }, null, { timeout: 15000 });
    const atBottom = await mask.evaluate(element => [...element.querySelectorAll('div')].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY)).scrollHeight);
    assert.equal((await fetch(`http://127.0.0.1:${controlPort}/__test/append`, { method: 'POST' })).status, 204);
    await page.waitForFunction(height => {
      const element = document.querySelector('[data-testid="timeline-mask"]');
      const scroll = [...(element?.querySelectorAll('div') ?? [])].find(e => /auto|scroll/.test(getComputedStyle(e).overflowY));
      return scroll && scroll.scrollHeight > height && scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight < 5;
    }, atBottom, { timeout: 15000 });
    assert.deepEqual(errors, []);
    console.log('PASS: 180-message timeline preserves history, reading position and near-bottom follow');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
