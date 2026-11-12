const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
(async () => {
 const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
 try {
  for (const reducedMotion of ['no-preference', 'reduce']) {
   const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 }, reducedMotion });
   const page = await context.newPage(); const errors=[]; page.on('pageerror', error => errors.push(error.message));
   await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
   const emoji = page.getByRole('button', { name: '表情', exact: true }); await emoji.waitFor({ timeout: 60000 });
   await emoji.click(); await page.getByRole('button', { name: '关闭表情' }).waitFor();
   await page.getByRole('button', { name: '关闭表情' }).click();
   await emoji.waitFor(); await page.getByRole('button', { name: '附件', exact: true }).click();
   await page.getByRole('button', { name: '选择文件' }).waitFor();
   await page.getByRole('button', { name: '关闭附件' }).click();
   await page.getByRole('dialog').waitFor({ state: 'hidden' });
   assert.deepEqual(errors, []); await context.close();
  }
  console.log('PASS: panel interactions with regular and reduced motion');
 } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
