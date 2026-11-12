const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');

(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  const errors = [];
  const external = [];
  page.on('pageerror', error => errors.push(error.message));
  const transparentPng = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAPElEQVR4nGNgGNTgf0DTfxAmWyM6pkgzUYYQ0kzQEIoMIFYzTkMoNmDgw4BYQ/BqJmQIUZqxGUSyRroCAIrMDhCz6+93AAAAAElFTkSuQmCC', 'base64');
  await page.route('**/api/chat/media/fixture-image/original', route => route.fulfill({ status: 200, contentType: 'image/png', body: transparentPng }));
  await page.route('https://image.example.test/transparent.png', async route => {
    external.push(route.request().headers());
    await route.fulfill({ status: 200, contentType: 'image/png', body: transparentPng });
  });
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    const input = page.getByRole('textbox', { name: '输入消息…' });
    await input.waitFor({ timeout: 60000 });
    const receivedSticker = page.getByTestId('message-agent').filter({ has: page.locator('img[alt="表情图片"]') });
    await receivedSticker.locator('img[alt="表情图片"]').waitFor();
    await page.waitForFunction(() => [...document.querySelectorAll('img[alt="表情图片"]')].some(image => image.naturalWidth === 16));
    await page.waitForFunction(() => [...document.querySelectorAll('img[alt="聊天图片"]')].some(image => image.naturalWidth === 16));
    const photo = page.locator('img[alt="聊天图片"]').first();
    const photoAlpha = await photo.evaluate(image => {
      const canvas = document.createElement('canvas'); canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
      const ctx = canvas.getContext('2d'); ctx.drawImage(image, 0, 0); return ctx.getImageData(0, 0, 1, 1).data[3];
    });
    assert.equal(photoAlpha, 0, 'transparent PNG attachment uses its original bytes');
    assert.equal(await receivedSticker.getByText('图片暂时不可用').count(), 0, 'a ready sticker is not reported as a missing image');
    const stickerStyle = await receivedSticker.locator('img[alt="表情图片"]').evaluate(image => ({ radius: getComputedStyle(image).borderRadius, background: getComputedStyle(image).backgroundColor }));
    assert.equal(stickerStyle.radius, '0px');
    assert.equal(stickerStyle.background, 'rgba(0, 0, 0, 0)');
    const alpha = await receivedSticker.locator('img[alt="表情图片"]').evaluate(image => {
      const canvas = document.createElement('canvas'); canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
      const ctx = canvas.getContext('2d'); ctx.drawImage(image, 0, 0);
      return [ctx.getImageData(0, 0, 1, 1).data[3], ctx.getImageData(8, 8, 1, 1).data[3]];
    });
    assert.deepEqual(alpha, [0, 255], 'sticker uses its transparent original, not the opaque preview');
    const markdown = '# 测试标题\n\n**加粗** 和行内 $x^2$\n\n$$\n\\frac{1}{2}\n$$\n\n```js\nconst x = 1;\n```';
    await input.fill(markdown);
    await page.getByRole('button', { name: '发送消息' }).click();
    const bubble = page.getByTestId('message-user').filter({ hasText: '测试标题' });
    await bubble.locator('h1').waitFor();
    assert.equal(await bubble.locator('strong').textContent(), '加粗');
    assert.equal(await bubble.locator('math').count(), 2, 'inline and display formulas use MathML on Web');
    assert.match(await bubble.locator('code').innerText(), /const x = 1/);
    const box = await bubble.boundingBox();
    assert.ok(box && box.x >= 0 && box.x + box.width <= 390, 'formatted message stays within the viewport');

    await input.fill('图片 **加粗** ![工作区图](fixture%20workspace/%E9%80%8F%E6%98%8E%20%25.png) 和 ![外部图](https://image.example.test/transparent.png)');
    await page.getByRole('button', { name: '发送消息' }).click();
    const withImages = page.getByTestId('message-user').filter({ hasText: '加粗' }).filter({ has: page.locator('img[alt="工作区图"]') });
    await withImages.locator('img[alt="工作区图"]').waitFor();
    await withImages.locator('img[alt="外部图"]').waitFor();
    await page.waitForFunction(() => [...document.querySelectorAll('img[alt="工作区图"], img[alt="外部图"]')].filter(image => image.naturalWidth > 0).length === 2);
    assert.equal(await withImages.locator('img[alt="外部图"]').getAttribute('src'), 'https://image.example.test/transparent.png', 'external image loads without a CORS-enabled fetch');
    assert.equal(await withImages.locator('strong').textContent(), '加粗', 'formatted text remains rendered alongside images');
    assert.equal(await withImages.locator('img[alt="工作区图"]').evaluate(image => getComputedStyle(image).objectFit), 'contain', 'inline images keep their aspect ratio');
    assert.equal(await withImages.locator('img[alt="工作区图"]').evaluate(image => getComputedStyle(image).borderRadius), '12px', 'inline photos have rounded corners');
    assert.ok(external.length > 0, 'external image is loaded');
    for (const headers of external) {
      assert.equal(headers.authorization, undefined, 'CFL bearer is never sent to an external image');
      assert.equal(headers.cookie, undefined, 'external image does not receive cookies');
    }
    await input.fill('<video src="https://example.invalid/private.mp4"></video>');
    await page.getByRole('button', { name: '发送消息' }).click();
    const video = page.getByTestId('message-user').filter({ hasText: '视频暂不支持显示' });
    await video.waitFor();
    assert.equal(await video.locator('video, source').count(), 0, 'unsupported video is an isolated placeholder');
    assert.deepEqual(errors, []);
    console.log('PASS: isolated Markdown, formulas, authenticated and external images, transparency, and sticker state');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
