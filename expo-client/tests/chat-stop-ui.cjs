const { chromium } = require('@playwright/test');
const { isolatedContext } = require('./ui-test-context.cjs');

(async () => {
  const port = Number(process.env.ETOS_UI_SYNTHETIC_HOST_PORT);
  if (!Number.isInteger(port) || port < 1024 || [3090, 5173, 8081, 8082, 8091, 8092].includes(port)) throw new Error('Expected test-only host port');
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('button', { name: '上下文', exact: true }).waitFor({ timeout: 60000 });
    const response = await fetch(`http://127.0.0.1:${port}/__test/turn/start`, { method: 'POST' });
    if (!response.ok) throw new Error(`fixture start: ${response.status}`);
    await page.getByRole('button', { name: '停止回复', exact: true }).click({ timeout: 4000 });
    await page.getByRole('button', { name: '上下文', exact: true }).waitFor({ timeout: 4000 });
    console.log('PASS: active turn can be stopped');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
