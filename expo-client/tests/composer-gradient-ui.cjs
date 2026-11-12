const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  try {
    const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByText('还在想，最近总觉得有点忙。', { exact: true }).waitFor({ timeout: 60000 });
    const mask = page.getByTestId('timeline-mask');
    const input = page.getByRole('textbox', { name: '输入消息…' });

    async function checkMask() {
      const result = await mask.evaluate(element => {
        const bounds = element.getBoundingClientRect();
        const scroll = [...element.querySelectorAll('div')].find(child => /auto|scroll/.test(getComputedStyle(child).overflowY));
        return { image: getComputedStyle(element).maskImage, height: bounds.height, scroll: !!scroll,
          composerInside: !!element.querySelector('[data-testid="floating-composer"]'),
          headerInside: !!element.querySelector('[data-testid="chat-topbar"]') };
      });
      assert.match(result.image, /linear-gradient.*20px.*20px/, 'the list has a 20px fade at both edges');
      assert.ok(result.height > 100 && result.scroll, 'the masked list retains its scroll viewport');
      assert.equal(result.composerInside, false, 'the composer stays outside the mask');
      assert.equal(result.headerInside, false, 'the header stays outside the mask');
    }

    await checkMask();
    const scrollRange = await mask.evaluate(element => {
      const scroll = [...element.querySelectorAll('div')].find(child => /auto|scroll/.test(getComputedStyle(child).overflowY));
      scroll.scrollTop = scroll.scrollHeight;
      return { offset: scroll.scrollTop, range: scroll.scrollHeight - scroll.clientHeight };
    });
    assert.ok(scrollRange.range > 0 && scrollRange.offset > 0, 'the masked message list can scroll');
    await input.fill('第一行\n第二行\n第三行\n第四行\n第五行');
    await page.waitForFunction(() => document.querySelector('textarea')?.getBoundingClientRect().height > 60);
    await checkMask();
    await page.setViewportSize({ width: 844, height: 390 });
    await checkMask();
    await page.getByRole('button', { name: '打开伴侣空间' }).click();
    await page.getByRole('button', { name: '返回聊天' }).click();
    await input.waitFor();
    await checkMask();
    assert.deepEqual(errors, []);
    console.log('PASS: only the timeline is masked in portrait, multiline, landscape and navigation');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
