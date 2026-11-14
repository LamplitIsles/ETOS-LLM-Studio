// Run with a fresh test-owned host, held submissions and partial-image fixture enabled.
const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

(async () => {
  const controlPort = Number(process.env.ETOS_UI_SYNTHETIC_HOST_PORT);
  if (!Number.isInteger(controlPort) || controlPort < 1024 || controlPort > 65535 || [3090, 5173, 8081, 8082, 8091, 8092, 18093].includes(controlPort)) throw new Error('Expected a test-owned fixture control port');
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const input = page.getByRole('textbox', { name: '输入消息…' });
    await input.waitFor({ timeout: 60000 });
    await page.getByRole('button', { name: '附件', exact: true }).click();
    const chooser = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: '选择照片', exact: true }).click();
    const data = fs.readFileSync('tests/fixtures/fixture-art.ts', 'utf8').match(/'([A-Za-z0-9+/=]+)'/)[1];
    const image = Buffer.from(data, 'base64');
    await (await chooser).setFiles([{ name: 'one.png', mimeType: 'image/png', buffer: image }, { name: 'two.png', mimeType: 'image/png', buffer: image }]);
    await page.getByRole('button', { name: '移除附件 two.png' }).waitFor();
    await page.getByRole('button', { name: '附件', exact: true }).click();
    const fileChooser = page.waitForEvent('filechooser');
    await page.getByRole('button', { name: '选择文件', exact: true }).click();
    await (await fileChooser).setFiles({ name: 'synthetic.txt', mimeType: 'text/plain', buffer: Buffer.from('fixture') });
    await page.getByRole('button', { name: '移除附件 synthetic.txt' }).waitFor();
    await input.fill('合成双图');
    await page.getByRole('button', { name: '发送消息', exact: true }).click();
    const bubble = page.getByTestId('message-user').filter({ hasText: '合成双图' });
    await bubble.waitFor({ timeout: 15000 });
    await bubble.getByText('文件 · synthetic.txt').waitFor();
    const images = bubble.locator('img[alt="聊天图片"]');
    await images.nth(1).waitFor({ timeout: 15000 });
    const firstSource = await images.nth(0).getAttribute('src');
    const secondSource = await images.nth(1).getAttribute('src');
    assert.ok(firstSource?.startsWith('blob:') && secondSource?.startsWith('blob:') && firstSource !== secondSource);
    const released = await fetch(`http://127.0.0.1:${controlPort}/__test/send/release`, { method: 'POST' });
    assert.equal(released.status, 204);
    await page.getByText('我听到了。我们可以慢慢聊，你现在最想从哪儿说起？', { exact: true }).waitFor({ timeout: 15000 });
    await page.waitForFunction(() => [...document.querySelectorAll('[data-testid="message-user"]')].filter(row => row.textContent.includes('合成双图')).some(row => [...row.querySelectorAll('img[alt="聊天图片"]')].some(image => image.src.startsWith('data:') && image.naturalWidth > 0)), null, { timeout: 15000 });
    assert.equal(await images.count(), 2, 'a server message omitting one image preserves its local preview');
    assert.equal(await bubble.getByText('文件 · synthetic.txt').count(), 1, 'a server message omitting the file preserves its local label');
    if (process.env.ETOS_UI_PARTIAL_IMAGES === 'first') {
      assert.ok((await images.nth(0).getAttribute('src'))?.startsWith('data:'), 'the received first image replaces only its own preview');
      assert.equal(await images.nth(1).getAttribute('src'), secondSource, 'the omitted second image stays in its original position');
    } else {
      assert.equal(await images.nth(0).getAttribute('src'), firstSource, 'the omitted first image remains the first local preview');
      assert.ok((await images.nth(1).getAttribute('src'))?.startsWith('data:'), 'the received second image replaces only its own preview');
    }
    console.log('PASS: partial server images preserve the right local preview by attachment identity');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
