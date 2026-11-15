// Use a test-owned seed host with ETOS_UI_REMINDER_FIXTURE=1.
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  try {
    const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('textbox', { name: '输入消息…' }).waitFor({ timeout: 60000 });
    await page.getByRole('button', { name: '加载更早消息' }).click();
    const reminder = page.getByTestId('reminder-message').filter({ hasText: '合成长提醒' });
    const text = reminder.getByTestId('reminder-text');
    await reminder.waitFor({ timeout: 15000 });
    const before = await reminder.boundingBox();
    const geometry = await text.evaluate(node => {
      const row = node.closest('[data-testid="message-agent"]');
      const style = getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      const container = node.closest('[data-testid="reminder-message"]').getBoundingClientRect();
      return { containerTop: container.top, containerBottom: container.bottom, rowWidth: row?.getBoundingClientRect().width, textWidth: node.clientWidth, fullWidth: node.scrollWidth,
        top: rect.top, bottom: rect.bottom, overflow: style.overflow, textOverflow: style.textOverflow, whiteSpace: style.whiteSpace };
    });
    assert.ok(before && geometry.rowWidth && Math.abs(before.width - geometry.rowWidth) <= 1, 'reminder fills the assistant row');
    assert.ok(geometry.fullWidth > geometry.textWidth, 'fixture text exceeds available width');
    assert.equal(geometry.textOverflow, 'ellipsis', 'long text truncates at the edge');
    assert.equal(geometry.whiteSpace, 'nowrap', 'reminder stays on one line');
    assert.ok(geometry.top >= geometry.containerTop && geometry.bottom <= geometry.containerBottom, `text stays inside the reminder container: ${JSON.stringify({ before, geometry })}`);
    assert.equal(await reminder.getByRole('button').count(), 0, 'reminder is not a tap action');
    await reminder.click();
    const after = await reminder.boundingBox();
    assert.ok(after && Math.abs(after.height - before.height) <= 1, 'tapping does not expand the reminder');
    const shortReminder = page.getByTestId('reminder-message').filter({ hasText: '记得喝水' });
    const short = await shortReminder.boundingBox();
    assert.ok(short && Math.abs(short.height - before.height) <= 1, 'long and short reminders have the same single-line height');
    assert.deepEqual(errors, []);
    console.log('PASS: reminder fills the assistant row, truncates, and does not expand');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
