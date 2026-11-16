// Test-only seed proxy and Metro; the Bark endpoint below is an in-memory fake.
const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}), args: ['--no-sandbox'] });
  const context = await isolatedContext(browser, { viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  let configured = false, enabled = false, writes = 0, loseReply = false, tests = 0, loseTestReply = false, testDisabled = false;
  await page.route('**/api/bark/test', async route => {
    assert.equal(route.request().method(), 'POST');
    assert.deepEqual(route.request().postDataJSON(), {});
    tests++;
    if (loseTestReply) { loseTestReply = false; return route.abort(); }
    if (testDisabled) { testDisabled = false; return route.fulfill({ status: 409, contentType: 'application/json', body: JSON.stringify({ error: { code: 'bark_disabled', message: 'fixture' } }) }); }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ status: 'accepted' }) });
  });
  await page.route('**/api/bark/settings', async route => {
    if (route.request().method() === 'POST') {
      const body = route.request().postDataJSON(); writes++;
      if (body.action === 'set') { assert.equal(body.key, 'fixture-only-key'); enabled = configured ? enabled : true; configured = true; }
      if (body.action === 'disable') enabled = false;
      if (body.action === 'enable') enabled = true;
      if (body.action === 'remove') { configured = false; enabled = false; }
      if (loseReply) { loseReply = false; return route.abort(); }
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ configured, enabled }) });
  });
  try {
    await page.goto('http://127.0.0.1:8091/', { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.getByRole('button', { name: '设置', exact: true }).click({ timeout: 60000 });
    const settings = page.getByRole('dialog');
    const navigation = settings.getByRole('navigation', { name: '设置导航' });
    for (const name of ['外观', '模型', '语音', '通知']) {
      const tab = navigation.getByRole('button', { name: new RegExp(`^${name}`) });
      const bounds = await tab.boundingBox();
      assert.ok(bounds && bounds.width >= 44 && bounds.height >= 44, `${name} tab has a usable touch target`);
    }
    await navigation.getByRole('button', { name: '通知', exact: true }).click();
    await settings.getByText('尚未配置 Bark key').waitFor().catch(async error => { console.error('Settings:', await settings.innerText()); throw error; });
    const testButton = settings.getByRole('button', { name: '发送测试通知' });
    assert.equal(await testButton.isDisabled(), true);
    const key = settings.getByRole('textbox', { name: 'Bark key' });
    assert.equal(await key.getAttribute('type'), 'password');
    const bounds = await key.boundingBox();
    assert.ok(bounds && bounds.width > 100 && bounds.height >= 40, 'secret input is visible and usable');
    await key.fill('fixture-only-key');
    await settings.getByRole('button', { name: '保存', exact: true }).click();
    await settings.getByText('已配置 Bark key').waitFor();
    assert.equal(await key.inputValue(), '');
    await testButton.click();
    await settings.getByText('测试请求已提交，请查看 Bark 通知。').waitFor();
    assert.equal(tests, 1);
    loseTestReply = true;
    await testButton.click();
    await settings.getByText('发送结果未确认，通知可能已送达，请先查看 Bark。').waitFor();
    assert.equal(tests, 2, 'uncertain test notifications are not automatically retried');
    testDisabled = true;
    await testButton.click();
    await settings.getByText('通知已关闭，请刷新设置后开启。').waitFor();
    await settings.getByRole('button', { name: '刷新通知设置' }).click();
    await settings.getByRole('button', { name: '通知：开' }).waitFor();
    assert.equal(tests, 3, 'refresh does not replay the test notification');
    await settings.getByRole('button', { name: '通知：开' }).click();
    await settings.getByRole('button', { name: '通知：关' }).waitFor();
    assert.equal(await testButton.isDisabled(), true);
    loseReply = true;
    await settings.getByRole('button', { name: '通知：关' }).click();
    await settings.getByText('保存结果未确认，请刷新设置。').waitFor();
    assert.equal(writes, 3, 'ambiguous writes are not retried');
    await settings.getByRole('button', { name: '刷新通知设置' }).click();
    await settings.getByRole('button', { name: '通知：开' }).waitFor();
    assert.equal(writes, 3, 'refresh does not replay the write');
    await settings.getByRole('button', { name: '删除 Bark key' }).click();
    await settings.getByText('尚未配置 Bark key').waitFor();
    loseReply = true;
    await key.fill('fixture-only-key');
    await settings.getByRole('button', { name: '保存', exact: true }).click();
    await settings.getByText('保存结果未确认。刷新只能查看是否已配置，不能确认此次 key 是否生效。').waitFor();
    assert.equal(writes, 5, 'uncertain key saves are not retried');
    await settings.getByRole('button', { name: '刷新通知设置' }).click();
    await settings.getByText('已配置 Bark key').waitFor();
    assert.equal(writes, 5);
    console.log('PASS: Bark settings, masked key, uncertain write and explicit refresh');
  } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
