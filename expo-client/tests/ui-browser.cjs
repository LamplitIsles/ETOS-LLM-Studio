const { isolatedContext } = require('./ui-test-context.cjs');
const { chromium } = require('@playwright/test');
const assert = require('node:assert/strict');
(async () => {
 const browser = await chromium.launch({headless:true,...(process.env.CHROME_PATH ? {executablePath:process.env.CHROME_PATH} : {}),args:['--no-sandbox']});
 for (const status of ['signed_out', 'unavailable']) {
  const startup = await isolatedContext(browser, {viewport:{width:390,height:844}}, status);
  const screen = await startup.newPage();
  await screen.goto('http://127.0.0.1:8091/', {waitUntil:'domcontentloaded', timeout:60000});
  await screen.getByRole('button', {name:'登录', exact:true}).waitFor({timeout:60000});
  await screen.waitForFunction(() => !document.body.innerText.includes('正在恢复连接…'));
  if (status === 'unavailable') await screen.getByText('无法连接，请检查服务地址。').waitFor();
  await startup.close();
 }
 const context = await isolatedContext(browser, {viewport:{width:Number(process.env.ETOS_TEST_WIDTH || 390),height:844},deviceScaleFactor:1}); const page = await context.newPage(); const errors=[];page.on('pageerror',e=>errors.push(e.message));
 try {
  await page.goto('http://127.0.0.1:8091/',{waitUntil:'domcontentloaded',timeout:60000});
  await page.getByRole('button',{name:'打开伴侣空间'}).waitFor({timeout:60000});
  await page.getByTestId('message-agent').first().waitFor();
  const agent = await page.getByTestId('message-agent').first().boundingBox();
  const user = await page.getByTestId('message-user').first().boundingBox();
  assert.ok(agent && user && agent.width > user.width, 'agent row has more horizontal room');
  assert.ok(Math.abs(agent.x - (page.viewportSize().width - agent.x - agent.width)) <= 1, 'agent row has symmetric margins');
  assert.equal(await page.getByTestId('bottom-navigation').count(),0,'chat does not show a tab bar');
  const input = page.getByRole('textbox',{name:'输入消息…'});
  await input.fill('保留的草稿');
  await page.getByRole('button',{name:'打开伴侣空间'}).click();
  const back = page.getByRole('button',{name:'返回聊天'});
  const backTarget = await back.boundingBox();
  assert.ok(backTarget && backTarget.width >= 44 && backTarget.height >= 44, 'back button has a comfortable navigation target');
  const navigation = page.getByRole('navigation', {name:'伴侣空间导航'});
  await navigation.waitFor();
  for (const name of ['纪念','日记','相册','唤醒']) {
   const item=navigation.getByRole('button',{name});
   const target=await item.boundingBox(); assert.ok(target && target.width>=44 && target.height>=44);
   await item.click(); await page.getByText(name,{exact:true}).first().waitFor();
  }
  await back.click();
  assert.equal(await input.inputValue(),'保留的草稿','navigation preserves the chat draft');
  await input.fill('测试发送');
  await page.getByRole('button',{name:'发送消息'}).click();
  await page.getByText('测试发送',{exact:true}).waitFor({timeout:15000});
  await page.waitForFunction(() => document.querySelector('textarea')?.value === '', null, {timeout:15000});
  await page.getByText('我听到了。我们可以慢慢聊，你现在最想从哪儿说起？').waitFor();
  await page.getByRole('button',{name:'加载更早消息'}).click(); await page.getByText('上次你说周末想出去走走，后来选好地方了吗？').waitFor();
  await page.getByRole('button',{name:'打开伴侣空间'}).click(); await page.getByRole('button',{name:'切换连接'}).click(); await page.getByText('回到对话').waitFor();
  assert.deepEqual(errors,[]); console.log('PASS: isolated login, chat, space tabs, draft preservation and send');
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1});
