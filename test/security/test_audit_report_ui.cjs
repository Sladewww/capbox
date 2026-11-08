'use strict';
// Exercise the real file:// artifact; no HTTP server or application dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {execFileSync} = require('node:child_process');
const {chromium} = require(process.env.CAPBOX_PLAYWRIGHT_PATH || '../browser/node_modules/playwright');
const repo = path.resolve(__dirname, '../..');

(async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'capbox-audit-ui-'));
  const workspace = path.join(base, 'DEMO-模拟审计数据');
  const logs = path.join(workspace, '.capbox/logs');
  const preview = process.env.CAPBOX_AUDIT_PREVIEW_DIR;
  const report = path.join(preview || base, 'capbox-audit-report-demo.html');
  await fs.mkdir(logs, {recursive:true});
  if (preview) await fs.mkdir(preview, {recursive:true});
  const malicious = '</script><img src=x onerror="globalThis.auditInjected=1"><script>globalThis.auditInjected=2</script>';
  const events = Array.from({length:62}, (_,i) => ({ts:`2026-11-${i<31?'08':'09'}T${String(Math.floor((i%31)/2)).padStart(2,'0')}:${i%2?'30':'00'}:00Z`,
    kind:'exec',status:[7,30].includes(i)?'fail':[10,25].includes(i)?'warn':'ok',exit:[7,30].includes(i)?7:0,
    ms:(i+1)*10,cmd:i===60?'curl --token browser-fixture-secret':i%3===0?'python3 (+2 args)':'git (+3 args)',
    object:i===60?malicious:`task-${i}`,detail:i===7?'package query failed':'local task',profile:i%4===0?'strict':'untrusted',net:'none',distro:'alpine'}));
  events.push({ts:'2026-11-09T18:00:00Z',kind:'service',status:'start',object:'demo-http'},
              {ts:'2026-11-09T19:00:00Z',kind:'service',status:'stop',object:'demo-http'});
  const source = path.join(logs, 'audit.jsonl');
  await fs.writeFile(source, events.map(e=>JSON.stringify(e)+'\n').join('')+'{broken fixture}\n');
  const env = Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('CAPBOX_')&&!key.startsWith('_CAPBOX_')));
  execFileSync(path.join(repo,'bin/capbox'),['--root',workspace,'audit','report','--output',report,'--force'],{env,encoding:'utf8'});
  const html = await fs.readFile(report,'utf8');
  assert(!html.includes('browser-fixture-secret'));
  let browser;
  try {
    browser = await chromium.launch({headless:true,executablePath:process.env.CAPBOX_CHROMIUM_EXECUTABLE});
    const page = await browser.newPage({viewport:{width:1440,height:1000}});
    const errors = []; const violations=[];const requests=[];
    page.on('pageerror',error=>errors.push(String(error)));
    page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
    page.on('request',request=>requests.push(request.url()));
    await page.addInitScript(()=>{document.addEventListener('securitypolicyviolation',event=>{globalThis.auditCspViolations=(globalThis.auditCspViolations||[]).concat(event.violatedDirective);});});
    await page.goto(pathToFileURL(report).href);
    await page.waitForFunction(()=>document.getElementById('total-count').textContent==='64');
    assert.equal(await page.locator('#failure-count').textContent(),'2');
    assert.equal(await page.locator('#warning-count').textContent(),'2');
    assert.equal(await page.locator('#p95').textContent(),'590 ms');
    assert.equal(await page.locator('#event-rows tr').count(),50);
    assert.equal(await page.locator('#timeline svg').count(),1);
    assert((await page.locator('#coverage-note').textContent()).includes('跳过 1 条'));
    await page.locator('#next').click();
    assert.equal(await page.locator('#event-rows tr').count(),14);
    await page.locator('#previous').click();
    assert.equal(await page.locator('#event-rows tr').count(),50);
    await page.locator('#kind').selectOption('service');
    assert.equal(await page.locator('#total-count').textContent(),'2');
    await page.locator('.detail-button').first().click();
    assert(await page.locator('#event-detail').isVisible());
    const detail=JSON.parse(await page.locator('#raw-data').inputValue());
    assert.equal(detail.object,'demo-http');
    await page.keyboard.press('Escape');
    await page.locator('#reset').click();
    await page.locator('#from').fill('2026-11-08');
    await page.locator('#to').fill('2026-11-08');
    await page.locator('#to').dispatchEvent('change');
    assert.equal(await page.locator('#total-count').textContent(),'31');
    await page.locator('#reset').click();
    await page.locator('#search').fill('auditInjected');
    await page.waitForFunction(()=>document.getElementById('total-count').textContent==='1');
    await page.locator('.detail-button').click();
    assert((await page.locator('#detail-fields').textContent()).includes(malicious));
    assert.equal(await page.evaluate(()=>globalThis.auditInjected),undefined);
    assert.equal(await page.locator('#detail-fields img, #detail-fields script').count(),0);
    await page.locator('#close-detail').click();
    await page.locator('#reset').click();
    await page.locator('#status').selectOption('fail');
    const downloadEvent=page.waitForEvent('download');await page.locator('#export').click();
    const download=await downloadEvent;
    const exported=JSON.parse(await fs.readFile(await download.path(),'utf8'));
    assert.equal(exported.events.length,2);
    assert(exported.events.every(event=>event.status==='fail'));
    await page.locator('#reset').click();
    await page.locator('#search').fill('does-not-exist');
    await page.waitForFunction(()=>document.getElementById('total-count').textContent==='0');
    assert(await page.locator('#empty').isVisible());
    assert(await page.locator('#export').isDisabled());
    await page.locator('#reset').click();
    if(preview) await page.screenshot({path:path.join(preview,'capbox-audit-report-preview.png')});
    await page.setViewportSize({width:390,height:844});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth));
    await page.locator('#status').selectOption('fail');
    assert.equal(await page.locator('#total-count').textContent(),'2');
    await page.locator('.detail-button').first().click();
    assert(await page.locator('#event-detail').isVisible());await page.keyboard.press('Escape');
    await page.locator('#reset').click();
    if(preview) await page.screenshot({path:path.join(preview,'capbox-audit-report-mobile.png'),fullPage:true});
    violations.push(...await page.evaluate(()=>globalThis.auditCspViolations||[]));
    assert.deepEqual(violations,[]);
    assert.deepEqual(errors,[]);
    assert(!requests.some(url=>/^https?:/i.test(url)),requests);
    console.log('Browser report checks passed: stats, charts, pagination, filters, detail, JSON download, empty state, mobile, CSP, inert log text, zero network requests.');
  } finally {
    if(browser) await browser.close();
    await fs.rm(base,{recursive:true,force:true});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
